import FormaCore
import SwiftUI

@main
struct FormaApplication: App {
    private let workspace: Result<SourceWorkspace, FormaError> = Result {
        let directory = URL.applicationSupportDirectory.appending(path: "Forma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try SourceWorkspace(databaseURL: directory.appending(path: "workspace.sqlite"))
    }.mapError { _ in
        FormaDiagnostics.failure(.openWorkspace, .storage)
        return .storage
    }

    var body: some Scene {
        Window("Forma", id: "workspace") {
            switch workspace {
            case .success(let workspace): WorkspaceAreas(workspace: workspace)
            case .failure(let error):
                ContentUnavailableView("Workspace unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1180, height: 700)

        Settings {
            ProbesView()
        }
    }
}

/// The four workspace areas, all driven by one orchestration model so a scan, a
/// context revision, a manifest and an export bundle stay the same objects in
/// every tab instead of being recomputed per view.
@MainActor
private struct WorkspaceAreas: View {
    @StateObject private var model: WorkspaceModel

    init(workspace: SourceWorkspace) {
        _model = StateObject(wrappedValue: WorkspaceModel(workspace: workspace))
    }

    var body: some View {
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
        // Cancelling belongs to the window's root view, not to a tab. Each area
        // used to cancel in its own `onDisappear`, and a macOS TabView unmounts
        // the tab you leave: clicking elsewhere in the window stopped whichever
        // long task was in flight - a scan, a context build, a mapping run that
        // had already paid for its provider requests - and left nothing but a
        // notice saying "Cancelled" to explain why.
        .onDisappear { model.cancelAll() }
        .task { await model.restore() }
        .alert("Forma", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}
