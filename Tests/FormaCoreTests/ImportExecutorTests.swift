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
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sha = String(repeating: "c", count: 64)
    private let fingerprint = String(repeating: "a", count: 64)
    private let association = "context revision 3 candidate cr-0001"
    private let groupPath = ["01_招标文件", "2026"]
    private let metadata: [String: String?] = ["completion_year": "2026"]

    private struct Stack {
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

    private func intent(_ stack: Stack, revision: Int = 1) throws -> ImportIntent {
        let entry = ManifestEntry(
            sourceID: UUID(), snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "synthetic/tender.pdf", state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive", groupPath: groupPath, resolved: true),
            eligibleForAutoExecution: true)
        let key = try ImportOperationKey(sourceID: entry.sourceID, snapshotFingerprint: fingerprint,
                                         manifestRevision: revision,
                                         targetAssociationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        return ImportIntent(runID: stack.runID, entry: entry, key: key, targetDatabase: "Project_Archive",
                            groupPath: groupPath, associationBasis: association,
                            metadata: metadata, sourceSHA256: sha)
    }

    private func stored(_ stack: Stack, _ intent: ImportIntent) throws -> ImportOperationRecord? {
        try stack.ledger.operation(keyDigest: intent.key.digest)
    }

    private let pass = ImportPreflightResult(failures: [])

    // MARK: - Happy path

    @Test("one intent, one record, one verified readback")
    func happyPath() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(result.reason == .writeVerified)
        #expect(result.actualUUID != nil)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
        #expect(try stored(stack, intent)?.phase == .readbackVerified)
        #expect(try stored(stack, intent)?.targetSHA256 == sha)
        let record = try #require(try stored(stack, intent))
        #expect(try stack.ledger.attempts(operationID: record.id).count == 2)
    }

    @Test("a second execution of the same key does not create a second record")
    func idempotentReexecution() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        _ = try await stack.executor.execute(intent, preflight: pass)
        let second = try await stack.executor.execute(intent, preflight: pass)

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

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
        #expect(try stored(stack, intent)?.actualUUID == "uuid-1")
    }

    @Test("refused before creating: the conclusive empty lookup does not retry")
    func createRefusedBeforeApply() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.createBeforeApply)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().isEmpty)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    @Test("metadata failure leaves the record in place and the operation unknown")
    func metadataFailure() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.metadata)

        let result = try await stack.executor.execute(intent, preflight: pass)

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

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .conflictHold)
        #expect(result.phase == .conflictHold)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    @Test("a failing readback is unknown, not a success")
    func readbackFailure() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.readback)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    // MARK: - Before any write

    @Test("a lookup timeout writes nothing")
    func lookupTimeout() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.lookup)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
        #expect(try stored(stack, intent)?.phase == .verifyRequired)
    }

    @Test("an inconclusive lookup does not import")
    func inconclusiveLookup() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setLookupInconclusive(true)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
    }

    // MARK: - Existing records

    @Test("a matching record is skipped as verified")
    func existingMatch() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-existing", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: association))

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .skipVerified)
        #expect(result.actualUUID == "uuid-existing")
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("an association-only match with different fields needs a person")
    func existingDifference() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-existing", database: "Project_Archive",
                                         parentPath: groupPath,
                                         metadata: ["completion_year": "2019"], sha256: sha,
                                         associationBasis: association))

        let result = try await stack.executor.execute(intent, preflight: pass)

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
        await stack.transport.seed(.init(uuid: "uuid-same-meta", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata,
                                         sha256: String(repeating: "d", count: 64),
                                         associationBasis: association))

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .conflictHold)
        #expect(result.reason == .confirmedButDiffers)
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("identical bytes without an association anchor do not confirm a record")
    func sameBytesNoAnchor() async throws {
        let stack = try await makeStack()
        var intent = try intent(stack)
        intent = ImportIntent(runID: intent.runID, entry: intent.entry, key: intent.key,
                              targetDatabase: intent.targetDatabase, groupPath: intent.groupPath,
                              associationBasis: nil, metadata: intent.metadata,
                              sourceSHA256: intent.sourceSHA256)
        await stack.transport.seed(.init(uuid: "uuid-other", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: nil))

        let result = try await stack.executor.execute(intent, preflight: pass)

        // The bytes and the fields agree, but nothing ties the record to this
        // source: a hash is not an identity.
        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
    }

    // MARK: - Resume after a restart

    @Test("a restart resolves an existing record by lookup, without creating")
    func resumeAfterRestart() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-crashed", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: association))
        // The process died right after persisting the intent.
        let record = ImportOperationRecord(runID: stack.runID, key: intent.key,
                                           targetDatabase: "Project_Archive", targetGroupPath: groupPath,
                                           intendedMetadataDigest: "d", intendedMetadataJSON: "{}",
                                           sourceSHA256: sha, createdAt: now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)

        let outcome = try ImportRecovery.open(stack.ledger, at: now)
        #expect(outcome.interrupted == 1)

        let result = try await stack.executor.resume(intent)
        #expect(result.outcome == .skipVerified)
        #expect(result.actualUUID == "uuid-crashed")
        #expect(await stack.transport.createCalls == 0)
    }

    @Test("a known UUID is finished rather than re-created")
    func resumeFinishesKnownRecord() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-half", database: "Project_Archive",
                                         parentPath: groupPath, metadata: [:], sha256: sha,
                                         associationBasis: association))
        let record = ImportOperationRecord(runID: stack.runID, key: intent.key,
                                           targetDatabase: "Project_Archive", targetGroupPath: groupPath,
                                           intendedMetadataDigest: "d", intendedMetadataJSON: "{}",
                                           sourceSHA256: sha, createdAt: now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)
        try stack.ledger.observeActualUUID("uuid-half", keyDigest: intent.key.digest, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .recordObserved, at: now)

        let result = try await stack.executor.resume(intent)

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 1)
    }

    @Test("resume never turns a proven absence into a write")
    func resumeDoesNotImport() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let record = ImportOperationRecord(runID: stack.runID, key: intent.key,
                                           targetDatabase: "Project_Archive", targetGroupPath: groupPath,
                                           intendedMetadataDigest: "d", intendedMetadataJSON: "{}",
                                           sourceSHA256: sha, createdAt: now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .verifyRequired, at: now)

        let result = try await stack.executor.resume(intent)

        #expect(result.phase == .failed)
        #expect(await stack.transport.createCalls == 0)
        #expect(try stored(stack, intent)?.errorCode == "absent_after_unknown")
    }

    // MARK: - Preflight gate

    @Test("a blocked preflight creates no intent and writes nothing")
    func blockedPreflight() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let blocked = ImportPreflightResult(failures: [.init(.sourceMissing, detail: "gone")])

        let result = try await stack.executor.execute(intent, preflight: blocked)

        #expect(result.phase == .planned)
        #expect(result.outcome == nil)
        #expect(try stored(stack, intent) == nil)
        #expect(await stack.transport.createCalls == 0)
    }
}
