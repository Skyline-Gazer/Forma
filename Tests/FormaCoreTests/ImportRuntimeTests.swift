import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The runtime entry that decides whether an import may run at all.
///
/// These tests are about the gate, not the import itself: the executor's own
/// behaviour is covered by `ImportExecutorTests`. What must hold here is that no
/// write path exists without an explicit authorization object that names a
/// disposable, non-production target, and that one authorization funds one run.
@Suite("Import runtime entry")
struct ImportRuntimeTests {
    private static let now = ImportFixtures.now
    private static let sandboxName = "FORMATEST-SANDBOX"
    private static let sandboxID = "AAAAAAAA-0000-4000-8000-000000000001"
    private static let sourceRoot = "/tmp/forma-runtime"
    private static let sourcePath = "/tmp/forma-runtime/synthetic/tender.pdf"

    private struct Rig: Sendable {
        let ledger: ImportLedger
        let transport: FakeImportTransport
        let runtime: ImportRuntime
        let intent: ImportIntent
        let clearance: ImportPreflightClearance
        let preflightAuthorization: ImportAuthorization
        let runID: UUID
    }

    /// The same session shape as the production runtime: the ledger is the
    /// budget journal, keyed by the authorization digest.
    private static func session(transport: FakeImportTransport, ledger: ImportLedger,
                                clock: @escaping @Sendable () -> Date) -> @Sendable (ImportRuntimeAuthorization) -> ImportWriteSession {
        { authorization in
            let guardAuthorization = ImportWriteAuthorization(
                scope: authorization.scope, journal: ledger,
                identity: authorization.digest, clock: clock)
            let surface = GuardedImportWriteTransport(
                base: transport, authorization: guardAuthorization,
                sourcePath: { binding in
                    "\(sourceRoot)/\(binding.relativePath)"
                })
            return ImportWriteSession(surface: surface, authorization: guardAuthorization,
                                      close: {})
        }
    }

    private func runtime(ledger: ImportLedger, transport: FakeImportTransport,
                         owner: String) -> ImportRuntime {
        let fixed = Self.now
        let writer = ImportSingleWriter(ledger: ledger, owner: owner, clock: { fixed })
        return ImportRuntime(ledger: ledger, writer: writer, read: transport,
                             clock: { fixed },
                             makeSession: Self.session(transport: transport, ledger: ledger,
                                                       clock: { fixed }))
    }

    private func makeRig() async throws -> Rig {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        let ledger = ImportLedger(database: database)
        let runID = UUID()
        try ledger.startRun(ImportRunRecord(
            id: runID, scopeID: UUID(), manifestID: UUID(), manifestRevision: 1,
            profileID: "project-archive", profileVersion: "1.0.0", schemaVersion: "1.0",
            authorizationDigest: String(repeating: "f", count: 64), startedAt: Self.now))

        let transport = FakeImportTransport()
        let runtime = self.runtime(ledger: ledger, transport: transport, owner: "test")

        // The import contract addresses a database by UUID; the human name is
        // only used for the reserved-production check.
        let preflight = ImportFixtures.authorization(groupPrefix: ImportFixtures.groupPath,
                                                     database: Self.sandboxID)
        let intent = try ImportFixtures.intent(runID: runID, database: Self.sandboxID,
                                               authorization: preflight)
        let clearance = try ImportFixtures.clearance(for: intent, authorization: preflight)
        return Rig(ledger: ledger, transport: transport, runtime: runtime, intent: intent,
                   clearance: clearance, preflightAuthorization: preflight, runID: runID)
    }

    private func authorization(
        _ mode: ImportRuntimeAuthorization.Mode = .write,
        name: String = ImportRuntimeTests.sandboxName,
        disposable: Bool = true,
        expiresAt: Date? = nil,
        scopeDatabase: String = ImportRuntimeTests.sandboxID,
        scopePath: [String] = ImportFixtures.groupPath
    ) -> ImportRuntimeAuthorization {
        ImportRuntimeAuthorization(
            mode: mode,
            target: ImportIsolatedTarget(
                databaseID: Self.sandboxID, databaseName: name,
                groupPath: ImportFixtures.groupPath, declaredDisposable: disposable),
            scope: ImportWriteScope(
                databaseID: scopeDatabase, groupPrefix: scopePath,
                tools: [.importFile], metadataIdentifiers: ["completion_year"],
                sourcePaths: [Self.sourcePath], recordLimit: 1, groupLimit: 1),
            authorizedBy: "synthetic-owner", issuedAt: Self.now, expiresAt: expiresAt)
    }

    private func request(_ rig: Rig) -> ImportRuntimeRequest {
        ImportRuntimeRequest(intent: rig.intent, clearance: rig.clearance)
    }

    // MARK: - Planning

    @Test("planning without an authorization reports what would happen and writes nothing")
    func planWithoutAuthorization() async throws {
        let rig = try await makeRig()
        let plan = try await rig.runtime.plan([request(rig)])

        #expect(plan.mode == .planOnly)
        #expect(plan.refusals.isEmpty)
        #expect(plan.entries.map(\.action) == [.wouldExecute])
        #expect(plan.willWrite == false)
        #expect(await rig.transport.createCalls == 0)
        #expect(await rig.transport.lookupCalls == 0)
    }

    @Test("a plan reports which keys are already recorded")
    func planReportsRecordedKeys() async throws {
        let rig = try await makeRig()
        _ = try await rig.runtime.execute([request(rig)], authorization: authorization())

        let plan = try await rig.runtime.plan([request(rig)], authorization: authorization())
        #expect(plan.entries.map(\.action) == [.alreadyRecorded])
        #expect(plan.entries.first?.recordedPhase == .readbackVerified)
    }

    @Test("a blocked clearance is planned as blocked with its codes")
    func planReportsBlockedClearance() async throws {
        let rig = try await makeRig()
        let clearance = try blockedClearance(rig.intent)
        let plan = try await rig.runtime.plan(
            [ImportRuntimeRequest(intent: rig.intent, clearance: clearance)])

        #expect(plan.entries.map(\.action) == [.blocked])
        #expect(plan.entries.first?.blockingCodes.contains(.targetMissing) == true)
        #expect(plan.willWrite == false)
    }

    // MARK: - Refusals

    @Test("a planning-only authorization cannot execute")
    func planOnlyAuthorizationRefusesToWrite() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute([request(rig)], authorization: authorization(.planOnly))

        #expect(outcome.refusals.map(\.code) == [.writeModeNotAuthorized])
        #expect(outcome.results.isEmpty)
        #expect(await rig.transport.createCalls == 0)
    }

    @Test("the reserved production database is never a target")
    func productionTargetRefused() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute(
            [request(rig)], authorization: authorization(name: "Project_Archive"))

        #expect(outcome.refusals.map(\.code).contains(.productionTarget))
        #expect(await rig.transport.createCalls == 0)
    }

    @Test("a target nobody declared disposable is refused")
    func undisposableTargetRefused() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute(
            [request(rig)], authorization: authorization(disposable: false))

        #expect(outcome.refusals.map(\.code).contains(.targetNotDisposable))
        #expect(await rig.transport.createCalls == 0)
    }

    @Test("a write scope for another target is refused")
    func mismatchedScopeRefused() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute(
            [request(rig)],
            authorization: authorization(scopeDatabase: "BBBBBBBB-0000-4000-8000-000000000009"))

        #expect(outcome.refusals.map(\.code).contains(.scopeDoesNotMatchTarget))
        #expect(await rig.transport.createCalls == 0)
    }

    @Test("an expired authorization is refused")
    func expiredAuthorizationRefused() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute(
            [request(rig)],
            authorization: authorization(expiresAt: Self.now.addingTimeInterval(-60)))

        #expect(outcome.refusals.map(\.code).contains(.authorizationExpired))
        #expect(await rig.transport.createCalls == 0)
    }

    // MARK: - Execution

    @Test("one authorization funds exactly one run")
    func oneAuthorizationFundsOneRun() async throws {
        let rig = try await makeRig()
        let granted = authorization()

        let first = try await rig.runtime.execute([request(rig)], authorization: granted)
        #expect(first.refusals.isEmpty)
        #expect(first.results.map(\.phase) == [.readbackVerified])
        #expect(first.wroteAnything)
        #expect(await rig.transport.createCalls == 1)

        let second = try await rig.runtime.execute([request(rig)], authorization: granted)
        #expect(second.refusals.map(\.code) == [.authorizationAlreadyUsed])
        #expect(second.results.isEmpty)
        // The exhausted budget cannot be spent a second time.
        #expect(await rig.transport.createCalls == 1)
    }

    @Test("an empty run is refused rather than silently succeeding")
    func emptyRunRefused() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute([], authorization: authorization())

        #expect(outcome.refusals.map(\.code) == [.noRequests])
        #expect(outcome.results.isEmpty)
    }

    @Test("a write run goes through the guarded surface, not around it")
    func writeRunUsesTheGuard() async throws {
        let rig = try await makeRig()
        let outcome = try await rig.runtime.execute([request(rig)], authorization: authorization())

        #expect(outcome.results.map(\.outcome) == [.importRecord])
        // One create, one recorded attempt row: the executor's own counter also
        // counts the readback step, so the ledger is the honest place to look.
        let stored = try #require(try rig.ledger.operation(keyDigest: rig.intent.key.digest))
        #expect(try rig.ledger.attempts(operationID: stored.id).count == 1)
        // The guarded surface demanded exactly one grant, and the fake saw one create.
        #expect(await rig.transport.createCalls == 1)
        #expect(await rig.transport.lookupCalls >= 1)
    }

    // MARK: - Helpers

    /// A clearance for the same facts but with a target the preflight rejects.
    private func blockedClearance(_ intent: ImportIntent) throws -> ImportPreflightClearance {
        let profile = try MappingProfile.projectArchive()
        let manifest = try ImportFixtures.manifest(revision: intent.key.manifestRevision)
        return ImportPreflight.evaluate(ImportPreflightInput(
            entry: ImportFixtures.entry(sourceID: intent.key.sourceID,
                                        snapshot: intent.key.snapshotFingerprint,
                                        groupPath: intent.groupPath,
                                        database: intent.targetDatabase),
            manifest: manifest,
            expectations: ImportExpectations(profileID: profile.profileID,
                                             profileVersion: profile.profileVersion,
                                             schemaVersion: manifest.schemaVersion),
            authorization: ImportFixtures.authorization(groupPrefix: ImportFixtures.groupPath,
                                                        database: intent.targetDatabase),
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: intent.key.snapshotFingerprint,
                                      sha256: ImportFixtures.sha),
            target: ImportTargetFacts(exists: false, writable: false),
            capability: ImportCapabilityFacts(writeToolsAvailable: true, readbackAvailable: true),
            expectedSHA256: intent.source.contentSHA256, now: Self.now))
    }

    // MARK: - Scope and plan agree

    @Test("the plan exposes the budget and refuses more writes than the scope allows")
    func planRefusesOversizedRun() async throws {
        let rig = try await makeRig()
        let other = try ImportFixtures.intent(runID: rig.runID, sourceID: UUID(),
                                              database: Self.sandboxID,
                                              authorization: rig.preflightAuthorization)
        let otherClearance = try ImportFixtures.clearance(for: other,
                                                          authorization: rig.preflightAuthorization)
        let granted = authorization() // recordLimit == 1
        let plan = try await rig.runtime.plan(
            [request(rig), ImportRuntimeRequest(intent: other, clearance: otherClearance)],
            authorization: granted)

        #expect(plan.limits == granted.scope.limits)
        #expect(plan.authorizationDigest == granted.digest)
        #expect(plan.refusals.map(\.code).contains(.planExceedsBudget))
        #expect(plan.willWrite == false)
    }

    @Test("the plan refuses a metadata identifier the scope never granted")
    func planRefusesMetadataOutsideScope() async throws {
        let rig = try await makeRig()
        let intent = try ImportFixtures.intent(runID: rig.runID, database: Self.sandboxID,
                                               authorization: rig.preflightAuthorization,
                                               metadata: ["not_authorized": "x"])
        let clearance = try ImportFixtures.clearance(for: intent,
                                                     authorization: rig.preflightAuthorization)
        let plan = try await rig.runtime.plan(
            [ImportRuntimeRequest(intent: intent, clearance: clearance)],
            authorization: authorization())

        #expect(plan.refusals.map(\.code).contains(.planOutsideScope))
        #expect(plan.willWrite == false)
    }

    @Test("a new runtime over the same ledger does not refresh the budget")
    func newRuntimeDoesNotRefreshBudget() async throws {
        let rig = try await makeRig()
        let granted = authorization()
        let first = try await rig.runtime.execute([request(rig)], authorization: granted)
        #expect(first.results.map(\.phase) == [.readbackVerified])

        let second = try ImportFixtures.intent(runID: rig.runID, sourceID: UUID(),
                                               database: Self.sandboxID,
                                               associationBasis: "budget-probe-\(UUID().uuidString)",
                                               authorization: rig.preflightAuthorization)
        let secondClearance = try ImportFixtures.clearance(for: second,
                                                           authorization: rig.preflightAuthorization)
        // A different runtime and writer, as after a process restart; the ledger
        // still holds the spend for this authorization digest.
        let restarted = runtime(ledger: rig.ledger, transport: rig.transport, owner: "test-2")
        let outcome = try await restarted.execute(
            [ImportRuntimeRequest(intent: second, clearance: secondClearance)],
            authorization: granted)

        #expect(outcome.results.map(\.reason) == [.writeRefused])
        #expect(await rig.transport.createCalls == 1)
    }
}
