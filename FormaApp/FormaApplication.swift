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
            case .success(let workspace): WorkspaceView(workspace: workspace)
            case .failure(let error):
                ContentUnavailableView("Workspace unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1050, height: 640)
    }
}
