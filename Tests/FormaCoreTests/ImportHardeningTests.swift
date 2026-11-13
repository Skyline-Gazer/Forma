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

    private func intent(_ stack: Stack, associationBasis: String? = ImportFixtures.association)
        throws -> ImportIntent {
        try ImportFixtures.intent(runID: stack.runID, associationBasis: associationBasis)
    }

    /// Persists an intent row the way an interrupted run would have left it.
    private func persistIntent(_ stack: Stack, _ intent: ImportIntent,
                               uuid: String? = nil) throws {
        let record = ImportOperationRecord(
            runID: stack.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath, intendedMetadataDigest: "d",
            intendedMetadataJSON: "{}", sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: intent.authorizationDigest, createdAt: ImportFixtures.now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: ImportFixtures.now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: ImportFixtures.now)
        if let uuid {
            try stack.ledger.observeActualUUID(uuid, keyDigest: intent.key.digest, at: ImportFixtures.now)
            try stack.ledger.transition(keyDigest: intent.key.digest, to: .recordObserved, at: ImportFixtures.now)
        }
    }

    // MARK: - Resume must not start an import

    @Test("resume without a ledger row writes nothing")
    func resumeWithoutIntent() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        // There is no intent to continue, so there is nothing to continue: the
        // result says so instead of starting a fresh import.
        #expect(result.outcome == .verifyRequired)
        #expect(result.reason == .intentMissing)
        #expect(result.attempts == 0)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest) == nil)
    }

    @Test("resume with a snapshot that no longer matches writes nothing")
    func resumeWithChangedSnapshot() async throws {
        let stack = try await makeStack()
        let original = try intent(stack)
        try persistIntent(stack, original)
        try stack.ledger.transition(keyDigest: original.key.digest, to: .verifyRequired,
                                    at: ImportFixtures.now)

        // The bytes under the operation changed while it was interrupted.
        let result = try await stack.executor.resume(
            original, source: ImportFixtures.sourceFacts(snapshot: String(repeating: "b", count: 64)))

        #expect(result.outcome == .verifyRequired)
        #expect(result.reason == .sourceChanged)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
    }

    // MARK: - Read before write

    @Test("a record somebody else changed is not overwritten")
    func externalChangeIsNotOverwritten() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.seed(.init(uuid: "uuid-external", database: ImportFixtures.database,
                                         parentPath: ImportFixtures.groupPath,
                                         metadata: ["completion_year": "2019"],
                                         sha256: ImportFixtures.sha,
                                         associationBasis: ImportFixtures.association))
        try persistIntent(stack, intent, uuid: "uuid-external")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        // The record carries our association but a different value: that is a
        // person's edit, not our pending write.
        #expect(result.outcome == .conflictHold)
        #expect(result.reason == .externalModification)
        #expect(await stack.transport.metadataCalls == 0)
        let records = await stack.transport.storedRecords()
        #expect(records.first?.metadata["completion_year"] == "2019")
    }

    // MARK: - Candidate recovery

    @Test("two candidates after an unknown create: neither is chosen")
    func twoCandidatesAreNotPicked() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        // The pre-create lookup is empty; the create itself is lost, and the
        // post-create lookup sees two records. This exercises the recovery path
        // rather than the arbitration before the create.
        await stack.transport.setExtraRecordsAfterCreate([
            .init(uuid: "uuid-extra", database: ImportFixtures.database,
                  parentPath: ImportFixtures.groupPath, metadata: ["completion_year": "2026"],
                  sha256: ImportFixtures.sha, associationBasis: ImportFixtures.association),
        ])
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent,
                                                     clearance: try ImportFixtures.clearance(for: intent))

        #expect(await stack.transport.createCalls == 1)
        #expect(result.outcome == .verifyRequired)
        #expect(result.reason == .candidatesAmbiguous)
        #expect(result.actualUUID == nil)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.actualUUID == nil)
    }

    @Test("a candidate whose business identity is not confirmed is not adopted")
    func unconfirmedCandidateIsNotAdopted() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        // The create vanishes after injecting one record that is in scope but
        // whose fields contradict the decision. The post-create lookup finds
        // exactly one candidate, and it must not be adopted.
        await stack.transport.setExtraRecordsAfterCreate([
            .init(uuid: "uuid-other", database: ImportFixtures.database,
                  parentPath: ImportFixtures.groupPath, metadata: ["completion_year": "1999"],
                  sha256: ImportFixtures.sha, associationBasis: ImportFixtures.association),
        ])
        await stack.transport.setFault(.createBeforeApply)

        let result = try await stack.executor.execute(intent,
                                                     clearance: try ImportFixtures.clearance(for: intent))

        #expect(await stack.transport.createCalls == 1)
        #expect(result.outcome == .verifyRequired)
        #expect(result.reason == .identityUnconfirmed)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.actualUUID == nil)
    }

    @Test("one confirmed candidate after an unknown create is recovered")
    func uniqueConfirmedCandidateIsRecovered() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setFault(.createAfterApply)

        let result = try await stack.executor.execute(intent,
                                                     clearance: try ImportFixtures.clearance(for: intent))

        // The record was created and the answer was lost. The read-only lookup
        // finds exactly one record that carries our association and our fields.
        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
    }

    // MARK: - The clearance is a permission for one operation

    @Test("a preflight pass that is not bound to this intent writes nothing")
    func unboundPreflightWritesNothing() async throws {
        let stack = try await makeStack()
        let mine = try intent(stack)
        // A conclusion about a different source and snapshot.
        let other = try ImportFixtures.intent(runID: stack.runID,
                                              snapshot: String(repeating: "b", count: 64))
        let foreign = try ImportFixtures.clearance(for: other)

        let result = try await stack.executor.execute(mine, clearance: foreign)

        #expect(result.reason == .clearanceMismatch)
        #expect(result.attempts == 0)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(try stack.ledger.operation(keyDigest: mine.key.digest) == nil)
    }

    @Test("a clearance decided under another authorization does not apply")
    func clearanceFromAnotherAuthorization() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        let otherAuthorization = ImportFixtures.authorization(groupPrefix: ["09_其他"])
        let foreign = try ImportFixtures.clearance(for: intent, authorization: otherAuthorization)

        let result = try await stack.executor.execute(intent, clearance: foreign)

        #expect(result.reason == .clearanceMismatch)
        #expect(await stack.transport.createCalls == 0)
    }

    // MARK: - Verification honesty

    @Test("a target that cannot prove its bytes is not readback verified")
    func unverifiableBytesAreNotVerified() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        // The record is created without the fields, so a metadata write would be
        // pending: the unverifiable target must stop BEFORE that write.
        await stack.transport.setCreateWithoutMetadata(true)
        await stack.transport.setReadbackSHAVerified(false)

        let result = try await stack.executor.execute(intent,
                                                     clearance: try ImportFixtures.clearance(for: intent))

        #expect(result.phase != .readbackVerified)
        #expect(result.outcome == .verifyRequired)
        #expect(result.reason == .hashUnverified)
        #expect(await stack.transport.metadataCalls == 0)
    }

    // MARK: - No blind retry

    @Test("a disconnect during the metadata write does not create a second record")
    func disconnectDoesNotRetry() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await stack.transport.setCreateWithoutMetadata(true)
        await stack.transport.setFault(.metadata)

        let result = try await stack.executor.execute(intent,
                                                     clearance: try ImportFixtures.clearance(for: intent))

        #expect(result.outcome == .verifyRequired)
        #expect(await stack.transport.createCalls == 1)
        #expect(await stack.transport.storedRecords().count == 1)
    }
}
