import Foundation
import GRDB
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
                      recordLimit: Int = 4, groupLimit: Int = 2,
                      metadataLimit: Int = 4, metadataPerRecord: Int = 2) -> ImportWriteScope {
        ImportWriteScope(
            databaseID: database, groupPrefix: prefix, tools: tools,
            metadataIdentifiers: identifiers,
            sourcePaths: [approvedPath, otherApprovedPath],
            recordLimit: recordLimit, groupLimit: groupLimit,
            metadataCallLimit: metadataLimit,
            metadataCallsPerRecordLimit: metadataPerRecord)
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
    actor ForeignDatabaseTransport: ImportWriteSurface {
        private(set) var createGroupCalls = 0
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

        func createGroup(database: String, path: [String]) async throws -> String {
            createGroupCalls += 1
            return "group-foreign"
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
    // MARK: - Group creation

    @Test func groupCreationPassesThePermitAndReachesTheTransportOnce() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        _ = try await guarded.createGroup(database: Self.database, path: Self.prefix)
        #expect(await base.createGroupCalls == 1)
        #expect(await authorization.createdGroups == 1)
    }

    @Test func groupCreationOutsideThePrefixNeverReachesTheTransport() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope())
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.createGroup(database: Self.database, path: ["Somewhere", "else"])
        }
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.createGroup(database: Self.foreignDatabase, path: Self.prefix)
        }
        #expect(await base.createGroupCalls == 0)
        #expect(await authorization.createdGroups == 0)
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
        #expect(await authorization.refusalCounts[.sourcePathNotInScope] == 1)
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

    // MARK: - Metadata budget

    private static func prove(_ authorization: ImportWriteAuthorization,
                              _ uuid: String) async throws {
        try await authorization.recordVerified(uuid: uuid, database: database,
                                               parentPath: prefix + ["batch-1"])
    }

    @Test func metadataTotalBudgetStopsTheNextCallBeforeTheTransport() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(
            scope: Self.scope(metadataLimit: 2, metadataPerRecord: 3))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        try await Self.prove(authorization, "uuid-1")
        try await Self.prove(authorization, "uuid-2")
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-1", metadata: ["projectname": "A"], source: Self.source()))
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-2", metadata: ["projectname": "B"], source: Self.source()))
        await #expect(throws: ImportWriteRefusal.self) {
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-1", metadata: ["projectname": "C"], source: Self.source()))
        }
        #expect(await base.metadataCalls == 2)
        #expect(await authorization.metadataGrantedCount == 2)
    }

    @Test func metadataPerRecordBudgetStopsTheSecondCallForOneRecord() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(
            scope: Self.scope(metadataLimit: 5, metadataPerRecord: 1))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        try await Self.prove(authorization, "uuid-1")
        try await Self.prove(authorization, "uuid-2")
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-1", metadata: ["projectname": "A"], source: Self.source()))
        await #expect(throws: ImportWriteRefusal.self) {
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-1", metadata: ["issuer": "B"], source: Self.source()))
        }
        // The per-record limit did not spend the other record's allowance.
        try await guarded.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-2", metadata: ["projectname": "C"], source: Self.source()))
        #expect(await base.metadataCalls == 2)
        #expect(await authorization.metadataGrantedCount == 2)
        let usage = await authorization.budget
        #expect(usage.calls(forRecord: "uuid-1") == 1)
    }

    @Test func aDeniedMetadataCallKeepsBothCountersAndTheTransportUntouched() async throws {
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(
            scope: Self.scope(metadataLimit: 1, metadataPerRecord: 1))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        try await Self.prove(authorization, "uuid-1")
        await #expect(throws: ImportWriteRefusal.self) {
            // Not proven: refused before the budget is considered.
            try await guarded.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-9", metadata: ["projectname": "x"], source: Self.source()))
        }
        #expect(await authorization.metadataGrantedCount == 0)
        #expect(await authorization.refusalCounts[.recordNotProvenInScope] == 1)
        #expect(await base.metadataCalls == 0)
    }

    // MARK: - Spent budget is not refunded

    @Test func timeoutDoesNotRefundTheImportBudget() async throws {
        let base = FakeImportTransport()
        await base.setFault(.createAfterApply)
        let authorization = ImportWriteAuthorization(scope: Self.scope(recordLimit: 2))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: FormaError.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await authorization.grantedCount == 1)
        _ = try await guarded.create(Self.createRequest())
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await base.createCalls == 2)
    }

    @Test func disconnectDoesNotRefundTheImportBudget() async throws {
        let base = FakeImportTransport()
        await base.setFault(.createBeforeApply)
        let authorization = ImportWriteAuthorization(scope: Self.scope(recordLimit: 2))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: FormaError.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await authorization.grantedCount == 1)
        _ = try await guarded.create(Self.createRequest())
        #expect(await base.createCalls == 2)
    }

    @Test func cancellationDoesNotRefundTheImportBudget() async throws {
        let base = FakeImportTransport()
        await base.setCreateDelay(300_000_000)
        let authorization = ImportWriteAuthorization(scope: Self.scope(recordLimit: 2))
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        let task = Task { _ = try await guarded.create(Self.createRequest()) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = try? await task.value
        // The grant was issued before the transport noticed the cancellation.
        #expect(await authorization.grantedCount == 1)
        await base.setCreateDelay(0)
        _ = try await guarded.create(Self.createRequest())
        await #expect(throws: ImportWriteRefusal.self) { _ = try await guarded.create(Self.createRequest()) }
        #expect(await base.createCalls == 2)
    }

    // MARK: - Cross-instance budget (journal)

    @Test func aSecondAuthorizationUnderTheSameJournalDoesNotRefreshImports() async throws {
        let journal = MemoryBudgetJournal()
        let base = FakeImportTransport()
        let first = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                             journal: journal, identity: "approval-1")
        let firstGuard = GuardedImportWriteTransport(base: base, authorization: first)
        { _ in Self.approvedPath }
        _ = try await firstGuard.create(Self.createRequest())

        let second = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                              journal: journal, identity: "approval-1")
        let secondGuard = GuardedImportWriteTransport(base: base, authorization: second)
        { _ in Self.approvedPath }
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await secondGuard.create(Self.createRequest())
        }
        #expect(await second.grantedCount == 0)
        #expect(await second.refusalCounts[.recordBudgetExhausted] == 1)
        #expect(await base.createCalls == 1)
    }

    @Test func aSecondAuthorizationUnderTheSameJournalDoesNotRefreshMetadata() async throws {
        let journal = MemoryBudgetJournal()
        let base = FakeImportTransport()
        let first = ImportWriteAuthorization(
            scope: Self.scope(metadataLimit: 1, metadataPerRecord: 1),
            journal: journal, identity: "approval-1")
        try await Self.prove(first, "uuid-1")
        let firstGuard = GuardedImportWriteTransport(base: base, authorization: first)
        { _ in Self.approvedPath }
        try await firstGuard.writeMetadata(ImportMetadataRequest(
            uuid: "uuid-1", metadata: ["projectname": "A"], source: Self.source()))

        let second = ImportWriteAuthorization(
            scope: Self.scope(metadataLimit: 1, metadataPerRecord: 1),
            journal: journal, identity: "approval-1")
        try await Self.prove(second, "uuid-1")
        let secondGuard = GuardedImportWriteTransport(base: base, authorization: second)
        { _ in Self.approvedPath }
        await #expect(throws: ImportWriteRefusal.self) {
            try await secondGuard.writeMetadata(ImportMetadataRequest(
                uuid: "uuid-1", metadata: ["issuer": "B"], source: Self.source()))
        }
        #expect(await second.refusalCounts[.metadataBudgetExhausted] == 1)
        #expect(await base.metadataCalls == 1)
    }

    @Test func differentIdentitiesHaveSeparateBudgets() async throws {
        let journal = MemoryBudgetJournal()
        let base = FakeImportTransport()
        let first = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                             journal: journal, identity: "approval-1")
        let firstGuard = GuardedImportWriteTransport(base: base, authorization: first)
        { _ in Self.approvedPath }
        _ = try await firstGuard.create(Self.createRequest())
        let other = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                             journal: journal, identity: "approval-2")
        let otherGuard = GuardedImportWriteTransport(base: base, authorization: other)
        { _ in Self.approvedPath }
        _ = try await otherGuard.create(Self.createRequest())
        #expect(await base.createCalls == 2)
        #expect(journal.usage(identity: "approval-1")?.importsGranted == 1)
        #expect(journal.usage(identity: "approval-2")?.importsGranted == 1)
    }

    @Test func anUnreadableJournalRefusesInsteadOfGranting() async throws {
        let journal = MemoryBudgetJournal()
        journal.setReadsFail(true)
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope(),
                                                     journal: journal, identity: "approval-1")
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.create(Self.createRequest())
        }
        #expect(await authorization.refusalCounts[.budgetUnavailable] == 1)
        #expect(await authorization.grantedCount == 0)
        #expect(await base.createCalls == 0)
    }

    @Test func anUnwritableJournalRollsBackTheGrant() async throws {
        let journal = MemoryBudgetJournal()
        journal.setWritesFail(true)
        let base = FakeImportTransport()
        let authorization = ImportWriteAuthorization(scope: Self.scope(),
                                                     journal: journal, identity: "approval-1")
        let guarded = GuardedImportWriteTransport(base: base, authorization: authorization,
                                                  sourcePath: { _ in Self.approvedPath })
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await guarded.create(Self.createRequest())
        }
        #expect(await authorization.grantedCount == 0)
        #expect(await base.createCalls == 0)
        #expect(journal.usage(identity: "approval-1") == nil)
    }

    @Test func theLedgerJournalCarriesSpendAcrossAuthorizationInstances() async throws {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        let ledger = ImportLedger(database: database)
        let base = FakeImportTransport()
        let first = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                             journal: ledger, identity: "approval-1")
        let firstGuard = GuardedImportWriteTransport(base: base, authorization: first)
        { _ in Self.approvedPath }
        _ = try await firstGuard.create(Self.createRequest())

        // A fresh ledger handle over the same database, as in a new process.
        let reopened = ImportLedger(database: database)
        #expect(try reopened.budgetUsage(identity: "approval-1")?.importsGranted == 1)
        let second = ImportWriteAuthorization(scope: Self.scope(recordLimit: 1),
                                              journal: reopened, identity: "approval-1")
        let secondGuard = GuardedImportWriteTransport(base: base, authorization: second)
        { _ in Self.approvedPath }
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await secondGuard.create(Self.createRequest())
        }
        #expect(await base.createCalls == 1)
    }
}
