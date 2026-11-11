import Foundation

// Shared value types for the mapping pipeline. These are the contract between
// the context builder, the evidence registry, the provider engine, the
// validator and the interface: none of them may be redefined locally.
//
// Artifact JSON is snake_case. Rather than repeating the wire names in every
// type, all of these encode and decode through `FormaJSON`, which applies the
// snake_case strategy. The checked-in schemas pin the resulting key names, so a
// property rename that would change the wire format fails a schema test instead
// of silently altering an artifact.

/// The one codec used for artifacts that cross a boundary: SQLite payloads,
/// exported files, and provider requests and responses.
public enum FormaJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(Self.timestamp)
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        else { encoder.outputFormatting = [.sortedKeys] }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(Self.timestamp)
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// Seconds with optional fraction, always UTC: the same shape the manifest
    /// schema pins with a pattern rather than a `format` annotation.
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
}


/// The artifact schemas bound every string that crosses a boundary. The same
/// bounds are applied where the values are constructed, so a program-built
/// artifact cannot violate its own schema: a limit that only the validator
/// knows is a limit that a future caller will exceed.
enum Bounded {
    static func text(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A value shorter than the schema's `minLength` carries no information,
        // so it is reported as unknown rather than kept as a stub.
        guard trimmed.count >= 4 else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func required(_ value: String, _ limit: Int) -> String {
        String(value.prefix(limit))
    }

    static func list(_ values: [String], _ limit: Int) -> [String] {
        values.compactMap { text($0, limit) }
    }

    /// Truncation without a minimum: the schema bounds the length but allows a
    /// short legitimate value, so dropping "A1" would be a data loss.
    static func clipped(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        return String(value.prefix(limit))
    }
}

// MARK: - Decision state

/// PLAN §7.3. `invalidated` is a revision-validity flag: it records that a
/// previously reached state may no longer be used, without rewriting history.
public enum DecisionState: String, Codable, Sendable, Equatable {
    case unknown, hold, mapped, validated, invalidated

    public static func < (lhs: DecisionState, rhs: DecisionState) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .hold: 1
        case .mapped: 2
        case .validated: 3
        case .invalidated: 4
        }
    }
}

/// The six validation groups PLAN §7 requires, reported independently so a
/// failure names its own cause instead of a generic "invalid".
public enum ValidationGroup: String, Codable, CaseIterable, Sendable {
    case schema, evidence, profilePolicy = "profile_policy", snapshot, association, eligibility
}

public enum ValidationStatus: String, Codable, Sendable {
    case passed, failed, blocked
}

public struct ValidationViolation: Codable, Sendable, Equatable, Hashable {
    public let code: String
    public let instancePath: String
    public let detail: String

    enum CodingKeys: String, CodingKey {
        case code, instancePath = "instance_path", detail
    }

    public init(code: String, instancePath: String = "", detail: String) {
        self.code = code
        self.instancePath = instancePath
        // A violation may be shown in the interface and exported: bound it and
        // never let it carry a whole document body.
        self.detail = String(detail.prefix(300))
    }
}

extension ValidationViolation {
    /// A schema violation is one kind of validation violation: the report keeps
    /// a single type so an exported bundle has one vocabulary.
    init(_ violation: ArtifactSchema.Violation) {
        self.init(code: violation.code, instancePath: violation.instancePath, detail: violation.detail)
    }
}

public struct ValidationGroupResult: Codable, Sendable, Equatable {
    public let group: ValidationGroup
    public var status: ValidationStatus
    public var violations: [ValidationViolation]

    public init(group: ValidationGroup, status: ValidationStatus = .passed, violations: [ValidationViolation] = []) {
        self.group = group
        self.status = violations.isEmpty ? status : .failed
        self.violations = violations
    }
}

public struct ValidationReport: Codable, Sendable, Equatable {
    /// Ordered by group so an exported report is byte-stable and diffable.
    public var groups: [ValidationGroupResult]
    public var counts: Counts

    public struct Counts: Codable, Sendable, Equatable {
        public var entries = 0
        public var validated = 0
        public var hold = 0
        public var unknown = 0
        public var invalidated = 0
        public var eligible = 0
    }

    public init(groups: [ValidationGroupResult] = ValidationGroup.allCases.map { .init(group: $0) }) {
        self.groups = groups
        self.counts = Counts()
    }

    public mutating func record(_ result: ValidationGroupResult) {
        if let index = groups.firstIndex(where: { $0.group == result.group }) { groups[index] = result }
        else { groups.append(result) }
    }

    public func result(for group: ValidationGroup) -> ValidationGroupResult? {
        groups.first { $0.group == group }
    }

    public var isFullyValid: Bool {
        groups.count == ValidationGroup.allCases.count && groups.allSatisfy { $0.status == .passed }
    }

    public var allViolations: [ValidationViolation] { groups.flatMap(\.violations) }
}

// MARK: - Project context

/// One candidate membership of a file in a project. A file may hold several
/// candidates; that is a legitimate outcome, not a failure to decide.
public struct ContextCandidate: Codable, Sendable, Equatable, Hashable {
    public enum Basis: String, Codable, Sendable {
        case directory, adjacency, naming, siblingEvidence = "sibling_evidence", historyReference = "history_reference"
    }

    public let id: String
    public let projectKey: String
    public let displayName: String?
    public let basis: [Basis]
    public let memberSourceIDs: Set<UUID>
    public let confidence: DecisionConfidence

    enum CodingKeys: String, CodingKey {
        case id, projectKey = "project_key", displayName = "display_name", basis
        case memberSourceIDs = "member_source_ids", confidence
    }

    public init(id: String, projectKey: String, displayName: String?, basis: [Basis],
                memberSourceIDs: Set<UUID>, confidence: DecisionConfidence) {
        self.id = id
        self.projectKey = projectKey
        self.displayName = displayName
        self.basis = basis
        self.memberSourceIDs = memberSourceIDs
        self.confidence = confidence
    }
}

/// Qualitative signal for display and later measurement only. It never grants
/// eligibility: PLAN §7.3 keeps that with the program's evidence rules.
public enum DecisionConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

/// The versioned project context produced by the two-phase builder.
public struct ProjectContext: Codable, Sendable, Equatable {
    public let revision: Int
    public let scopeID: UUID
    public let profileID: String
    public let profileVersion: String
    /// Digest over the inputs that produced this context, so an unrelated
    /// rescan cannot silently reuse a stale context.
    public let inputDigest: String
    public let candidates: [ContextCandidate]
    /// Files with no defensible candidate. They are not errors; they must not
    /// acquire a project by guessing.
    public let unassignedSourceIDs: Set<UUID>
    /// Directories whose contents conflict about project membership.
    public let conflictedSourceIDs: Set<UUID>
    public let builtAt: Date

    enum CodingKeys: String, CodingKey {
        case revision, scopeID = "scope_id", profileID = "profile_id", profileVersion = "profile_version"
        case inputDigest = "input_digest", candidates, unassignedSourceIDs = "unassigned_source_ids"
        case conflictedSourceIDs = "conflicted_source_ids", builtAt = "built_at"
    }

    public init(revision: Int, scopeID: UUID, profileID: String, profileVersion: String, inputDigest: String,
                candidates: [ContextCandidate], unassignedSourceIDs: Set<UUID>, conflictedSourceIDs: Set<UUID>,
                builtAt: Date) {
        self.revision = revision
        self.scopeID = scopeID
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.inputDigest = inputDigest
        self.candidates = candidates
        self.unassignedSourceIDs = unassignedSourceIDs
        self.conflictedSourceIDs = conflictedSourceIDs
        self.builtAt = builtAt
    }

    public func candidate(for sourceID: UUID) -> [ContextCandidate] {
        candidates.filter { $0.memberSourceIDs.contains(sourceID) }
    }

    /// The source IDs whose membership actually depends on this context, used
    /// to invalidate only the affected mappings.
    public var coveredSourceIDs: Set<UUID> {
        Set(candidates.flatMap(\.memberSourceIDs))
    }
}

// MARK: - Evidence registry

/// A program-created, addressable piece of evidence. The model may cite an
/// `id`; it may never create one.
public struct EvidenceRecord: Codable, Sendable, Equatable {
    public let id: String
    public let sourceID: UUID
    /// The snapshot revision the excerpt was read from. Citing evidence from a
    /// different snapshot is a validation failure, not a warning.
    public let snapshotRevision: Int
    public let snapshotFingerprint: String
    public let source: EvidenceSource
    public let locator: EvidenceLocator?
    /// Relative path for path or filename evidence; nil for content locators,
    /// which already carry the part, page or cell.
    public let relativePath: String?
    public let excerpt: String?
    public let extractionStatus: EvidenceStatus
    public let extractorVersion: String
    public let createdAt: Date
    /// For `sibling` evidence: the context candidate that established the
    /// membership a value was inherited through. PLAN §7.2 forbids circular
    /// mutual proof, so an inherited value must name the relationship it came
    /// from instead of only pointing at another file.
    public let contextCandidateID: String?

    enum CodingKeys: String, CodingKey {
        case id, sourceID = "source_id", snapshotRevision = "snapshot_revision"
        case snapshotFingerprint = "snapshot_fingerprint", source, locator, relativePath = "relative_path"
        case excerpt, extractionStatus = "extraction_status", extractorVersion = "extractor_version"
        case createdAt = "created_at", contextCandidateID = "context_candidate_id"
    }

    public init(id: String, sourceID: UUID, snapshotRevision: Int, snapshotFingerprint: String,
                source: EvidenceSource, locator: EvidenceLocator?, relativePath: String?, excerpt: String?,
                extractionStatus: EvidenceStatus, extractorVersion: String, createdAt: Date,
                contextCandidateID: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.snapshotRevision = snapshotRevision
        self.snapshotFingerprint = snapshotFingerprint
        self.source = source
        self.locator = locator
        self.relativePath = relativePath
        self.excerpt = excerpt
        self.extractionStatus = extractionStatus
        self.extractorVersion = extractorVersion
        self.createdAt = createdAt
        self.contextCandidateID = contextCandidateID
    }

    /// Only `ok` or `truncated` evidence may support a value: an unread,
    /// encrypted or corrupt file cannot prove anything.
    public var isUsable: Bool {
        (extractionStatus == .ok || extractionStatus == .truncated) && excerpt != nil
    }
}

/// A model citation: field plus registry id.
public struct EvidenceCitation: Codable, Sendable, Equatable, Hashable {
    public let field: MetadataFieldID
    public let evidenceID: String

    enum CodingKeys: String, CodingKey {
        case field, evidenceID = "evidence_id"
    }

    public init(field: MetadataFieldID, evidenceID: String) {
        self.field = field
        self.evidenceID = evidenceID
    }
}

// MARK: - Mapping proposal (model output)

public struct ProposalAssociation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case confirmed, unconfirmed, conflict
    }

    public let candidateRef: String?
    public let state: State

    enum CodingKeys: String, CodingKey {
        case candidateRef = "candidate_ref", state
    }

    public init(candidateRef: String?, state: State) {
        self.candidateRef = candidateRef
        self.state = state
    }
}

public struct ProposalConflict: Codable, Sendable, Equatable, Hashable {
    public let field: MetadataFieldID
    public let detail: String

    enum CodingKeys: String, CodingKey {
        case field, detail
    }

    public init(field: MetadataFieldID, detail: String) {
        self.field = field
        self.detail = Bounded.text(detail, 300) ?? "unspecified conflict"
    }
}

public struct ProposalEntry: Codable, Sendable, Equatable {
    public let entryRef: String
    public let projectAssociation: ProposalAssociation?
    public let documentCategory: String?
    public let documentType: String?
    public let metadata: MetadataValues
    public let evidence: [EvidenceCitation]
    public let unknownFields: Set<MetadataFieldID>
    public let conflicts: [ProposalConflict]
    public let confidence: DecisionConfidence
    public let reasoning: String

    enum CodingKeys: String, CodingKey {
        case entryRef = "entry_ref", projectAssociation = "project_association"
        case documentCategory = "document_category", documentType = "document_type"
        case metadata, evidence, unknownFields = "unknown_fields", conflicts, confidence, reasoning
    }

    public init(entryRef: String, projectAssociation: ProposalAssociation?, documentCategory: String?,
                documentType: String?, metadata: MetadataValues, evidence: [EvidenceCitation],
                unknownFields: Set<MetadataFieldID>, conflicts: [ProposalConflict],
                confidence: DecisionConfidence, reasoning: String) {
        self.entryRef = entryRef
        self.projectAssociation = projectAssociation
        self.documentCategory = documentCategory
        self.documentType = documentType
        self.metadata = metadata
        self.evidence = evidence
        self.unknownFields = unknownFields
        self.conflicts = conflicts
        self.confidence = confidence
        self.reasoning = Bounded.required(reasoning, 600)
    }
}

public struct MappingProposal: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let batchID: String
    public let entries: [ProposalEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", batchID = "batch_id", entries
    }

    public init(schemaVersion: String = "1.0", batchID: String, entries: [ProposalEntry]) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.entries = entries
    }
}

// MARK: - Manifest

public struct ManifestEnvelope: Codable, Sendable, Equatable {
    public let manifestID: UUID
    /// Program-assigned by storage when a revision is written; a rebased
    /// revision supersedes the one before it instead of replacing it.
    public var revision: Int
    public var supersedesRevision: Int?
    public let scopeID: UUID
    public let sourceRootID: UUID
    public let profileID: String
    public let profileVersion: String
    public let schemaVersion: String
    public let casePackID: String
    public let casePackVersion: String
    public let modelProvider: String
    public let modelID: String?
    public let contextRevision: Int
    public let promptVersion: String
    public let extractorVersion: String
    public let redactionVersion: String?
    public let inputDigest: String
    public let contextDigest: String
    public let createdAt: Date
    public var state: ManifestState
    /// Constant false in the Prototype: eligibility is a policy simulation and
    /// no serialized manifest may claim authority to write.
    public let grantsExecution: Bool

    enum CodingKeys: String, CodingKey {
        case manifestID = "manifest_id", revision, supersedesRevision = "supersedes_revision"
        case scopeID = "scope_id", sourceRootID = "source_root_id", profileID = "profile_id"
        case profileVersion = "profile_version", schemaVersion = "schema_version"
        case casePackID = "case_pack_id", casePackVersion = "case_pack_version"
        case modelProvider = "model_provider", modelID = "model_id", contextRevision = "context_revision"
        case promptVersion = "prompt_version", extractorVersion = "extractor_version"
        case redactionVersion = "redaction_version", inputDigest = "input_digest"
        case contextDigest = "context_digest", createdAt = "created_at", state
        case grantsExecution = "grants_execution"
    }

    public enum ManifestState: String, Codable, Sendable {
        case draft, validated, partiallyValidated = "partially_validated", invalidated
    }

    public init(manifestID: UUID, revision: Int, supersedesRevision: Int?, scopeID: UUID, sourceRootID: UUID,
                profile: MappingProfile, casePack: (id: String, version: String), modelProvider: String,
                modelID: String?, contextRevision: Int, promptVersion: String, extractorVersion: String,
                redactionVersion: String?, inputDigest: String, contextDigest: String, createdAt: Date,
                state: ManifestState) {
        self.manifestID = manifestID
        self.revision = revision
        self.supersedesRevision = supersedesRevision
        self.scopeID = scopeID
        self.sourceRootID = sourceRootID
        self.profileID = profile.profileID
        self.profileVersion = profile.profileVersion
        self.schemaVersion = "1.0"
        self.casePackID = casePack.id
        self.casePackVersion = casePack.version
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.contextRevision = contextRevision
        self.promptVersion = promptVersion
        self.extractorVersion = extractorVersion
        self.redactionVersion = redactionVersion
        self.inputDigest = inputDigest
        self.contextDigest = contextDigest
        self.createdAt = createdAt
        self.state = state
        self.grantsExecution = false
    }

    /// The same decision at the next revision. Storage assigns the number, so a
    /// caller cannot overwrite an existing revision by reusing one.
    func rebased(to revision: Int) -> ManifestEnvelope {
        var copy = self
        copy.revision = revision
        copy.supersedesRevision = revision > 1 ? revision - 1 : nil
        return copy
    }
}

/// One field's final program-side result, including which evidence supports it.
public struct FieldOutcome: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case evidenced, inherited, unknown, conflict
        case rejectedByPolicy = "rejected_by_policy", notApplicable = "not_applicable"
    }

    public let field: MetadataFieldID
    public var value: String?
    public var status: Status
    public var evidenceIDs: [String]
    public var conflicts: [String]

    enum CodingKeys: String, CodingKey {
        case field, value, status, evidenceIDs = "evidence_ids", conflicts
    }

    public init(field: MetadataFieldID, value: String?, status: Status, evidenceIDs: [String] = [],
                conflicts: [String] = []) {
        self.field = field
        self.value = Bounded.clipped(value, 512)
        self.status = status
        self.evidenceIDs = evidenceIDs
        self.conflicts = Bounded.list(conflicts, 300)
    }
}

public struct ManifestAssociation: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case projectCandidate = "project_candidate", sibling, duplicateContent = "duplicate_content", historyReference = "history_reference"
    }

    public let kind: Kind
    public let sourceID: UUID
    public let basis: String
    public let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case kind, sourceID = "source_id", basis, evidenceIDs = "evidence_ids"
    }

    public init(kind: Kind, sourceID: UUID, basis: String, evidenceIDs: [String] = []) {
        self.kind = kind
        self.sourceID = sourceID
        self.basis = Bounded.text(basis, 300) ?? "unspecified basis"
        self.evidenceIDs = evidenceIDs
    }
}

public struct ManifestTarget: Codable, Sendable, Equatable {
    public let databaseName: String?
    public let groupPath: [String]

    enum CodingKeys: String, CodingKey {
        case databaseName = "database_name", groupPath = "group_path", resolved
    }
    /// False while any template placeholder is unresolved; an unresolved target
    /// can never be eligible.
    public let resolved: Bool

    public init(databaseName: String?, groupPath: [String], resolved: Bool) {
        self.databaseName = Bounded.clipped(databaseName, 128)
        self.groupPath = groupPath.map { Bounded.required($0, 256) }
        self.resolved = resolved
    }
}

public struct ManifestEntry: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let snapshotRevision: Int
    public let sourceVersion: Int
    public var relativePath: String
    public var state: DecisionState
    public let target: ManifestTarget
    public var metadata: MetadataValues
    public var fields: [FieldOutcome]
    public var associations: [ManifestAssociation]
    /// Computed by the program from evidence, key fields, conflicts and policy.
    public var eligibleForAutoExecution: Bool
    public var invalidatedReason: String?
    /// Display and measurement only.
    public var confidence: DecisionConfidence?
    public var providerReasoning: String?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", snapshotFingerprint = "snapshot_fingerprint"
        case snapshotRevision = "snapshot_revision", sourceVersion = "source_version"
        case relativePath = "relative_path", state, target, metadata, fields, associations
        case eligibleForAutoExecution = "eligible_for_auto_execution"
        case invalidatedReason = "invalidated_reason", confidence, providerReasoning = "provider_reasoning"
    }

    public init(sourceID: UUID, snapshotFingerprint: String, snapshotRevision: Int, sourceVersion: Int,
                relativePath: String, state: DecisionState, target: ManifestTarget,
                metadata: MetadataValues = .allUnknown, fields: [FieldOutcome] = [],
                associations: [ManifestAssociation] = [], eligibleForAutoExecution: Bool = false,
                invalidatedReason: String? = nil, confidence: DecisionConfidence? = nil,
                providerReasoning: String? = nil) {
        self.sourceID = sourceID
        self.snapshotFingerprint = snapshotFingerprint
        self.snapshotRevision = snapshotRevision
        self.sourceVersion = sourceVersion
        // The exported schema forbids an absolute path, so a leading separator
        // is stripped instead of letting a hand-built entry fail validation.
        self.relativePath = Bounded.required(
            relativePath.replacingOccurrences(of: "^/+", with: "", options: .regularExpression), 1_024)
        self.state = state
        self.target = target
        self.metadata = metadata
        // Every entry states all twelve slots: an absent slot would be
        // indistinguishable from "never considered", and the exported schema
        // requires the full set.
        self.fields = fields.isEmpty
            ? MetadataFieldID.allCases.map { FieldOutcome(field: $0, value: metadata[$0], status: .unknown) }
            : fields
        self.associations = associations
        self.eligibleForAutoExecution = eligibleForAutoExecution
        self.invalidatedReason = Bounded.text(invalidatedReason, 300)
        self.confidence = confidence
        self.providerReasoning = Bounded.clipped(providerReasoning, 600)
    }

    public func outcome(for field: MetadataFieldID) -> FieldOutcome? {
        fields.first { $0.field == field }
    }

    public mutating func setOutcome(_ outcome: FieldOutcome) {
        if let index = fields.firstIndex(where: { $0.field == outcome.field }) { fields[index] = outcome }
        else { fields.append(outcome) }
    }
}

public struct Manifest: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public var envelope: ManifestEnvelope
    public var entries: [ManifestEntry]
    public var report: ValidationReport

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", envelope, entries, report = "validation_report"
    }

    public init(schemaVersion: String = "1.0", envelope: ManifestEnvelope, entries: [ManifestEntry],
                report: ValidationReport = ValidationReport()) {
        self.schemaVersion = schemaVersion
        self.envelope = envelope
        self.entries = entries
        self.report = report
    }

    public func entry(for sourceID: UUID) -> ManifestEntry? {
        entries.first { $0.sourceID == sourceID }
    }

    public var eligibleCount: Int {
        entries.filter { $0.eligibleForAutoExecution }.count
    }
}

// MARK: - Metadata slot map

/// The twelve metadata slots as one closed map.
///
/// Every key must be present, and an explicit JSON `null` means "unknown"
/// while a missing key or an extra key is a decoding failure. That distinction
/// is what stops a model from omitting an inconvenient field or inventing a
/// thirteenth one.
public struct MetadataValues: Sendable, Equatable {
    public private(set) var values: [MetadataFieldID: String?]

    public init(_ values: [MetadataFieldID: String?]) throws {
        guard Set(values.keys) == Set(MetadataFieldID.allCases) else { throw FormaError.invalidOutput }
        // The artifact schemas bound every metadata value; the same bound is
        // applied here so a program-built entry cannot exceed its own schema.
        self.values = values.mapValues { Bounded.clipped($0, 512) }
    }

    /// All slots unknown: the honest starting point for a program-built entry.
    public static var allUnknown: MetadataValues {
        MetadataValues(unchecked: Dictionary(uniqueKeysWithValues: MetadataFieldID.allCases.map { ($0, nil) }))
    }

    init(unchecked values: [MetadataFieldID: String?]) {
        self.values = values
    }

    public subscript(field: MetadataFieldID) -> String? {
        get { values[field] ?? nil }
        set { values[field] = Bounded.clipped(newValue, 512) }
    }

    public var nonNullFields: Set<MetadataFieldID> {
        Set(values.compactMap { $0.value != nil ? $0.key : nil })
    }
}

extension MetadataValues: Codable {
    public init(from decoder: any Decoder) throws {
        // A keyed container silently drops keys that do not convert to the
        // CodingKey type, so an invented thirteenth field would pass unnoticed.
        // Decoding the object as a plain string map keeps every key visible.
        let slots = try decoder.singleValueContainer().decode([String: String?].self)
        let known = Set(MetadataFieldID.allCases.map(\.rawValue))
        guard Set(slots.keys) == known else { throw FormaError.invalidOutput }
        var values: [MetadataFieldID: String?] = [:]
        for (name, value) in slots {
            guard let field = MetadataFieldID(rawValue: name) else { throw FormaError.invalidOutput }
            values[field] = value
        }
        try self.init(values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MetadataFieldKey.self)
        for field in MetadataFieldID.allCases {
            // `encode` with an Optional writes an explicit null; `encodeIfPresent`
            // would drop the slot, and a dropped slot means something else.
            try container.encode(values[field] ?? nil, forKey: MetadataFieldKey(field))
        }
    }
}

/// A CodingKey whose string form is the frozen identifier. Kept separate from
/// `MetadataFieldID` so the identifier stays a plain domain enum.
struct MetadataFieldKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ field: MetadataFieldID) { self.stringValue = field.rawValue }
    init?(stringValue: String) {
        guard MetadataFieldID(rawValue: stringValue) != nil else { return nil }
        self.stringValue = stringValue
    }
    init?(intValue: Int) { nil }
}

// MARK: - Explicit artifact encoding
//
// Swift omits an optional property whose value is nil, but the artifact schemas
// require every slot to be present: an explicit null means "unknown" while a
// missing key means a malformed document. These encoders write the null.

extension ManifestEnvelope {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifestID.sourceKey, forKey: .manifestID)
        try container.encode(revision, forKey: .revision)
        try container.encode(supersedesRevision, forKey: .supersedesRevision)
        try container.encode(scopeID.sourceKey, forKey: .scopeID)
        try container.encode(sourceRootID.sourceKey, forKey: .sourceRootID)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(profileVersion, forKey: .profileVersion)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(casePackID, forKey: .casePackID)
        try container.encode(casePackVersion, forKey: .casePackVersion)
        try container.encode(modelProvider, forKey: .modelProvider)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(contextRevision, forKey: .contextRevision)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(extractorVersion, forKey: .extractorVersion)
        try container.encode(redactionVersion, forKey: .redactionVersion)
        try container.encode(inputDigest, forKey: .inputDigest)
        try container.encode(contextDigest, forKey: .contextDigest)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(state, forKey: .state)
        try container.encode(grantsExecution, forKey: .grantsExecution)
    }
}

extension ManifestEntry {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID.sourceKey, forKey: .sourceID)
        try container.encode(snapshotFingerprint, forKey: .snapshotFingerprint)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(sourceVersion, forKey: .sourceVersion)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(state, forKey: .state)
        try container.encode(target, forKey: .target)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(fields, forKey: .fields)
        try container.encode(associations, forKey: .associations)
        try container.encode(eligibleForAutoExecution, forKey: .eligibleForAutoExecution)
        try container.encode(invalidatedReason, forKey: .invalidatedReason)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(providerReasoning, forKey: .providerReasoning)
    }
}

extension FieldOutcome {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(value, forKey: .value)
        try container.encode(status, forKey: .status)
        try container.encode(evidenceIDs, forKey: .evidenceIDs)
        try container.encode(conflicts, forKey: .conflicts)
    }
}

extension ManifestTarget {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(databaseName, forKey: .databaseName)
        try container.encode(groupPath, forKey: .groupPath)
        try container.encode(resolved, forKey: .resolved)
    }
}

extension ProposalEntry {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryRef, forKey: .entryRef)
        try container.encode(projectAssociation, forKey: .projectAssociation)
        try container.encode(documentCategory, forKey: .documentCategory)
        try container.encode(documentType, forKey: .documentType)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(unknownFields, forKey: .unknownFields)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(reasoning, forKey: .reasoning)
    }
}

extension ProposalAssociation {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidateRef, forKey: .candidateRef)
        try container.encode(state, forKey: .state)
    }
}

extension ContextCandidate {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectKey, forKey: .projectKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(basis, forKey: .basis)
        try container.encode(memberSourceIDs.map { $0.sourceKey }.sorted(), forKey: .memberSourceIDs)
        try container.encode(confidence, forKey: .confidence)
    }
}

extension EvidenceRecord {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID.sourceKey, forKey: .sourceID)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(snapshotFingerprint, forKey: .snapshotFingerprint)
        try container.encode(source, forKey: .source)
        try container.encode(locator, forKey: .locator)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(excerpt, forKey: .excerpt)
        try container.encode(extractionStatus, forKey: .extractionStatus)
        try container.encode(extractorVersion, forKey: .extractorVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(contextCandidateID, forKey: .contextCandidateID)
    }
}

extension ManifestEnvelope {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestID = try sourceUUID(container.decode(String.self, forKey: .manifestID))
        revision = try container.decode(Int.self, forKey: .revision)
        supersedesRevision = try container.decodeIfPresent(Int.self, forKey: .supersedesRevision)
        scopeID = try sourceUUID(container.decode(String.self, forKey: .scopeID))
        sourceRootID = try sourceUUID(container.decode(String.self, forKey: .sourceRootID))
        profileID = try container.decode(String.self, forKey: .profileID)
        profileVersion = try container.decode(String.self, forKey: .profileVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        casePackID = try container.decode(String.self, forKey: .casePackID)
        casePackVersion = try container.decode(String.self, forKey: .casePackVersion)
        modelProvider = try container.decode(String.self, forKey: .modelProvider)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        contextRevision = try container.decode(Int.self, forKey: .contextRevision)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        extractorVersion = try container.decode(String.self, forKey: .extractorVersion)
        redactionVersion = try container.decodeIfPresent(String.self, forKey: .redactionVersion)
        inputDigest = try container.decode(String.self, forKey: .inputDigest)
        contextDigest = try container.decode(String.self, forKey: .contextDigest)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(ManifestState.self, forKey: .state)
        grantsExecution = try container.decode(Bool.self, forKey: .grantsExecution)
        // An artifact that claims execution authority is not a Forma manifest.
        guard !grantsExecution else { throw FormaError.invalidOutput }
    }
}

extension ManifestEntry {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try sourceUUID(container.decode(String.self, forKey: .sourceID))
        snapshotFingerprint = try container.decode(String.self, forKey: .snapshotFingerprint)
        snapshotRevision = try container.decode(Int.self, forKey: .snapshotRevision)
        sourceVersion = try container.decode(Int.self, forKey: .sourceVersion)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        state = try container.decode(DecisionState.self, forKey: .state)
        target = try container.decode(ManifestTarget.self, forKey: .target)
        metadata = try container.decode(MetadataValues.self, forKey: .metadata)
        fields = try container.decode([FieldOutcome].self, forKey: .fields)
        associations = try container.decode([ManifestAssociation].self, forKey: .associations)
        eligibleForAutoExecution = try container.decode(Bool.self, forKey: .eligibleForAutoExecution)
        invalidatedReason = try container.decodeIfPresent(String.self, forKey: .invalidatedReason)
        confidence = try container.decodeIfPresent(DecisionConfidence.self, forKey: .confidence)
        providerReasoning = try container.decodeIfPresent(String.self, forKey: .providerReasoning)
    }
}

extension ContextCandidate {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectKey = try container.decode(String.self, forKey: .projectKey)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        basis = try container.decode([Basis].self, forKey: .basis)
        // Membership is stored as sorted lowercase UUID strings and must come
        // back as the same set or an invalidation comparison would be wrong.
        let keys = try container.decode([String].self, forKey: .memberSourceIDs)
        memberSourceIDs = try Set(keys.map { try sourceUUID($0) })
        confidence = try container.decode(DecisionConfidence.self, forKey: .confidence)
    }
}

extension EvidenceRecord {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try sourceUUID(container.decode(String.self, forKey: .sourceID))
        snapshotRevision = try container.decode(Int.self, forKey: .snapshotRevision)
        snapshotFingerprint = try container.decode(String.self, forKey: .snapshotFingerprint)
        source = try container.decode(EvidenceSource.self, forKey: .source)
        locator = try container.decodeIfPresent(EvidenceLocator.self, forKey: .locator)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        extractionStatus = try container.decode(EvidenceStatus.self, forKey: .extractionStatus)
        extractorVersion = try container.decode(String.self, forKey: .extractorVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        contextCandidateID = try container.decodeIfPresent(String.self, forKey: .contextCandidateID)
    }
}
