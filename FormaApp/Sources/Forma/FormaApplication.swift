import AppKit
import FormaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct FormaApplication: App {
    @NSApplicationDelegateAdaptor(FormaAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Forma", id: "workspace") {
            FormaRoot(state: delegate.state)
        }
        .defaultSize(width: 1180, height: 700)
        // No `windowResizability`, no fixed sizes: the window stays genuinely
        // user-resizable (owner failure #1/#2 were nested split views forcing
        // frame growth, not a missing constraint). One shell owns the columns;
        // every pane inside is flexible with declared bounds.

        Settings {
            ProbesView()
        }
    }
}

/// The application's lifecycle owner.
///
/// Startup and shutdown live here rather than in a view's `.task`, because a view
/// can be recreated at any time and quitting must not depend on which view
/// happens to be mounted. Cleanup runs in `applicationWillTerminate`, which
/// cannot delay quitting at all — the strongest form of "must not block".
/// Everything worth keeping is already durable: a cancelled scan loses its
/// in-progress step, not its record, and the next launch sweeps an interrupted
/// import.
@MainActor
final class FormaAppDelegate: NSObject, NSApplicationDelegate {
    let state = FormaApplicationState()
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didStart else { return }
        didStart = true
        // The trace sink goes in before any model exists, so no instrumented
        // stage of the first window can run unhooked. With no Instruments
        // session attached the sink writes nothing, and each stage costs one
        // closure test.
        FormaPerf.install()
        Task { await state.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.prepareForTermination()
    }
}

@MainActor
final class FormaApplicationState: ObservableObject {
    enum Launch {
        case starting
        case ready(SourceWorkspace)
        /// The store or ledger could not be opened. No write may be attempted and
        /// no recovery sweep has run.
        case degraded(FormaError)
    }

    @Published private(set) var launch: Launch = .starting
    @Published private(set) var recovery: ImportRecoveryOverview = .empty
    @Published private(set) var recoveryFailure: FormaError?
    /// Why the read-only recheck cannot run, in a stable code.
    @Published private(set) var recoveryReviewReason: String?
    /// The scope a person confirmed for the recheck. Session only: it is a
    /// statement about now, not a preference to remember.
    @Published private(set) var recoveryScope: ImportRecoveryScopeConfirmation?
    @Published private(set) var recoveryReview: ImportRecoveryReviewReport?
    @Published private(set) var recoveryReviewInFlight = false

    private var shutdownHandlers: [() -> Void] = []

    func start() async {
        let directory = URL.applicationSupportDirectory.appending(path: "Forma", directoryHint: .isDirectory)
        let workspace: SourceWorkspace
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            workspace = try SourceWorkspace(databaseURL: directory.appending(path: "workspace.sqlite"))
        } catch {
            FormaDiagnostics.failure(.openWorkspace, .storage)
            launch = .degraded(.storage)
            return
        }

        do {
            // The sweep is the first thing a process does; it is also the reason
            // "no record" and "we do not know" stay different states.
            recovery = try await workspace.importRecoveryOverview()
        } catch {
            FormaDiagnostics.failure(.openWorkspace, (error as? FormaError) ?? .storage)
            recoveryFailure = (error as? FormaError) ?? .storage
        }
        if recovery.requiresReview {
            // A scope has to be confirmed before anything can be read back; until
            // then the operations stay `verify_required` and nothing retries.
            recoveryReviewReason = "no_authorized_scope"
        }
        launch = .ready(workspace)
    }

    /// Records the scope a person explicitly confirmed for the read-only check.
    ///
    /// Validation lives in `RecoveryScopeDraft` (FormaCore) so the sheet and its
    /// tests agree on what "valid" means. A refused confirmation writes nothing:
    /// the form owns its own error text, and the application-level reason is for
    /// the banner only. Mixing the two is what left a valid form showing a stale
    /// error (field defect A).
    func confirmRecoveryScope(_ draft: RecoveryScopeDraft) {
        guard case .ready(let scope) = draft.validation else { return }
        recoveryScope = scope
        // Clear a stale refusal from an earlier build or session if one lingers.
        if recoveryReviewReason == "invalid_scope" { recoveryReviewReason = nil }
    }

    /// The read-only recheck.
    ///
    /// It needs a confirmed scope; without one it refuses and says why. It reads
    /// through an independent client, updates only what this screen shows, and
    /// never writes to DEVONthink or to the ledger — an inconclusive result leaves
    /// the operation in `verify_required`.
    func requestRecoveryRecheck() async {
        guard recovery.requiresReview else {
            recoveryReviewReason = "nothing_to_review"
            return
        }
        guard case .ready = launch, recoveryFailure == nil else {
            recoveryReviewReason = "workspace_unavailable"
            return
        }
        guard let scope = recoveryScope else {
            recoveryReviewReason = "no_authorized_scope"
            return
        }
        guard let databaseID = UUID(uuidString: scope.databaseID) else {
            recoveryReviewReason = "invalid_scope"
            return
        }
        recoveryReviewInFlight = true
        defer { recoveryReviewInFlight = false }

        let client = DEVONthinkReadOnlyClient()
        let adapter = DEVONthinkImportReadAdapter(client: client, databaseID: databaseID)
        let coordinator = ImportRecoveryCoordinator(read: adapter)
        recoveryReview = await coordinator.review(recovery.entries, scope: scope)
        await client.close()
    }

    /// Registered cancellation hooks. They are synchronous on purpose: quitting
    /// must not depend on a task finishing, and the ledger is already durable.
    func registerShutdown(_ handler: @escaping () -> Void) {
        shutdownHandlers.append(handler)
    }

    /// Stops new work. It returns immediately: quitting must never wait for a
    /// task, and intents plus observations are already durable.
    func prepareForTermination() {
        let handlers = shutdownHandlers
        shutdownHandlers.removeAll()
        for handler in handlers { handler() }
    }
}

@MainActor
private struct FormaRoot: View {
    @ObservedObject var state: FormaApplicationState

    var body: some View {
        switch state.launch {
        case .starting:
            ProgressView("Opening workspace…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let workspace):
            WorkspaceAreas(workspace: workspace, state: state)
        case .degraded(let error):
            ContentUnavailableView(
                "Workspace unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(error.localizedDescription))
        }
    }
}

/// Column widths for the whole app. Every split in the window is bounded here,
/// once, so no area can drag the frame wider than its own geometry (owner
/// failure #2: three per-tab split views each insisted on their own minimums).
struct AreaWidth {
    let min: CGFloat
    let ideal: CGFloat
    let max: CGFloat
}

enum ShellGeometry {
    static let sidebar = AreaWidth(min: 132, ideal: 168, max: 230)
    static let inspector = AreaWidth(min: 260, ideal: 340, max: 520)
    static let workspaceLeading = AreaWidth(min: 150, ideal: 190, max: 280)
    static let mappingLeading = AreaWidth(min: 240, ideal: 300, max: 420)
    static let exceptionsLeading = AreaWidth(min: 210, ideal: 260, max: 360)
}

extension View {
    /// Applies one shell-declared width bound to a pane.
    func areaWidth(_ width: AreaWidth) -> some View {
        frame(minWidth: width.min, idealWidth: width.ideal, maxWidth: width.max)
    }
}

extension WorkspaceModel.PlannerMode {
    /// The persisted app mode as the command grammar's vocabulary.
    var grammar: PlannerMode { PlannerMode(rawValue: rawValue) ?? .offline }
}

/// The one scene-owned shell: area navigation, the shared status surface, the
/// per-area toolbar grammar, the contextual inspector, and the panels those
/// commands open. All five areas are driven by one orchestration model so a
/// scan, a context revision, a manifest and an export bundle stay the same
/// objects in every area instead of being recomputed per view; nothing here
/// computes a value FormaCore owns.
@MainActor
private struct WorkspaceAreas: View {
    @StateObject private var model: WorkspaceModel
    @ObservedObject var state: FormaApplicationState

    @AppStorage("shell.selectedArea") private var storedArea: String = AppArea.workspace.rawValue
    @AppStorage("shell.inspectorVisible") private var inspectorVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var bundleImporting = false
    @State private var egressConfirmation = false

    init(workspace: SourceWorkspace, state: FormaApplicationState) {
        _model = StateObject(wrappedValue: WorkspaceModel(workspace: workspace))
        self.state = state
    }

    private var selection: AppArea { AppArea.restored(from: storedArea) }

    /// The sidebar's selection binding: reads normalize a stale stored value to
    /// a real area, writes persist the raw value.
    private var selectionBinding: Binding<AppArea> {
        Binding(
            get: { AppArea.restored(from: storedArea) },
            set: { storedArea = $0.rawValue }
        )
    }

    private var commands: [ToolbarCommand] {
        ShellCommands.commands(for: selection,
                               phase: BusyState(isBusy: model.phase.isBusy),
                               planner: model.plannerMode.grammar)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selectionBinding) {
                ForEach(AppArea.allCases) { area in
                    Label(area.title, systemImage: area.systemImage)
                        .tag(area)
                        .accessibilityIdentifier("area-\(area.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: ShellGeometry.sidebar.min,
                                            ideal: ShellGeometry.sidebar.ideal,
                                            max: ShellGeometry.sidebar.max)
            .accessibilityIdentifier("area-navigation")
        } detail: {
            VStack(spacing: 0) {
                if state.recovery.requiresReview || state.recoveryFailure != nil {
                    ImportRecoveryBanner(state: state)
                    Divider()
                }
                statusStrip
                areaContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("area-\(selection.rawValue)-content")
                    // Panel appearance is instrumented as its own event because
                    // it is the moment that used to cost a registry read: a
                    // view-owned `.task` re-ran here on every switch. Nothing
                    // below does work - the evidence read hangs off the *file*
                    // selection, which is what it always described - so the
                    // pair of events, `area-switch` then `panel-appearance`,
                    // with no `evidence-load` between them is what a Mac trace
                    // reads as "the switch is free". The count is how many rows
                    // the area is about to draw, which is the only number that
                    // tells a 6-file fixture from a 1k one.
                    .task(id: selection) {
                        FormaPerf.record(PerfFact(stage: .panelAppearance, count: model.rows.count))
                    }
            }
            .navigationTitle(selection.title)
            .inspector(isPresented: $inspectorVisible) {
                inspectorContent
                    .inspectorColumnWidth(min: ShellGeometry.inspector.min,
                                          ideal: ShellGeometry.inspector.ideal,
                                          max: ShellGeometry.inspector.max)
                    .accessibilityIdentifier("shell-inspector")
            }
        }
        .toolbar { toolbarContent }
        // The shell is scene-owned, so this unmount means the window closed -
        // unlike the old per-tab placement, it no longer cancels work on every
        // switch between areas. Quitting still goes through the delegate, which
        // runs the same registered cancellation.
        //
        // The call is not `model.cancelAll()` any more, and that is the point:
        // what an unmount owes is decided by FormaCore's transition rule
        // (`apply(.shellClosed, …)`), and `ShellNavigationTests` fails the day
        // an area switch grows the same effect. The interpreter is in
        // `WorkspaceModel.perform(_:)`.
        .onDisappear { model.navigate(.shellClosed) }
        .onChange(of: storedArea) { _, value in
            // Where the old shell's bug lived. Five areas used to mean five
            // views each with a `.task` that re-ran, plus an `.onDisappear`
            // that cancelled everything; a switch was a teardown and a cold
            // start. Here a switch reaches the rule, the rule returns no
            // effects for any of the twenty pairs, and the only things that
            // happen are the counter FormaCore keeps and the signpost emitted
            // beside it - which is what the trace recipe counts to prove the
            // stall is gone rather than merely unmentioned.
            model.navigate(.areaChanged(to: AppArea.restored(from: value)))
        }
        .task {
            state.registerShutdown { model.cancelAll() }
            await model.restore()
        }
        .alert("Forma", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
        .fileImporter(isPresented: $bundleImporting, allowedContentTypes: [.folder, .json]) { result in
            switch result {
            case .success(let url): model.loadBundle(from: url)
            case .failure(let error): model.importRejected(error)
            }
        }
        .sheet(item: $model.draft) { draft in
            CorrectionSheet(model: model, draft: draft)
        }
        .confirmationDialog(EgressConsent.confirmationHeading,
                            isPresented: $egressConfirmation, titleVisibility: .visible) {
            Button(EgressConsent.confirmAction) { model.reprocessEgress = true }
            Button(EgressConsent.cancelAction, role: .cancel) {}
        } message: {
            VStack(alignment: .leading, spacing: 4) {
                Text("本次运行将发送：").font(.caption.weight(.medium))
                ForEach(Array(EgressConsent.whatLeavesLines.enumerated()), id: \.offset) { _, line in
                    Text("· \(line)").font(.caption)
                }
                Text(EgressConsent.whatStaysLine).font(.caption).foregroundStyle(.secondary)
                Text(EgressConsent.defaultOffNote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Gone: a view resetting the area selections when the scope changed.
        // The scope's own `didSet` raises `.scopeChanged`, whose effect list
        // (`FormaCore`'s `apply`) contains `resetAreaSelections`, so the shell
        // no longer holds a second copy of the rule that decides what a source
        // switch owes - and an area switch, by the same list, owes nothing.
        .onChange(of: model.workspaceFileSelection) { _, _ in model.clearFileEvidence() }
        .task(id: model.mappingFileSelection) {
            model.mappingEvidenceSelection = nil
            if let mappingFileSelection = model.mappingFileSelection {
                await model.loadEvidence(for: mappingFileSelection)
            }
        }
    }

    // MARK: - Status surface

    /// The one place busy state and the model's own notice are shown. Inline
    /// hints that explain an empty pane stay with the pane; these two describe
    /// the whole window and must not be duplicated per area.
    @ViewBuilder private var statusStrip: some View {
        if model.phase.isBusy || model.notice != nil {
            HStack(spacing: 8) {
                if model.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label)
                        .font(.callout)
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))
            .accessibilityIdentifier("shell-status")
            Divider()
        }
    }

    // MARK: - Area and inspector content

    @ViewBuilder private var areaContent: some View {
        switch selection {
        case .workspace:
            WorkspaceView(model: model, leading: ShellGeometry.workspaceLeading)
        case .mapping:
            MappingView(model: model, leading: ShellGeometry.mappingLeading)
        case .importArchive:
            ImportView(model: model)
        case .exceptions:
            ExceptionsView(model: model, leading: ShellGeometry.exceptionsLeading)
        case .settings:
            SettingsView(model: model)
        }
    }

    @ViewBuilder private var inspectorContent: some View {
        switch selection {
        case .workspace:
            WorkspaceInspector(model: model)
        case .mapping:
            MappingInspector(model: model)
        case .exceptions:
            ExceptionsInspector(model: model)
        case .importArchive, .settings:
            ContentUnavailableView("此区域没有可检视的选中项", systemImage: "sidebar.right",
                                   description: Text("在「工作区」「映射」或「诊断」中选择一条记录，详情会显示在这里。"))
        }
    }

    // MARK: - Toolbar grammar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(commands) { command in
                // A contextual fix belongs to the selection that needs it; every
                // other command is always visible and only disabled.
                if command.id != "reauthorize-source" || needsReauthorization {
                    commandButton(command)
                }
            }
            if selection == .workspace {
                profilePicker
            }
            if selection == .exceptions {
                egressControl
            }
            Button { inspectorVisible.toggle() } label: {
                Label("详情", systemImage: "sidebar.right")
            }
            .help("显示或隐藏上下文详情")
            .accessibilityIdentifier("toggle-inspector")
        }
    }

    private func commandButton(_ command: ToolbarCommand) -> some View {
        Group {
            if let systemImage = command.systemImage {
                Button(command.title, systemImage: systemImage) { perform(command) }
            } else {
                Button(command.title) { perform(command) }
            }
        }
        .help(command.help)
        .disabled(!command.isEnabled || contextualDisabled(command.id))
        .accessibilityIdentifier(command.id)
    }

    // MARK: - Commands

    private func perform(_ command: ToolbarCommand) {
        switch command.id {
        case "add-source": chooseSource()
        case "reauthorize-source":
            if let scope = model.selectedScope { chooseReauthorization(for: scope) }
        case "scan-source": model.scan()
        case "build-context": model.buildContext()
        case "reconcile-manifest": model.reconcile()
        case "cancel-work", "cancel-mapping", "cancel-reprocess": model.cancelWork()
        case "run-mapping":
            // Offline mode never sends anything, so the egress switch is
            // irrelevant to it; AI mode still needs consent.
            model.runMapping(egress: model.plannerMode == .ai && model.allowCloud)
        case "assess-local": model.runMapping(egress: false)
        case "export-manifest": chooseExportDirectory()
        case "open-bundle": bundleImporting = true
        case "revalidate-bundle": model.revalidate()
        case "build-plan": model.buildImportPlan()
        case "export-plan": choosePlanExportFolder()
        case "reprocess-selected":
            // The run says whether anything left the guard list. Clearing
            // consent after a refusal - no context, no case pack, an engine
            // that failed to build - would make the reviewer re-authorise
            // bytes that were never touched.
            if model.runMapping(sourceIDs: model.exceptionSelection, egress: model.reprocessEgress) {
                model.reprocessEgress = false
            }
        case "clear-selection": model.exceptionSelection.removeAll()
        default: break
        }
    }

    /// The enablement facts the command grammar cannot know because they are
    /// selection state, not phase: core's `isEnabled` is always honoured too,
    /// so a command is enabled only when neither side objects.
    private func contextualDisabled(_ id: String) -> Bool {
        switch id {
        case "scan-source": model.selectedScopeID == nil
        case "build-context": model.selectedScopeID == nil || model.selectedProfile == nil
        case "reconcile-manifest", "export-manifest", "build-plan": model.manifest == nil
        case "run-mapping": !model.canMap || (model.plannerMode == .ai && !model.allowCloud)
        case "assess-local": !model.canMap
        case "revalidate-bundle": model.bundleURL == nil
        case "export-plan": model.importPlan == nil
        case "reprocess-selected": model.exceptionSelection.isEmpty || !model.canMap
        case "clear-selection": model.exceptionSelection.isEmpty
        default: false
        }
    }

    // MARK: - Profile picker

    /// A picker is never blank: an empty list or a stale restored selection
    /// shows the placeholder as its own resolvable row, and the control says
    /// so by being disabled (owner failure #5).
    private var profilePickerSelection: Binding<String?> {
        Binding(
            get: {
                guard model.profiles.contains(where: { $0.profileID == model.selectedProfileID }) else { return nil }
                return model.selectedProfileID
            },
            set: { model.selectedProfileID = $0 }
        )
    }

    private var profilePicker: some View {
        let resolved = profilePickerSelection.wrappedValue
        return Picker("Profile", selection: profilePickerSelection) {
            if resolved == nil {
                Text(ShellProfilePicker.placeholder).tag(String?.none)
            }
            ForEach(model.profiles, id: \.profileID) { profile in
                Text(profile.displayName).tag(Optional(profile.profileID))
            }
        }
        .fixedSize()
        .disabled(!ShellProfilePicker.isEnabled(optionCount: model.profiles.count) || model.phase.isBusy)
        .help(ShellProfilePicker.label(selected: resolved,
                                       options: model.profiles.map { ($0.profileID, $0.displayName) }))
        .accessibilityIdentifier("select-profile")
    }

    // MARK: - Egress permission (per reprocess run)

    /// The old titlebar sentence becomes a short labeled control; turning it on
    /// is a deliberate confirmation of what leaves the machine, and the flag
    /// still lives and dies with one reprocess run.
    private var egressControl: some View {
        Button {
            if model.reprocessEgress {
                model.reprocessEgress = false
            } else {
                egressConfirmation = true
            }
        } label: {
            Label("\(EgressConsent.shortLabel)·\(model.reprocessEgress ? "已开启" : "关闭")",
                  systemImage: model.reprocessEgress ? "globe" : "lock.shield")
        }
        .help(model.reprocessEgress ? "本次重新处理已允许外发；点击立即关闭" : EgressConsent.defaultOffNote)
        .disabled(model.phase.isBusy)
        .accessibilityIdentifier("reprocess-egress")
    }

    // MARK: - Panels

    private var needsReauthorization: Bool {
        guard let scope = model.selectedScope else { return false }
        return model.sourceStatus(for: scope.id)?.needsReauthorization == true
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a source folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.register(url) }
        }
    }

    private func chooseReauthorization(for scope: SourceScope) {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for \(scope.displayName) again"
        panel.message = "Forma renews access only when the folder is the same one."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.reauthorize(scope, url: url) }
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the export bundle"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Export Here"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.export(to: url) }
        }
    }

    private func choosePlanExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the import plan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Write Plan Here"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The encode and the write are off the main actor now (#151 audit
            // item 4), so the click hands the work to a task and the notice
            // arrives when the file exists.
            Task { await model.writeImportPlan(to: url) }
        }
    }
}

/// What the recovery sweep found, and why nothing was retried.
@MainActor
private struct ImportRecoveryBanner: View {
    @ObservedObject var state: FormaApplicationState

    @State private var configuringScope = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Interrupted import operations")
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let failure = state.recoveryFailure {
                    Text("Recovery sweep failed: \(failure.localizedDescription)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let scope = state.recoveryScope {
                    Text("Read scope: \(scope.databaseName) · \(scope.groupPath.joined(separator: "/"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let review = state.recoveryReview {
                    Text(reviewSummary(review))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = state.recoveryReviewReason {
                    Text(reviewExplanation(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Read Scope…") { configuringScope = true }
                .disabled(state.recovery.requiresReview == false)
                .accessibilityIdentifier("configure-recovery-scope")
            Button("Recheck read-only") {
                Task { await state.requestRecoveryRecheck() }
            }
            .disabled(state.recovery.requiresReview == false
                      || state.recoveryScope == nil
                      || state.recoveryReviewInFlight)
            .accessibilityIdentifier("recheck-recovery")
        }
        .padding(12)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("import-recovery-banner")
        .sheet(isPresented: $configuringScope) {
            RecoveryScopeSheet(state: state)
        }
    }

    private func reviewSummary(_ report: ImportRecoveryReviewReport) -> String {
        let counts = report.counts
        let parts = ImportRecoveryReviewResult.Outcome.allCases.compactMap { outcome -> String? in
            guard let count = counts[outcome], count > 0 else { return nil }
            return "\(count) \(outcome.rawValue)"
        }
        let verdict = report.isConclusive ? "conclusive" : "inconclusive"
        return "Read-only check \(verdict): " + (parts.isEmpty ? "nothing reviewed" : parts.joined(separator: " · "))
    }

    private var summary: String {
        let counts = state.recovery.counts
        let parts = ImportRecoveryEntry.State.allCases.compactMap { entryState -> String? in
            guard let count = counts[entryState], count > 0 else { return nil }
            return "\(count) \(label(entryState))"
        }
        return parts.isEmpty ? "No pending operation." : parts.joined(separator: " · ")
    }

    private func label(_ entryState: ImportRecoveryEntry.State) -> String {
        switch entryState {
        case .notStarted: return "not started"
        case .intentRecorded: return "intent recorded, no record"
        case .recordCreated: return "record created, fields pending"
        case .metadataAnswered: return "fields written, readback pending"
        case .outcomeUnknown: return "outcome unknown"
        case .settled: return "settled"
        }
    }

    private func reviewExplanation(_ reason: String) -> String {
        switch reason {
        case "no_authorized_scope":
            return "A read-only recheck needs a confirmed read scope. Until one is confirmed these operations stay VERIFY_REQUIRED and are never retried automatically."
        case "nothing_to_review":
            return "Nothing is waiting for a readback."
        case "workspace_unavailable":
            return "The workspace or ledger could not be opened; no recheck is attempted."
        default:
            return reason
        }
    }
}

/// The one place a read scope can be confirmed.
///
/// It asks for the UUID rather than offering a list on purpose: listing databases
/// would itself be a live call, and the point of this sheet is that a person
/// states which database may be read.
@MainActor
private struct RecoveryScopeSheet: View {
    @ObservedObject var state: FormaApplicationState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RecoveryScopeDraft()

    /// Form-local feedback only.
    ///
    /// The application's `recoveryReviewReason` describes the banner (for example
    /// `no_authorized_scope`); consulting it here is what kept a valid form red
    /// after one failed submit (field defect A). `RecoveryScopeDraft` owns this
    /// decision so it is testable without a window.
    private var errorText: String? {
        switch draft.feedback {
        case .none, .ready:
            return nil
        case .missingFields:
            return "Enter a database UUID, a name and at least one group component."
        case .invalidUUID:
            return "The database UUID is not a valid UUID."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-only recovery scope")
                .font(.headline)
            Text("Forma will read the records of interrupted operations in this database and group. It never writes and never retries an import.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Database UUID", text: $draft.databaseID)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-database-id")
            TextField("Database name (label only)", text: $draft.databaseName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-database-name")
            TextField("Group path, e.g. Forma_I1B2/r1", text: $draft.groupPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-group-path")
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("recovery-scope-error")
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    draft.reset()
                    dismiss()
                }
                Button("Confirm read-only scope") {
                    draft.attemptConfirmation()
                    // Dismiss and commit only on a valid submission. Checking the
                    // application's `recoveryScope` here would also dismiss after a
                    // failed submit whenever an earlier scope was already confirmed.
                    guard draft.feedback == .ready else { return }
                    state.confirmRecoveryScope(draft)
                    draft.reset()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirm-recovery-scope")
            }
        }
        // A sheet may be reused across presentations; start from an empty draft so
        // a previous attempt's error can never appear on a fresh form.
        .onAppear { draft.reset() }
        .padding(20)
        .frame(width: 480)
    }
}
