import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The fault matrix: every injectable failure, and what the ledger is allowed to
/// say afterwards.
///
/// The property under test is not "the happy path works" — A3 covers that. It is
/// that no fault ever produces a second record, a silent success, or a phase the
/// contract does not permit.
@Suite("Import fault matrix")
struct ImportFaultMatrixTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sha = String(repeating: "c", count: 64)
    private let fingerprint = String(repeating: "a", count: 64)
    private let association = "context revision 3 candidate cr-0001"
    private let groupPath = ["01_招标文件", "2026"]
    private let metadata: [String: String?] = ["completion_year": "2026"]

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

    private func intent(_ stack: Stack) throws -> ImportIntent {
        let entry = ManifestEntry(
            sourceID: UUID(), snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "synthetic/tender.pdf", state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive", groupPath: groupPath, resolved: true),
            eligibleForAutoExecution: true)
        let key = try ImportOperationKey(sourceID: entry.sourceID, snapshotFingerprint: fingerprint,
                                         manifestRevision: 1,
                                         targetAssociationID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        return ImportIntent(runID: stack.runID, entry: entry, key: key, targetDatabase: "Project_Archive",
                            groupPath: groupPath, associationBasis: association,
                            metadata: metadata, sourceSHA256: sha)
    }

    private let pass = ImportPreflightResult(failures: [])

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

            let result = try await stack.executor.execute(intent, preflight: pass)

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
        await stack.transport.setFault(.createAfterApply)

        // The process dies while the create is in flight: the executor never sees
        // the error, so the ledger row stays at intent_persisted.
        let record = ImportOperationRecord(runID: stack.runID, key: intent.key,
                                           targetDatabase: "Project_Archive", targetGroupPath: groupPath,
                                           intendedMetadataDigest: "d", intendedMetadataJSON: "{}",
                                           sourceSHA256: sha, createdAt: now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)
        await stack.transport.setFault(.none)
        await stack.transport.seed(.init(uuid: "uuid-crashed", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: association))

        let sweep = try ImportRecovery.open(stack.ledger, at: now)
        #expect(sweep.interrupted == 1)

        let result = try await stack.executor.resume(intent)

        #expect(result.outcome == .skipVerified)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    @Test("two concurrent executions of one key create at most one record")
    func concurrentSameKey() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let pass = self.pass

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    _ = try? await stack.executor.execute(intent, preflight: pass)
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
        await stack.transport.setLookupDelay(200_000_000)

        let pass = self.pass
        let task = Task { try await stack.executor.execute(intent, preflight: pass) }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        _ = try? await task.value

        let stored = try stack.ledger.operation(keyDigest: intent.key.digest)
        #expect(stored?.phase == .cancelled)
        #expect(try stack.ledger.leaseOwner(at: now) == nil)
        #expect(await stack.transport.createCalls == 0)
    }
}
