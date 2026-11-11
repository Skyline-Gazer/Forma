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
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .formatted(Self.timestamp)
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        else { encoder.outputFormatting = [.sortedKeys] }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
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

    public init(candidateRef: String?, state: State) {
        self.candidateRef = candidateRef
        self.state = state
    }
}

public struct ProposalConflict: Codable, Sendable, Equatable, Hashable {
    public let field: MetadataFieldID
    public let detail: String

    public init(field: MetadataFieldID, detail: String) {
        self.field = field
        self.detail = detail
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
        self.reasoning = reasoning
    }
}

public struct MappingProposal: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let batchID: String
    public let entries: [ProposalEntry]

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

    public init(field: MetadataFieldID, value: String?, status: Status, evidenceIDs: [String] = [],
                conflicts: [String] = []) {
        self.field = field
        self.value = value
        self.status = status
        self.evidenceIDs = evidenceIDs
        self.conflicts = conflicts
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

    public init(kind: Kind, sourceID: UUID, basis: String, evidenceIDs: [String] = []) {
        self.kind = kind
        self.sourceID = sourceID
        self.basis = String(basis.prefix(300))
        self.evidenceIDs = evidenceIDs
    }
}

public struct ManifestTarget: Codable, Sendable, Equatable {
    public let databaseName: String?
    public let groupPath: [String]
    /// False while any template placeholder is unresolved; an unresolved target
    /// can never be eligible.
    public let resolved: Bool

    public init(databaseName: String?, groupPath: [String], resolved: Bool) {
        self.databaseName = databaseName
        self.groupPath = groupPath
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
        self.relativePath = relativePath
        self.state = state
        self.target = target
        self.metadata = metadata
        self.fields = fields
        self.associations = associations
        self.eligibleForAutoExecution = eligibleForAutoExecution
        self.invalidatedReason = invalidatedReason
        self.confidence = confidence
        self.providerReasoning = providerReasoning
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
        self.values = values
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
        set { values[field] = newValue }
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
