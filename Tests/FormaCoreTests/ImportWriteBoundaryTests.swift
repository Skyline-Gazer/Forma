import Foundation
import Testing

@testable import FormaCore

/// The boundary exists so that "denied before the call" is enforced by code
/// rather than by the adapter remembering to check. Every test below asserts
/// both halves of that: the refusal code, and the wrapped transport's call
/// counter still being zero.
@Suite("I1-B2 write boundary")
struct ImportWriteBoundaryTests {
    static let database = "AAAAAAAA-0000-4000-8000-000000000001"
    static let foreignDatabase = "BBBBBBBB-0000-4000-8000-000000000002"
    static let runID = "run-1"
    static let approvedPath = "/tmp/forma-i1b2/forma-b1-probe-01.md"
    static let otherApprovedPath = "/tmp/forma-i1b2/forma-b1-probe-02.txt"
    static let prefix = ["Forma_I1B2", runID]

    static let allowedIdentifiers: Set<String> = [
        "projectname", "documentcategory", "documenttype", "issuer",
        "bidderentity", "endcustomer", "completionyear", "biddeadline",
    ]

    static func scope(tools: Set<ImportWriteTool> = Set(ImportWriteTool.allCases),
                      identifiers: Set<String> = allowedIdentifiers,
                      recordLimit: Int = 4, groupLimit: Int = 2) -> ImportWriteScope {
        ImportWriteScope(
            databaseID: database, groupPrefix: prefix, tools: tools,
            metadataIdentifiers: identifiers,
            sourcePaths: [approvedPath, otherApprovedPath],
            recordLimit: recordLimit, groupLimit: groupLimit)
    }

    static func source() -> ImportSourceBinding {
        ImportSourceBinding(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            relativePath: "forma-b1-probe-01.md",
            snapshotFingerprint: String(repeating: "a", count: 64),
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 47, readSessionID: "session-1")
    }

    static func createRequest(path: String = approvedPath) -> ImportCreateRequest {
        ImportCreateRequest(database: database, groupPath: prefix + ["batch-1"],
                            associationBasis: nil, metadata: ["projectname": "FORMA-SYNTHETIC"],
                            source: source())
    }

    /// A stub whose only job is to return a record from a database the scope
    /// does not own, so the boundary's independent check is the only thing that
    /// can catch it.
    actor ForeignDatabaseTransport: ImportWriteTransport {
        private(set) var lookupCalls = 0
        private(set) var createCalls = 0
        private(set) var metadataCalls = 0
        let database: String

        init(database: String) { self.database = database }

        func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult {
            lookupCalls += 1
            return ImportLookupResult(records: [ImportRecordSnapshot(
                uuid: "uuid-foreign", database: database,
                parentPath: ImportWriteBoundaryTests.prefix + ["batch-1"],
                metadata: [:], standardSHA256: String(repeating: "c", count: 64),
                shaVerified: true, associationBasis: nil)], conclusive: true)
        }

        func create(_ request: ImportCreateRequest) async throws -> String {
            createCalls += 1
            return "uuid-foreign"
        }

        func writeMetadata(_ request: ImportMetadataRequest) async throws {
            metadataCalls += 1
        }
    }

    static func lookupQuery(database: String = database) -> ImportLookupQuery {
        ImportLookupQuery(database: database, groupPath: prefix + ["batch-1"],
                          associationBasis: nil, source: source())
    }

    // MARK: - Default deny

    @Test func unknownToolCannotBeExpressedOrGranted() async throws {
        let authorization = ImportWriteAuthorization(scope: Self.scope(tools: [.importFile]))
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await authorization.permit(.createGroup(
                location: Self.prefix.joined(separator: "/"), database: Self.database))
        }
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await authorization.permit(.setMetadata(
                recordUUID: "uuid-1", metadata: ["projectname": "x"]))
        }
        #expect(await authorization.grantedCount == 0)
        // The tool enum is the whole vocabulary: there is no string entry point.
        #expect(ImportWriteTool.allCases.map(\.rawValue).sorted() == [
            "create_group_path", "import_file", "set_record_custom_metadata",
        ])
    }

    @Test func foreignDatabaseIsRefusedBeforeTheTransportIsCalled() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.lookup(Self.lookupQuery(database: Self.foreignDatabase))
        }
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.create(ImportCreateRequest(
                database: Self.foreignDatabase, groupPath: Self.prefix + ["batch-1"],
                associationBasis: nil, metadata: [:], source: Self.source()))
        }
        #expect(await base.lookupCalls == 0)
        #expect(await base.createCalls == 0)
    }

    @Test func groupPathMustExtendThePrefixAndNotMerelyShareIt() async throws {
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        for path in [["Forma_I1B2X", "run-1"], ["Forma_I1B2"], ["Other", "run-1"], []] {
            await #expect(throws: ImportWriteRefusal.self) {
                _ = try await authorization.permit(.createGroup(
                    location: path.joined(separator: "/"), database: Self.database))
            }
        }
        // The prefix itself and anything below it are allowed.
        _ = try await authorization.permit(.createGroup(
            location: Self.prefix.joined(separator: "/"), database: Self.database))
        _ = try await authorization.permit(.createGroup(
            location: (Self.prefix + ["batch-1"]).joined(separator: "/"), database: Self.database))
        await #expect(throws: ImportWriteRefusal.self) {
            // Third group exceeds the approved group count.
            _ = try await authorization.permit(.createGroup(
                location: (Self.prefix + ["batch-2"]).joined(separator: "/"), database: Self.database))
        }
    }

    @Test func unapprovedSourcePathIsRefused() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in "/tmp/forma-i1b2/notes.pdf" })
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await base.createCalls == 0)
    }

    @Test func unresolvedSourcePathIsRefused() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in nil })
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await base.createCalls == 0)
    }

    @Test func indexingModeIsRefused() async throws {
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await authorization.permit(.importFile(
                path: Self.approvedPath, destination: Self.prefix.joined(separator: "/"),
                database: Self.database, mode: "index"))
        }
    }

    // MARK: - Metadata identifier whitelist

    @Test func unknownMetadataIdentifierIsRefusedBeforeAnyWrite() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        try await authorization.recordVerified(uuid: "uuid-1", database: Self.database,
                                               parentPath: Self.prefix + ["batch-1"])
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-1", metadata: ["projetname": "typo"], source: Self.source()))
        }
        #expect(await base.metadataCalls == 0)
        #expect(await authorization.grantedCount == 0)
    }

    /// A record can live in the authorized database and still not belong to this
    /// run — a leftover from someone else's work. It must not become a metadata
    /// target, so the proof carries the observed parent group too.
    @Test func recordOutsideTheApprovedGroupIsNotAValidMetadataTarget() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        await #expect(throws: ImportWriteRefusal.self) {
            try await authorization.recordVerified(uuid: "uuid-1", database: Self.database,
                                                   parentPath: ["SomeOtherGroup"])
        }
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-1", metadata: ["projectname": "x"], source: Self.source()))
        }
        #expect(await base.metadataCalls == 0)
    }


    @Test func metadataWriteRequiresARecordProvenInScope() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-unproven", metadata: ["projectname": "x"], source: Self.source()))
        }
        // A database claim the tool cannot send is not evidence either.
        await #expect(throws: ImportWriteRefusal.self) {
            try await authorization.recordVerified(uuid: "uuid-foreign", database: Self.foreignDatabase,
                                                   parentPath: Self.prefix + ["batch-1"])
        }
        #expect(await base.metadataCalls == 0)
        #expect(await authorization.isProven("uuid-foreign") == false)
    }

    @Test func permittedMetadataWriteReachesTheTransportOnce() async throws {
        let base = FakeImportTransport()
        await base.seed(.init(uuid: "uuid-1", database: Self.database,
                              parentPath: Self.prefix + ["batch-1"], metadata: [:],
                              sha256: String(repeating: "d", count: 64), associationBasis: nil))
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        try await authorization.recordVerified(uuid: "uuid-1", database: Self.database,
                                               parentPath: Self.prefix + ["batch-1"])
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-1", metadata: ["projectname": "FORMA-SYNTHETIC", "issuer": nil],
            source: Self.source()))
        #expect(await base.metadataCalls == 1)
        #expect(await authorization.grantedCount == 0) // metadata grants do not consume the record budget
    }

    // MARK: - Budgets

    @Test func recordBudgetStopsTheFifthImportBeforeTheCall() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        for _ in 0..<4 { _ = try await guarded.create(Self.createRequest()) }
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await base.createCalls == 4)
        #expect(await authorization.grantedCount == 4)
    }

    @Test func deniedRequestDoesNotConsumeBudget() async throws {
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await authorization.permit(.importFile(
                path: "/tmp/not-approved.md", destination: Self.prefix.joined(separator: "/"),
                database: Self.database, mode: "import"))
        }
        #expect(await authorization.grantedCount == 0)
        _ = try await authorization.permit(.importFile(
            path: Self.approvedPath, destination: Self.prefix.joined(separator: "/"),
            database: Self.database, mode: "import"))
        #expect(await authorization.grantedCount == 1)
    }

    // MARK: - Returned identity is checked independently

    @Test func lookupResultFromAnotherDatabaseIsRefused() async throws {
        let base = ForeignDatabaseTransport(database: Self.foreignDatabase)
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.lookup(Self.lookupQuery()) }
        #expect(await base.lookupCalls == 1) // the call happened; its answer was rejected
        #expect(await authorization.isProven("uuid-foreign") == false)
    }

    @Test func inScopeLookupProvesTheRecordForLaterMetadataWrites() async throws {
        let base = FakeImportTransport()
        await base.seed(.init(uuid: "uuid-1", database: Self.database,
                              parentPath: Self.prefix + ["batch-1"], metadata: [:],
                              sha256: String(repeating: "d", count: 64), associationBasis: nil))
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        _ = try await guarded.lookup(Self.lookupQuery())
        #expect(await authorization.isProven("uuid-1") == true)
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-1", metadata: ["documentcategory": "99_TEST"], source: Self.source()))
        #expect(await base.metadataCalls == 1)
    }
}
