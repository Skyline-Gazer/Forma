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

public protocol ImportReadTransport: Sendable {
    /// Independent read of one record. Never the write call's own response.
    func read(uuid: String) async throws -> ImportRecordSnapshot
}

public struct ImportLookupQuery: Sendable, Equatable {
    public let database: String
    public let groupPath: [String]
    /// The manifest's candidate association, used as an identity anchor.
    public let associationBasis: String?
    public let sourceSHA256: String?

    public init(database: String, groupPath: [String], associationBasis: String?, sourceSHA256: String?) {
        self.database = database
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.sourceSHA256 = sourceSHA256
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
    public let metadata: [String: String?]
    public let sourceSHA256: String

    public init(database: String, groupPath: [String], associationBasis: String?,
                metadata: [String: String?], sourceSHA256: String) {
        self.database = database
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.metadata = metadata
        self.sourceSHA256 = sourceSHA256
    }
}

public struct ImportMetadataRequest: Sendable, Equatable {
    public let uuid: String
    public let metadata: [String: String?]
    public let sourceSHA256: String

    public init(uuid: String, metadata: [String: String?], sourceSHA256: String) {
        self.uuid = uuid
        self.metadata = metadata
        self.sourceSHA256 = sourceSHA256
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
