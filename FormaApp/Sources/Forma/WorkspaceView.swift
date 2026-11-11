import AppKit
import FormaCore
import SwiftUI

struct WorkspaceView: View {
    let workspace: SourceWorkspace
    @AppStorage("selectedSourceScope") private var savedScope = ""
    @State private var scopes: [SourceScope] = []
    @State private var selectedScope: UUID?
    @State private var listing: SourceListing?
    @State private var selectedFile: UUID?
    @State private var evidence: SourceEvidence?
    @State private var operation: Task<Void, Never>?
    @State private var evidenceOperation: Task<Void, Never>?
    @State private var error: FormaError?
    @State private var evidenceRequest: UUID?

    private var entry: SourceEntry? { listing?.entries.first { $0.id == selectedFile } }

    var body: some View {
        NavigationSplitView {
            List(scopes, selection: $selectedScope) { scope in
                Label(scope.displayName, systemImage: "folder")
                    .tag(scope.id)
                    .help(scope.relativePath)
            }
            .navigationTitle("Sources")
            .navigationSplitViewColumnWidth(min: 150, ideal: 200)
        } detail: {
            if let listing {
                VStack(spacing: 0) {
                    HSplitView {
                        Table(listing.entries, selection: $selectedFile) {
                            TableColumn("Relative path") { file in
                                Text(file.relativePath).lineLimit(1).help(file.relativePath)
                            }
                            TableColumn("Size") { file in Text(size(file.sizeBytes)).monospacedDigit() }
                                .width(min: 72, ideal: 90)
                            TableColumn("Status") { file in Text(status(file)) }
                                .width(min: 90, ideal: 115)
                        }
                        .frame(minWidth: 300)
                        fileDetail
                            .frame(minWidth: 240, idealWidth: 310)
                    }
                    Divider()
                    scanSummary(listing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .navigationTitle(listing.scope.displayName)
            } else {
                ContentUnavailableView("Choose a source", systemImage: "folder", description: Text("Add a local or OneDrive folder to scan its files."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add Source…", systemImage: "folder.badge.plus", action: chooseSource)
                    .disabled(operation != nil)
                    .accessibilityIdentifier("add-source")
                if operation != nil {
                    Button("Cancel", systemImage: "stop.circle") { operation?.cancel() }
                } else {
                    Button("Scan", systemImage: "arrow.clockwise", action: scan)
                        .disabled(selectedScope == nil)
                        .accessibilityIdentifier("scan-source")
                }
            }
        }
        .task { await restore() }
        .task(id: selectedScope) { await loadSelectedScope() }
        .onChange(of: selectedFile) { _, _ in clearEvidence() }
        .onDisappear {
            operation?.cancel()
            evidenceOperation?.cancel()
        }
        .alert("Forma", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error?.localizedDescription ?? "")
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
                    if let sha = entry.sha256 {
                        Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(sha).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text(entry.snapshotFingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Divider()
                    if evidenceOperation != nil {
                        Button("Cancel evidence read") { evidenceOperation?.cancel() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Read Evidence") { readEvidence(extracting: true) }
                            .disabled(operation != nil || entry.state != .present
                                      || !["pdf", "docx", "xlsx"].contains((entry.relativePath as NSString).pathExtension.lowercased()))
                            .accessibilityIdentifier("read-evidence")
                        Button("Compute SHA-256") { readEvidence(extracting: false) }
                            .disabled(operation != nil || entry.state != .present)
                    }
                    if let evidence {
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

    private func scanSummary(_ listing: SourceListing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(operation != nil ? "Scanning…" : scanStatus(listing.state))
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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

    private func restore() async {
        do {
            scopes = try await workspace.scopes()
            selectedScope = scopes.first { $0.id.uuidString == savedScope }?.id ?? scopes.first?.id
        } catch { show(error, operation: .openWorkspace, fallback: .storage) }
    }

    private func loadSelectedScope() async {
        guard let scope = scopes.first(where: { $0.id == selectedScope }) else { return }
        savedScope = scope.id.uuidString
        selectedFile = nil
        listing = nil
        clearEvidence()
        do {
            let result = try await workspace.listing(scope)
            if !Task.isCancelled, selectedScope == scope.id { listing = result }
        } catch { if !Task.isCancelled { show(error, operation: .openWorkspace, fallback: .storage) } }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a source folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let scope = try await workspace.register(url)
                    scopes = try await workspace.scopes()
                    selectedScope = scope.id
                } catch { show(error, operation: .registerSource, fallback: .invalidSource) }
            }
        }
    }

    private func scan() {
        guard operation == nil, let scope = scopes.first(where: { $0.id == selectedScope }) else { return }
        clearEvidence()
        operation = Task {
            defer { operation = nil }
            do {
                let updated = try await workspace.scan(scope)
                if selectedScope == scope.id { listing = updated }
            } catch {
                if let saved = try? await workspace.listing(scope), selectedScope == scope.id { listing = saved }
                if !Task.isCancelled { show(error, operation: .scanSource, fallback: .invalidSource) }
            }
        }
    }

    private func readEvidence(extracting: Bool) {
        guard let entry, evidenceOperation == nil else { return }
        evidence = nil
        let request = UUID()
        evidenceRequest = request
        evidenceOperation = Task {
            defer {
                if evidenceRequest == request {
                    evidenceOperation = nil
                    evidenceRequest = nil
                }
            }
            do {
                let result = extracting
                    ? try await workspace.evidence(for: entry)
                    : try await workspace.hash(for: entry)
                guard !Task.isCancelled, selectedFile == entry.id else { return }
                if let scope = listing?.scope {
                    let updated = try await workspace.listing(scope)
                    guard !Task.isCancelled, selectedFile == entry.id, selectedScope == scope.id else { return }
                    listing = updated
                }
                evidence = result
            } catch {
                if !Task.isCancelled { show(error, operation: .readEvidence, fallback: .unavailable) }
            }
        }
    }

    private func clearEvidence() {
        evidenceOperation?.cancel()
        evidenceOperation = nil
        evidenceRequest = nil
        evidence = nil
    }

    private func show(_ error: any Error, operation: FormaDiagnostics.Operation, fallback: FormaError) {
        let safe = error as? FormaError ?? fallback
        FormaDiagnostics.failure(operation, safe)
        self.error = safe
    }
}
