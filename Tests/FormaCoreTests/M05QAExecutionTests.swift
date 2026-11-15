import Foundation
import Testing

@testable import FormaCore

/// M05 execution readiness, proven offline.
///
/// These tests are the reproducible QA flow: plan-only by default, refused
/// without an approval, three fixed files and keys, deterministic faults, a
/// restart over the same ledger, read-only recovery, and a report that carries
/// the budget, digest, counters and refusals.
///
/// They use no DEVONthink process and no real file. A "restart" is a new harness
/// stack over the same SQLite database; a "crash" is a ledger row seeded at the
/// state a crashed process would leave. Whether a real `kill -9` produces the
/// same row is NOT_VERIFIED and stays an M05 real-run question.
@Suite("M05 QA execution")
struct M05QAExecutionTests {
    @Test("planning is the default and no approval means no call")
    func planIsDefaultAndApprovalIsRequired() async throws {
        let stack = try M05QA.stack()
        let plan = try await stack.runtime.plan(M05QA.requests(stack))

        #expect(plan.mode == .planOnly)
        #expect(plan.entries.map(\.action) == [.wouldExecute, .wouldExecute, .wouldExecute])
        #expect(plan.refusals.isEmpty)
        #expect(plan.willWrite == false)
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.createGroupCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)

        // Without an explicit approval the harness refuses before building a
        // scope, so no transport can be reached.
        do {
            _ = try M05QA.requireApproval(nil)
            Issue.record("execute accepted a missing approval")
        } catch let error as M05QA.Refusal {
            #expect(error == .noApproval)
        }
        do {
            _ = try M05QA.authorization(M05QA.Approval(runID: "", approvedBy: "owner",
                                                       issuedAt: M05QA.now))
            Issue.record("authorization accepted an empty run id")
        } catch let error as M05QA.Refusal {
            #expect(error == .malformedApproval)
        }
    }

    @Test("three fixed files have recomputable digests and independent keys")
    func syntheticFilesAndKeysAreFixed() throws {
        let stack = try M05QA.stack()
        #expect(M05QA.files.count == 3)
        #expect(Set(M05QA.files.map(\.sha256)).count == 3)
        #expect(Set(M05QA.files.map(\.sourceID)).count == 3)
        #expect(Set(stack.intents.map(\.key.digest)).count == 3)
        for (file, intent) in zip(M05QA.files, stack.intents) {
            #expect(intent.source.contentSHA256 == file.sha256)
            #expect(intent.source.byteCount == Int64(file.bytes.count))
            #expect(intent.targetDatabase == M05QA.databaseID)
            #expect(intent.groupPath == M05QA.groupPath(.canonical))
        }
        // Byte-literal fixtures: the digest is a function of this source file.
        #expect(M05QA.files[0].sha256.count == 64)
    }

    @Test("the fault matrix keeps one create per key and the expected phases")
    func faultMatrixIsDeterministic() async throws {
        let stack = try M05QA.stack()
        try await M05QA.createGroups(stack)
        await stack.transport.setCreateFault(.createAfterApply, forSource: M05QA.files[0].sourceID)
        await stack.transport.setCreateFault(.createBeforeApply, forSource: M05QA.files[1].sourceID)
        await stack.transport.setCreateWithoutMetadata(forSource: M05QA.files[2].sourceID)
        await stack.transport.setMetadataFault(.metadata, forSource: M05QA.files[2].sourceID)

        let outcome = try await stack.runtime.execute(M05QA.requests(stack),
                                                      authorization: stack.authorization)

        #expect(outcome.refusals.isEmpty)
        // file 1: applied then response lost → adopted read-only, verified.
        // file 2: sent then disconnected before apply → proven absent, failed.
        // file 3: created, metadata failed → verify_required.
        let phases = try stack.ledger.operations(runID: stack.runID).map(\.phase)
        #expect(phases.filter { $0 == .readbackVerified }.count == 1)
        #expect(phases.filter { $0 == .failed }.count == 1)
        #expect(phases.filter { $0 == .verifyRequired }.count == 1)

        // One create per key, no retry after an unknown result.
        #expect(await stack.transport.createCalls == 3)
        #expect(await stack.transport.storedRecords().count == 2)
        #expect(await stack.transport.metadataCalls == 1)
        #expect(await stack.transport.createGroupCalls == 2)
    }

    @Test("a restart keeps the unknown outcome and recovery only reads")
    func restartSweepAndReadOnlyRecovery() async throws {
        let stack = try M05QA.stack()
        try await M05QA.createGroups(stack)
        await stack.transport.setCreateWithoutMetadata(forSource: M05QA.files[2].sourceID)
        await stack.transport.setMetadataFault(.metadata, forSource: M05QA.files[2].sourceID)

        let request = M05QA.requests(stack)[2]
        _ = try await stack.runtime.execute([request], authorization: stack.authorization)
        #expect(try stack.ledger.operation(keyDigest: request.intent.key.digest)?.phase
                == .verifyRequired)
        let writesBefore = await stack.transport.createCalls
        let metadataBefore = await stack.transport.metadataCalls

        // A new process: same database, new handle, no in-memory state.
        let reopened = ImportLedger(database: stack.database)
        let before = try reopened.operations(runID: stack.runID)
        let sweep = try ImportRecovery.open(reopened, at: M05QA.now)
        let after = try reopened.operations(runID: stack.runID)
        let overview = ImportRecoveryPresenter.overview(before: before, after: after)
        #expect(sweep.inFlight.count == 1)
        #expect(overview.count == 1)
        #expect(overview.requiresReview)

        let confirmation = ImportRecoveryScopeConfirmation(
            databaseID: M05QA.databaseID, databaseName: M05QA.databaseName,
            groupPath: M05QA.groupPath(.canonical), confirmedAt: M05QA.now,
            confirmedBy: "synthetic-operator")!
        let review = await ImportRecoveryCoordinator(read: stack.transport).review(
            overview.entries, scope: confirmation, at: M05QA.now)

        #expect(review.results.map(\.outcome) == [.verified])
        // The recovery path holds no write surface: nothing new was sent.
        #expect(await stack.transport.createCalls == writesBefore)
        #expect(await stack.transport.metadataCalls == metadataBefore)
        #expect(await stack.transport.readCalls == 1)
    }

    @Test("crash residue is swept and reviewed without a write")
    func simulatedCrashResidueIsRecoveredReadOnly() async throws {
        let stack = try M05QA.stack()
        let uuid = "uuid-crash-1"
        _ = try await M05QA.seedCrashResidue(stack, file: M05QA.files[0], uuid: uuid)

        let before = try stack.ledger.operations(runID: stack.runID)
        let sweep = try ImportRecovery.open(stack.ledger, at: M05QA.now)
        let after = try stack.ledger.operations(runID: stack.runID)
        let overview = ImportRecoveryPresenter.overview(before: before, after: after)

        #expect(sweep.interrupted == 1)
        #expect(overview.entries.first?.state == .recordCreated)

        let confirmation = ImportRecoveryScopeConfirmation(
            databaseID: M05QA.databaseID, databaseName: M05QA.databaseName,
            groupPath: M05QA.groupPath(.canonical), confirmedAt: M05QA.now,
            confirmedBy: "synthetic-operator")!
        let review = await ImportRecoveryCoordinator(read: stack.transport).review(
            overview.entries, scope: confirmation, at: M05QA.now)

        #expect(review.results.map(\.outcome) == [.verified])
        #expect(await stack.transport.createCalls == 0)
        #expect(await stack.transport.metadataCalls == 0)
        #expect(await stack.transport.readCalls == 1)
    }

    @Test("the report carries budget, digest, counters and refusals")
    func reportIsCompleteAndStable() async throws {
        let stack = try M05QA.stack()
        try await M05QA.createGroups(stack)
        await #expect(throws: ImportWriteRefusal.self) {
            _ = try await stack.groupGuard.createGroup(
                database: M05QA.databaseID, path: [M05QA.groupRoot, "run-qa-01", "extra"])
        }
        await stack.transport.setCreateWithoutMetadata(true)
        let outcome = try await stack.runtime.execute(M05QA.requests(stack),
                                                      authorization: stack.authorization)
        #expect(outcome.results.map(\.phase) == Array(repeating: .readbackVerified, count: 3))

        let report = try await M05QA.report(stack, results: outcome.results)
        #expect(report.authorizationDigest == stack.authorization.digest)
        #expect(report.limits == M05QA.limits)
        #expect(report.budget.importsGranted == 3)
        #expect(report.budget.groupsGranted == 2)
        #expect(report.budget.metadataCalls == 3)
        #expect(report.refusals[ImportWriteDenial.groupBudgetExhausted.rawValue] == 1)
        #expect(report.createCalls == 3)
        #expect(report.metadataCalls == 3)
        #expect(report.createGroupCalls == 2)

        // The JSON is deterministic and decodes back to the same report.
        let json = report.json()
        let decoded = try JSONDecoder().decode(M05QA.Report.self, from: Data(json.utf8))
        #expect(decoded == report)
        #expect(json.contains("\"importsGranted\":3"))
        #expect(json.contains(stack.authorization.digest))
    }
}
