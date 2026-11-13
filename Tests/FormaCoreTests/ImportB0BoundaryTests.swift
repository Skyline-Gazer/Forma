import Foundation
import GRDB
import Testing

@testable import FormaCore

/// I1-B0: the last two execution-boundary gaps, expressed as counterexamples.
///
/// Task A — `finish()` may write metadata before it has compared the target's
/// database, parent group, UUID and *verified* SHA value with the intent.
/// Task B — `resume()` treats a missing source SHA as "not a mismatch" and
/// does not check that the source is present, authorized, readable, hydrated
/// and still the same bytes.
///
/// These tests are written against the current behaviour: they fail first,
/// then the implementation is changed. Reason codes are compared as raw
/// strings so a missing code is a failing assertion, not a compile error.
@Suite("I1-B0 execution boundary")
struct ImportB0BoundaryTests {
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
        try ImportFixtures.intent(runID: stack.runID,
                                  metadata: ["completion_year": "2026", "title": "Tender"])
    }

    /// Persists an interrupted operation that already knows its record UUID.
    private func persistKnownUUID(_ stack: Stack, _ intent: ImportIntent, uuid: String) throws {
        let record = ImportOperationRecord(
            runID: stack.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath, intendedMetadataDigest: "d",
            intendedMetadataJSON: "{}", sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: intent.authorizationDigest, createdAt: ImportFixtures.now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: ImportFixtures.now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: ImportFixtures.now)
        try stack.ledger.observeActualUUID(uuid, keyDigest: intent.key.digest, at: ImportFixtures.now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .recordObserved, at: ImportFixtures.now)
    }

    /// Seeds the target record a recovery would find.
    private func seed(_ stack: Stack, uuid: String = "uuid-target",
                      database: String = ImportFixtures.database,
                      groupPath: [String] = ImportFixtures.groupPath,
                      sha: String = ImportFixtures.sha, shaVerified: Bool = true,
                      metadata: [String: String?] = ["completion_year": "2026"],
                      association: String? = ImportFixtures.association) async {
        await stack.transport.seed(.init(uuid: uuid, database: database, parentPath: groupPath,
                                         metadata: metadata, sha256: sha,
                                         associationBasis: association, shaVerified: shaVerified))
    }

    /// The six assertions every counterexample makes.
    private func expectNoWrite(_ stack: Stack, _ intent: ImportIntent, _ result: ImportExecutionResult,
                               outcome: String, reason: String) async throws {
        #expect(result.outcome?.rawValue == outcome, "outcome")
        #expect(result.reason?.rawValue == reason, "reason")
        #expect(await stack.transport.createCalls == 0, "createCalls")
        #expect(await stack.transport.metadataCalls == 0, "metadataCalls")
        let stored = try stack.ledger.operation(keyDigest: intent.key.digest)
        #expect(stored?.phase == result.phase, "ledger phase")
    }

    // MARK: - Task A: target verification before a metadata write

    @Test("A1: a verified SHA that differs from the source blocks the write")
    func targetSHADiffers() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        // Record is ours, has a missing field, but its content digest differs.
        await seed(stack, sha: String(repeating: "d", count: 64),
                   metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "conflict_hold",
                                reason: "target_sha_mismatch")
        let records = await stack.transport.storedRecords()
        #expect((records.first?.metadata["title"] ?? nil) == nil, "simulated record unchanged")
    }

    @Test("A2: an unverifiable target SHA blocks the write")
    func targetSHAUnverified() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, shaVerified: false, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "verify_required",
                                reason: "hash_unverified")
    }

    @Test("A3: a target in another database blocks the write")
    func targetDatabaseChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, database: "Other_Archive",
                   metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "verify_required",
                                reason: "target_location_changed")
    }

    @Test("A4: a target under another parent group blocks the write")
    func targetGroupChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, groupPath: ["09_其他", "2026"],
                   metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "verify_required",
                                reason: "target_location_changed")
    }

    @Test("A5: an externally changed field is preserved")
    func externalFieldPreserved() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2019"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "conflict_hold",
                                reason: "external_modification")
        let records = await stack.transport.storedRecords()
        #expect(records.first?.metadata["completion_year"] == "2019", "external value preserved")
    }

    @Test("A6: a matching target with a missing field is safely completed")
    func matchingTargetAllowsWrite() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 1, "the missing slot is written")
        #expect(await stack.transport.readCalls >= 1, "independent read precedes the write")
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.phase == .readbackVerified)
    }

    @Test("A7: a target read that returns another UUID blocks the write")
    func targetUUIDMismatch() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")
        await stack.transport.setReadUUIDOverride("uuid-somebody-else")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "verify_required",
                                reason: "target_identity_mismatch")
    }

    // MARK: - Task B: source verification before recovery

    private func resumeExpectsNoWrite(_ stack: Stack, _ intent: ImportIntent,
                                      source: ImportSourceFacts, reason: String) async throws {
        await seed(stack, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")
        let result = try await stack.executor.resume(intent, source: source)
        try await expectNoWrite(stack, intent, result, outcome: "verify_required", reason: reason)
        let records = await stack.transport.storedRecords()
        #expect((records.first?.metadata["title"] ?? nil) == nil, "simulated record unchanged")
    }

    @Test("B1: a nil source SHA cannot prove the bytes")
    func sourceSHANil() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(stack, intent, source: ImportFixtures.sourceFacts(sha: nil),
                                       reason: "source_sha_unavailable")
    }

    @Test("B2: a missing source is refused")
    func sourceMissing() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportSourceFacts(state: .missing, authorized: true, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: ImportFixtures.snapshot,
                                      sha256: ImportFixtures.sha),
            reason: "source_missing")
    }

    @Test("B3: a source that lost authorization is refused")
    func sourceUnauthorized() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportSourceFacts(state: .present, authorized: false, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: ImportFixtures.snapshot,
                                      sha256: ImportFixtures.sha),
            reason: "source_unauthorized")
    }

    @Test("B4: an unreadable source is refused")
    func sourceUnreadable() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportSourceFacts(state: .present, authorized: true, readable: false,
                                      hydrationPending: false,
                                      snapshotFingerprint: ImportFixtures.snapshot,
                                      sha256: ImportFixtures.sha),
            reason: "source_unreadable")
    }

    @Test("B5: a source awaiting hydration is refused")
    func sourceHydrationPending() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: true,
                                      snapshotFingerprint: ImportFixtures.snapshot,
                                      sha256: ImportFixtures.sha),
            reason: "hydration_pending")
    }

    @Test("B6: a changed snapshot is refused")
    func sourceSnapshotChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportFixtures.sourceFacts(snapshot: String(repeating: "b", count: 64)),
            reason: "source_changed")
    }

    @Test("B7: a changed source SHA is refused with its own code")
    func sourceSHAChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportFixtures.sourceFacts(sha: String(repeating: "e", count: 64)),
            reason: "source_sha_mismatch")
    }

    @Test("B8: a verified source and verified target recover normally")
    func verifiedRecovery() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        #expect(result.outcome == .importRecord)
        #expect(result.phase == .readbackVerified)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 1)
        #expect(try stack.ledger.operation(keyDigest: intent.key.digest)?.phase == .readbackVerified)
    }

    @Test("B10: a stale read session is refused")
    func staleReadSession() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportFixtures.sourceFacts(readSessionID: "stale-session"),
            reason: "read_session_invalid")
    }

    @Test("B11: a changed byte count is refused")
    func sourceSizeChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        try await resumeExpectsNoWrite(
            stack, intent,
            source: ImportFixtures.sourceFacts(byteCount: 9_999),
            reason: "source_size_changed")
    }

    @Test("B12: an operation stored under another authorization is refused")
    func authorizationChanged() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2026"])
        let record = ImportOperationRecord(
            runID: stack.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath, intendedMetadataDigest: "d",
            intendedMetadataJSON: "{}", sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: String(repeating: "0", count: 64), createdAt: ImportFixtures.now)
        try stack.ledger.recordIntent(record)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .preflighted, at: ImportFixtures.now)
        try stack.ledger.transition(keyDigest: intent.key.digest, to: .intentPersisted, at: ImportFixtures.now)

        let result = try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts())

        try await expectNoWrite(stack, intent, result, outcome: "verify_required",
                                reason: "authorization_changed")
    }

    @Test("B9: a cancellation during recovery starts no write")
    func cancellationDuringRecovery() async throws {
        let stack = try await makeStack()
        let intent = try intent(stack)
        await seed(stack, metadata: ["completion_year": "2026"])
        try persistKnownUUID(stack, intent, uuid: "uuid-target")
        await stack.transport.setReadCancellation(true)

        let task = Task { try await stack.executor.resume(intent, source: ImportFixtures.sourceFacts()) }
        _ = try? await task.value

        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        let records = await stack.transport.storedRecords()
        #expect((records.first?.metadata["title"] ?? nil) == nil, "simulated record unchanged")
    }
}
