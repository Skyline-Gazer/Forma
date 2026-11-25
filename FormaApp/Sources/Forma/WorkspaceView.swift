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

    /// The column budget the shell declared for the candidate table.
    private var candidateWidths: [ShellColumnWidth] { ShellLayout.columns(for: .workspaceCandidates) }

    @AppStorage("shell.workspace.clustersVisible") private var clustersVisible = true

    var body: some View {
        HSplitView {
            sourceList
                .areaWidth(leading)
            if let listing = model.listing {
                mainPane(listing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(ProductCopy.Workspace.chooseSource, systemImage: "folder",
                                       description: Text(model.notice ?? ProductCopy.Workspace.chooseSourceHint))
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
                        .help(ProductCopy.Workspace.sourceAttentionHint)
                        .accessibilityLabel(ProductCopy.Workspace.sourceNeedsAttention)
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
        let widths = ShellLayout.columns(for: .workspaceFiles)
        return Table(listing.entries, selection: $model.workspaceFileSelection) {
            TableColumn(ProductCopy.Workspace.relativePath) { file in
                Text(file.relativePath).lineLimit(1).help(file.relativePath)
            }
            .width(min: widths[0].cgMin, ideal: widths[0].cgIdeal, max: widths[0].cgMax)
            TableColumn(ProductCopy.Workspace.project) { file in
                Text(model.clusterLabel(for: file.id)).lineLimit(1).help(model.clusterLabel(for: file.id))
            }
            .width(min: widths[1].cgMin, ideal: widths[1].cgIdeal, max: widths[1].cgMax)
            TableColumn(ProductCopy.Workspace.size) { file in Text(size(file.sizeBytes)).monospacedDigit() }
                .width(min: widths[2].cgMin, ideal: widths[2].cgIdeal, max: widths[2].cgMax)
            TableColumn(ProductCopy.Workspace.status) { file in Text(status(file)) }
                .width(min: widths[3].cgMin, ideal: widths[3].cgIdeal, max: widths[3].cgMax)
        }
    }

    @ViewBuilder private var clusterPanel: some View {
        if let context = model.context {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(ProductCopy.Workspace.candidatesRevision(revision: context.revision))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(ProductCopy.Workspace.builtAt) \(context.builtAt.formatted())")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.contextIsStale {
                        Text(ProductCopy.Workspace.contextInputsChanged)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Table(model.clusterRows, selection: $model.workspaceClusterSelection) {
                    TableColumn(ProductCopy.Workspace.candidate) { row in
                        Text(row.title).lineLimit(1).help(row.title)
                    }
                    .width(min: candidateWidths[0].cgMin, ideal: candidateWidths[0].cgIdeal, max: candidateWidths[0].cgMax)
                    TableColumn(ProductCopy.Workspace.filesCount) { row in Text(row.fileCount.formatted()).monospacedDigit() }
                        .width(min: candidateWidths[1].cgMin, ideal: candidateWidths[1].cgIdeal, max: candidateWidths[1].cgMax)
                    TableColumn(ProductCopy.Workspace.basis) { row in Text(row.basis).lineLimit(1).help(row.basis) }
                        .width(min: candidateWidths[2].cgMin, ideal: candidateWidths[2].cgIdeal, max: candidateWidths[2].cgMax)
                    TableColumn(ProductCopy.Workspace.confidence) { row in Text(row.confidence) }
                        .width(min: candidateWidths[3].cgMin, ideal: candidateWidths[3].cgIdeal, max: candidateWidths[3].cgMax)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                Text(model.notice ?? ProductCopy.Workspace.noContextYet)
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
                Text(model.phase == .scanning ? ProductCopy.Work.scanning : scanStatus(listing.state))
                if !listing.issues.isEmpty {
                    Menu("\(listing.issues.count) \(ProductCopy.Workspace.issues)") {
                        ForEach(listing.issues.indices.prefix(25), id: \.self) { index in
                            let issue = listing.issues[index]
                            Text("\(issue.relativePath): \(issue.reason.productLabel)")
                                .help(issue.reason.rawValue)
                        }
                        if listing.issues.count > 25 { Text(ProductCopy.Workspace.showingFirst25Issues) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                if let stats = listing.statistics {
                    Text("\(stats.fileCount.formatted()) \(ProductCopy.Workspace.filesUnit) · \(stats.directoryCount.formatted()) \(ProductCopy.Workspace.foldersUnit) · \(size(stats.sizeBytes))")
                    Menu(ProductCopy.Workspace.fileTypes) {
                        ForEach(stats.extensions.keys.sorted(), id: \.self) { ext in
                            Text("\(ext.isEmpty ? ProductCopy.Workspace.noExtension : ext): \(stats.extensions[ext, default: 0])")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(stats.extensions.isEmpty)
                }
            }
            if let profile = model.selectedProfile {
                HStack {
                    Text(ProductCopy.Workspace.profileLine(versionKey: profile.versionKey,
                                                           target: profile.target.kind.rawValue,
                                                           categories: profile.categories.count,
                                                           granted: profile.grantsExecution))
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
        case .notScanned: ProductCopy.Workspace.readyToScan
        case .scanning: ProductCopy.Work.scanning
        case .complete: ProductCopy.Workspace.scanComplete
        case .incomplete: ProductCopy.Workspace.incompleteScan
        case .cancelled: ProductCopy.Workspace.scanCancelled
        case .interrupted: ProductCopy.Workspace.scanInterrupted
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
                Button(ProductCopy.Workspace.reauthorize) {
                    let panel = NSOpenPanel()
                    panel.title = ProductCopy.Shell.reauthorizeFolder(name: scope.displayName)
                    panel.message = ProductCopy.Workspace.renewsAccess
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
        case .accessible: return ProductCopy.Workspace.sourceAvailable
        case .bookmarkStale: return ProductCopy.Workspace.accessNeedsRenewing
        case .permissionDenied: return ProductCopy.Workspace.accessRevoked
        case .missing: return ProductCopy.Workspace.folderNotFound
        case .hydrationPending: return ProductCopy.Workspace.notDownloadedYet
        case .identityChanged: return ProductCopy.Workspace.folderDifferentNow
        case .unavailable: return ProductCopy.Workspace.sourceUnavailable
        }
    }

    private func sourceUnavailableDetail(_ status: SourceScopeStatus) -> String {
        switch status.availability {
        case .accessible:
            return ProductCopy.Workspace.sourceReadable
        case .bookmarkStale:
            return ProductCopy.Workspace.bookmarkStaleDetail(path: status.lastKnownPath)
        case .permissionDenied:
            return ProductCopy.Workspace.accessRevokedDetail(path: status.lastKnownPath)
        case .missing:
            return ProductCopy.Workspace.folderGoneDetail(path: status.lastKnownPath)
        case .hydrationPending:
            return ProductCopy.Workspace.cloudNotDownloaded
        case .identityChanged:
            return ProductCopy.Notice.folderNotRegistered(
                path: status.lastKnownPath, pathHint: ProductCopy.Notice.addAsNewSource)
        case .unavailable:
            return ProductCopy.Workspace.stateUnknownDetail(path: status.lastKnownPath)
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
                LabeledContent(ProductCopy.Workspace.filesCount, value: files.count.formatted())
                LabeledContent(ProductCopy.Workspace.basis, value: cluster.basis)
                LabeledContent(ProductCopy.Workspace.confidence, value: cluster.confidence)
                Text(ProductCopy.Workspace.clusterMembershipNote)
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
                    Text(ProductCopy.Workspace.noFilesInCategory)
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
                LabeledContent(ProductCopy.Workspace.status, value: status(entry))
                LabeledContent(ProductCopy.Workspace.storage, value: providerName(entry.provider))
                LabeledContent(ProductCopy.Workspace.size, value: size(entry.sizeBytes))
                LabeledContent(ProductCopy.Workspace.sourceVersion, value: entry.sourceVersion.formatted())
                LabeledContent(ProductCopy.Workspace.snapshotRevision, value: entry.snapshotRevision.formatted())
                LabeledContent(ProductCopy.Workspace.project, value: model.clusterLabel(for: entry.id))
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
                    Button(ProductCopy.Workspace.cancelEvidenceRead) { model.cancelFileRead() }
                    ProgressView().controlSize(.small)
                } else {
                    Button(ProductCopy.Workspace.readEvidence) { model.readFileEvidence(entry, extracting: true) }
                        .disabled(entry.state != .present
                                  || !["pdf", "docx", "xlsx"].contains((entry.relativePath as NSString).pathExtension.lowercased()))
                        .accessibilityIdentifier("read-evidence")
                    Button(ProductCopy.Workspace.computeHash) { model.readFileEvidence(entry, extracting: false) }
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
            case .text(let range):
                Text("UTF-16 \(range.lowerBound)–\(range.upperBound)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let text = item.text { Text(text).textSelection(.enabled) }
            if let formula = item.formula {
                Text(ProductCopy.Workspace.formulaLine(formula)).font(.caption.monospaced()).textSelection(.enabled)
                Text(item.cachedValue.map { ProductCopy.Workspace.cachedLine($0) } ?? ProductCopy.Workspace.noCachedValue).font(.caption)
            }
        }
    }

    private func providerName(_ provider: SourceProvider) -> String {
        switch provider {
        case .local: ProductCopy.Workspace.local
        case .oneDrive: "OneDrive"
        case .fileProvider: ProductCopy.Workspace.fileProvider
        case .iCloud: "iCloud"
        case .unknown: ProductCopy.Workspace.unknown
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
    case .present: file.hydrationPending ? ProductCopy.Workspace.cloudPlaceholder : ProductCopy.Workspace.present
    case .missing: ProductCopy.Workspace.missing
    case .symlink: ProductCopy.Workspace.symbolicLink
    case .held: ProductCopy.Workspace.needsReview
    }
}

private func wsSize(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
}
