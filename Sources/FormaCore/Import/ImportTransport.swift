import Foundation

/// The two directions an import needs, kept as separate protocols.
///
/// A writer that can also read its own echo is not evidence: PLAN §10.3 requires
/// the readback to come from an independent read-only client. Keeping the
/// protocols apart is what makes that a type-level statement rather than a
/// convention someone has to remember.
public protocol ImportWriteTransport: Sendable {
    /// Read-only lookup used before any write and again after an unknown outcome.
    func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult
    /// Creates one record and returns the target's UUID.
    func create(_ request: ImportCreateRequest) async throws -> String
    /// Writes metadata to an existing record.
    func writeMetadata(_ request: ImportMetadataRequest) async throws
}

/// Group creation is part of a run's approved scope, so it belongs on the same
/// surface the boundary guards rather than on a side channel the boundary
/// cannot see.
public protocol ImportGroupCreating: Sendable {
    /// Creates the path if needed and returns the group UUID, or an empty string
    /// when the response does not name exactly one object. An empty answer is an
    /// unknown outcome: the caller verifies the group by reading its parent.
    func createGroup(database: String, path: [String]) async throws -> String
}

/// Everything a bounded import run may invoke on the target.
public protocol ImportWriteSurface: ImportWriteTransport, ImportGroupCreating {}

public protocol ImportReadTransport: Sendable {
    /// Independent read of one record. Never the write call's own response.
    func read(uuid: String) async throws -> ImportRecordSnapshot
}

/// The authorized source file an import is bound to.
///
/// This is Forma's own contract, not DEVONthink's: it says **which bytes**, from
/// **which snapshot**, read **under which session**. It exists so that a create
/// request carries the evidence for the file it is about to import instead of a
/// loose digest.
///
/// It deliberately does **not** carry a ready-to-send tool argument. The shape of
/// DEVONthink's file-import tool is unverified: a path parameter, a file
/// reference and an upload are three different contracts, and guessing would
/// produce an adapter that looks finished and cannot work. Until I1-B verifies
/// the tool schema, the mapping from this binding to tool arguments stays open
/// (see `docs/I1-A-ACCEPTANCE.md` §4) and no real adapter is written.
public struct ImportSourceBinding: Sendable, Equatable {
    public let sourceID: UUID
    public let scopeID: UUID
    /// Path relative to the authorized scope. Never absolute, never sent to a
    /// target that has not been verified to accept it.
    public let relativePath: String
    /// The snapshot the bytes were read from.
    public let snapshotFingerprint: String
    /// SHA-256 of the bytes that were read, lowercase hex.
    public let contentSHA256: String
    public let byteCount: Int64
    /// The read session that produced the bytes (scope grant / bookmark identity).
    public let readSessionID: String

    public init(sourceID: UUID, scopeID: UUID, relativePath: String, snapshotFingerprint: String,
                contentSHA256: String, byteCount: Int64, readSessionID: String) {
        self.sourceID = sourceID
        self.scopeID = scopeID
        self.relativePath = relativePath
        self.snapshotFingerprint = snapshotFingerprint
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.readSessionID = readSessionID
    }
}

public struct ImportLookupQuery: Sendable, Equatable {
    public let database: String
    public let groupPath: [String]
    /// The manifest's candidate association, used as an identity anchor.
    public let associationBasis: String?
    /// The source the lookup is about, so a candidate can be tied to it.
    public let source: ImportSourceBinding

    public init(database: String, groupPath: [String], associationBasis: String?,
                source: ImportSourceBinding) {
        self.database = database
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.source = source
    }
}

public struct ImportLookupResult: Sendable, Equatable {
    public let records: [ImportRecordSnapshot]
    /// Whether the search covered the whole scope (pagination exhausted, scope
    /// known). A single empty page is not proof of absence.
    public let conclusive: Bool

    public init(records: [ImportRecordSnapshot], conclusive: Bool) {
        self.records = records
        self.conclusive = conclusive
    }
}

public struct ImportCreateRequest: Sendable, Equatable {
    public let database: String
    public let groupPath: [String]
    public let associationBasis: String?
    /// The field values mapping already decided. The executor never re-decides them.
    public let metadata: [String: String?]
    /// The authorized source file, with its bytes, snapshot and read session.
    ///
    /// A digest alone is not enough to import a file: the transport needs to know
    /// *which* file, *which* snapshot it was read from and under which session the
    /// read happened, and it must be able to prove that the bytes it sends are the
    /// bytes that were hashed. The target-side tool arguments are decided by the
    /// I1-B adapter, not here.
    public let source: ImportSourceBinding

    public init(database: String, groupPath: [String], associationBasis: String?,
                metadata: [String: String?], source: ImportSourceBinding) {
        self.database = database
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.metadata = metadata
        self.source = source
    }
}

public struct ImportMetadataRequest: Sendable, Equatable {
    public let uuid: String
    /// Only the slots that still need to be written. A slot the record already
    /// holds at the intended value is not part of the request, so a resumed
    /// operation cannot overwrite a value somebody else changed.
    public let metadata: [String: String?]
    public let source: ImportSourceBinding

    public init(uuid: String, metadata: [String: String?], source: ImportSourceBinding) {
        self.uuid = uuid
        self.metadata = metadata
        self.source = source
    }
}

/// What an independent readback reports.
public struct ImportRecordSnapshot: Sendable, Equatable {
    public let uuid: String
    public let database: String
    public let parentPath: [String]
    public let metadata: [String: String?]
    public let standardSHA256: String?
    /// False when the target cannot expose bytes or a proven-equivalent digest.
    public let shaVerified: Bool
    /// The association the record carries, when the target exposes one. This is
    /// an identity anchor, not a content fact.
    public let associationBasis: String?

    public init(uuid: String, database: String, parentPath: [String],
                metadata: [String: String?], standardSHA256: String?, shaVerified: Bool,
                associationBasis: String? = nil) {
        self.uuid = uuid
        self.database = database
        self.parentPath = parentPath
        self.metadata = metadata
        self.standardSHA256 = standardSHA256
        self.shaVerified = shaVerified
        self.associationBasis = associationBasis
    }

    public func matches(groupPath: [String], metadata expected: [String: String?],
                        sha256: String) -> Bool {
        guard parentPath == groupPath else { return false }
        guard shaVerified, let standardSHA256, standardSHA256 == sha256 else { return false }
        return Self.sameMetadata(metadata, expected)
    }

    static func sameMetadata(_ lhs: [String: String?], _ rhs: [String: String?]) -> Bool {
        let keys = Set(lhs.keys).union(rhs.keys)
        return keys.allSatisfy { (lhs[$0] ?? nil) == (rhs[$0] ?? nil) }
    }
}
