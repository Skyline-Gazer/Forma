import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The fault matrix: every injectable failure, and what the ledger is allowed to
/// say afterwards.
///
/// The property under test is not "the happy path works" — the executor suite
/// covers that. It is that no fault ever produces a second record, a silent
/// success, or a phase the contract does not permit.
@Suite("Import fault matrix")
struct ImportFaultMatrixTests {
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
                                            startedAt: ImportFixtures.now))
        let transport = FakeImportTransport()
        let fixed = ImportFixtures.now
        let writer = ImportSingleWriter(ledger: ledger, owner: "test", clock: { fixed })
        let executor = ImportExecutor(ledger: ledger, writer: writer, write: transport,
                                      read: transport, clock: { fixed })
        return Stack(ledger: ledger, transport: transport, executor: executor, runID: runID)
    }

    private func intent(_ stack: Stack) throws -> ImportIntent {
        try ImportFixtures.intent(runID: stack.runID)
    }

    @Test("every injected fault ends in a permitted phase and never duplicates a record")
    func matrix() async throws {
        let faults: [FakeImportTransport.Fault] = [.createBeforeApply, .createAfterApply,
                                                   .lookup, .metadata, .readback]
        let permitted: Set<ImportPhase> = [.readbackVerified, .skippedVerified, .conflictHold,
                                           .verifyRequired, .failed]
        for fault in faults {
            let stack = try await makeStack()
            let intent = try intent(stack)
            await stack.transport.setFault(fault)
            if fault == .metadata { await stack.transport.setCreateWithoutMetadata(true) }

            let result = try await stack.executor.execute(intent,
                                                         clearance: try ImportFixtures.clearance(for: intent))

            #expect(permitted.contains(result.phase), "\(fault) -> \(result.phase.rawValue)")
            #expect(await stack.transport.storedRecords().count <= 1, "\(fault)")
            let stored = try stack.ledger.operation(keyDigest: intent.key.digest)
            #expect(stored?.phase == result.phase, "\(fault)")
            #expect(stored?.phase != .planned, "\(fault)")
        }
    }

    @Test("a crash after create is resolved by resume without a second create")
    func crashThenResume() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-crashed", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2026"],
                                         sha256: ImportFixtures.sha,
                                         associationBasis: ImportFixtures.association))
        // The process died right after persisting the intent.
        let record = ImportOperationRecord(
            runID: stack.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath, intendedMetadataDigest: "d",
            intendedMetadataJSON: "{}", sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: intent.authorizationDigest, createdAt: ImportFixtures.now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: ImportFixtures.now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: ImportFixtures.now)

        let sweep = try ImportRecovery.open(stack.ledger, at: ImportFixtures.now)
        #expect(sweep.interrupted == 1)

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        #expect(result.outcome == .skipVerified)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    @Test("two concurrent executions of one key create at most one record")
    func concurrentSameKey() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let clearance = try ImportFixtures.clearance(for: intent)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    _ = try? await stack.executor.execute(intent, clearance: clearance)
                }
            }
            await group.waitForAll()
        }

        #expect(await stack.transport.createCalls <= 1)
        #expect(await stack.transport.storedRecords().count <= 1)
        let stored = try stack.ledger.operation(keyDigest: intent.key.digest)
        #expect(stored != nil)
    }

    @Test("cancellation before any write leaves a cancelled row and no lease")
    func cancellation() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let clearance = try ImportFixtures.clearance(for: intent)
        await stack.transport.setLookupDelay(200_000_000)

        let task = Task { try await stack.executor.execute(intent, clearance: clearance) }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        _ = try? await task.value

        let stored = try stack.ledger.operation(keyDigest: intent.key.digest)
        #expect(stored?.phase == .cancelled)
        #expect(try stack.ledger.leaseOwner(at: ImportFixtures.now) == nil)
        #expect(await stack.transport.createCalls == 0)
    }
}
