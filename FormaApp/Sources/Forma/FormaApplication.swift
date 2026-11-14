import FormaCore
import SwiftUI

@main
struct FormaApplication: App {
    @NSApplicationDelegateAdaptor(FormaAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Forma", id: "workspace") {
            FormaRoot(state: delegate.state)
        }
        .defaultSize(width: 1180, height: 700)

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
    func confirmRecoveryScope(databaseID: String, databaseName: String, groupPath: String) {
        let path = groupPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let scope = ImportRecoveryScopeConfirmation(
            databaseID: databaseID.trimmingCharacters(in: .whitespacesAndNewlines),
            databaseName: databaseName.trimmingCharacters(in: .whitespacesAndNewlines),
            groupPath: path, confirmedAt: Date(), confirmedBy: "operator") else {
            recoveryReviewReason = "invalid_scope"
            return
        }
        recoveryScope = scope
        recoveryReviewReason = nil
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

/// The four workspace areas, all driven by one orchestration model so a scan, a
/// context revision, a manifest and an export bundle stay the same objects in
/// every tab instead of being recomputed per view.
@MainActor
private struct WorkspaceAreas: View {
    @StateObject private var model: WorkspaceModel
    @ObservedObject var state: FormaApplicationState

    init(workspace: SourceWorkspace, state: FormaApplicationState) {
        _model = StateObject(wrappedValue: WorkspaceModel(workspace: workspace))
        self.state = state
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.recovery.requiresReview || state.recoveryFailure != nil {
                ImportRecoveryBanner(state: state)
                Divider()
            }
            TabView {
                WorkspaceView(model: model)
                    .tabItem { Label("Workspace", systemImage: "folder") }
                    .accessibilityIdentifier("area-workspace")
                MappingView(model: model)
                    .tabItem { Label("Mapping", systemImage: "tablecells") }
                    .accessibilityIdentifier("area-mapping")
                ExceptionsView(model: model)
                    .tabItem { Label("Exceptions", systemImage: "exclamationmark.triangle") }
                    .accessibilityIdentifier("area-exceptions")
                SettingsView(model: model)
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("area-settings")
            }
        }
        // A tab unmount is a cancellation, not a completion: the scan row keeps
        // `scanning` and the next launch reports it as interrupted. Quitting goes
        // through the application delegate, which runs the registered shutdown.
        .onDisappear { model.cancelAll() }
        .task {
            state.registerShutdown { model.cancelAll() }
            await model.restore()
        }
        .alert("Forma", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error?.localizedDescription ?? "")
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
    @State private var databaseID = ""
    @State private var databaseName = ""
    @State private var groupPath = ""

    private var isInvalid: Bool { state.recoveryReviewReason == "invalid_scope" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-only recovery scope")
                .font(.headline)
            Text("Forma will read the records of interrupted operations in this database and group. It never writes and never retries an import.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Database UUID", text: $databaseID)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-database-id")
            TextField("Database name (label only)", text: $databaseName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-database-name")
            TextField("Group path, e.g. Forma_I1B2/r1", text: $groupPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery-group-path")
            if isInvalid {
                Text("Enter a database UUID, a name and at least one group component.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Confirm read-only scope") {
                    state.confirmRecoveryScope(databaseID: databaseID,
                                               databaseName: databaseName,
                                               groupPath: groupPath)
                    if state.recoveryScope != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirm-recovery-scope")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
