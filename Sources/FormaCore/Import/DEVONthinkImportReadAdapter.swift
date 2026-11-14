import CryptoKit
import Foundation

/// The read-only operations an import needs from a DEVONthink target.
///
/// It exists so the production adapter can be tested against scripted answers
/// instead of a live library, and so the adapter never reaches for anything the
/// read client does not expose.
public protocol DEVONthinkReadbackSource: Sendable {
    func discover() async throws -> DEVONthinkCapabilities
    func record(_ id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecord
    func parents(of id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecordParents
    func metadata(of id: UUID, in scope: DEVONthinkReadScope) async throws -> [DEVONthinkMetadataField: DEVONthinkMetadataValue]
    /// The on-disk path of the stored bytes. `nil` means the target cannot
    /// expose bytes at all (a group, a smart group, a broken alias).
    func contentPath(of id: UUID, in scope: DEVONthinkReadScope) async throws -> String?
}

extension DEVONthinkReadOnlyClient: DEVONthinkReadbackSource {}

/// Computes a *standard* SHA-256 over the target's bytes.
///
/// DEVONthink exposes its own digest in some payloads; that is a private hash
/// with unknown inputs and is never accepted as the standard digest. The only
/// digest this type produces is SHA-256 over the file's bytes as they are.
public protocol TargetByteHasher: Sendable {
    /// Returns nil when the bytes cannot be read (absent, unreadable, not a
    /// regular file, or larger than `limit`). Never a partial digest.
    func sha256(ofFileAt path: String, limit: Int64) async -> String?
}

public struct FileTargetByteHasher: TargetByteHasher {
    public init() {}

    public func sha256(ofFileAt path: String, limit: Int64) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            // A path that names a directory opens on Darwin but never yields
            // bytes; rejecting it here keeps "unreadable" distinct from "empty".
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                let chunk: Data?
                do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
                guard let chunk, !chunk.isEmpty else { break }
                total += Int64(chunk.count)
                guard total <= limit else { return nil }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// The production `ImportReadTransport`: one target UUID in, one
/// `ImportRecordSnapshot` out, built only from read-only tool results.
///
/// Three rules decide the shape of this type:
///
/// 1. **Database identity comes from the observation.** The `database_uuid` it
///    sends is a request parameter the server may or may not honour, so the
///    answer is checked against the record's own `databaseUUID` and the scope.
/// 2. **A UUID string is echoed, not rewritten.** The executor compares
///    `snapshot.uuid` with the UUID it asked for; the lookup itself is issued
///    with the canonical uppercase form, because record-UUID queries are
///    case-sensitive on the live server (I1-B1 §3).
/// 3. **Unprovable bytes are `nil`, never a guess.** A private digest, a
///    missing path or a permission failure all produce
///    `standardSHA256 = nil, shaVerified = false`, which the arbitration turns
///    into `verify_required` — not into "matches" and not into "differs".
public actor DEVONthinkImportReadAdapter: ImportReadTransport {
    public enum Limits {
        /// Guards against a corrupt or adversarial parent chain.
        public static let maximumPathDepth = 64
        /// A target larger than this cannot be proven by streaming it during a
        /// single readback; it stays unverified instead.
        public static let maximumTargetBytes: Int64 = 8 * 1024 * 1024 * 1024
    }

    private let source: any DEVONthinkReadbackSource
    private let databaseID: UUID
    private let hasher: any TargetByteHasher
    private let maximumPathDepth: Int
    private let maximumTargetBytes: Int64
    private var discovered = false
    /// Record IDs this adapter has been asked about and their observed
    /// ancestors. The read client refuses IDs it was not scoped to, so the set
    /// grows exactly along relationships the target itself reported.
    private var authorized: Set<UUID> = []

    public init(client: DEVONthinkReadOnlyClient, databaseID: UUID,
                hasher: any TargetByteHasher = FileTargetByteHasher()) {
        self.init(source: client, databaseID: databaseID, hasher: hasher)
    }

    init(source: any DEVONthinkReadbackSource, databaseID: UUID,
         hasher: any TargetByteHasher = FileTargetByteHasher(),
         maximumPathDepth: Int = Limits.maximumPathDepth,
         maximumTargetBytes: Int64 = Limits.maximumTargetBytes) {
        self.source = source
        self.databaseID = databaseID
        self.hasher = hasher
        self.maximumPathDepth = maximumPathDepth
        self.maximumTargetBytes = maximumTargetBytes
    }

    public func read(uuid: String) async throws -> ImportRecordSnapshot {
        guard let id = UUID(uuidString: uuid) else { throw FormaError.invalidSource }
        if !discovered {
            _ = try await source.discover()
            discovered = true
        }
        authorized.insert(id)

        let record = try await source.record(id, in: scope())
        // The requested database is a parameter; this is the answer's own claim,
        // and the client already rejects a mismatch. Checking it here means the
        // adapter's guarantee does not depend on the client's internals.
        guard record.databaseID == databaseID else { throw FormaError.unauthorized }

        let metadata = try await source.metadata(of: id, in: scope())
        let path = try await parentPath(of: id)
        let fields = try Self.fields(metadata)

        var digest: String?
        var verified = false
        if let content = try await source.contentPath(of: id, in: scope()) {
            digest = await hasher.sha256(ofFileAt: content, limit: maximumTargetBytes)
            verified = digest != nil
        }

        return ImportRecordSnapshot(
            uuid: uuid, database: record.databaseID.uuidString, parentPath: path,
            metadata: fields, standardSHA256: digest, shaVerified: verified)
    }

    // MARK: - Parent path

    /// The group path the executor compares with the intent's `groupPath`.
    ///
    /// It is root-first and excludes the database root itself: a record sitting
    /// directly in the root reports `[]`, one in `Forma_I1B2/r1` reports
    /// `["Forma_I1B2", "r1"]`. Every step is a fresh read; nothing is inferred
    /// from a name or from an earlier operation.
    private func parentPath(of id: UUID) async throws -> [String] {
        var names: [String] = []
        var cursor = id
        var seen: Set<UUID> = [id]
        for _ in 0..<maximumPathDepth {
            let relation = try await source.parents(of: cursor, in: scope())
            guard relation.recordID == cursor else { throw FormaError.invalidResponse }
            guard let parentID = relation.primaryParentID else { return names }
            if parentID == databaseID { return names }
            guard seen.insert(parentID).inserted else { throw FormaError.invalidResponse }
            guard let parent = relation.parents.first(where: { $0.id == parentID }),
                  parent.type == "group", parent.databaseID == databaseID else {
                throw FormaError.invalidResponse
            }
            authorized.insert(parentID)
            names.insert(parent.name, at: 0)
            cursor = parentID
        }
        throw FormaError.invalidResponse
    }

    private func scope() -> DEVONthinkReadScope {
        DEVONthinkReadScope(databaseID: databaseID, recordIDs: authorized)
    }

    // MARK: - Metadata

    /// Maps the 12 contract fields onto the snapshot's string slots.
    ///
    /// The live field definitions declare every one of these fields as
    /// `string`. A scalar of another type is therefore canonicalised (integers
    /// and booleans have exactly one faithful text form) so that a value the
    /// record *does* hold is never mistaken for an empty slot — mistaking it
    /// would let the executor write over it. An array or object has no single
    /// text form, so the readback fails instead of silently dropping it.
    static func fields(_ values: [DEVONthinkMetadataField: DEVONthinkMetadataValue])
        throws -> [String: String?] {
        var result: [String: String?] = [:]
        for field in DEVONthinkMetadataField.allCases {
            let value = values[field] ?? .missing
            switch value {
            case .missing, .null:
                result.updateValue(nil, forKey: field.rawValue)
            case .string(let text):
                result.updateValue(text, forKey: field.rawValue)
            case .integer(let number):
                result.updateValue(String(number), forKey: field.rawValue)
            case .number(let number):
                result.updateValue(String(number), forKey: field.rawValue)
            case .boolean(let flag):
                result.updateValue(flag ? "true" : "false", forKey: field.rawValue)
            case .strings:
                throw FormaError.invalidResponse
            }
        }
        return result
    }
}
