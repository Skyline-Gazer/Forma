import Foundation

/// One model answer plus the program's own facts about the file it describes.
public struct ProposalForEntry: Sendable {
    public let sourceID: UUID
    public let proposal: ProposalEntry?
    /// Why there is no answer: a provider failure, a refusal, or a batch that
    /// never returned this entry. Each has a different recovery path.
    public let failure: FormaError?

    public init(sourceID: UUID, proposal: ProposalEntry?, failure: FormaError? = nil) {
        self.sourceID = sourceID
        self.proposal = proposal
        self.failure = failure
    }
}

/// Inputs the validator is allowed to trust: everything here was produced by
/// Forma, not by a model.
public struct ValidationInput: Sendable {
    public let profile: MappingProfile
    public let context: ProjectContext
    public let entries: [SourceEntry]
    public let evidence: [UUID: [EvidenceRecord]]
    public let proposals: [ProposalForEntry]

    public init(profile: MappingProfile, context: ProjectContext, entries: [SourceEntry],
                evidence: [UUID: [EvidenceRecord]], proposals: [ProposalForEntry]) {
        self.profile = profile
        self.context = context
        self.entries = entries
        self.evidence = evidence
        self.proposals = proposals
    }
}

/// The independent, deterministic Manifest Validator required by PLAN §7.
///
/// It never trusts a model's self-assessment: `confidence` is copied for display
/// and measurement, while the decision state, the per-field outcome and
/// `eligible_for_auto_execution` are computed from the profile policy, the
/// evidence registry, the snapshot binding and the project context. A model that
/// asserts `high` and cites nothing ends up `hold`.
public struct ManifestValidator: Sendable {
    public let profile: MappingProfile
    private let input: ValidationInput

    public init(_ input: ValidationInput) {
        self.profile = input.profile
        self.input = input
    }

    public struct Result: Sendable {
        public let entries: [ManifestEntry]
        public let report: ValidationReport
    }

    public func validate() -> Result {
        var report = ValidationReport()
        var entries: [ManifestEntry] = []
        var schemaViolations: [ValidationViolation] = []
        var evidenceViolations: [ValidationViolation] = []
        var policyViolations: [ValidationViolation] = []
        var snapshotViolations: [ValidationViolation] = []
        var associationViolations: [ValidationViolation] = []
        var eligibilityViolations: [ValidationViolation] = []

        let bySource = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.id, $0) })
        let proposalsByID: [UUID: ProposalForEntry] = Dictionary(
            grouping: input.proposals, by: \.sourceID
        ).compactMapValues { $0.first }

        // Group 1: schema and coverage. A batch that silently drops a file is a
        // schema-level failure even if every returned entry is well formed, and
        // a proposal naming a source outside the listing is an authorization
        // failure rather than a typo.
        let answered = Set(input.proposals.compactMap { $0.proposal == nil ? nil : $0.sourceID })
        let referenced = Set(input.proposals.map(\.sourceID))
        for missing in Set(input.entries.map(\.id)).subtracting(answered).subtracting(referenced) {
            schemaViolations.append(ValidationViolation(
                code: "entry_unanswered", instancePath: missing.sourceKey,
                detail: "The batch never returned this source."
            ))
        }
        for foreign in referenced.subtracting(bySource.keys) {
            schemaViolations.append(ValidationViolation(
                code: "entry_unknown", instancePath: foreign.sourceKey,
                detail: "A proposal referenced a source outside the authorized listing."
            ))
        }

        for entry in input.entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            let answer = proposalsByID[entry.id]
            let registry = input.evidence[entry.id] ?? []
            var outcome = EntryDecision()

            // Group 4 first: nothing else matters if the file identity moved.
            evaluateSnapshot(entry, answer: answer, into: &outcome, violations: &snapshotViolations)

            // Group 2: citations must resolve against the registry.
            let citations = resolveCitations(answer?.proposal, entry: entry, registry: registry,
                                             violations: &evidenceViolations)

            // Group 3: profile policy over the cited evidence.
            let fields = evaluateFields(answer?.proposal, entry: entry, citations: citations, registry: registry,
                                        violations: &policyViolations)

            // Group 5: project association against the versioned context.
            evaluateAssociation(answer?.proposal, entry: entry, fields: fields, into: &outcome,
                                violations: &associationViolations)

            let manifestEntry = finish(entry: entry, answer: answer, fields: fields, citations: citations,
                                       outcome: outcome, registry: registry)

            // Group 6: eligibility is computed, never copied.
            evaluateEligibility(manifestEntry, registry: registry, violations: &eligibilityViolations)

            entries.append(manifestEntry)
        }

        report.record(.init(group: .schema, violations: schemaViolations))
        report.record(.init(group: .evidence, violations: evidenceViolations))
        report.record(.init(group: .profilePolicy, violations: policyViolations))
        report.record(.init(group: .snapshot, violations: snapshotViolations))
        report.record(.init(group: .association, violations: associationViolations))
        report.record(.init(group: .eligibility, violations: eligibilityViolations))
        report.counts = counts(entries)
        return Result(entries: entries, report: report)
    }

    // MARK: - Snapshot

    private struct EntryDecision {
        var snapshotBlocking = false
        var snapshotReason: String?
        var associationBlocking = false
        var associationReason: String?
        var candidateKeys: [String] = []
    }

    private func evaluateSnapshot(_ entry: SourceEntry, answer: ProposalForEntry?, into outcome: inout EntryDecision,
                                  violations: inout [ValidationViolation]) {
        switch entry.state {
        case .missing:
            outcome.snapshotBlocking = true
            outcome.snapshotReason = "source_missing"
        case .symlink:
            outcome.snapshotBlocking = true
            outcome.snapshotReason = "symlink_not_read"
        case .held:
            outcome.snapshotBlocking = true
            outcome.snapshotReason = "source_held"
        case .present:
            break
        }
        if entry.hydrationPending {
            outcome.snapshotBlocking = true
            outcome.snapshotReason = "hydration_pending"
            violations.append(ValidationViolation(code: "hydration_pending", instancePath: entry.relativePath,
                                                  detail: "The file content is not local; no body evidence exists."))
        }
        if answer?.failure != nil {
            outcome.snapshotBlocking = true
            outcome.snapshotReason = "provider_\(answer?.failure?.code ?? "failed")"
            violations.append(ValidationViolation(code: "provider_\(answer?.failure?.code ?? "failed")",
                                                  instancePath: entry.relativePath,
                                                  detail: "The mapping request for this entry did not produce an answer."))
        }
    }

    // MARK: - Evidence

    private struct ResolvedCitation {
        let field: MetadataFieldID
        let record: EvidenceRecord
    }

    /// Checks that a citation exists, belongs to this source and snapshot, is
    /// locatable, and is of a kind the field may use. Semantic agreement between
    /// the quoted text and the proposed value is checked here only where it is
    /// mechanically decidable; whether the model's *interpretation* is right is a
    /// P3 measurement question, not something a validator can prove.
    private func resolveCitations(_ proposal: ProposalEntry?, entry: SourceEntry, registry: [EvidenceRecord],
                                  violations: inout [ValidationViolation]) -> [ResolvedCitation] {
        guard let proposal else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: registry.map { ($0.id, $0) })
        var resolved: [ResolvedCitation] = []
        var seen: Set<String> = []
        for citation in proposal.evidence {
            guard let record = byID[citation.evidenceID] else {
                violations.append(ValidationViolation(code: "evidence_not_found",
                                                      instancePath: "\(entry.relativePath)#\(citation.evidenceID)",
                                                      detail: "Cited evidence is not in the registry for this source."))
                continue
            }
            guard seen.insert(record.id).inserted else { continue }
            if record.sourceID != entry.id {
                violations.append(ValidationViolation(code: "evidence_foreign_source",
                                                      instancePath: citation.evidenceID,
                                                      detail: "Evidence belongs to a different source."))
                continue
            }
            if record.snapshotRevision != Int(entry.snapshotRevision)
                || record.snapshotFingerprint != entry.snapshotFingerprint {
                violations.append(ValidationViolation(code: "evidence_snapshot_mismatch",
                                                      instancePath: citation.evidenceID,
                                                      detail: "Evidence was read from a different snapshot revision."))
                continue
            }
            if record.source == .content, record.locator == nil {
                violations.append(ValidationViolation(code: "locator_invalid", instancePath: citation.evidenceID,
                                                      detail: "Content evidence carries no page, part or cell locator."))
                continue
            }
            if let locator = record.locator, !Self.locatorIsSane(locator) {
                violations.append(ValidationViolation(code: "locator_invalid", instancePath: citation.evidenceID,
                                                      detail: "Locator is outside the addressable range."))
                continue
            }
            guard let policy = profile.fields[citation.field] else { continue }
            if !policy.allowedEvidenceSources.contains(record.source) {
                violations.append(ValidationViolation(code: "source_not_allowed",
                                                      instancePath: "\(citation.field.rawValue):\(citation.evidenceID)",
                                                      detail: "This field may not be supported by \(record.source.rawValue) evidence."))
                continue
            }
            if !record.isUsable {
                violations.append(ValidationViolation(code: "evidence_unusable",
                                                      instancePath: citation.evidenceID,
                                                      detail: "Status \(record.extractionStatus.rawValue) cannot support a value."))
                continue
            }
            resolved.append(ResolvedCitation(field: citation.field, record: record))
        }
        return resolved
    }

    static func locatorIsSane(_ locator: EvidenceLocator) -> Bool {
        switch locator {
        case .pdf(let page, let range):
            page >= 1 && range.lowerBound >= 0 && range.upperBound >= range.lowerBound
        case .docx(let part, let paragraph, let range):
            !part.isEmpty && paragraph >= 1 && range.lowerBound >= 0 && range.upperBound >= range.lowerBound
        case .xlsx(let sheet, let cell):
            !sheet.isEmpty && cell.range(of: #"^[A-Z]{1,3}[1-9][0-9]{0,6}$"#, options: .regularExpression) != nil
        }
    }

    // MARK: - Fields

    private func evaluateFields(_ proposal: ProposalEntry?, entry: SourceEntry,
                                citations: [ResolvedCitation], registry: [EvidenceRecord],
                                violations: inout [ValidationViolation]) -> [FieldOutcome] {
        var outcomes: [FieldOutcome] = []
        let byField = Dictionary(grouping: citations, by: \.field)
        let declaredUnknown = proposal?.unknownFields ?? []

        for field in MetadataFieldID.allCases {
            guard let policy = profile.fields[field] else { continue }
            let proposed = proposal.map { value(of: field, in: $0) } ?? nil
            let supporting = byField[field] ?? []

            // A value the model says it does not know, but still filled in.
            if proposed != nil, declaredUnknown.contains(field) {
                violations.append(ValidationViolation(code: "unknown_conflict",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "The field is listed as unknown but carries a value."))
            }
            let conflictsForField = proposal?.conflicts.filter { $0.field == field } ?? []
            if !conflictsForField.isEmpty {
                violations.append(ValidationViolation(code: "field_conflict",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: conflictsForField.first?.detail ?? "conflicting evidence"))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .conflict,
                                             evidenceIDs: supporting.map(\.record.id),
                                             conflicts: conflictsForField.map(\.detail)))
                continue
            }

            guard let value = proposed else {
                outcomes.append(FieldOutcome(field: field, value: nil, status: .unknown, evidenceIDs: []))
                continue
            }

            // Type and vocabulary checks come from the profile, not the model.
            if !policy.valueType.validate(value) {
                violations.append(ValidationViolation(code: "value_type",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "The value does not match the field's declared shape."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy,
                                             evidenceIDs: supporting.map(\.record.id)))
                continue
            }
            if field == .documentcategory, !profile.categoryIdentifier(value) {
                violations.append(ValidationViolation(code: "category_unknown",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "The category is not part of this profile."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy))
                continue
            }
            if field == .documenttype, !profile.documentTypeIdentifier(value) {
                violations.append(ValidationViolation(code: "document_type_unknown",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "The document type is not part of this profile."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy))
                continue
            }

            // Evidence must exist and must be of a kind that is conclusive on
            // its own: a source listed as insufficient cannot carry a field by
            // itself, no matter how confident the model claims to be.
            if supporting.isEmpty {
                violations.append(ValidationViolation(code: "evidence_missing",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "A non-null value was proposed without citing evidence."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy))
                continue
            }
            let conclusive = supporting.filter { !policy.insufficientEvidenceSources.contains($0.record.source) }
            if conclusive.isEmpty {
                violations.append(ValidationViolation(code: "insufficient_evidence",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "Only \(Set(supporting.map(\.record.source.rawValue))) evidence was offered, which alone is not enough for this field."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy,
                                             evidenceIDs: supporting.map(\.record.id)))
                continue
            }
            // Two usable records that disagree about the same field is a
            // conflict, not a choice by confidence.
            let distinct = Set(conclusive.compactMap(\.record.excerpt))
            if distinct.count > 1, field != .documentcategory, field != .documenttype {
                violations.append(ValidationViolation(code: "conflicting_evidence",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "Cited evidence records more than one value for this field."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .conflict,
                                             evidenceIDs: conclusive.map(\.record.id),
                                             conflicts: ["multiple cited excerpts"]))
                continue
            }
            if !quoteSupportsValue(value, conclusive.map(\.record)) {
                violations.append(ValidationViolation(code: "quote_mismatch",
                                                      instancePath: "\(entry.relativePath)#\(field.rawValue)",
                                                      detail: "The cited excerpt does not contain the proposed value."))
                outcomes.append(FieldOutcome(field: field, value: nil, status: .rejectedByPolicy,
                                             evidenceIDs: conclusive.map(\.record.id)))
                continue
            }
            let inherited = conclusive.allSatisfy { $0.record.source == .sibling }
            outcomes.append(FieldOutcome(field: field, value: value, status: inherited ? .inherited : .evidenced,
                                         evidenceIDs: conclusive.map(\.record.id)))
        }
        return outcomes
    }

    /// Mechanically decidable agreement between a quoted excerpt and the value.
    ///
    /// Each evidence kind states something different, so the comparison is
    /// defined per kind instead of one loose rule:
    /// - `content`, `filename`, `path`: the value appears in what was observed.
    /// - `fs_metadata`: the value matches a recorded `key=value` term.
    /// - `sibling`: the registry writes `inherited from <path>: <value>`, so the
    ///   value is compared against the part after the marker. Inheritance has to
    ///   be checkable, not merely permitted.
    /// - `mcp`: the value equals what the authorized read-only query returned.
    private func quoteSupportsValue(_ value: String, _ records: [EvidenceRecord]) -> Bool {
        let needle = normalize(value)
        guard !needle.isEmpty else { return false }
        return records.contains { record in
            guard let text = record.excerpt else { return false }
            switch record.source {
            case .content, .filename, .path:
                return normalize(text).contains(needle)
            case .fsMetadata:
                return normalize(text).split(separator: ";").contains { normalize(String($0)).contains(needle) }
            case .sibling:
                guard let marker = text.range(of: ": ") else { return normalize(text) == needle }
                return normalize(String(text[marker.upperBound...])) == needle
            case .mcp:
                return normalize(text) == needle
            }
        }
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func value(of field: MetadataFieldID, in proposal: ProposalEntry) -> String? {
        proposal.metadata[field] ?? nil
    }

    // MARK: - Association

    private func evaluateAssociation(_ proposal: ProposalEntry?, entry: SourceEntry, fields: [FieldOutcome],
                                     into outcome: inout EntryDecision,
                                     violations: inout [ValidationViolation]) {
        let candidates = input.context.candidate(for: entry.id)
        let keys = Set(candidates.map(\.projectKey))
        outcome.candidateKeys = Array(keys).sorted()
        if input.context.conflictedSourceIDs.contains(entry.id) {
            outcome.associationBlocking = true
            outcome.associationReason = "membership_conflict"
            violations.append(ValidationViolation(code: "membership_conflict", instancePath: entry.relativePath,
                                                  detail: "More than one candidate claims this file."))
        }
        guard let association = proposal?.projectAssociation else {
            if !profile.permitsUnaffiliatedDocuments {
                outcome.associationBlocking = true
                outcome.associationReason = "association_unknown"
            }
            return
        }
        switch association.state {
        case .conflict:
            outcome.associationBlocking = true
            outcome.associationReason = "association_conflict"
            violations.append(ValidationViolation(code: "association_conflict", instancePath: entry.relativePath,
                                                  detail: "The model reported conflicting project evidence."))
        case .confirmed, .unconfirmed:
            guard let ref = association.candidateRef else {
                if !profile.permitsUnaffiliatedDocuments {
                    outcome.associationBlocking = true
                    outcome.associationReason = "association_unknown"
                    violations.append(ValidationViolation(code: "association_unknown",
                                                          instancePath: entry.relativePath,
                                                          detail: "A project file must name a candidate from the context."))
                }
                return
            }
            guard keys.contains(ref) else {
                outcome.associationBlocking = true
                outcome.associationReason = "candidate_unknown"
                violations.append(ValidationViolation(code: "candidate_unknown", instancePath: ref,
                                                      detail: "The candidate is not part of the current context for this file."))
                return
            }
            if association.state == .confirmed, !candidates.contains(where: { $0.projectKey == ref }) {
                outcome.associationBlocking = true
                outcome.associationReason = "membership_mismatch"
                violations.append(ValidationViolation(code: "membership_mismatch", instancePath: entry.relativePath,
                                                      detail: "The confirmed candidate does not contain this source."))
            }
        }
    }

    // MARK: - Entry assembly

    private func finish(entry: SourceEntry, answer: ProposalForEntry?, fields: [FieldOutcome],
                        citations: [ResolvedCitation], outcome: EntryDecision,
                        registry: [EvidenceRecord]) -> ManifestEntry {
        var metadata = MetadataValues.allUnknown
        for field in MetadataFieldID.allCases {
            metadata[field] = fields.first { $0.field == field }?.value
        }
        let blocking = outcome.snapshotBlocking || outcome.associationBlocking
        let requiredMissing = MetadataFieldID.allCases.filter {
            profile.fields[$0]?.requiredForValidated == true && metadata[$0] == nil
        }
        let state: DecisionState
        if answer?.proposal == nil {
            state = .unknown
        } else if blocking || !requiredMissing.isEmpty {
            state = .hold
        } else {
            state = .validated
        }
        let target = resolveTarget(entry: entry, metadata: metadata, profile: profile)
        var manifestEntry = ManifestEntry(
            sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
            snapshotRevision: Int(entry.snapshotRevision), sourceVersion: Int(entry.sourceVersion),
            relativePath: entry.relativePath, state: state, target: target, metadata: metadata,
            fields: fields,
            associations: outcome.candidateKeys.map {
                ManifestAssociation(kind: .projectCandidate, sourceID: entry.id,
                                    basis: "context revision \(input.context.revision) candidate \($0)")
            },
            eligibleForAutoExecution: false,
            invalidatedReason: outcome.snapshotReason ?? outcome.associationReason,
            confidence: answer?.proposal?.confidence,
            providerReasoning: answer?.proposal?.reasoning
        )
        manifestEntry.eligibleForAutoExecution = computeEligibility(manifestEntry, state: state,
                                                                    blocking: blocking,
                                                                    requiredMissing: requiredMissing,
                                                                    registry: registry)
        return manifestEntry
    }

    /// A target is resolved only when every template placeholder has a value the
    /// program accepted. An unresolved target can never be eligible.
    private func resolveTarget(entry: SourceEntry, metadata: MetadataValues, profile: MappingProfile) -> ManifestTarget {
        var path: [String] = []
        var resolved = true
        for segment in profile.target.groupTemplate {
            if segment.hasPrefix("{"), segment.hasSuffix("}"),
               let field = MetadataFieldID(rawValue: String(segment.dropFirst().dropLast())) {
                guard let value = metadata[field], !value.isEmpty else { resolved = false; continue }
                path.append(value)
            } else {
                path.append(segment)
            }
        }
        return ManifestTarget(databaseName: profile.target.databaseName, groupPath: path, resolved: resolved)
    }

    private func computeEligibility(_ entry: ManifestEntry, state: DecisionState, blocking: Bool,
                                    requiredMissing: [MetadataFieldID], registry: [EvidenceRecord]) -> Bool {
        // PLAN §7.3: eligibility is a policy computation over evidence, key
        // fields, conflicts and the current snapshot. Model confidence is not an
        // input, and a weak snapshot is not enough for a body claim.
        guard state == .validated, !blocking, requiredMissing.isEmpty, entry.target.resolved else { return false }
        if entry.fields.contains(where: { $0.status == .conflict }) { return false }
        let citedIDs = Set(entry.fields.flatMap(\.evidenceIDs))
        guard !citedIDs.isEmpty else { return false }
        // Every cited record must still exist and still match this snapshot.
        let byID = Dictionary(uniqueKeysWithValues: registry.map { ($0.id, $0) })
        for id in citedIDs {
            guard let record = byID[id], record.snapshotRevision == entry.snapshotRevision,
                  record.snapshotFingerprint == entry.snapshotFingerprint, record.isUsable else { return false }
        }
        // A high-impact field must rest on this file's own content, not on an
        // inherited sibling value, even when inheritance passed the policy.
        for field in MetadataFieldID.allCases where field.isHighImpact {
            guard let outcome = entry.outcome(for: field), outcome.value != nil else { continue }
            if outcome.status == .inherited, field != .projectname { return false }
        }
        return true
    }

    private func evaluateEligibility(_ entry: ManifestEntry, registry: [EvidenceRecord],
                                     violations: inout [ValidationViolation]) {
        // Nothing is reported here beyond an inconsistency: eligibility must
        // never be true for an entry that is not validated, and never true at
        // all while the profile grants no execution.
        if entry.eligibleForAutoExecution, entry.state != .validated {
            violations.append(ValidationViolation(code: "eligibility_state", instancePath: entry.relativePath,
                                                  detail: "Only a validated entry may be considered eligible."))
        }
        if profile.grantsExecution {
            violations.append(ValidationViolation(code: "eligibility_authority", instancePath: entry.relativePath,
                                                  detail: "No prototype profile may grant execution authority."))
        }
    }

    private func counts(_ entries: [ManifestEntry]) -> ValidationReport.Counts {
        var result = ValidationReport.Counts()
        result.entries = entries.count
        result.validated = entries.filter { $0.state == .validated }.count
        result.hold = entries.filter { $0.state == .hold }.count
        result.unknown = entries.filter { $0.state == .unknown }.count
        result.invalidated = entries.filter { $0.state == .invalidated }.count
        result.eligible = entries.filter { $0.eligibleForAutoExecution }.count
        return result
    }
}
