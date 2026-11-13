import Foundation

@testable import FormaCore

/// An in-memory stand-in for the DEVONthink write surface.
///
/// It exists to make failure *deterministic*: the interesting cases are
/// "created, then the connection dropped", "the lookup timed out", and "the
/// record exists but the metadata write never landed". A real client cannot be
/// asked for those on demand, and a fake that only ever succeeds proves nothing.
actor FakeImportTransport: ImportWriteTransport, ImportReadTransport {
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
    private(set) var lookupCalls = 0
    private(set) var metadataCalls = 0

    var fault: Fault = .none
    /// A lookup that cannot prove absence, however few records it returns.
    var lookupInconclusive = false
    /// Makes a lookup take long enough for a cancellation test to land.
    var lookupDelayNanoseconds: UInt64 = 0
    /// Corrupts the readback of the first record, for mismatch tests.
    var readbackMetadataOverride: [String: String?]?

    func setFault(_ fault: Fault) { self.fault = fault }
    func setLookupInconclusive(_ value: Bool) { lookupInconclusive = value }
    func setLookupDelay(_ nanoseconds: UInt64) { lookupDelayNanoseconds = nanoseconds }
    func setReadbackOverride(_ metadata: [String: String?]?) { readbackMetadataOverride = metadata }
    func storedRecords() -> [Stored] { records.values.sorted { $0.uuid < $1.uuid } }
    func seed(_ record: Stored) { records[record.uuid] = record }

    // MARK: - Write side

    func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult {
        lookupCalls += 1
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

    func create(_ request: ImportCreateRequest) async throws -> String {
        createCalls += 1
        if fault == .createBeforeApply { throw FormaError.disconnected }
        next += 1
        let uuid = "uuid-\(next)"
        records[uuid] = Stored(uuid: uuid, database: request.database, parentPath: request.groupPath,
                               metadata: request.metadata, sha256: request.sourceSHA256,
                               associationBasis: request.associationBasis)
        if fault == .createAfterApply { throw FormaError.timeout }
        return uuid
    }

    func writeMetadata(_ request: ImportMetadataRequest) async throws {
        metadataCalls += 1
        if fault == .metadata { throw FormaError.disconnected }
        guard var record = records[request.uuid] else { throw FormaError.invalidResponse }
        record.metadata = request.metadata
        record.sha256 = request.sourceSHA256
        records[request.uuid] = record
    }

    // MARK: - Read side

    func read(uuid: String) async throws -> ImportRecordSnapshot {
        if fault == .readback { throw FormaError.disconnected }
        guard let record = records[uuid] else { throw FormaError.invalidResponse }
        return ImportRecordSnapshot(
            uuid: record.uuid, database: record.database, parentPath: record.parentPath,
            metadata: readbackMetadataOverride ?? record.metadata,
            standardSHA256: record.sha256, shaVerified: record.shaVerified,
            associationBasis: record.associationBasis)
    }
}
