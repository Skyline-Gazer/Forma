import CryptoKit
import Foundation

/// What an import operation *is*, and what it is not.
///
/// Three questions the ledger must never conflate:
///
///   1. Is this the same **operation**?  -> `ImportOperationKey`
///   2. Is this the same **source bytes**? -> `SourceBytesIdentity`
///   3. Is this the same **business record**? -> `BusinessRecordIdentity`
///
/// A shared SHA-256 answers only the second. Treating it as the third is how a
/// library ends up with one record standing in for two files that happen to
/// hold identical bytes, and the mistake is invisible until someone audits.

// MARK: - Operation key

public enum ImportOperationKind: String, Codable, Sendable, CaseIterable {
    /// Create one business record from one manifest entry.
    ///
    /// Metadata writing and readback are *phases* of this operation, not
    /// separate keys: a second key for "write metadata" would let a retry create
    /// a second record. Adding a kind requires an ADR amendment.
    case createRecord = "create_record"
}

/// The idempotency key from PLAN §10.2.
///
/// A new key is a new intent — a changed Profile or target produces one — but a
/// new key never proves the record is absent. The write path still has to look.
public struct ImportOperationKey: Codable, Sendable, Hashable {
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let manifestRevision: Int
    public let targetAssociationID: UUID
    public let operationKind: ImportOperationKind

    public init(sourceID: UUID, snapshotFingerprint: String, manifestRevision: Int,
                targetAssociationID: UUID,
                operationKind: ImportOperationKind = .createRecord) throws {
        guard Self.isCanonicalComponent(snapshotFingerprint), manifestRevision >= 1 else {
            throw FormaError.invalidOutput
        }
        self.sourceID = sourceID
        self.snapshotFingerprint = snapshotFingerprint
        self.manifestRevision = manifestRevision
        self.targetAssociationID = targetAssociationID
        self.operationKind = operationKind
    }

    /// Unambiguous, separator-free encoding. UUID strings cannot contain `|`, and
    /// the fingerprint is rejected above if it does.
    public var canonicalString: String {
        "v1|\(sourceID.uuidString.lowercased())|\(snapshotFingerprint)"
            + "|\(manifestRevision)|\(targetAssociationID.uuidString.lowercased())|\(operationKind.rawValue)"
    }

    /// The Ledger's unique key.
    public var digest: String {
        SHA256.hash(data: Data(canonicalString.utf8)).hexadecimalDigest
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", snapshotFingerprint = "snapshot_fingerprint"
        case manifestRevision = "manifest_revision", targetAssociationID = "target_association_id"
        case operationKind = "operation_kind"
    }

    /// Decoding goes through the validating initializer: a persisted key that
    /// could not have been constructed must not be usable either.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceID: container.decode(UUID.self, forKey: .sourceID),
                      snapshotFingerprint: container.decode(String.self, forKey: .snapshotFingerprint),
                      manifestRevision: container.decode(Int.self, forKey: .manifestRevision),
                      targetAssociationID: container.decode(UUID.self, forKey: .targetAssociationID),
                      operationKind: container.decode(ImportOperationKind.self, forKey: .operationKind))
    }

    static func isCanonicalComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.contains("|") && !value.utf8.contains(0)
    }
}

// MARK: - Source bytes

/// The evidence that two runs are looking at the same bytes.
public struct SourceBytesIdentity: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let snapshotFingerprint: String
    /// Verified digest of the bytes this run actually read; nil means "not
    /// verified", which is not the same as "unchanged".
    public let sha256: String?

    public init(sourceID: UUID, snapshotFingerprint: String, sha256: String?) {
        self.sourceID = sourceID
        self.snapshotFingerprint = snapshotFingerprint
        self.sha256 = sha256
    }

    public var isVerified: Bool {
        guard let sha256 else { return false }
        return sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit }
    }

    public func matches(_ other: SourceBytesIdentity) -> Bool {
        sourceID == other.sourceID && snapshotFingerprint == other.snapshotFingerprint
            && isVerified && other.isVerified && sha256 == other.sha256
    }
}

// MARK: - Business record

/// Evidence that an observed record *is* the record this manifest describes.
///
/// Deliberately impossible to satisfy with a hash: `isConfirmed` needs an
/// observed UUID, an identity anchor, and a second corroborating fact.
public struct BusinessRecordIdentity: Codable, Sendable, Equatable {
    public enum Corroboration: String, Codable, Sendable, CaseIterable {
        /// The source ledger says this source maps to this target.
        case sourceLedgerMatch = "source_ledger_match"
        /// The record carries this manifest's candidate association.
        case targetAssociationMatch = "target_association_match"
        /// Project and usage semantics agree.
        case projectAndUsageMatch = "project_and_usage_match"
        /// The observed attributes agree with the manifest.
        case attributesMatch = "attributes_match"
    }

    /// The UUID the target reported. Nil means no record was observed at all.
    public let observedUUID: String?
    public let corroboration: Set<Corroboration>

    public init(observedUUID: String?, corroboration: Set<Corroboration>) {
        self.observedUUID = observedUUID
        self.corroboration = corroboration
    }

    /// Anchors are the facts that tie a record to *this source*; a project name
    /// or a file name can coincide across unrelated documents.
    public static let anchors: Set<Corroboration> = [.sourceLedgerMatch, .targetAssociationMatch]

    public var isConfirmed: Bool {
        guard observedUUID != nil else { return false }
        return !corroboration.isDisjoint(with: Self.anchors) && corroboration.count >= 2
    }

    /// Whether the evidence can even be called "insufficient" rather than "absent":
    /// a hash match alone is a candidate, never a confirmation.
    public var isCandidateOnly: Bool {
        observedUUID == nil || corroboration.isDisjoint(with: Self.anchors)
    }
}
