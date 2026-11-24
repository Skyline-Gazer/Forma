import AppKit
import FormaCore
import SwiftUI

/// The workspace area, rendered inside the shell: a sources pane, the file
/// table with its cluster panel, and the scan summary. It owns no split view,
/// no window title and no toolbar - the shell does; this view fills whatever
/// detail column the shell gives it (owner failures #1, #2 and #3 came from
/// this view owning a `NavigationSplitView` whose minimums pushed the window
/// and whose fixed-height cluster panel collapsed the tables).
///
/// File and cluster selections live on the model so the shell's inspector can
/// read them and so they survive an area switch.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    /// The width bounds the shell declared for this area's leading pane.
    let leading: AreaWidth

    @AppStorage("shell.workspace.clustersVisible") private var clustersVisible = true

    var body: some View {
        HSplitView {
            sourceList
                .areaWidth(leading)
            if let listing = model.listing {
                mainPane(listing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Choose a source", systemImage: "folder",
                                       description: Text(model.notice ?? "Add a local or OneDrive folder to scan its files."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Sources

    private var sourceList: some View {
        List(model.scopes, selection: $model.selectedScopeID) { scope in
            HStack(spacing: 6) {
                Label(scope.displayName, systemImage: "folder")
                if let status = model.sourceStatus(for: scope.id),
                   status.needsReauthorization || status.availability == .identityChanged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This source needs attention.")
                        .accessibilityLabel("Source needs attention")
                }
            }
            .tag(scope.id)
            .help(scope.relativePath)
        }
    }

    // MARK: - Files, clusters, summary

    private func mainPane(_ listing: SourceListing) -> some View {
        VStack(spacing: 0) {
            if let status = selectedStatus, status.isUnreadable {
                sourceUnavailableBanner(status)
                Divider()
            }
            // A resizable vertical split, not a fixed-height panel: the tables
            // fill the viewport and the person decides how much the candidate
            // list gets (owner failure #3).
            VSplitView {
                fileTable(listing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if clustersVisible {
                    clusterPanel
                        .frame(minHeight: 96, idealHeight: 176, maxHeight: 320)
                }
            }
            Divider()
            bottomBar(listing)
        }
    }

    private func fileTable(_ listing: SourceListing) -> some View {
        Table(listing.entries, selection: $model.workspaceFileSelection) {
            TableColumn("Relative path") { file in
                Text(file.relativePath).lineLimit(1).help(file.relativePath)
            }
            .shellWidth(.workspaceFiles, 0)
            TableColumn("Project") { file in
                Text(model.clusterLabel(for: file.id)).lineLimit(1).help(model.clusterLabel(for: file.id))
            }
            .shellWidth(.workspaceFiles, 1)
            TableColumn("Size") { file in Text(size(file.sizeBytes)).monospacedDigit() }
                .shellWidth(.workspaceFiles, 2)
            TableColumn("Status") { file in Text(status(file)) }
                .shellWidth(.workspaceFiles, 3)
        }
    }

    @ViewBuilder private var clusterPanel: some View {
        if let context = model.context {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Project candidates · revision \(context.revision.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("built \(context.builtAt.formatted())")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.contextIsStale {
                        Text("Context inputs changed · build it again before mapping")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Table(model.clusterRows, selection: $model.workspaceClusterSelection) {
                    TableColumn("Candidate") { row in
                        Text(row.title).lineLimit(1).help(row.title)
                    }
                    .shellWidth(.workspaceCandidates, 0)
                    TableColumn("Files") { row in Text(row.fileCount.formatted()).monospacedDigit() }
                        .shellWidth(.workspaceCandidates, 1)
                    TableColumn("Basis") { row in Text(row.basis).lineLimit(1).help(row.basis) }
                        .shellWidth(.workspaceCandidates, 2)
                    TableColumn("Confidence") { row in Text(row.confidence) }
                        .shellWidth(.workspaceCandidates, 3)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                Text(model.notice ?? "No project context yet. Choose a profile, scan the source, then build a context; FormaCore will not map files without one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func bottomBar(_ listing: SourceListing) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            scanSummary(listing)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(clustersVisible ? "隐藏项目候选" : "显示项目候选") { clustersVisible.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("toggle-cluster-panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func scanSummary(_ listing: SourceListing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.phase == .scanning ? "Scanning…" : scanStatus(listing.state))
                if !listing.issues.isEmpty {
                    Menu("\(listing.issues.count) issues") {
                        ForEach(listing.issues.indices.prefix(25), id: \.self) { index in
                            let issue = listing.issues[index]
                            Text("\(issue.relativePath): \(String(describing: issue.reason))")
                        }
                        if listing.issues.count > 25 { Text("Showing first 25 issues") }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                if let stats = listing.statistics {
                    Text("\(stats.fileCount.formatted()) files · \(stats.directoryCount.formatted()) folders · \(size(stats.sizeBytes))")
                    Menu("File types") {
                        ForEach(stats.extensions.keys.sorted(), id: \.self) { ext in
                            Text("\(ext.isEmpty ? "No extension" : ext): \(stats.extensions[ext, default: 0])")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(stats.extensions.isEmpty)
                }
            }
            if let profile = model.selectedProfile {
                HStack {
                    Text("Profile \(profile.versionKey) · target \(profile.target.kind.rawValue) · \(profile.categories.count.formatted()) categories · execution \(profile.grantsExecution ? "granted" : "never granted")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Formatting

    private func scanStatus(_ state: SourceScanState) -> String {
        switch state {
        case .notScanned: "Ready to scan"
        case .scanning: "Scanning…"
        case .complete: "Scan complete"
        case .incomplete: "Incomplete scan · rescan to recover"
        case .cancelled: "Scan cancelled · rescan to recover"
        case .interrupted: "Scan interrupted · rescan to recover"
        }
    }

    private func status(_ file: SourceEntry) -> String { wsFileStatus(file) }

    private func size(_ bytes: Int64?) -> String { wsSize(bytes) }

    private var selectedStatus: SourceScopeStatus? {
        guard let id = model.selectedScopeID else { return nil }
        return model.sourceStatus(for: id)
    }

    // MARK: - Source availability banner

    /// What the source needs, in the words a person can act on. The four cases
    /// stay apart because only two of them are fixed by choosing the folder again.
    private func sourceUnavailableBanner(_ status: SourceScopeStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceUnavailableTitle(status.availability))
                    .font(.headline)
                Text(sourceUnavailableDetail(status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status.needsReauthorization, let scope = model.selectedScope {
                Button("Reauthorize…") {
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
                .disabled(model.phase.isBusy)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("source-unavailable-banner")
    }

    private func sourceUnavailableTitle(_ availability: SourceRootAvailability) -> String {
        switch availability {
        case .accessible: return "Source available"
        case .bookmarkStale: return "Access needs renewing"
        case .permissionDenied: return "Access was revoked"
        case .missing: return "Folder not found"
        case .hydrationPending: return "Not downloaded yet"
        case .identityChanged: return "This folder is different now"
        case .unavailable: return "Source unavailable"
        }
    }

    private func sourceUnavailableDetail(_ status: SourceScopeStatus) -> String {
        switch status.availability {
        case .accessible:
            return "This source can be read."
        case .bookmarkStale:
            return "The stored permission for \(status.lastKnownPath) is no longer valid. Choose the same folder again to renew it."
        case .permissionDenied:
            return "macOS no longer allows Forma to read \(status.lastKnownPath). Files were not marked missing; renew access to continue."
        case .missing:
            return "\(status.lastKnownPath) is gone. Scans stay incomplete until it is back, so nothing is marked missing by accident."
        case .hydrationPending:
            return "The provider has not downloaded this folder's contents yet. Metadata can still be read."
        case .identityChanged:
            return "The folder at \(status.lastKnownPath) is not the one this source was registered from. Add it as a new source instead."
        case .unavailable:
            return "Forma could not determine the state of \(status.lastKnownPath)."
        }
    }
}

/// The workspace inspector: the selected file's evidence actions and result, or
/// the selected cluster's membership. The shell presents this beside any area;
/// the content below is the file detail the area used to carry in its own
/// split view - same buttons, same values, now contextual.
@MainActor
struct WorkspaceInspector: View {
    @ObservedObject var model: WorkspaceModel

    private var entry: SourceEntry? {
        guard let id = model.workspaceFileSelection else { return nil }
        return model.listing?.entries.first { $0.id == id }
    }

    private var cluster: ClusterRow? {
        model.clusterRows.first { $0.id == model.workspaceClusterSelection }
    }

    var body: some View {
        if let cluster {
            clusterFiles(cluster)
        } else if let entry {
            fileDetail(entry)
        } else {
            ContentUnavailableView("选择文件或候选", systemImage: "doc.text",
                                   description: Text("在工作区的文件表或项目候选中选择一行，详情显示在这里。"))
        }
    }

    private func clusterFiles(_ cluster: ClusterRow) -> some View {
        let files = model.files(in: cluster)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(cluster.title).font(.headline)
                LabeledContent("Files", value: files.count.formatted())
                LabeledContent("Basis", value: cluster.basis)
                LabeledContent("Confidence", value: cluster.confidence)
                Text("Cluster membership is FormaCore's. Unassigned and conflicted files stay visible and gain no project by guessing.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.relativePath).font(.caption).textSelection(.enabled)
                        Text(status(file)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if files.isEmpty {
                    Text("FormaCore reported no file in this category for the current listing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }

    private func fileDetail(_ entry: SourceEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.relativePath)
                    .font(.headline)
                    .textSelection(.enabled)
                LabeledContent("Status", value: status(entry))
                LabeledContent("Storage", value: providerName(entry.provider))
                LabeledContent("Size", value: size(entry.sizeBytes))
                LabeledContent("Source version", value: entry.sourceVersion.formatted())
                LabeledContent("Snapshot revision", value: entry.snapshotRevision.formatted())
                LabeledContent("Project", value: model.clusterLabel(for: entry.id))
                if let sha = entry.sha256 {
                    Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(sha).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text(entry.snapshotFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Divider()
                // Driven by the read's own slot. While `phase` also
                // described this read, a provider run in flight made this
                // panel offer "Cancel evidence read" for a read that had
                // finished - and the run it actually named could only be
                // stopped from the toolbar.
                if model.fileReadInFlight {
                    Button("Cancel evidence read") { model.cancelFileRead() }
                    ProgressView().controlSize(.small)
                } else {
                    Button("Read Evidence") { model.readFileEvidence(entry, extracting: true) }
                        .disabled(entry.state != .present
                                  || !["pdf", "docx", "xlsx"].contains((entry.relativePath as NSString).pathExtension.lowercased()))
                        .accessibilityIdentifier("read-evidence")
                    Button("Compute SHA-256") { model.readFileEvidence(entry, extracting: false) }
                        .disabled(entry.state != .present)
                }
                if let evidence = model.fileEvidence {
                    Text(evidence.status.rawValue).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(evidence.items.indices, id: \.self) { index in
                        evidenceRow(evidence.items[index])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }

    private func evidenceRow(_ item: EvidenceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item.locator {
            case .pdf(let page, let range):
                Text("PDF page \(page) · UTF-16 \(range.lowerBound)–\(range.upperBound)")
                    .font(.caption).foregroundStyle(.secondary)
            case .docx(let part, let paragraph, _):
                Text("\(part) · paragraph \(paragraph)")
                    .font(.caption).foregroundStyle(.secondary)
            case .xlsx(let sheet, let cell):
                Text("\(sheet) · \(cell)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let text = item.text { Text(text).textSelection(.enabled) }
            if let formula = item.formula {
                Text("Formula: \(formula)").font(.caption.monospaced()).textSelection(.enabled)
                Text(item.cachedValue.map { "Cached: \($0)" } ?? "No cached value").font(.caption)
            }
        }
    }

    private func providerName(_ provider: SourceProvider) -> String {
        switch provider {
        case .local: "Local"
        case .oneDrive: "OneDrive"
        case .fileProvider: "File Provider"
        case .iCloud: "iCloud"
        case .unknown: "Unknown"
        }
    }

    private func status(_ file: SourceEntry) -> String { wsFileStatus(file) }

    private func size(_ bytes: Int64?) -> String { wsSize(bytes) }
}

// MARK: - Shared readout formatters
//
// The area's tables and the shell's inspector describe the same entries, so
// they share the same words.
private func wsFileStatus(_ file: SourceEntry) -> String {
    switch file.state {
    case .present: file.hydrationPending ? "Cloud placeholder" : "Present"
    case .missing: "Missing"
    case .symlink: "Symbolic link"
    case .held: "Needs review"
    }
}

private func wsSize(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
}
