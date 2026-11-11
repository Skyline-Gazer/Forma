import AppKit
import FormaCore
import SwiftUI
import UniformTypeIdentifiers

/// The mapping area: run FormaCore's engine over the current listing, read the
/// manifest it produced file by file, export the bundle and re-check it offline.
///
/// Every value here is FormaCore's: a `ManifestEntry` field outcome, a
/// `MappingRunOutcome` counter, a `ValidationReport` group, an
/// `ManifestExport.Summary` or a `Revalidation`. A slot FormaCore left unknown
/// says so, and a request FormaCore refused reports its own error text.
struct MappingView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var selectedFile: UUID?
    @State private var selectedEvidence: String?
    @State private var importing = false

    private var row: WorkspaceModel.MappingRow? {
        model.rows.first { $0.sourceID == selectedFile }
    }

    var body: some View {
        NavigationSplitView {
            runPanel
                .navigationTitle("Mapping")
                .navigationSplitViewColumnWidth(min: 250, ideal: 310)
        } detail: {
            if model.rows.isEmpty {
                ContentUnavailableView("No mapping result", systemImage: "tablecells",
                                       description: Text(emptyReason))
            } else {
                HSplitView {
                    fileTable
                        .frame(minWidth: 430)
                    detailPane
                        .frame(minWidth: 300, idealWidth: 390)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.phase.isBusy {
                    Button("Cancel", systemImage: "stop.circle") { model.cancelWork() }
                        .accessibilityIdentifier("cancel-mapping")
                } else {
                    Button("Map Files", systemImage: "square.text.square") {
                        model.runMapping(egress: model.allowCloud)
                    }
                    .disabled(!model.canMap || !model.allowCloud)
                    .help(model.allowCloud
                          ? "Register evidence, then send one mapping request per batch"
                          : "Cloud egress is off, so nothing may be sent: enable it in Settings")
                    .accessibilityIdentifier("run-mapping")
                    Button("Assess Without Egress", systemImage: "desktopcomputer") {
                        model.runMapping(egress: false)
                    }
                    .disabled(!model.canMap)
                    .help("FormaCore refuses every provider request; each file keeps the reason it recorded")
                    .accessibilityIdentifier("assess-local")
                }
                Button("Export…", systemImage: "square.and.arrow.up", action: chooseExportDirectory)
                    .disabled(model.manifest == nil || model.phase.isBusy)
                    .help("Write the manifest, report, exceptions, evidence rows, versions and digests")
                    .accessibilityIdentifier("export-manifest")
                Button("Open Bundle…", systemImage: "folder.badge.magnifyingglass") { importing = true }
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("open-bundle")
                Button("Revalidate", systemImage: "checkmark.seal") { model.revalidate() }
                    .disabled(model.bundleURL == nil || model.phase.isBusy)
                    .accessibilityIdentifier("revalidate-bundle")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .json]) { result in
            switch result {
            case .success(let url): model.loadBundle(from: url)
            case .failure(let error): model.importRejected(error)
            }
        }
        .task(id: selectedFile) {
            selectedEvidence = nil
            if let selectedFile { await model.loadEvidence(for: selectedFile) }
        }
        .sheet(item: $model.draft) { draft in
            correctionSheet(draft)
        }
        .onDisappear { model.cancelWork() }
    }

    private var emptyReason: String {
        if model.selectedScope == nil { return "Choose a source in the Workspace area." }
        if model.context == nil {
            return "Build a project context in the Workspace area first: FormaCore will not map files without one."
        }
        if model.manifest == nil { return "Run the mapping engine, or open an exported bundle." }
        return "FormaCore wrote no entry for this run."
    }

    // MARK: - Left panel

    private var runPanel: some View {
        List {
            Section("Run") {
                LabeledContent("Phase", value: model.phase.label)
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let outcome = model.outcome {
                    LabeledContent("Batches", value: outcome.batches.formatted())
                    LabeledContent("Provider requests", value: outcome.requests.formatted())
                    LabeledContent("Refused references", value: outcome.refusedReferences.formatted())
                    LabeledContent("Returned model", value: outcome.modelID ?? "Not reported")
                    LabeledContent("Input tokens", value: outcome.usage.input.map { $0.formatted() } ?? "Not reported")
                    LabeledContent("Output tokens", value: outcome.usage.output.map { $0.formatted() } ?? "Not reported")
                    LabeledContent("Cache read tokens", value: outcome.usage.cacheRead.map { $0.formatted() } ?? "Not reported")
                    LabeledContent("Cache write tokens", value: outcome.usage.cacheCreation.map { $0.formatted() } ?? "Not reported")
                    LabeledContent("Files with a provider failure", value: outcome.failures.count.formatted())
                    LabeledContent("Files FormaCore could not read", value: model.evidenceFailures.count.formatted())
                } else {
                    Text("No engine run in this session. A manifest restored from storage or read from a bundle is shown without run counters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let manifest = model.manifest {
                Section("Manifest revision \(manifest.envelope.revision.formatted())") {
                    LabeledContent("Schema", value: manifest.schemaVersion)
                    LabeledContent("State", value: manifest.envelope.state.rawValue)
                    LabeledContent("Profile", value: "\(manifest.envelope.profileID) · \(manifest.envelope.profileVersion)")
                    LabeledContent("CasePack", value: "\(manifest.envelope.casePackID) · \(manifest.envelope.casePackVersion)")
                    LabeledContent("Provider", value: manifest.envelope.modelProvider)
                    LabeledContent("Model", value: manifest.envelope.modelID ?? "Not reported")
                    LabeledContent("Context revision", value: manifest.envelope.contextRevision.formatted())
                    LabeledContent("Prompt version", value: manifest.envelope.promptVersion)
                    LabeledContent("Extractor version", value: manifest.envelope.extractorVersion)
                    LabeledContent("Redaction version", value: manifest.envelope.redactionVersion ?? "Identity (no terms)")
                    LabeledContent("Built", value: manifest.envelope.createdAt.formatted())
                    LabeledContent("Grants execution", value: manifest.envelope.grantsExecution ? "Yes" : "No · nothing is written")
                    LabeledContent("Entries", value: manifest.entries.count.formatted())
                    LabeledContent("Eligible by policy simulation", value: "\(manifest.eligibleCount.formatted()) of \(manifest.entries.count.formatted())")
                    Text("input \(manifest.envelope.inputDigest)").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Text("context \(manifest.envelope.contextDigest)").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("Validation") {
                    LabeledContent("Fully valid", value: manifest.report.isFullyValid ? "Yes" : "No")
                    LabeledContent("Entries", value: manifest.report.counts.entries.formatted())
                    LabeledContent("Validated", value: manifest.report.counts.validated.formatted())
                    LabeledContent("Hold", value: manifest.report.counts.hold.formatted())
                    LabeledContent("Unknown", value: manifest.report.counts.unknown.formatted())
                    LabeledContent("Invalidated", value: manifest.report.counts.invalidated.formatted())
                    ForEach(manifest.report.groups, id: \.group) { group in
                        LabeledContent(group.group.rawValue,
                                       value: "\(group.status.rawValue) · \(group.violations.count.formatted()) violations")
                    }
                }
            }
            if let decision = model.reconciliation {
                Section("Reconciliation") {
                    LabeledContent("Invalidated files", value: decision.invalidatedSourceIDs.count.formatted())
                    LabeledContent("Reason", value: decision.reason)
                    // Reconciliation is reported even when no manifest is on
                    // screen, so the entry count is read from the model rather
                    // than from the `if let` above, which has already closed.
                    LabeledContent("Still usable",
                                   value: "\(((model.manifest?.entries.count ?? 0) - decision.invalidatedSourceIDs.count).formatted())"
                                       + " of \((model.manifest?.entries.count ?? 0).formatted())")
                }
            }
            if let summary = model.exportSummary {
                Section("Export") {
                    LabeledContent("Manifest", value: summary.manifestID)
                    LabeledContent("Revision", value: summary.revision.formatted())
                    LabeledContent("Entries", value: summary.entries.formatted())
                    LabeledContent("Validated", value: summary.validated.formatted())
                    LabeledContent("Hold", value: summary.hold.formatted())
                    LabeledContent("Unknown", value: summary.unknown.formatted())
                    LabeledContent("Eligible", value: summary.eligible.formatted())
                    ForEach(summary.files, id: \.self) { name in
                        Text(name).font(.caption.monospaced())
                    }
                }
            }
            if let revalidation = model.revalidation {
                Section("Offline revalidation") {
                    LabeledContent("Artifact consistent", value: revalidation.artifactConsistent ? "Yes" : "No")
                    LabeledContent("Revision", value: revalidation.revision.formatted())
                    LabeledContent("Violations", value: revalidation.violations.count.formatted())
                    LabeledContent("Missing evidence rows", value: revalidation.missingEvidence.count.formatted())
                    LabeledContent("Digest mismatches", value: revalidation.digestMismatch.count.formatted())
                    LabeledContent("Grants execution", value: revalidation.grantsExecution ? "Yes" : "No")
                    ForEach(revalidation.violations.indices, id: \.self) { index in
                        let violation = revalidation.violations[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(violation.code) · \(violation.instancePath)").font(.caption.monospaced())
                            Text(violation.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Model settings") {
                LabeledContent("Provider", value: model.provider.displayName)
                LabeledContent("Model", value: model.modelID)
                LabeledContent("Files per batch", value: model.entryLimit.formatted())
                LabeledContent("Cloud egress", value: model.allowCloud ? "Consented for one run" : "Off")
                Text("Provider, model and egress consent are set in the Settings area.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Table

    private var fileTable: some View {
        Table(model.rows, selection: $selectedFile) {
            TableColumn("Relative path") { row in
                Text(row.entry.relativePath).lineLimit(1).help(row.entry.relativePath)
            }
            TableColumn("documentcategory") { row in
                Text(row.value(.documentcategory)).lineLimit(1).help(row.value(.documentcategory))
            }
            .width(min: 110, ideal: 140)
            TableColumn("documenttype") { row in
                Text(row.value(.documenttype)).lineLimit(1).help(row.value(.documenttype))
            }
            .width(min: 100, ideal: 130)
            TableColumn("State") { row in
                Text(row.entry.state.rawValue)
            }
            .width(min: 80, ideal: 95)
            TableColumn("Confidence (model-reported)") { row in
                Text(row.entry.confidence?.rawValue ?? "Not reported")
                    .help("Reported by the model. FormaCore's evidence rules, not this value, decide eligibility.")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Eligible (policy simulation)") { row in
                Text(row.entry.eligibleForAutoExecution ? "Simulated yes" : "Simulated no")
                    .help("Policy simulation only. FormaCore writes nothing to any database.")
            }
            .width(min: 130, ideal: 160)
            TableColumn("Evidence") { row in
                Text("\(row.entry.fields.reduce(0) { $0 + $1.evidenceIDs.count }).formatted()")
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detailPane: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.entry.relativePath)
                        .font(.headline)
                        .textSelection(.enabled)
                    LabeledContent("Decision state", value: row.entry.state.rawValue)
                    LabeledContent("Model-reported confidence", value: row.entry.confidence?.rawValue ?? "Not reported")
                    LabeledContent("Eligible for auto-execution",
                                   value: row.entry.eligibleForAutoExecution
                                    ? "Yes · policy simulation, nothing is written"
                                    : "No · policy simulation, nothing is written")
                    LabeledContent("Cluster", value: clusterText(row))
                    LabeledContent("Target group", value: targetText(row.entry.target))
                    LabeledContent("Snapshot", value: "revision \(row.entry.snapshotRevision.formatted()) · \(row.entry.snapshotFingerprint)")
                        .font(.caption)
                    LabeledContent("Source version", value: row.entry.sourceVersion.formatted())
                    LabeledContent("File state", value: sourceText(row.source))
                    if let reason = row.entry.invalidatedReason {
                        LabeledContent("Invalidated by FormaCore", value: reason)
                    }
                    if let failure = row.failure {
                        Divider()
                        Text("Provider failure").font(.subheadline)
                        Text(failure.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Metadata slots").font(.subheadline)
                    ForEach(MetadataFieldID.allCases, id: \.self) { field in
                        slotRow(row, field)
                    }
                    Divider()
                    evidencePane
                    if let reasoning = row.entry.providerReasoning {
                        Divider()
                        Text("Provider reasoning").font(.caption).foregroundStyle(.secondary)
                        Text(reasoning).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "tablecells")
        }
    }

    @ViewBuilder private func slotRow(_ row: WorkspaceModel.MappingRow, _ field: MetadataFieldID) -> some View {
        let outcome = row.entry.outcome(for: field)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.rawValue).font(.caption.monospaced())
                Text(outcome?.status.rawValue ?? "not written").font(.caption2).foregroundStyle(.secondary)
                if let policy = model.selectedProfile?.fields[field] {
                    Text(policy.requiredForValidated ? "required" : "optional")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(policy.rule)
                }
            }
            Text(outcome?.value ?? "No value")
                .font(.callout)
                .textSelection(.enabled)
            if let outcome, !outcome.conflicts.isEmpty {
                ForEach(outcome.conflicts, id: \.self) { conflict in
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let outcome, !outcome.evidenceIDs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(outcome.evidenceIDs, id: \.self) { id in
                        Button(chipTitle(id)) { selectedEvidence = id }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .accessibilityIdentifier("evidence-\(id)")
                    }
                }
            } else {
                Text("No evidence cited for this slot").font(.caption2).foregroundStyle(.secondary)
            }
            // A reviewer can disagree with a slot, but not quietly: the sheet
            // asks which registered rows the new value rests on, and FormaCore
            // decides whether that is enough to record a new revision.
            Button("Correct…") { model.beginCorrection(sourceID: row.sourceID, field: field) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.phase.isBusy)
                .accessibilityIdentifier("correct-\(field.rawValue)")
            Divider()
        }
    }

    @ViewBuilder private func correctionSheet(_ draft: WorkspaceModel.CorrectionDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct \(draft.field.rawValue)").font(.headline)
            if let policy = model.selectedProfile?.fields[draft.field] {
                Text(policy.rule).font(.caption).foregroundStyle(.secondary)
            }
            TextField("New value", text: Binding(
                get: { draft.value },
                set: { model.draft?.value = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("correction-value")
            Text("An empty value clears the slot and needs no citation.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Cite the rows this decision rests on").font(.subheadline)
            let rows = model.evidenceBySource[draft.sourceID] ?? []
            if rows.isEmpty {
                Text("No registered evidence for this file, so a value here will be refused as an opinion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.id) { record in
                        Toggle(isOn: Binding(
                            get: { draft.citations.contains(record.id) },
                            set: { turning in
                                if turning { model.draft?.citations.insert(record.id) }
                                else { model.draft?.citations.remove(record.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(record.source.rawValue) · \(record.id)").font(.caption.monospaced())
                                Text(record.excerpt ?? "No excerpt").font(.caption2).lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("cite-\(record.id)")
                    }
                }
            }
            Divider()
            HStack {
                Button("Cancel") { model.cancelCorrection() }
                    .accessibilityIdentifier("cancel-correction")
                Button("Record Correction") { model.applyCorrection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("record-correction")
            }
        }
        .padding(15)
        .frame(width: 540, height: 480)
    }

    @ViewBuilder private var evidencePane: some View {
        if let id = selectedEvidence {
            if let record = model.record(for: id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evidence \(record.id)").font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Source", value: record.source.rawValue)
                    LabeledContent("Locator", value: locatorText(record.locator))
                    LabeledContent("Extraction", value: record.extractionStatus.rawValue)
                    LabeledContent("Usable", value: record.isUsable ? "Yes" : "No")
                    LabeledContent("Extractor", value: record.extractorVersion)
                    LabeledContent("Read", value: record.createdAt.formatted())
                    if let path = record.relativePath {
                        LabeledContent("Path", value: path)
                    }
                    if let candidate = record.contextCandidateID {
                        LabeledContent("Inherited through candidate", value: candidate)
                    }
                    Text(record.excerpt ?? "No excerpt stored")
                        .font(.caption)
                        .textSelection(.enabled)
                    if let prompt = EvidenceRegistry.promptExcerpt(record) {
                        Text("Prompt excerpt (\(EvidenceRegistry.maximumPromptExcerptCharacters.formatted()) characters)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(prompt).font(.caption).textSelection(.enabled)
                    }
                }
            } else {
                Text("Evidence row \(id) is not in the local registry: \(FormaError.unavailable.localizedDescription) Open the exported bundle's \(ManifestExport.evidenceFile) to read it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text("Select an evidence chip to read its excerpt and locator.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Text helpers

    private func chipTitle(_ id: String) -> String {
        guard let record = model.record(for: id) else { return FormaError.unavailable.localizedDescription }
        return "\(record.source.rawValue) · \(String(id.dropFirst(3).prefix(6)))"
    }

    private func clusterText(_ row: WorkspaceModel.MappingRow) -> String {
        guard !row.candidates.isEmpty else { return model.context == nil ? "No context" : "Unassigned" }
        return row.candidates
            .map { "\($0.projectKey) (\($0.confidence.rawValue))" }
            .sorted()
            .joined(separator: " · ")
    }

    private func targetText(_ target: ManifestTarget) -> String {
        let database = target.databaseName ?? "No database named"
        let path = target.groupPath.isEmpty ? "No group template" : target.groupPath.joined(separator: " / ")
        return "\(database) · \(path) · \(target.resolved ? "resolved" : "unresolved placeholder")"
    }

    private func sourceText(_ source: SourceEntry?) -> String {
        guard let source else { return "Not in this listing" }
        return source.state.rawValue + (source.hydrationPending ? " · cloud placeholder" : "")
    }

    private func locatorText(_ locator: EvidenceLocator?) -> String {
        switch locator {
        case .pdf(let page, let range): "PDF page \(page) · UTF-16 \(range.lowerBound)–\(range.upperBound)"
        case .docx(let part, let paragraph, _): "\(part) · paragraph \(paragraph)"
        case .xlsx(let sheet, let cell): "\(sheet) · \(cell)"
        case nil: "No content locator"
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
}
