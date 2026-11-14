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
            // Batch 1 has no import authorization, so it has no authorized read
            // scope either. The operations stay `verify_required`; nothing retries.
            recoveryReviewReason = "no_authorized_scope"
        }
        launch = .ready(workspace)
    }

    /// The read-only recheck entry point.
    ///
    /// It refuses, with a reason, when no authorized target exists. It never
    /// writes and never retries an import.
    func requestRecoveryRecheck() {
        guard recovery.requiresReview else {
            recoveryReviewReason = "nothing_to_review"
            return
        }
        guard case .ready = launch, recoveryFailure == nil else {
            recoveryReviewReason = "workspace_unavailable"
            return
        }
        // The reviewer needs a scope an operator authorised. No such scope exists
        // in this build, so the refusal is the honest answer.
        recoveryReviewReason = "no_authorized_scope"
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
                if let reason = state.recoveryReviewReason {
                    Text(reviewExplanation(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Recheck read-only") { state.requestRecoveryRecheck() }
                .disabled(state.recovery.requiresReview == false)
        }
        .padding(12)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("import-recovery-banner")
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
            return "A read-only recheck needs an authorized target scope. None is configured in this build, so these operations stay VERIFY_REQUIRED and are never retried automatically."
        case "nothing_to_review":
            return "Nothing is waiting for a readback."
        case "workspace_unavailable":
            return "The workspace or ledger could not be opened; no recheck is attempted."
        default:
            return reason
        }
    }
}
