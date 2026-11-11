import AppKit
import FormaCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    // No @AppStorage mirror of the selected scope: `WorkspaceModel.selectedScopeID`
    // is the only writer of that key. A second writer on appear raced the model's
    // own fallback for a stored scope that no longer exists, persisted a value no
    // source matched, and could land the next start on a different source than the
    // one just chosen.
    @State private var selectedFile: UUID?
    @State private var selectedCluster: String?

    private var entry: SourceEntry? {
        guard let id = selectedFile else { return nil }
        return model.listing?.entries.first { $0.id == id }
    }

    private var cluster: WorkspaceModel.ClusterRow? {
        model.clusterRows.first { $0.id == selectedCluster }
    }

    var body: some View {
        NavigationSplitView {
            List(model.scopes, selection: $model.selectedScopeID) { scope in
                Label(scope.displayName, systemImage: "folder")
                    .tag(scope.id)
                    .help(scope.relativePath)
            }
            .navigationTitle("Sources")
            .navigationSplitViewColumnWidth(min: 150, ideal: 200)
        } detail: {
            if let listing = model.listing {
                VStack(spacing: 0) {
                    HSplitView {
                        fileTable(listing)
                            .frame(minWidth: 300)
                        rightPane
                            .frame(minWidth: 240, idealWidth: 310)
                    }
                    Divider()
                    clusterPanel
                        .frame(height: 168)
                    Divider()
                    scanSummary(listing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .navigationTitle(listing.scope.displayName)
            } else {
                ContentUnavailableView("Choose a source", systemImage: "folder",
                                       description: Text(model.notice ?? "Add a local or OneDrive folder to scan its files."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add Source…", systemImage: "folder.badge.plus", action: chooseSource)
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("add-source")
                if model.phase.isBusy {
                    Button("Cancel", systemImage: "stop.circle") { model.cancelWork() }
                        .accessibilityIdentifier("cancel-work")
                } else {
                    Button("Scan", systemImage: "arrow.clockwise", action: model.scan)
                        .disabled(model.selectedScopeID == nil)
                        .accessibilityIdentifier("scan-source")
                    Button("Build Context", systemImage: "square.3.layers.3d") { model.buildContext() }
                        .disabled(model.selectedScopeID == nil || model.selectedProfile == nil)
                        .help("FormaCore clusters the listing into project candidates from structure alone")
                        .accessibilityIdentifier("build-context")
                    Button("Reconcile", systemImage: "arrow.triangle.2.circlepath") { model.reconcile() }
                        .disabled(model.manifest == nil)
                        .help("Ask FormaCore which stored entries its snapshot binding still supports")
                        .accessibilityIdentifier("reconcile-manifest")
                }
                Picker("Profile", selection: $model.selectedProfileID) {
                    ForEach(model.profiles, id: \.profileID) { profile in
                        Text(profile.displayName).tag(Optional(profile.profileID))
                    }
                }
                .fixedSize()
                .disabled(model.phase.isBusy)
                .accessibilityIdentifier("select-profile")
            }
        }
        .task(id: model.selectedScopeID) {
            selectedFile = nil
            selectedCluster = nil
            model.clearFileEvidence()
            // The model persists this itself; reading it back here was the race.
        }
        .onChange(of: selectedFile) { _, _ in model.clearFileEvidence() }
    }

    // MARK: - Files

    private func fileTable(_ listing: SourceListing) -> some View {
        Table(listing.entries, selection: $selectedFile) {
            TableColumn("Relative path") { file in
                Text(file.relativePath).lineLimit(1).help(file.relativePath)
            }
            TableColumn("Project") { file in
                Text(model.clusterLabel(for: file.id)).lineLimit(1).help(model.clusterLabel(for: file.id))
            }
            .width(min: 130, ideal: 190)
            TableColumn("Size") { file in Text(size(file.sizeBytes)).monospacedDigit() }
                .width(min: 72, ideal: 90)
            TableColumn("Status") { file in Text(status(file)) }
                .width(min: 90, ideal: 115)
        }
    }

    @ViewBuilder private var rightPane: some View {
        if let cluster {
            clusterFiles(cluster)
        } else {
            fileDetail
        }
    }

    private func clusterFiles(_ cluster: WorkspaceModel.ClusterRow) -> some View {
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

    @ViewBuilder private var fileDetail: some View {
        if let entry {
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
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text")
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

    // MARK: - Clusters

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
                Table(model.clusterRows, selection: $selectedCluster) {
                    TableColumn("Candidate") { row in
                        Text(row.title).lineLimit(1).help(row.title)
                    }
                    TableColumn("Files") { row in Text(row.fileCount.formatted()).monospacedDigit() }
                        .width(min: 60, ideal: 70)
                    TableColumn("Basis") { row in Text(row.basis).lineLimit(1).help(row.basis) }
                        .width(min: 140, ideal: 220)
                    TableColumn("Confidence") { row in Text(row.confidence) }
                        .width(min: 80, ideal: 95)
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
        }
    }

    // MARK: - Scan summary

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

    private func providerName(_ provider: SourceProvider) -> String {
        switch provider {
        case .local: "Local"
        case .oneDrive: "OneDrive"
        case .fileProvider: "File Provider"
        case .iCloud: "iCloud"
        case .unknown: "Unknown"
        }
    }

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

    private func status(_ file: SourceEntry) -> String {
        switch file.state {
        case .present: file.hydrationPending ? "Cloud placeholder" : "Present"
        case .missing: "Missing"
        case .symlink: "Symbolic link"
        case .held: "Needs review"
        }
    }

    private func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    // MARK: - Source picker

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
}
