import Foundation
import Testing
@testable import FormaCore

private let databaseID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let recordID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let innerGroupID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let outerGroupID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let otherDatabaseID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

/// A scripted read-only target.
///
/// It enforces the same scope rule as the live client — an ID the caller did not
/// authorise is refused — so a test can prove the adapter grows its authorised
/// set along observed relationships instead of widening it up front.
private actor FakeReadbackSource: DEVONthinkReadbackSource {
    private var records: [UUID: DEVONthinkRecord] = [:]
    private var relations: [UUID: DEVONthinkRecordParents] = [:]
    private var metadata: [UUID: [DEVONthinkMetadataField: DEVONthinkMetadataValue]] = [:]
    private var contentPaths: [UUID: String] = [:]
    private(set) var discoverCalls = 0
    private(set) var readCalls: [UUID] = []
    private(set) var observedScopes: [DEVONthinkReadScope] = []
    private var recordError: FormaError?

    func discover() async throws -> DEVONthinkCapabilities {
        discoverCalls += 1
        return DEVONthinkCapabilities(
            protocolVersion: "2025-06-18", serverName: "fixture", serverVersion: "1.0",
            probedAt: Date(timeIntervalSince1970: 0), tools: [], availableReadOnlyTools: [])
    }

    private func authorize(_ id: UUID, _ scope: DEVONthinkReadScope) throws {
        observedScopes.append(scope)
        guard scope.recordIDs.contains(id) else { throw FormaError.unauthorized }
    }

    func record(_ id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecord {
        try authorize(id, scope)
        readCalls.append(id)
        if let recordError { throw recordError }
        guard let record = records[id] else { throw FormaError.remoteStatus(-32002) }
        return record
    }

    func parents(of id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecordParents {
        try authorize(id, scope)
        guard let relation = relations[id] else {
            return DEVONthinkRecordParents(recordID: id, primaryParentID: nil, parents: [])
        }
        return relation
    }

    func metadata(of id: UUID, in scope: DEVONthinkReadScope) async throws
        -> [DEVONthinkMetadataField: DEVONthinkMetadataValue] {
        try authorize(id, scope)
        return metadata[id] ?? [:]
    }

    func contentPath(of id: UUID, in scope: DEVONthinkReadScope) async throws -> String? {
        try authorize(id, scope)
        return contentPaths[id]
    }

    // MARK: - Fixtures

    func failRecordReads(with error: FormaError) { recordError = error }
    func clearRecordFailure() { recordError = nil }

    func insertRecord(_ record: DEVONthinkRecord,
                      metadata values: [DEVONthinkMetadataField: DEVONthinkMetadataValue] = [:],
                      path: String? = nil) {
        records[record.id] = record
        metadata[record.id] = values
        contentPaths[record.id] = path
    }

    func insertGroup(_ record: DEVONthinkRecord, parent: UUID?, primaryParent: UUID?) {
        records[record.id] = record
        let parents: [DEVONthinkRecord] = parent.flatMap { records[$0] }.map { [$0] } ?? []
        relations[record.id] = DEVONthinkRecordParents(
            recordID: record.id, primaryParentID: primaryParent, parents: parents)
    }

    func setParents(of id: UUID, primary: UUID?, all: [UUID]) {
        relations[id] = DEVONthinkRecordParents(
            recordID: id, primaryParentID: primary, parents: all.compactMap { records[$0] })
    }
}

private struct StubHasher: TargetByteHasher {
    let digest: String?
    func sha256(ofFileAt path: String, limit: Int64) async -> String? { digest }
}

private func group(_ id: UUID, _ name: String, database: UUID = databaseID) -> DEVONthinkRecord {
    DEVONthinkRecord(id: id, databaseID: database, name: name, type: "group", location: nil)
}

private func record(_ id: UUID = recordID, database: UUID = databaseID,
                    name: String = "probe.md") -> DEVONthinkRecord {
    DEVONthinkRecord(id: id, databaseID: database, name: name, type: "markdown", location: nil)
}

/// `Forma_I1B2/r1` under the database root, holding one record.
private func nestedFixture() async -> FakeReadbackSource {
    let source = FakeReadbackSource()
    await source.insertGroup(group(outerGroupID, "Forma_I1B2"), parent: nil, primaryParent: nil)
    await source.insertGroup(group(innerGroupID, "r1"), parent: outerGroupID, primaryParent: outerGroupID)
    await source.insertRecord(record(), metadata: [
        .projectname: .string("FORMA-SYNTHETIC-PROJECT-001"),
        .completionyear: .integer(2099),
        .documentcategory: .string("99_TEST"),
        .bidderentity: .null,
    ], path: "/tmp/forma-readback/probe")
    await source.setParents(of: recordID, primary: innerGroupID, all: [innerGroupID])
    return source
}

@Test func readAdapterBuildsSnapshotFromObservedFacts() async throws {
    let source = await nestedFixture()
    let adapter = DEVONthinkImportReadAdapter(
        source: source, databaseID: databaseID, hasher: StubHasher(digest: "abc123"))

    let snapshot = try await adapter.read(uuid: recordID.uuidString)

    #expect(snapshot.uuid == recordID.uuidString)
    #expect(snapshot.database == databaseID.uuidString)
    #expect(snapshot.parentPath == ["Forma_I1B2", "r1"])
    #expect(snapshot.metadata["projectname"] == "FORMA-SYNTHETIC-PROJECT-001")
    #expect(snapshot.metadata["documentcategory"] == "99_TEST")
    #expect(snapshot.standardSHA256 == "abc123")
    #expect(snapshot.shaVerified)
    let discoveries = await source.discoverCalls
    #expect(discoveries == 1)
}

@Test func readAdapterCanonicalisesScalarMetadataButNeverDropsIt() async throws {
    let source = await nestedFixture()
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: nil))
    let snapshot = try await adapter.read(uuid: recordID.uuidString)

    // A year stored as a number is rendered in its one faithful text form, so the
    // executor sees a value the record holds instead of treating the slot as
    // empty — treating it as empty would let a later write overwrite it.
    #expect((snapshot.metadata["completionyear"] ?? nil) == "2099")
    // An explicit null is an empty slot; fields nobody wrote stay empty too.
    #expect((snapshot.metadata["bidderentity"] ?? nil) == nil)
    #expect((snapshot.metadata["endcustomer"] ?? nil) == nil)
}

@Test func readAdapterRefusesAnArrayWhereTheContractDeclaresText() async throws {
    let source = FakeReadbackSource()
    await source.insertRecord(record(), metadata: [.projectname: .strings(["A", "B"])])
    await source.setParents(of: recordID, primary: nil, all: [])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    // An array has no single text form: refusing the readback is safer than
    // reporting "no value" and letting a write land on top of it.
    await #expect(throws: FormaError.invalidResponse) { try await adapter.read(uuid: recordID.uuidString) }
}

@Test func readAdapterKeepsUnprovableBytesUnverified() async throws {
    let source = await nestedFixture()
    // No content path recorded: no bytes can be named at all.
    await source.insertRecord(record(), metadata: [:], path: nil)
    await source.setParents(of: recordID, primary: innerGroupID, all: [innerGroupID])
    let withBytes = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                                hasher: StubHasher(digest: "abc123"))
    let noPath = try await withBytes.read(uuid: recordID.uuidString)
    #expect(noPath.standardSHA256 == nil)
    #expect(noPath.shaVerified == false)

    // A path that exists but cannot be read produces the same answer.
    await source.insertRecord(record(), metadata: [:], path: "/tmp/forma-readback/unreadable")
    await source.setParents(of: recordID, primary: innerGroupID, all: [innerGroupID])
    let unreadable = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                                 hasher: StubHasher(digest: nil))
    let snapshot = try await unreadable.read(uuid: recordID.uuidString)
    #expect(snapshot.standardSHA256 == nil)
    #expect(snapshot.shaVerified == false)
}

@Test func readAdapterRejectsACrossDatabaseRecord() async throws {
    let source = FakeReadbackSource()
    await source.insertRecord(record(database: otherDatabaseID), path: "/tmp/other")
    await source.setParents(of: recordID, primary: nil, all: [])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    // The request named the authorised database; the answer says otherwise, and
    // the answer is what identity is checked against.
    await #expect(throws: FormaError.unauthorized) { try await adapter.read(uuid: recordID.uuidString) }
}

@Test func readAdapterReportsAnEmptyPathAtTheDatabaseRoot() async throws {
    let source = FakeReadbackSource()
    await source.insertRecord(record(), path: "/tmp/root-level")
    await source.setParents(of: recordID, primary: nil, all: [])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    let snapshot = try await adapter.read(uuid: recordID.uuidString)
    #expect(snapshot.parentPath.isEmpty)
}

@Test func readAdapterStopsAtTheDatabaseRootInsteadOfNamingIt() async throws {
    let source = FakeReadbackSource()
    await source.insertRecord(record(), path: "/tmp/child")
    await source.setParents(of: recordID, primary: databaseID, all: [databaseID])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    let snapshot = try await adapter.read(uuid: recordID.uuidString)
    #expect(snapshot.parentPath.isEmpty)
}

@Test func readAdapterRefusesCyclicParentChains() async throws {
    let source = FakeReadbackSource()
    await source.insertGroup(group(outerGroupID, "A"), parent: innerGroupID, primaryParent: innerGroupID)
    await source.insertGroup(group(innerGroupID, "B"), parent: outerGroupID, primaryParent: outerGroupID)
    await source.insertRecord(record(), path: "/tmp/cycle")
    await source.setParents(of: recordID, primary: outerGroupID, all: [outerGroupID])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    await #expect(throws: FormaError.invalidResponse) { try await adapter.read(uuid: recordID.uuidString) }
}

@Test func readAdapterBoundsTheParentWalk() async throws {
    let source = FakeReadbackSource()
    await source.insertGroup(group(outerGroupID, "A"), parent: innerGroupID, primaryParent: innerGroupID)
    await source.insertGroup(group(innerGroupID, "B"), parent: nil, primaryParent: nil)
    await source.insertRecord(record(), path: "/tmp/deep")
    await source.setParents(of: recordID, primary: outerGroupID, all: [outerGroupID])
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"),
                                              maximumPathDepth: 1)

    await #expect(throws: FormaError.invalidResponse) { try await adapter.read(uuid: recordID.uuidString) }
}

@Test func readAdapterEchoesTheRequestedUUIDAndQueriesTheCanonicalForm() async throws {
    let source = await nestedFixture()
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))
    let lowercase = recordID.uuidString.lowercased()

    let snapshot = try await adapter.read(uuid: lowercase)

    // The executor compares this string with the one it asked for, so it is
    // echoed unchanged.
    #expect(snapshot.uuid == lowercase)
    #expect(snapshot.database == databaseID.uuidString)
    let reads = await source.readCalls
    // The lookup itself used the canonical form the live server requires.
    #expect(reads == [recordID])
}

@Test func readAdapterRejectsAMalformedUUID() async {
    let adapter = DEVONthinkImportReadAdapter(source: FakeReadbackSource(), databaseID: databaseID,
                                              hasher: StubHasher(digest: nil))
    await #expect(throws: FormaError.invalidSource) { try await adapter.read(uuid: "not-a-uuid") }
}

@Test func readAdapterDiscoversOnceAndPropagatesClientFailures() async throws {
    let source = await nestedFixture()
    await source.failRecordReads(with: .disconnected)
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))

    await #expect(throws: FormaError.disconnected) { try await adapter.read(uuid: recordID.uuidString) }
    var discoveries = await source.discoverCalls
    #expect(discoveries == 1)

    // A second attempt reuses the discovery; it does not silently renegotiate.
    await source.clearRecordFailure()
    _ = try await adapter.read(uuid: recordID.uuidString)
    discoveries = await source.discoverCalls
    #expect(discoveries == 1)
}

@Test func readAdapterNeverWidensItsScopeBeyondObservedRelationships() async throws {
    let source = await nestedFixture()
    let adapter = DEVONthinkImportReadAdapter(source: source, databaseID: databaseID,
                                              hasher: StubHasher(digest: "abc123"))
    _ = try await adapter.read(uuid: recordID.uuidString)

    let scopes = await source.observedScopes
    #expect(scopes.allSatisfy { $0.databaseID == databaseID })
    let first = try #require(scopes.first)
    #expect(first.recordIDs == Set([recordID]))
    let last = try #require(scopes.last)
    #expect(last.recordIDs == Set([recordID, innerGroupID, outerGroupID]))
}
