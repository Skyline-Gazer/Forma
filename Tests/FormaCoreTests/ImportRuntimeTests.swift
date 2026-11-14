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
        let fixed = Self.now
        let writer = ImportSingleWriter(ledger: ledger, owner: "test", clock: { fixed })
        let runtime = ImportRuntime(ledger: ledger, writer: writer, read: transport,
                                    clock: { fixed }) { authorization in
            let guardAuthorization = ImportWriteAuthorization(scope: authorization.scope,
                                                              clock: { fixed })
            let surface = GuardedImportWriteTransport(
                base: transport, authorization: guardAuthorization,
                sourcePath: { binding in
                    "\(Self.sourceRoot)/\(binding.relativePath)"
                })
            return ImportWriteSession(surface: surface, authorization: guardAuthorization,
                                      close: {})
        }

        // The import contract addresses a database by UUID; the human name is
        // only used for the reserved-production check.
        let preflight = ImportFixtures.authorization(groupPrefix: ImportFixtures.groupPath,
                                                     database: Self.sandboxID)
        let intent = try ImportFixtures.intent(runID: runID, database: Self.sandboxID,
                                               authorization: preflight)
        let clearance = try ImportFixtures.clearance(for: intent, authorization: preflight)
        return Rig(ledger: ledger, transport: transport, runtime: runtime, intent: intent,
                   clearance: clearance, preflightAuthorization: preflight)
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
        #expect(outcome.results.first?.attempts == 1)
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
}
