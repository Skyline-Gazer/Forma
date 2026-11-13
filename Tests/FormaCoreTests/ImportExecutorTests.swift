import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The executor against a fake transport: the crash window, duplicates, and the
/// difference between "nothing was written" and "I do not know".
///
/// Every case starts from a real SQLite ledger so the phase assertions are about
/// what was persisted, not about what a stub remembered.
@Suite("Import executor")
struct ImportExecutorTests {
    private let now = ImportFixtures.now

    private struct Stack: Sendable {
        let ledger: ImportLedger
        let transport: FakeImportTransport
        let executor: ImportExecutor
        let runID: UUID
    }

    private func makeStack() async throws -> Stack {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        let ledger = ImportLedger(database: database)
        let runID = UUID()
        try ledger.startRun(ImportRunRecord(id: runID, scopeID: UUID(), manifestID: UUID(),
                                            manifestRevision: 1, profileID: "project-archive",
                                            profileVersion: "1.0.0", schemaVersion: "1.0",
                                            authorizationDigest: String(repeating: "f", count: 64),
                                            startedAt: now))
        let transport = FakeImportTransport()
        let fixed = now
        let writer = ImportSingleWriter(ledger: ledger, owner: "test", clock: { fixed })
        let executor = ImportExecutor(ledger: ledger, writer: writer, write: transport,
                                      read: transport, clock: { fixed })
        return Stack(ledger: ledger, transport: transport, executor: executor, runID: runID)
    }

    private func intent(_ stack: Stack, associationBasis: String? = ImportFixtures.association)
        throws -> ImportIntent {
        try ImportFixtures.intent(runID: stack.runID, associationBasis: associationBasis)
    }

    private func clearance(_ intent: ImportIntent) throws -> ImportPreflightClearance {
        try ImportFixtures.clearance(for: intent)
    }

    private func stored(_ stack: Stack, _ intent: ImportIntent) throws -> ImportOperationRecord? {
        try stack.ledger.operation(keyDigest: intent.key.digest)
    }

    // MARK: - Happy path

    @Test("one intent, one record, one verified readback")
    func happyPath() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(result.reason == .writeVerified)
        #expect(result.actualUUID != nil)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
        #expect(try stored(stack, intent)?.phase == .readbackVerified)
        #expect(try stored(stack, intent)?.targetSHA256 == ImportFixtures.sha)
        let record = try #require(try stored(stack, intent))
        #expect(try stack.ledger.attempts(operationID: record.id).count == 1)
    }

    @Test("a second execution of the same key does not create a second record")
    func idempotentReexecution() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        _ = try await stack.executor.execute(intent, clearance: try clearance(intent))
        let second = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(second.phase == .readbackVerified)
        #expect(second.attempts == 0)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    // MARK: - The crash window

    @Test("created then disconnected: recovered by lookup, not by a second create")
    func createUnknownOutcome() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
        #expect(try stored(stack, intent)?.actualUUID == "uuid-1")
    }

    @Test("refused before creating: the conclusive empty lookup ends the operation")
    func createRefusedBeforeApply() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.createBeforeApply)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        // The create's outcome was unknown; a conclusive lookup then proved the
        // record is absent. That is reported, not retried.
        #expect(result.phase == .failed)
        #expect(result.outcome == nil)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().isEmpty)
        #expect(try stored(stack, intent)?.errorCode == "absent_after_unknown")
    }

    @Test("a metadata failure leaves the record in place and the operation unknown")
    func metadataFailure() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setCreateWithoutMetadata(true)
        await stack.transport.setFault(.metadata)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .verifyRequired)
        #expect(result.actualUUID == "uuid-1")
        #expect(await stack.transport.storedRecords().count == 1)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    @Test("a readback that disagrees holds instead of overwriting")
    func readbackMismatch() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setReadbackOverride(["completion_year": "2019"])

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .conflictHold)
        #expect(result.phase == .conflictHold)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    @Test("a failing readback is unknown, not a success")
    func readbackFailure() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.readback)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .verifyRequired)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    // MARK: - Before any write

    @Test("a lookup timeout writes nothing")
    func lookupTimeout() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.lookup)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    @Test("an inconclusive lookup does not import")
    func inconclusiveLookup() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setLookupInconclusive(true)

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
    }

    // MARK: - Existing records

    @Test("a matching record is skipped as verified")
    func existingMatch() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-existing", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2026"],
                                         sha256: ImportFixtures.sha,
                                         associationBasis: ImportFixtures.association))

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .skipVerified)
        #expect(result.actualUUID == "uuid-existing")
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("an association-only match with different fields needs a person")
    func existingDifference() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-existing", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2019"],
                                         sha256: ImportFixtures.sha,
                                         associationBasis: ImportFixtures.association))

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        // One anchor plus differing fields is a candidate, not a confirmation:
        // the contract needs a second corroborating fact before calling it the
        // same business record.
        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("a confirmed record whose bytes differ is held")
    func confirmedButBytesDiffer() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-same-meta", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2026"],
                                         sha256: String(repeating: "d", count: 64),
                                         associationBasis: ImportFixtures.association))

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        #expect(result.outcome == .conflictHold)
        #expect(result.reason == .confirmedButDiffers)
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("identical bytes without an association anchor do not confirm a record")
    func sameBytesNoAnchor() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack, associationBasis: nil)
        await stack.transport.seed(.init(uuid: "uuid-other", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2026"],
                                         sha256: ImportFixtures.sha, associationBasis: nil))

        let result = try await stack.executor.execute(intent, clearance: try clearance(intent))

        // The bytes and the fields agree, but nothing ties the record to this
        // source: a hash is not an identity.
        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
    }

    // MARK: - Clearance gate

    @Test("a clearance for other facts does not authorize this operation")
    func clearanceMustMatch() async throws {
        let stack = try await makeStack()
        let mine = try intent(stack)
        let other = try ImportFixtures.intent(runID: stack.runID,
                                              snapshot: String(repeating: "b", count: 64))
        // A clearance that was decided for a different snapshot.
        let foreign = try ImportFixtures.clearance(for: other)

        let result = try await stack.executor.execute(mine, clearance: foreign)

        #expect(result.reason == .clearanceMismatch)
        #expect(result.attempts == 0)
        #expect(await stack.transport.createCalls == 0)
        #expect(try stored(stack, mine) == nil)
    }

    @Test("a blocked clearance creates no intent and writes nothing")
    func blockedPreflight() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let blocked = try ImportFixtures.clearance(for: intent, sha: String(repeating: "e", count: 64))

        let result = try await stack.executor.execute(intent, clearance: blocked)

        #expect(result.phase == .planned)
        #expect(result.outcome == nil)
        #expect(result.blockingCodes == [.sourceSHAMismatch])
        #expect(try stored(stack, intent) == nil)
        #expect(await stack.transport.createCalls == 0)
    }
}
