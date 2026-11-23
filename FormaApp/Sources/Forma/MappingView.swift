import FormaCore
import SwiftUI

/// The mapping area inside the shell: the run/manifest diagnostics pane and the
/// file table. The per-file detail, the metadata slots and the evidence rows
/// moved to the shell inspector (`MappingInspector`); the toolbar commands to
/// the shell grammar. Every value here is still FormaCore's: a `ManifestEntry`
/// field outcome, a `MappingRunOutcome` counter, a `ValidationReport` group, an
/// `ManifestExport.Summary` or a `Revalidation`. A slot FormaCore left unknown
/// says so, and a request FormaCore refused reports its own error text.
struct MappingView: View {
    @ObservedObject var model: WorkspaceModel
    /// The width bounds the shell declared for this area's leading pane.
    let leading: AreaWidth

    var body: some View {
        HSplitView {
            runPanel
                .areaWidth(leading)
            if model.rows.isEmpty {
                ContentUnavailableView("No mapping result", systemImage: "tablecells",
                                       description: Text(emptyReason))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var emptyReason: String {
        if model.selectedScope == nil { return "先在「工作区」选择一个来源。" }
        if model.context == nil {
            return "先在「工作区」构建项目上下文：没有上下文时 FormaCore 不会映射文件。"
        }
        if model.manifest == nil { return "运行映射引擎，或打开一个已导出的映射包。" }
        return "FormaCore 本次运行没有写出任何条目。"
    }

    // MARK: - Diagnostics pane

    private var runPanel: some View {
        List {
            Section("Run") {
                Picker("Mode", selection: Binding(get: { model.plannerMode },
                                                  set: { model.plannerMode = $0 })) {
                    ForEach([WorkspaceModel.PlannerMode.offline, .ai], id: \.self) { mode in
                        Text(plannerModeLabel(mode.grammar)).tag(mode)
                    }
                }
                .accessibilityIdentifier("mapping-mode")
                if model.plannerMode == .offline {
                    // The mode switch is the reachable statement of what
                    // offline means; the banner no longer repeats it at length
                    // (owner decision: Offline Planner stays, not promoted).
                    Label(offlinePlannerShortNotice, systemImage: "iphone.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("offline-mode-notice")
                }
                LabeledContent("Phase", value: model.phase.label)
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
                    let digestCopy = businessCopy(for: "digest")
                    Text("input \(manifest.envelope.inputDigest)").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .help(digestCopy.sentence)
                        .accessibilityIdentifier("diagnostic-raw-input-digest")
                    Text("context \(manifest.envelope.contextDigest)").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .help(digestCopy.sentence)
                        .accessibilityIdentifier("diagnostic-raw-context-digest")
                }
                Section("Correction attempts") {
                    // Each way this list can be empty says something different,
                    // and only one of them is a fact about the manifest: a
                    // refusal still happened, an unread list says nothing about
                    // whether anything happened, and a bundle exported elsewhere
                    // has its attempts in a store this machine cannot open.
                    switch model.correctionHistoryState {
                    case .notRead:
                        Text("Attempts for this manifest have not been read from storage yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .offlineBundle:
                        Text("This bundle was exported elsewhere; its correction attempts are not stored here.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .fromStore:
                        if model.correctionHistory.isEmpty {
                            Text("No reviewer decision has been recorded for this manifest.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .readFailed:
                        Text("The history could not be read from storage, so only the decision just "
                            + "made is listed here. This is not the full set of attempts.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(model.correctionHistory, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.field.rawValue) → \(record.correctedValue ?? "cleared")")
                                .font(.caption)
                            Text(Self.outcomeLine(record).text)
                                .font(.caption2)
                                .foregroundStyle(Self.outcomeLine(record).color)
                        }
                        .accessibilityIdentifier("correction-\(record.id)")
                    }
                }
                Section("Validation") {
                    LabeledContent("Fully valid", value: manifest.report.isFullyValid ? "Yes" : "No")
                    LabeledContent("Entries", value: manifest.report.counts.entries.formatted())
                    LabeledContent("Validated", value: manifest.report.counts.validated.formatted())
                    LabeledContent("Hold", value: manifest.report.counts.hold.formatted())
                    LabeledContent("Unknown", value: manifest.report.counts.unknown.formatted())
                    LabeledContent("Invalidated", value: manifest.report.counts.invalidated.formatted())
                    ForEach(manifest.report.groups, id: \.group) { group in
                        LabeledContent(businessCopy(for: group.group.rawValue).headline,
                                       value: "\(businessCopy(for: group.status.rawValue).headline) · \(group.violations.count.formatted()) violations")
                            .help(businessCopy(for: group.group.rawValue).sentence)
                            .accessibilityIdentifier("diagnostic-raw-\(group.group.rawValue)")
                    }
                }
            }
            // A reconciliation is a judgement about a specific manifest, so it
            // is shown with the manifest it was computed against and nowhere
            // else: a count of "still usable" without the entry total it came
            // from is a number about nothing.
            if let manifest = model.manifest, let decision = model.reconciliation {
                Section("Reconciliation") {
                    LabeledContent("Invalidated files", value: decision.invalidatedSourceIDs.count.formatted())
                    LabeledContent("Reason", value: decision.reason)
                    LabeledContent("Still usable",
                                   value: "\((manifest.entries.count - decision.invalidatedSourceIDs.count).formatted())"
                                       + " of \(manifest.entries.count.formatted())")
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
                        let copy = businessCopy(for: violation.code)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(copy.headline) · \(violation.instancePath)")
                                .font(.caption)
                            Text(violation.detail).font(.caption2).foregroundStyle(.secondary)
                            // The raw code lives here and nowhere else the
                            // person reads as prose (owner failure #8).
                            DisclosureGroup("诊断详情") {
                                Text("\(copy.rawCode) · \(violation.instancePath)")
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                            .font(.caption2)
                        }
                        .accessibilityIdentifier("diagnostic-raw-\(violation.code)-\(index)")
                    }
                }
            }
            Section("Model settings") {
                LabeledContent("Provider", value: model.provider.displayName)
                LabeledContent("Model", value: model.modelID)
                LabeledContent("Files per batch", value: model.entryLimit.formatted())
                LabeledContent(EgressConsent.shortLabel,
                               value: model.allowCloud ? "本次运行已获同意" : "关闭")
                Text("Provider、模型与外发许可在「设置」区域调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Table

    private var fileTable: some View {
        Table(model.rows, selection: $model.mappingFileSelection) {
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
                let copy = businessCopy(for: row.entry.state.rawValue)
                Text(copy.headline)
                    .help(copy.sentence)
                    .accessibilityIdentifier("diagnostic-raw-\(row.entry.state.rawValue)")
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

    /// One attempt, described by what it did to the version history: a stored
    /// decision names the revision it wrote, a refusal names the one it read
    /// and wrote nothing. A verified row with no revision is the later of two
    /// accepted attempts that both recorded the same revision they read - the
    /// version 1 migration credits the successor to the earlier one and leaves
    /// this one unattributed rather than guessing. Anything else came from
    /// outside a review.
    private static func outcomeLine(_ record: CorrectionRecord) -> (text: String, color: Color) {
        switch (record.reviewState, record.producedRevision) {
        case (.evidenceVerified, let produced?):
            ("Recorded at revision \(produced.formatted()), superseding "
                + "\(record.manifestRevision.formatted()) · replaced \(record.previousValue ?? "nothing")",
             .secondary)
        case (.rejected, _):
            ("Refused by FormaCore · attempted against revision "
                + "\(record.manifestRevision.formatted()) · published nothing", .orange)
        case (.evidenceVerified, nil):
            ("Verified decision against revision \(record.manifestRevision.formatted()) - a second "
                + "attempt named the same revision, so the version 1 migration left this one without "
                + "a version it wrote", .orange)
        default:
            ("Row \(record.id) is neither shape a review produces - verified with the revision it "
                + "wrote, or refused with none: it carries \(record.reviewState.rawValue) with "
                + (record.producedRevision.map { "revision \($0.formatted())" } ?? "no produced revision"),
             .red)
        }
    }
}

/// The mapping inspector: the selected file's manifest entry, its metadata
/// slots with evidence chips, and the evidence rows behind those chips. This is
/// the detail pane the area used to own; the corrections it launches are still
/// decided by FormaCore alone.
@MainActor
struct MappingInspector: View {
    @ObservedObject var model: WorkspaceModel

    private var row: WorkspaceModel.MappingRow? {
        model.rows.first { $0.sourceID == model.mappingFileSelection }
    }

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.entry.relativePath)
                        .font(.headline)
                        .textSelection(.enabled)
                    let stateCopy = businessCopy(for: row.entry.state.rawValue)
                    LabeledContent("Decision state", value: stateCopy.headline)
                        .help(stateCopy.sentence)
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
                        let copy = businessCopy(for: reason)
                        LabeledContent("Invalidated by FormaCore", value: copy.headline)
                            .help(copy.sentence)
                            .accessibilityIdentifier("diagnostic-raw-\(reason)")
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
            ContentUnavailableView("Select a file", systemImage: "tablecells",
                                   description: Text("在「映射」的文件表中选择一行。"))
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
                        Button(chipTitle(id)) { model.mappingEvidenceSelection = id }
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

    @ViewBuilder private var evidencePane: some View {
        if let id = model.mappingEvidenceSelection {
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
                Text("Evidence row \(id) has not been read into this session. It is stored in the exported bundle's \(ManifestExport.evidenceFile), and FormaCore keeps every row an older revision cited.")
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
        guard let record = model.record(for: id) else { return "Row not read · \(String(id.dropFirst(3).prefix(6)))" }
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
        case .text(let range): "UTF-16 \(range.lowerBound)–\(range.upperBound)"
        case nil: "No content locator"
        }
    }
}

/// The correction sheet, presented by the shell for whichever area launched
/// it. Its bindings write only into the model's draft; FormaCore alone decides
/// whether the citations recorded are enough for a new revision.
@MainActor
struct CorrectionSheet: View {
    @ObservedObject var model: WorkspaceModel
    let draft: WorkspaceModel.CorrectionDraft

    var body: some View {
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
                if model.recordingDraftID == draft.id {
                    // A disabled button alone says nothing about a click that
                    // was accepted: the press looks ignored, so the reviewer
                    // presses again. Keyed on this draft rather than on the
                    // model's phase, which another operation can hold.
                    ProgressView().controlSize(.small)
                    Text("Recording…").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("correction-progress")
                } else {
                    Button("Record Correction") { model.applyCorrection() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.phase.isBusy)
                        .accessibilityIdentifier("record-correction")
                }
            }
        }
        .padding(15)
        .frame(width: 540, height: 480)
    }
}
