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

    /// The column budget the shell declared for the result table.
    private var rowWidths: [ShellColumnWidth] { ShellLayout.columns(for: .mappingRows) }

    var body: some View {
        HSplitView {
            runPanel
                .areaWidth(leading)
            if model.rows.isEmpty {
                ContentUnavailableView(ProductCopy.ReviewVocabulary.noMappingResult, systemImage: "tablecells",
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
            Section(ProductCopy.ReviewVocabulary.run) {
                Picker(ProductCopy.ReviewVocabulary.mode, selection: Binding(get: { model.plannerMode },
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
                LabeledContent(ProductCopy.ReviewVocabulary.phase, value: model.phase.label)
                if let outcome = model.outcome {
                    LabeledContent("Batches", value: outcome.batches.formatted())
                    LabeledContent("Provider requests", value: outcome.requests.formatted())
                    LabeledContent("Refused references", value: outcome.refusedReferences.formatted())
                    LabeledContent("Returned model", value: outcome.modelID ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Input tokens", value: outcome.usage.input.map { $0.formatted() } ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Output tokens", value: outcome.usage.output.map { $0.formatted() } ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Cache read tokens", value: outcome.usage.cacheRead.map { $0.formatted() } ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Cache write tokens", value: outcome.usage.cacheCreation.map { $0.formatted() } ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Files with a provider failure", value: outcome.failures.count.formatted())
                    LabeledContent("Files FormaCore could not read", value: model.evidenceFailures.count.formatted())
                } else {
                    Text(ProductCopy.Notice.noManifestRunThisSession)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let manifest = model.manifest {
                Section(ProductCopy.ReviewVocabulary.manifestRevision(manifest.envelope.revision)) {
                    LabeledContent("Schema", value: manifest.schemaVersion)
                    LabeledContent(ProductCopy.ReviewVocabulary.state, value: manifest.envelope.state.rawValue)
                    LabeledContent("Profile", value: "\(manifest.envelope.profileID) · \(manifest.envelope.profileVersion)")
                    LabeledContent("CasePack", value: "\(manifest.envelope.casePackID) · \(manifest.envelope.casePackVersion)")
                    LabeledContent("Provider", value: manifest.envelope.modelProvider)
                    LabeledContent("Model", value: manifest.envelope.modelID ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent("Context revision", value: manifest.envelope.contextRevision.formatted())
                    LabeledContent("Prompt version", value: manifest.envelope.promptVersion)
                    LabeledContent("Extractor version", value: manifest.envelope.extractorVersion)
                    LabeledContent("Redaction version", value: manifest.envelope.redactionVersion ?? ProductCopy.ReviewVocabulary.identityRedaction)
                    LabeledContent(ProductCopy.Workspace.builtAt, value: manifest.envelope.createdAt.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.grantsExecution,
                                   value: manifest.envelope.grantsExecution
                                    ? ProductCopy.ReviewVocabulary.yes
                                    : "\(ProductCopy.ReviewVocabulary.no) · \(ProductCopy.ReviewVocabulary.nothingWritten)")
                    LabeledContent(ProductCopy.ReviewVocabulary.entries, value: manifest.entries.count.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.eligibleBySimulation,
                                   value: ProductCopy.ReviewVocabulary.countPair(manifest.eligibleCount, manifest.entries.count))
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
                Section(ProductCopy.ReviewVocabulary.correctionAttempts) {
                    // Each way this list can be empty says something different,
                    // and only one of them is a fact about the manifest: a
                    // refusal still happened, an unread list says nothing about
                    // whether anything happened, and a bundle exported elsewhere
                    // has its attempts in a store this machine cannot open.
                    switch model.correctionHistoryState {
                    case .notRead:
                        Text(ProductCopy.ReviewVocabulary.correctionNotRead)
                            .font(.caption).foregroundStyle(.secondary)
                    case .offlineBundle:
                        Text(ProductCopy.ReviewVocabulary.correctionStoredElsewhere)
                            .font(.caption).foregroundStyle(.secondary)
                    case .fromStore:
                        if model.correctionHistory.isEmpty {
                            Text(ProductCopy.ReviewVocabulary.correctionNone)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .readFailed:
                        Text(ProductCopy.ReviewVocabulary.correctionReadFailed)
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(model.correctionHistory, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.field.rawValue) → \(record.correctedValue ?? ProductCopy.ReviewVocabulary.cleared)")
                                .font(.caption)
                            Text(Self.outcomeLine(record).text)
                                .font(.caption2)
                                .foregroundStyle(Self.outcomeLine(record).color)
                        }
                        .accessibilityIdentifier("correction-\(record.id)")
                    }
                }
                Section(ProductCopy.ReviewVocabulary.validation) {
                    LabeledContent(ProductCopy.ReviewVocabulary.fullyValid,
                                   value: manifest.report.isFullyValid ? ProductCopy.ReviewVocabulary.yes : ProductCopy.ReviewVocabulary.no)
                    LabeledContent(ProductCopy.ReviewVocabulary.entries, value: manifest.report.counts.entries.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.validated, value: manifest.report.counts.validated.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.hold, value: manifest.report.counts.hold.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.unknown, value: manifest.report.counts.unknown.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.invalidated, value: manifest.report.counts.invalidated.formatted())
                    ForEach(manifest.report.groups, id: \.group) { group in
                        LabeledContent(businessCopy(for: group.group.rawValue).headline,
                                       value: "\(businessCopy(for: group.status.rawValue).headline) · \(group.violations.count.formatted()) \(ProductCopy.ReviewVocabulary.violations)")
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
                Section(ProductCopy.ReviewVocabulary.reconciliation) {
                    LabeledContent(ProductCopy.ReviewVocabulary.invalidatedFiles, value: decision.invalidatedSourceIDs.count.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.reason, value: decision.reason)
                    LabeledContent(ProductCopy.ReviewVocabulary.stillUsable,
                                   value: ProductCopy.ReviewVocabulary.countPair(
                                        manifest.entries.count - decision.invalidatedSourceIDs.count,
                                        manifest.entries.count))
                }
            }
            if let summary = model.exportSummary {
                Section(ProductCopy.ReviewVocabulary.export) {
                    LabeledContent(ProductCopy.ReviewVocabulary.manifest, value: summary.manifestID)
                    LabeledContent(ProductCopy.Workspace.revisionLabel, value: summary.revision.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.entries, value: summary.entries.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.validated, value: summary.validated.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.hold, value: summary.hold.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.unknown, value: summary.unknown.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.eligible, value: summary.eligible.formatted())
                    ForEach(summary.files, id: \.self) { name in
                        Text(name).font(.caption.monospaced())
                    }
                }
            }
            if let revalidation = model.revalidation {
                Section(ProductCopy.ReviewVocabulary.offlineRevalidation) {
                    LabeledContent(ProductCopy.ReviewVocabulary.artifactConsistent,
                                   value: revalidation.artifactConsistent ? ProductCopy.ReviewVocabulary.yes : ProductCopy.ReviewVocabulary.no)
                    LabeledContent(ProductCopy.Workspace.revisionLabel, value: revalidation.revision.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.violations, value: revalidation.violations.count.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.missingEvidenceRows, value: revalidation.missingEvidence.count.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.digestMismatches, value: revalidation.digestMismatch.count.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.grantsExecution,
                                   value: revalidation.grantsExecution ? ProductCopy.ReviewVocabulary.yes : ProductCopy.ReviewVocabulary.no)
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
            Section(ProductCopy.ReviewVocabulary.modelSettings) {
                LabeledContent("Provider", value: model.provider.displayName)
                LabeledContent("模型", value: model.modelID)
                LabeledContent(ProductCopy.ReviewVocabulary.filesPerBatch, value: model.entryLimit.formatted())
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
            TableColumn(ProductCopy.ReviewVocabulary.relativePath) { row in
                Text(row.entry.relativePath).lineLimit(1).help(row.entry.relativePath)
            }
            .width(min: rowWidths[0].cgMin, ideal: rowWidths[0].cgIdeal, max: rowWidths[0].cgMax)
            TableColumn("documentcategory") { row in
                Text(row.value(.documentcategory)).lineLimit(1).help(row.value(.documentcategory))
            }
            .width(min: rowWidths[1].cgMin, ideal: rowWidths[1].cgIdeal, max: rowWidths[1].cgMax)
            TableColumn("documenttype") { row in
                Text(row.value(.documenttype)).lineLimit(1).help(row.value(.documenttype))
            }
            .width(min: rowWidths[2].cgMin, ideal: rowWidths[2].cgIdeal, max: rowWidths[2].cgMax)
            TableColumn(ProductCopy.ReviewVocabulary.state) { row in
                let copy = businessCopy(for: row.entry.state.rawValue)
                Text(copy.headline)
                    .help(copy.sentence)
                    .accessibilityIdentifier("diagnostic-raw-\(row.entry.state.rawValue)")
            }
            .width(min: rowWidths[3].cgMin, ideal: rowWidths[3].cgIdeal, max: rowWidths[3].cgMax)
            TableColumn(ProductCopy.ReviewVocabulary.confidenceModelReported) { row in
                Text(row.entry.confidence?.rawValue ?? ProductCopy.ReviewVocabulary.notReported)
                    .help(ProductCopy.ReviewVocabulary.confidenceHelp)
            }
            .width(min: rowWidths[4].cgMin, ideal: rowWidths[4].cgIdeal, max: rowWidths[4].cgMax)
            TableColumn(ProductCopy.ReviewVocabulary.eligibleSimulationColumn) { row in
                Text(row.entry.eligibleForAutoExecution ? ProductCopy.ReviewVocabulary.simulatedYes : ProductCopy.ReviewVocabulary.simulatedNo)
                    .help(ProductCopy.ReviewVocabulary.policySimulationHelp)
            }
            .width(min: rowWidths[5].cgMin, ideal: rowWidths[5].cgIdeal, max: rowWidths[5].cgMax)
            TableColumn(ProductCopy.ReviewVocabulary.evidenceCount) { row in
                Text("\(row.entry.fields.reduce(0) { $0 + $1.evidenceIDs.count }).formatted()")
                    .monospacedDigit()
            }
            .width(min: rowWidths[6].cgMin, ideal: rowWidths[6].cgIdeal, max: rowWidths[6].cgMax)
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
            (ProductCopy.ReviewVocabulary.correctionRecorded(
                produced: produced,
                superseded: record.manifestRevision,
                previous: record.previousValue),
             .secondary)
        case (.rejected, _):
            (ProductCopy.ReviewVocabulary.correctionRefused(against: record.manifestRevision), .orange)
        case (.evidenceVerified, nil):
            (ProductCopy.ReviewVocabulary.correctionUnattributed(revision: record.manifestRevision), .orange)
        default:
            (ProductCopy.ReviewVocabulary.correctionAnomalous(
                id: record.id,
                state: record.reviewState.rawValue,
                produced: record.producedRevision.map { $0.formatted() }),
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

    private var row: MappingRow? {
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
                    LabeledContent(ProductCopy.ReviewVocabulary.decisionState, value: stateCopy.headline)
                        .help(stateCopy.sentence)
                    LabeledContent(ProductCopy.ReviewVocabulary.modelReportedConfidence, value: row.entry.confidence?.rawValue ?? ProductCopy.ReviewVocabulary.notReported)
                    LabeledContent(ProductCopy.ReviewVocabulary.eligibleForAutoExecution,
                                   value: row.entry.eligibleForAutoExecution
                                    ? "\(ProductCopy.ReviewVocabulary.yes) · \(ProductCopy.ReviewVocabulary.policySimulationNothingWritten)"
                                    : "\(ProductCopy.ReviewVocabulary.no) · \(ProductCopy.ReviewVocabulary.policySimulationNothingWritten)")
                    LabeledContent(ProductCopy.Workspace.project, value: clusterText(row))
                    LabeledContent(ProductCopy.ReviewVocabulary.targetGroup, value: targetText(row.entry.target))
                    LabeledContent(ProductCopy.ReviewVocabulary.snapshot,
                                   value: "\(ProductCopy.Workspace.revisionLabel) \(row.entry.snapshotRevision.formatted()) · \(row.entry.snapshotFingerprint)")
                        .font(.caption)
                    LabeledContent(ProductCopy.Workspace.sourceVersion, value: row.entry.sourceVersion.formatted())
                    LabeledContent(ProductCopy.ReviewVocabulary.fileState, value: sourceText(row.source))
                    if let reason = row.entry.invalidatedReason {
                        let copy = businessCopy(for: reason)
                        LabeledContent(ProductCopy.ReviewVocabulary.invalidatedBy, value: copy.headline)
                            .help(copy.sentence)
                            .accessibilityIdentifier("diagnostic-raw-\(reason)")
                    }
                    if let failure = row.failure {
                        Divider()
                        Text(ProductCopy.ReviewVocabulary.providerFailure).font(.subheadline)
                        Text(failure.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(ProductCopy.ReviewVocabulary.metadataSlots).font(.subheadline)
                    ForEach(MetadataFieldID.allCases, id: \.self) { field in
                        slotRow(row, field)
                    }
                    Divider()
                    evidencePane
                    if let reasoning = row.entry.providerReasoning {
                        Divider()
                        Text(ProductCopy.ReviewVocabulary.providerReasoning).font(.caption).foregroundStyle(.secondary)
                        Text(reasoning).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        } else {
            ContentUnavailableView(ProductCopy.ReviewVocabulary.selectFile, systemImage: "tablecells",
                                   description: Text("在「映射」的文件表中选择一行。"))
        }
    }

    @ViewBuilder private func slotRow(_ row: MappingRow, _ field: MetadataFieldID) -> some View {
        let outcome = row.entry.outcome(for: field)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.rawValue).font(.caption.monospaced())
                Text(outcome?.status.rawValue ?? ProductCopy.ReviewVocabulary.notWritten).font(.caption2).foregroundStyle(.secondary)
                if let policy = model.selectedProfile?.fields[field] {
                    Text(policy.requiredForValidated ? ProductCopy.ReviewVocabulary.required : ProductCopy.ReviewVocabulary.optional)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(policy.rule)
                }
            }
            Text(outcome?.value ?? ProductCopy.ReviewVocabulary.noValue)
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
                Text(ProductCopy.ReviewVocabulary.noEvidenceCited).font(.caption2).foregroundStyle(.secondary)
            }
            // A reviewer can disagree with a slot, but not quietly: the sheet
            // asks which registered rows the new value rests on, and FormaCore
            // decides whether that is enough to record a new revision.
            Button(ProductCopy.ReviewVocabulary.correct) { model.beginCorrection(sourceID: row.sourceID, field: field) }
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
                    LabeledContent(ProductCopy.ReviewVocabulary.source, value: record.source.rawValue)
                    LabeledContent(ProductCopy.ReviewVocabulary.locator, value: locatorText(record.locator))
                    LabeledContent(ProductCopy.ReviewVocabulary.extraction, value: record.extractionStatus.rawValue)
                    LabeledContent(ProductCopy.ReviewVocabulary.usable, value: record.isUsable ? ProductCopy.ReviewVocabulary.yes : ProductCopy.ReviewVocabulary.no)
                    LabeledContent(ProductCopy.ReviewVocabulary.extractor, value: record.extractorVersion)
                    LabeledContent(ProductCopy.ReviewVocabulary.readAt, value: record.createdAt.formatted())
                    if let path = record.relativePath {
                        LabeledContent(ProductCopy.ReviewVocabulary.path, value: path)
                    }
                    if let candidate = record.contextCandidateID {
                        LabeledContent(ProductCopy.ReviewVocabulary.inheritedThroughCandidate, value: candidate)
                    }
                    Text(record.excerpt ?? ProductCopy.ReviewVocabulary.noExcerptStored)
                        .font(.caption)
                        .textSelection(.enabled)
                    if let prompt = EvidenceRegistry.promptExcerpt(record) {
                        Text(ProductCopy.ReviewVocabulary.promptExcerpt(characters: EvidenceRegistry.maximumPromptExcerptCharacters))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(prompt).font(.caption).textSelection(.enabled)
                    }
                }
            } else {
                Text(ProductCopy.ReviewVocabulary.evidenceRowNotRead(
                        id: id, bundleFile: ManifestExport.evidenceFile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text(ProductCopy.ReviewVocabulary.selectEvidenceChip)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Text helpers

    private func chipTitle(_ id: String) -> String {
        guard let record = model.record(for: id) else { return "\(ProductCopy.ReviewVocabulary.rowNotRead) · \(String(id.dropFirst(3).prefix(6)))" }
        return "\(record.source.rawValue) · \(String(id.dropFirst(3).prefix(6)))"
    }

    private func clusterText(_ row: MappingRow) -> String {
        guard !row.candidates.isEmpty else {
            return model.context == nil ? ProductCopy.ReviewVocabulary.noContext
                                        : ProductCopy.ReviewVocabulary.unassigned
        }
        return row.candidates
            .map { "\($0.projectKey) (\($0.confidence.rawValue))" }
            .sorted()
            .joined(separator: " · ")
    }

    private func targetText(_ target: ManifestTarget) -> String {
        let database = target.databaseName ?? ProductCopy.ReviewVocabulary.noDatabaseNamed
        let path = target.groupPath.isEmpty ? ProductCopy.ReviewVocabulary.noGroupTemplate : target.groupPath.joined(separator: " / ")
        return "\(database) · \(path) · \(target.resolved ? ProductCopy.ReviewVocabulary.resolved : ProductCopy.ReviewVocabulary.unresolvedPlaceholder)"
    }

    private func sourceText(_ source: SourceEntry?) -> String {
        guard let source else { return ProductCopy.ReviewVocabulary.notInCurrentListing }
        return source.state.rawValue + (source.hydrationPending ? " · \(ProductCopy.Workspace.cloudPlaceholder)" : "")
    }

    private func locatorText(_ locator: EvidenceLocator?) -> String {
        switch locator {
        case .pdf(let page, let range): "PDF page \(page) · UTF-16 \(range.lowerBound)–\(range.upperBound)"
        case .docx(let part, let paragraph, _): "\(part) · paragraph \(paragraph)"
        case .xlsx(let sheet, let cell): "\(sheet) · \(cell)"
        case .text(let range): "UTF-16 \(range.lowerBound)–\(range.upperBound)"
        case nil: ProductCopy.ReviewVocabulary.noLocator
        }
    }
}

/// The correction sheet, presented by the shell for whichever area launched
/// it. Its bindings write only into the model's draft; FormaCore alone decides
/// whether the citations recorded are enough for a new revision.
///
/// Business-facing per #144 P1: the field is named in Chinese, the category
/// slot offers exactly the Profile's enum choices (never free text), the
/// citable evidence rows read by provenance (文件名/来源目录/正文 · 页/段) and
/// excerpt rather than by opaque registry id - the ids are recorded under the
/// hood for FormaCore and surfaced only in the 诊断详情 expander. A refusal
/// keeps the sheet open with its value and selections intact and names the
/// bucket cause (缺少证据/证据过期/冲突/权限) beside the field.
@MainActor
struct CorrectionSheet: View {
    @ObservedObject var model: WorkspaceModel
    let draft: WorkspaceModel.CorrectionDraft

    /// Refusal codes captured while THIS sheet was open. A notice left over
    /// from an earlier field's refusal must not pre-fill a fresh sheet
    /// (`onAppear` starts from no codes; only a later transition counts), and
    /// a published success clears the list on its way through.
    @State private var refusalCodes: [String] = []

    private var policy: MetadataFieldPolicy? { model.selectedProfile?.fields[draft.field] }

    /// The live draft's text. `draft` is the presented snapshot; `model.draft`
    /// is what the bindings write, so reads go through the model with the
    /// snapshot as the fallback - the only way a typed value is certain to
    /// show up in its own field.
    private var currentText: String { model.draft?.value ?? draft.value }
    private var currentCitations: Set<String> { model.draft?.citations ?? draft.citations }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("确认「\(metadataFieldLabel(draft.field))」")
                .font(.title3.bold())
            if let policy {
                Text(policy.rule)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            valueEditor

            Text("留空表示清空该字段，无需引用证据。")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("选择支持上述判断的来源内容")
                .font(.subheadline.weight(.medium))
            Text("只勾选实际包含该事实的证据行；系统仍会按 Profile 规则复核，不会替你确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
            citationList
            if !currentText.isEmpty && currentCitations.isEmpty {
                Label("尚未勾选任何证据，保存会被系统拒绝。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            refusalFeedback

            Divider()
            HStack {
                Spacer()
                Button("取消") { model.cancelCorrection() }
                    .accessibilityIdentifier("cancel-correction")
                if model.recordingDraftID == draft.id {
                    // A disabled button alone says nothing about a click that
                    // was accepted: the press looks ignored, so the reviewer
                    // presses again. Keyed on this draft rather than on the
                    // model's phase, which another operation can hold.
                    ProgressView("正在验证…")
                        .controlSize(.small)
                        .accessibilityIdentifier("correction-progress")
                } else {
                    Button("验证并保存") { model.applyCorrection() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.phase.isBusy)
                        .accessibilityIdentifier("record-correction")
                }
            }
        }
        .padding(20)
        .frame(width: 570, height: 520)
        .onAppear { refusalCodes = [] }
        .onChange(of: model.lastRefusalCodes) { _, codes in
            refusalCodes = codes
        }
    }

    /// The control matches the Profile's declared type: category and document
    /// type are Profile enums, everything else is text. An enum slot can never
    /// carry a value Forma did not offer - that is the #144 gate "available
    /// choices exactly equal Profile categories".
    @ViewBuilder private var valueEditor: some View {
        switch policy?.valueType {
        case .category:
            Picker("文件分类", selection: Binding(
                get: { currentText },
                set: { model.draft?.value = $0 }
            )) {
                Text("请选择分类").tag("")
                ForEach(model.selectedProfile?.categories ?? [], id: \.identifier) { category in
                    Text(category.identifier)
                        .help(category.meaning)
                        .tag(category.identifier)
                }
            }
            .accessibilityIdentifier("review-category-select")
        case .documentType:
            Picker("文件类型", selection: Binding(
                get: { currentText },
                set: { model.draft?.value = $0 }
            )) {
                Text("请选择类型").tag("")
                ForEach(model.selectedProfile?.documentTypes ?? [], id: \.identifier) { type in
                    Text(type.identifier).tag(type.identifier)
                }
            }
            .accessibilityIdentifier("review-document-type-select")
        default:
            TextField("字段内容", text: Binding(
                get: { currentText },
                set: { model.draft?.value = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("correction-value")
        }
    }

    /// Citable rows, grouped by provenance so the reviewer reads 文件名 /
    /// 来源目录 / 正文摘录 instead of a flat id list. Unusable rows stay
    /// visible but unchecked - their absence from a citation is information.
    @ViewBuilder private var citationList: some View {
        let rows = model.evidenceBySource[draft.sourceID] ?? []
        let expired = rows.filter { model.currency(of: $0, for: draft.sourceID) == .expired }
        if rows.isEmpty {
            Text("这份文件还没有登记过证据；只填写内容而不勾选证据的判断会被 FormaCore 拒绝。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !expired.isEmpty {
                        // The rows on screen describe an older snapshot. They
                        // are shown, marked, and not offered: a checked row
                        // that cannot be cited is the trap this replaces.
                        VStack(alignment: .leading, spacing: 4) {
                            Label(EvidenceCurrencyCopy.expiredSentence, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(EvidenceCurrencyCopy.rereadHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(EvidenceCurrencyCopy.rereadAction) { model.rereadEvidence(for: draft.sourceID) }
                                .controlSize(.small)
                                .disabled(model.phase.isBusy)
                                .accessibilityIdentifier("reread-evidence")
                        }
                    }
                    ForEach(CitationGroup.groups(in: rows), id: \.key) { group in
                        Text(group.key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(group.rows, id: \.id) { record in
                            let currency = model.currency(of: record, for: draft.sourceID)
                            Toggle(isOn: Binding(
                                get: { currentCitations.contains(record.id) },
                                set: { turning in
                                    if turning { model.draft?.citations.insert(record.id) }
                                    else { model.draft?.citations.remove(record.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("\(deskEvidenceSourceLabel(record.source)) · \(deskEvidenceLocatorLabel(record.locator))")
                                            .font(.caption.weight(.semibold))
                                        if currency == .expired {
                                            Text(EvidenceCurrencyCopy.expiredBadge)
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(record.excerpt ?? "内容不可读取")
                                        .font(.callout)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!record.isUsable || currency != .current)
                            .accessibilityIdentifier("cite-\(record.id)")
                        }
                    }
                }
            }
        }
    }

    /// The refusal, in the four actionable buckets, plus the raw codes in an
    /// expander - the sentence tells the reviewer what to change; the code
    /// stays for support. The old engineering notice remains in 诊断.
    @ViewBuilder private var refusalFeedback: some View {
        if !refusalCodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(refusalCodes, id: \.self) { code in
                    Label(deskRefusalSentence(forCode: code), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("review-correction-error")
                }
                DisclosureGroup("诊断详情") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(refusalCodes, id: \.self) { code in
                            Text("FormaCore 代码：\(code)").font(.caption.monospaced())
                        }
                        Text("已勾选证据的内部 ID：\(currentCitations.sorted().joined(separator: " "))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                }
                .font(.caption)
                .accessibilityIdentifier("review-correction-diagnostics")
            }
        }
    }

    /// Evidence rows bucketed by the provenance label, in reading order.
    struct CitationGroup {
        let key: String
        let rows: [EvidenceRecord]

        static func groups(in records: [EvidenceRecord]) -> [CitationGroup] {
            let order: [EvidenceSource] = [.filename, .path, .content, .sibling, .fsMetadata, .mcp]
            var seen: [String] = []
            var buckets: [String: [EvidenceRecord]] = [:]
            for record in records {
                let key = deskEvidenceSourceLabel(record.source)
                if buckets[key] == nil { seen.append(key) }
                buckets[key, default: []].append(record)
            }
            return seen.map { key in CitationGroup(key: key, rows: buckets[key] ?? []) }
                .sorted { lhs, rhs in
                    let li = order.firstIndex(where: { deskEvidenceSourceLabel($0) == lhs.key }) ?? 99
                    let ri = order.firstIndex(where: { deskEvidenceSourceLabel($0) == rhs.key }) ?? 99
                    return li < ri
                }
        }
    }
}
