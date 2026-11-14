import Foundation

@testable import FormaCore

/// An in-memory stand-in for the DEVONthink write surface.
///
/// It exists to make failure *deterministic*: the interesting cases are
/// "created, then the connection dropped", "the lookup timed out", and "the
/// record exists but the metadata write never landed". A real client cannot be
/// asked for those on demand, and a fake that only ever succeeds proves nothing.
actor FakeImportTransport: ImportWriteSurface, ImportReadTransport {
    enum Fault: Sendable, Equatable {
        case none
        /// The record is created and then the call throws: the crash window.
        case createAfterApply
        /// The call throws before anything is created.
        case createBeforeApply
        case lookup
        case metadata
        /// The independent readback fails.
        case readback
    }

    struct Stored: Sendable, Equatable {
        var uuid: String
        var database: String
        var parentPath: [String]
        var metadata: [String: String?]
        var sha256: String
        var associationBasis: String?
        var shaVerified: Bool = true
    }

    private var records: [String: Stored] = [:]
    private var next = 0
    private(set) var createCalls = 0
    private(set) var createGroupCalls = 0
    private(set) var createdGroupPaths: [[String]] = []
    private(set) var lookupCalls = 0
    private(set) var metadataCalls = 0
    private(set) var readCalls = 0
    /// Ordered log of external operations, so a test can prove a read came
    /// before a write instead of only counting them.
    private(set) var events: [String] = []
    /// The last create request, so a test can inspect the source binding.
    private(set) var lastCreateRequest: ImportCreateRequest?

    var fault: Fault = .none
    /// A lookup that cannot prove absence, however few records it returns.
    var lookupInconclusive = false
    /// Makes a lookup take long enough for a cancellation test to land.
    var lookupDelayNanoseconds: UInt64 = 0
    /// When false the independent read cannot prove the bytes, which is what a
    /// target without a verifiable digest looks like.
    var readbackSHAVerified = true
    /// Creates the record without the fields, so the metadata step still has to
    /// happen. Separate from `fault` because the two are independent failures.
    var createWithoutMetadata = false
    /// Records that become visible only when `create` runs, so the *post-create*
    /// recovery lookup can see candidates the pre-create lookup did not.
    var extraRecordsAfterCreate: [Stored] = []
    /// Corrupts the readback of the first record, for mismatch tests.
    var readbackMetadataOverride: [String: String?]?
    /// Makes the independent read throw CancellationError.
    var readCancellation = false
    /// Makes the independent read report a different UUID than the record key.
    var readUUIDOverride: String?
    /// Makes every independent read report a different (still verified) digest.
    var readSHAOverride: String?
    /// Corrupts the record's digest after a metadata write, so the readback
    /// sees a target that changed between the write and the verification.
    var corruptSHAAfterWrite = false

    func setFault(_ fault: Fault) { self.fault = fault }
    func setLookupInconclusive(_ value: Bool) { lookupInconclusive = value }
    func setLookupDelay(_ nanoseconds: UInt64) { lookupDelayNanoseconds = nanoseconds }
    func setReadbackSHAVerified(_ value: Bool) { readbackSHAVerified = value }
    func setCreateWithoutMetadata(_ value: Bool) { createWithoutMetadata = value }
    func setExtraRecordsAfterCreate(_ records: [Stored]) { extraRecordsAfterCreate = records }
    func setReadbackOverride(_ metadata: [String: String?]?) { readbackMetadataOverride = metadata }
    func setReadCancellation(_ value: Bool) { readCancellation = value }
    func setReadUUIDOverride(_ value: String?) { readUUIDOverride = value }
    func setReadSHAOverride(_ value: String?) { readSHAOverride = value }
    func setCorruptSHAAfterWrite(_ value: Bool) { corruptSHAAfterWrite = value }
    func eventLog() -> [String] { events }
    func storedRecords() -> [Stored] { records.values.sorted { $0.uuid < $1.uuid } }
    func seed(_ record: Stored) { records[record.uuid] = record }

    // MARK: - Write side

    func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult {
        lookupCalls += 1
        events.append("lookup")
        if lookupDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: lookupDelayNanoseconds)
        }
        if fault == .lookup { throw FormaError.timeout }
        let matches = records.values
            .filter { $0.database == query.database && $0.parentPath == query.groupPath }
            .filter { query.associationBasis == nil || $0.associationBasis == query.associationBasis }
            .sorted { $0.uuid < $1.uuid }
            .map {
                ImportRecordSnapshot(uuid: $0.uuid, database: $0.database, parentPath: $0.parentPath,
                                     metadata: $0.metadata, standardSHA256: $0.sha256,
                                     shaVerified: $0.shaVerified, associationBasis: $0.associationBasis)
            }
        return ImportLookupResult(records: matches, conclusive: !lookupInconclusive)
    }

    func createGroup(database: String, path: [String]) async throws -> String {
        createGroupCalls += 1
        createdGroupPaths.append(path)
        events.append("createGroup")
        return "group-\(path.joined(separator: "/"))"
    }

    func create(_ request: ImportCreateRequest) async throws -> String {
        createCalls += 1
        events.append("create")
        lastCreateRequest = request
        if fault == .createBeforeApply {
            for extra in extraRecordsAfterCreate { records[extra.uuid] = extra }
            throw FormaError.disconnected
        }
        next += 1
        let uuid = "uuid-\(next)"
        // A create may or may not carry the fields; the transport that leaves them
        // out is what the metadata step exists for.
        let metadata = createWithoutMetadata ? [:] : request.metadata
        records[uuid] = Stored(uuid: uuid, database: request.database, parentPath: request.groupPath,
                               metadata: metadata, sha256: request.source.contentSHA256,
                               associationBasis: request.associationBasis)
        for extra in extraRecordsAfterCreate { records[extra.uuid] = extra }
        if fault == .createAfterApply { throw FormaError.timeout }
        return uuid
    }

    func writeMetadata(_ request: ImportMetadataRequest) async throws {
        metadataCalls += 1
        events.append("metadata")
        if fault == .metadata { throw FormaError.disconnected }
        guard var record = records[request.uuid] else { throw FormaError.invalidResponse }
        // A metadata write fills the named slots; it does not clear the others.
        for (key, value) in request.metadata { record.metadata[key] = value }
        record.sha256 = corruptSHAAfterWrite ? String(repeating: "f", count: 64)
            : request.source.contentSHA256
        records[request.uuid] = record
    }

    // MARK: - Read side

    func read(uuid: String) async throws -> ImportRecordSnapshot {
        readCalls += 1
        events.append("read")
        if readCancellation { throw CancellationError() }
        if fault == .readback { throw FormaError.disconnected }
        guard let record = records[uuid] else { throw FormaError.invalidResponse }
        return ImportRecordSnapshot(
            uuid: readUUIDOverride ?? record.uuid, database: record.database,
            parentPath: record.parentPath,
            metadata: readbackMetadataOverride ?? record.metadata,
            standardSHA256: readSHAOverride ?? record.sha256,
            shaVerified: record.shaVerified && readbackSHAVerified,
            associationBasis: record.associationBasis)
    }
}
