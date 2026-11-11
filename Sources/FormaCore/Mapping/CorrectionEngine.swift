import CryptoKit
import Foundation

/// Correction Capture, per SPEC §11.1.1 and PLAN §8.4.
///
/// A correction never rewrites the decision it corrects. The old manifest
/// revision stays exactly as it was, and the correction produces a new revision
/// that supersedes it. That is what makes "we changed our mind" auditable rather
/// than invisible, and it is why the review state of a derived case is tracked
/// separately from the correction itself: a person fixing one file has not
/// thereby produced a teaching example.
public struct CorrectionRecord: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        case manual, evidenceReextraction = "evidence_reextraction", historyReconciliation = "history_reconciliation"
    }

    public enum ReviewState: String, Codable, Sendable {
        case pending, evidenceVerified = "evidence_verified", rejected
    }

    public let id: UUID
    public let manifestID: UUID
    public let manifestRevision: Int
    public let supersedesRevision: Int?
    public let sourceID: UUID
    public let field: MetadataFieldID
    public let previousValue: String?
    public let correctedValue: String?
    public let evidenceIDs: [String]
    public let snapshotFingerprint: String
    public let contextRevision: Int
    public let origin: Origin
    public var reviewState: ReviewState
    public let caseCandidateID: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), manifestID: UUID, manifestRevision: Int, supersedesRevision: Int?,
                sourceID: UUID, field: MetadataFieldID, previousValue: String?, correctedValue: String?,
                evidenceIDs: [String], snapshotFingerprint: String, contextRevision: Int, origin: Origin,
                reviewState: ReviewState = .pending, caseCandidateID: UUID? = nil, createdAt: Date = .now) {
        self.id = id
        self.manifestID = manifestID
        self.manifestRevision = manifestRevision
        self.supersedesRevision = supersedesRevision
        self.sourceID = sourceID
        self.field = field
        self.previousValue = previousValue
        self.correctedValue = correctedValue
        self.evidenceIDs = evidenceIDs
        self.snapshotFingerprint = snapshotFingerprint
        self.contextRevision = contextRevision
        self.origin = origin
        self.reviewState = reviewState
        self.caseCandidateID = caseCandidateID
        self.createdAt = createdAt
    }

    /// A correction is only usable if it either cites evidence the program can
    /// verify, or explicitly clears a value. Inventing a value by clicking is
    /// not evidence: PLAN §7.3 keeps human correction under the same rule.
    public var isSupported: Bool {
        correctedValue == nil || !evidenceIDs.isEmpty
    }
}

/// A candidate teaching case derived from corrections, before any review.
public struct CaseCandidate: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case candidate, reviewed, accepted, rejected
    }

    public let id: UUID
    public let correctionIDs: [UUID]
    public var status: Status
    public let scenario: String
    public let profiles: [String]
    public let redactionChecked: Bool
    public let duplicateOf: UUID?
    public let createdAt: Date
    public var reviewedAt: Date?

    public init(id: UUID = UUID(), correctionIDs: [UUID], status: Status = .candidate, scenario: String,
                profiles: [String], redactionChecked: Bool = false, duplicateOf: UUID? = nil,
                createdAt: Date = .now, reviewedAt: Date? = nil) {
        self.id = id
        self.correctionIDs = correctionIDs
        self.status = status
        self.scenario = scenario
        self.profiles = profiles
        self.redactionChecked = redactionChecked
        self.duplicateOf = duplicateOf
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
    }

    /// Only an accepted, redaction-checked, non-duplicate candidate may enter a
    /// CasePack, and only as a synthetic or reviewed sample.
    public var isAdmissible: Bool { status == .accepted && redactionChecked && duplicateOf == nil }
}

/// Applies corrections and derives candidate cases.
///
/// The engine holds no provider and no DEVONthink client: a correction is a
/// local decision that re-runs the deterministic validator over the same
/// evidence, with the corrected value substituted. Nothing here can write to an
/// archive, and nothing here can promote itself into the shipped CasePack.
public struct CorrectionEngine: Sendable {
    public struct Applied: Sendable {
        public let manifest: Manifest
        public let correction: CorrectionRecord
        public let violations: [ValidationViolation]
    }

    public let profile: MappingProfile

    public init(profile: MappingProfile) {
        self.profile = profile
    }

    /// Produces the next manifest revision with one field corrected.
    ///
    /// The corrected value still has to pass the profile's type, vocabulary and
    /// evidence rules; a correction that violates policy is recorded as a
    /// rejected attempt rather than silently stored as truth.
    public func apply(to manifest: Manifest, sourceID: UUID, field: MetadataFieldID, correctedValue: String?,
                      evidenceIDs: [String], origin: CorrectionRecord.Origin, context: ProjectContext,
                      evidence: [UUID: [EvidenceRecord]], currentEntries: [SourceEntry]) -> Applied {
        guard let position = manifest.entries.firstIndex(where: { $0.sourceID == sourceID }) else {
            return Applied(manifest: manifest, correction: CorrectionRecord(
                manifestID: manifest.envelope.manifestID, manifestRevision: manifest.envelope.revision,
                supersedesRevision: nil, sourceID: sourceID, field: field, previousValue: nil,
                correctedValue: correctedValue, evidenceIDs: evidenceIDs, snapshotFingerprint: "",
                contextRevision: context.revision, origin: origin
            ), violations: [ValidationViolation(code: "entry_unknown", instancePath: sourceID.sourceKey,
                                                detail: "The corrected source is not in this manifest.")])
        }
        let previous = manifest.entries[position].outcome(for: field)?.value
        var violations: [ValidationViolation] = []

        if let correctedValue {
            if let policy = profile.fields[field] {
                if !policy.valueType.validate(correctedValue) {
                    violations.append(ValidationViolation(code: "value_type", instancePath: field.rawValue,
                                                          detail: "The corrected value does not match the field's shape."))
                }
            } else {
                violations.append(ValidationViolation(code: "field_unknown", instancePath: field.rawValue,
                                                      detail: "The identifier is not part of the frozen twelve."))
            }
            if field == .documentcategory, !profile.categoryIdentifier(correctedValue) {
                violations.append(ValidationViolation(code: "category_unknown", instancePath: field.rawValue,
                                                      detail: "The corrected category is not in this profile."))
            }
            if field == .documenttype, !profile.documentTypeIdentifier(correctedValue) {
                violations.append(ValidationViolation(code: "document_type_unknown", instancePath: field.rawValue,
                                                      detail: "The corrected type is not in this profile."))
            }
            // The correction must be traceable to evidence the program holds for
            // this source and this snapshot, or it is only an opinion. An empty
            // citation list is an opinion too: a value with nothing behind it is
            // exactly what a human click must not silently introduce.
            let registry = Dictionary(uniqueKeysWithValues: (evidence[sourceID] ?? []).map { ($0.id, $0) })
            let verified = evidenceIDs.filter { registry[$0]?.isUsable == true }
            if verified.count != Set(evidenceIDs).count || verified.isEmpty {
                violations.append(ValidationViolation(code: "evidence_not_found", instancePath: field.rawValue,
                                                      detail: "A corrected value must cite evidence that exists."))
            }
        }

        var entries = manifest.entries
        if violations.isEmpty {
            var metadata = entries[position].metadata
            metadata[field] = correctedValue
            entries[position].metadata = metadata
            entries[position].setOutcome(FieldOutcome(field: field, value: correctedValue,
                                                      status: correctedValue == nil ? .unknown : .evidenced,
                                                      evidenceIDs: evidenceIDs))
            entries[position].state = .mapped
        }

        var candidate = manifest
        candidate.envelope = ManifestEnvelope(
            manifestID: manifest.envelope.manifestID, revision: manifest.envelope.revision + 1,
            supersedesRevision: manifest.envelope.revision, scopeID: manifest.envelope.scopeID,
            sourceRootID: manifest.envelope.sourceRootID, profile: profile,
            casePack: (manifest.envelope.casePackID, manifest.envelope.casePackVersion),
            modelProvider: manifest.envelope.modelProvider, modelID: manifest.envelope.modelID,
            contextRevision: context.revision, promptVersion: manifest.envelope.promptVersion,
            extractorVersion: manifest.envelope.extractorVersion,
            redactionVersion: manifest.envelope.redactionVersion, inputDigest: manifest.envelope.inputDigest,
            contextDigest: MappingEngine.contextDigest(context), createdAt: .now, state: .draft
        )
        candidate.entries = entries
        // Revalidate rather than trusting the edit: the new revision goes
        // through the same six groups as a model answer would.
        let proposals = entries.map { entry in
            ProposalForEntry(sourceID: entry.sourceID, proposal: Self.proposal(from: entry, context: context))
        }
        let result = ManifestValidator(ValidationInput(profile: profile, context: context,
                                                       entries: currentEntries, evidence: evidence,
                                                       proposals: proposals)).validate()
        candidate.entries = result.entries
        candidate.report = result.report
        let state: ManifestEnvelope.ManifestState
        if result.report.counts.validated == 0 { state = .draft }
        else if result.report.counts.validated == result.report.counts.entries { state = .validated }
        else { state = .partiallyValidated }
        candidate.envelope.state = state

        let correction = CorrectionRecord(
            manifestID: manifest.envelope.manifestID, manifestRevision: candidate.envelope.revision,
            supersedesRevision: manifest.envelope.revision, sourceID: sourceID, field: field,
            previousValue: previous, correctedValue: correctedValue, evidenceIDs: evidenceIDs,
            snapshotFingerprint: manifest.entries[position].snapshotFingerprint,
            contextRevision: context.revision, origin: origin,
            reviewState: violations.isEmpty ? .evidenceVerified : .rejected
        )
        return Applied(manifest: candidate, correction: correction, violations: violations)
    }

    /// Turns a set of verified corrections into one candidate case, which starts
    /// life as `candidate` and cannot be admissible until reviewed.
    public static func candidate(from corrections: [CorrectionRecord], profile: MappingProfile,
                                 scenario: String, redaction: RedactionPlan) -> CaseCandidate {
        let verified = corrections.filter { $0.reviewState == .evidenceVerified }
        // Any sensitive term that survives redaction disqualifies the candidate:
        // an unredacted example must never reach a public case pack.
        let leaks = redaction.leaks(scenario)
        return CaseCandidate(
            correctionIDs: verified.map(\.id), status: verified.isEmpty ? .rejected : .candidate,
            scenario: scenario, profiles: [profile.profileID], redactionChecked: leaks.isEmpty,
            duplicateOf: nil, createdAt: .now
        )
    }

    /// A content-and-scenario fingerprint used to refuse duplicate cases rather
    /// than inflating the pack with near-identical examples.
    public static func duplicateKey(sourceID: UUID, field: MetadataFieldID, scenario: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(sourceID.sourceKey)|\(field.rawValue)|\(scenario)".utf8))
        return hasher.finalize().hexadecimalDigest
    }

    private static func proposal(from entry: ManifestEntry, context: ProjectContext) -> ProposalEntry? {
        let candidates = context.candidate(for: entry.sourceID).sorted { $0.id < $1.id }
        guard !entry.fields.isEmpty else { return nil }
        return ProposalEntry(
            entryRef: entry.sourceID.sourceKey,
            // A re-validated answer names its candidate by the same opaque id
            // the prompt issues and the validator compares; the project key is
            // a directory-derived name and is not a reference.
            projectAssociation: candidates.isEmpty ? nil
                : ProposalAssociation(candidateRef: candidates[0].id,
                                      state: entry.state == .validated ? .confirmed : .unconfirmed),
            documentCategory: entry.metadata[.documentcategory],
            documentType: entry.metadata[.documenttype],
            metadata: entry.metadata,
            evidence: entry.fields.flatMap { outcome in
                outcome.evidenceIDs.map { EvidenceCitation(field: outcome.field, evidenceID: $0) }
            },
            unknownFields: Set(entry.fields.filter { $0.value == nil }.map(\.field)),
            conflicts: entry.fields.filter { $0.status == .conflict }
                .flatMap { outcome in outcome.conflicts.map { ProposalConflict(field: outcome.field, detail: $0) } },
            confidence: entry.confidence ?? .low,
            reasoning: entry.providerReasoning ?? "corrected locally"
        )
    }

}
