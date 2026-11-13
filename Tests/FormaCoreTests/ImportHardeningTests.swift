import Foundation
import GRDB
import Testing

@testable import FormaCore

/// Counterexamples for the I1-A execution boundary.
///
/// Every case here is a way the executor could write something it should not:
/// start an import it was never cleared for, overwrite a record somebody else
/// changed, pick a candidate because it was first, or call a record verified
/// when the target never proved the bytes.
///
/// The suite is written against the behaviour, not the implementation, so it
/// survives the API changes the fixes introduce.
@Suite("Import execution boundary")
struct ImportHardeningTests {
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

    private func intent(_ stack: Stack, snapshot: String? = nil,
                        associationBasis: String? = nil) throws -> ImportIntent {
        let entry = ManifestEntry(
            sourceID: UUID(), snapshotFingerprint: snapshot ?? fingerprint, snapshotRevision: 1,
            sourceVersion: 1, relativePath: "synthetic/tender.pdf", state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive", groupPath: groupPath, resolved: true),
            eligibleForAutoExecution: true)
        let key = try ImportOperationKey(sourceID: entry.sourceID,
                                         snapshotFingerprint: entry.snapshotFingerprint,
                                         manifestRevision: 1,
                                         targetAssociationID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
        return ImportIntent(runID: stack.runID, entry: entry, key: key, targetDatabase: "Project_Archive",
                            groupPath: groupPath, associationBasis: associationBasis ?? association,
                            metadata: metadata, sourceSHA256: sha)
    }

    /// Persists an intent row the way an interrupted run would have left it.
    private func persistIntent(_ stack: Stack, _ intent: ImportIntent, phase: ImportPhase,
                               uuid: String? = nil) throws {
        let record = ImportOperationRecord(
            runID: stack.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath, intendedMetadataDigest: "d",
            intendedMetadataJSON: "{}", sourceSHA256: intent.sourceSHA256, createdAt: now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: now)
        if let uuid {
            try stack.ledger.observeActualUUID(uuid, keyDigest: intent.key.digest, at: now)
            try stack.ledger.transition(keyDigest: intent.key.digest, to: .recordObserved, at: now)
        } else {
            try stack.ledger.transition(keyDigest: intent.key.digest, to: phase, at: now)
        }
    }

    private let pass = ImportPreflightResult(failures: [])

    // MARK: - Resume must not start an import

    @Test("resume without a ledger row writes nothing")
    func resumeWithoutIntent() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        let result = try await stack.executor.resume(intent)

        // There is no intent to continue, so there is nothing to continue: the
        // result says so instead of starting a fresh import.
        #expect(result.outcome == .verifyRequired)
        #expect(result.attempts == 0)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest) == nil)
    }

    @Test("resume with a snapshot that no longer matches writes nothing")
    func resumeWithChangedSnapshot() async throws {
        let stack = try await makeStack()
        let original = try intent(stack)
        try persistIntent(stack, original, phase: .verifyRequired)
        // The caller comes back with a different snapshot: the decision it would
        // resume belongs to bytes that are no longer there.
        let changed = try intent(stack, snapshot: String(repeating: "b", count: 64))

        let result = try await stack.executor.resume(changed)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
    }

    // MARK: - Read before write

    @Test("a record somebody else changed is not overwritten")
    func externalChangeIsNotOverwritten() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-external", database: "Project_Archive",
                                         parentPath: groupPath,
                                         metadata: ["completion_year": "2019"], sha256: sha,
                                         associationBasis: association))
        try persistIntent(stack, intent, phase: .intentPersisted, uuid: "uuid-external")

        let result = try await stack.executor.resume(intent)

        // The record carries our association but a different value: that is a
        // person's edit, not our pending write.
        #expect(result.outcome == .conflictHold)
        #expect(await stack.transport.metadataCalls == 0)
        let records = await stack.transport.storedRecords()
        #expect(records.first?.metadata["completion_year"] == "2019")
    }

    // MARK: - Candidate recovery

    @Test("two candidates after an unknown create: neither is chosen")
    func twoCandidatesAreNotPicked() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-a", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: association))
        await stack.transport.seed(.init(uuid: "uuid-b", database: "Project_Archive",
                                         parentPath: groupPath, metadata: metadata, sha256: sha,
                                         associationBasis: association))
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(result.actualUUID == nil)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.actualUUID == nil)
    }

    @Test("a candidate whose business identity is not confirmed is not adopted")
    func unconfirmedCandidateIsNotAdopted() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        // Same group and our association, but the fields do not agree: the
        // record is not provably the one this operation would have written.
        await stack.transport.seed(.init(uuid: "uuid-other", database: "Project_Archive",
                                         parentPath: groupPath,
                                         metadata: ["completion_year": "1999"], sha256: sha,
                                         associationBasis: association))
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.actualUUID == nil)
    }

    @Test("one confirmed candidate after an unknown create is recovered")
    func uniqueConfirmedCandidateIsRecovered() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent, preflight: pass)

        // The record was created and the answer was lost. The read-only lookup
        // finds exactly one record that carries our association and our fields.
        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    // MARK: - Preflight is not a free-form permission

    @Test("a preflight pass that is not bound to this intent writes nothing")
    func unboundPreflightWritesNothing() async throws {
        let stack = try await makeStack()
        // A conclusion about a different source, snapshot and target.
        let other = try intent(stack, snapshot: String(repeating: "b", count: 64),
                               associationBasis: "another association")

        let result = try await stack.executor.execute(other, preflight: pass)

        #expect(result.outcome == nil)
        #expect(result.attempts == 0)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: other.key.digest) == nil)
    }

    // MARK: - Verification honesty

    @Test("a target that cannot prove its bytes is not readback verified")
    func unverifiableBytesAreNotVerified() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setReadbackSHAVerified(false)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.phase != .readbackVerified)
        #expect(result.outcome == .verifyRequired)
    }

    // MARK: - No blind retry

    @Test("a disconnect during the metadata write does not create a second record")
    func disconnectDoesNotRetry() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.metadata)

        let result = try await stack.executor.execute(intent, preflight: pass)

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
    }
}
