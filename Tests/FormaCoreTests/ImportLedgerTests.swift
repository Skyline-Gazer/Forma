import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The ledger is the only record that an external effect may exist.
///
/// These tests are about the invariants that make recovery possible: one intent
/// per key, append-only attempts and observations, transitions the contract
/// allows and nothing else, a UUID written once, and a restart that cannot
/// silently resume as if the last attempt had failed cleanly.
@Suite("Import ledger")
struct ImportLedgerTests {
    private let sourceID = UUID()
    private let associationID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger() throws -> (ImportLedger, DatabaseQueue) {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        return (ImportLedger(database: database), database)
    }

    private func run(_ id: UUID = UUID()) -> ImportRunRecord {
        ImportRunRecord(id: id, scopeID: UUID(), manifestID: UUID(), manifestRevision: 4,
                        profileID: "project-archive", profileVersion: "1.0.0", schemaVersion: "1.0",
                        authorizationDigest: String(repeating: "f", count: 64), startedAt: now)
    }

    private func key(revision: Int = 4, source: UUID? = nil) throws -> ImportOperationKey {
        try ImportOperationKey(sourceID: source ?? sourceID,
                               snapshotFingerprint: String(repeating: "a", count: 64),
                               manifestRevision: revision, targetAssociationID: associationID)
    }

    private func operation(_ run: ImportRunRecord, key: ImportOperationKey? = nil) throws -> ImportOperationRecord {
        ImportOperationRecord(runID: run.id, key: try (key ?? self.key()),
                              targetDatabase: "Project_Archive", targetGroupPath: ["01_招标文件", "2026"],
                              intendedMetadataDigest: String(repeating: "b", count: 64),
                              intendedMetadataJSON: "{}", createdAt: now)
    }

    // MARK: - Intents

    @Test("one key has exactly one intent")
    func oneIntentPerKey() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)

        let first = try ledger.recordIntent(try operation(run))
        #expect(first.inserted)
        let second = try ledger.recordIntent(try operation(run))
        #expect(!second.inserted)
        #expect(second.record.id == first.record.id)
        #expect(try ledger.operations(runID: run.id).count == 1)
    }

    @Test("a new revision is a different intent")
    func revisionIsANewIntent() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        try ledger.recordIntent(try operation(run, key: try key(revision: 4)))
        try ledger.recordIntent(try operation(run, key: try key(revision: 5)))
        #expect(try ledger.operations(runID: run.id).count == 2)
    }

    @Test("the stored key round-trips")
    func keyRoundTrip() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        try ledger.recordIntent(try operation(run, key: key))
        let stored = try #require(try ledger.operation(keyDigest: key.digest))
        #expect(stored.key == key)
        #expect(stored.phase == .planned)
        #expect(stored.targetGroupPath == ["01_招标文件", "2026"])
        #expect(stored.outcomeForPhase == nil)
    }

    // MARK: - Transitions

    @Test("the contract's happy path is recorded, with the outcome at the end")
    func happyPath() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        try ledger.recordIntent(try operation(run, key: key))

        for phase in [ImportPhase.preflighted, .intentPersisted, .recordObserved,
                      .metadataObserved, .readbackVerified] {
            try ledger.transition(keyDigest: key.digest, to: phase, at: now)
        }
        let stored = try #require(try ledger.operation(keyDigest: key.digest))
        #expect(stored.phase == .readbackVerified)
        #expect(stored.phase.isTerminal)
    }

    @Test("a transition the contract forbids is refused")
    func illegalTransition() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        try ledger.recordIntent(try operation(run, key: key))

        #expect(throws: FormaError.self) {
            try ledger.transition(keyDigest: key.digest, to: .readbackVerified, at: now)
        }
        #expect(throws: FormaError.self) {
            try ledger.transition(keyDigest: key.digest, to: .recordObserved, at: now)
        }
        #expect(try ledger.operation(keyDigest: key.digest)?.phase == .planned)
    }

    @Test("a terminal row cannot be moved again")
    func terminalIsFinal() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        try ledger.recordIntent(try operation(run, key: key))
        try ledger.transition(keyDigest: key.digest, to: .preflighted, at: now)
        try ledger.transition(keyDigest: key.digest, to: .intentPersisted, at: now)
        try ledger.transition(keyDigest: key.digest, to: .conflictHold, at: now, errorCode: "field_conflict")

        #expect(throws: FormaError.self) {
            try ledger.transition(keyDigest: key.digest, to: .recordObserved, at: now)
        }
        #expect(try ledger.operation(keyDigest: key.digest)?.phase == .conflictHold)
    }

    @Test("any in-flight phase may become verify_required, and only in-flight ones")
    func verifyRequiredReachability() throws {
        #expect(ImportPhase.planned.canTransition(to: .verifyRequired) == false)
        #expect(ImportPhase.preflighted.canTransition(to: .verifyRequired) == false)
        #expect(ImportPhase.intentPersisted.canTransition(to: .verifyRequired))
        #expect(ImportPhase.recordObserved.canTransition(to: .verifyRequired))
        #expect(ImportPhase.metadataObserved.canTransition(to: .verifyRequired))
        #expect(ImportPhase.readbackVerified.canTransition(to: .verifyRequired) == false)
    }

    @Test("terminals are final, planned is not skippable, and only preflight opens an intent")
    func transitionShape() {
        for terminal in ImportPhase.allCases where terminal.isTerminal {
            for next in ImportPhase.allCases {
                #expect(!terminal.canTransition(to: next), "\(terminal.rawValue) -> \(next.rawValue)")
            }
        }
        for next in ImportPhase.allCases where next != .planned {
            let expected = next == .preflighted || next == .deferred || next == .failed || next == .cancelled
            #expect(ImportPhase.planned.canTransition(to: next) == expected,
                    "planned -> \(next.rawValue)")
        }
        for from in ImportPhase.allCases where from.canTransition(to: .intentPersisted) {
            #expect(from == .preflighted, "\(from.rawValue) -> intent_persisted")
        }
        for from in ImportPhase.allCases where from != .planned && from != .deferred {
            #expect(!from.canTransition(to: .planned), "\(from.rawValue) -> planned")
        }
    }

    @Test("there is no transition back to import from verify_required")
    func noBlindRetry() {
        #expect(ImportPhase.verifyRequired.canTransition(to: .recordObserved))
        #expect(ImportPhase.verifyRequired.canTransition(to: .readbackVerified))
        #expect(ImportPhase.verifyRequired.canTransition(to: .conflictHold))
        #expect(ImportPhase.verifyRequired.canTransition(to: .planned) == false)
        #expect(ImportPhase.verifyRequired.canTransition(to: .intentPersisted) == false)
    }

    // MARK: - UUID and evidence

    @Test("the target UUID is written once")
    func uuidWrittenOnce() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        try ledger.recordIntent(try operation(run, key: key))

        try ledger.observeActualUUID("uuid-1", keyDigest: key.digest, at: now)
        #expect(try ledger.operation(keyDigest: key.digest)?.actualUUID == "uuid-1")
        #expect(throws: FormaError.self) {
            try ledger.observeActualUUID("uuid-2", keyDigest: key.digest, at: now)
        }
        #expect(try ledger.operation(keyDigest: key.digest)?.actualUUID == "uuid-1")
    }

    @Test("attempts and observations are append-only")
    func appendOnly() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)
        let key = try key()
        let operation = try operation(run, key: key)
        try ledger.recordIntent(operation)

        try ledger.appendAttempt(ImportAttemptRecord(operationID: operation.id, attempt: 1,
                                                     phaseBefore: .intentPersisted, phaseAfter: .recordObserved,
                                                     requestDigest: "r1", responseDigest: "s1", errorCode: nil,
                                                     startedAt: now, finishedAt: now))
        try ledger.appendAttempt(ImportAttemptRecord(operationID: operation.id, attempt: 2,
                                                     phaseBefore: .recordObserved, phaseAfter: nil,
                                                     requestDigest: "r2", responseDigest: nil,
                                                     errorCode: "timeout", startedAt: now, finishedAt: nil))
        #expect(try ledger.attempts(operationID: operation.id).map(\.attempt) == [1, 2])

        // A duplicate attempt number is a programming error, not a retry.
        #expect(throws: DatabaseError.self) {
            try ledger.appendAttempt(ImportAttemptRecord(operationID: operation.id, attempt: 1,
                                                         phaseBefore: .intentPersisted, phaseAfter: nil,
                                                         requestDigest: "r3", responseDigest: nil,
                                                         errorCode: nil, startedAt: now, finishedAt: nil))
        }

        try ledger.appendObservation(ImportObservationRecord(operationID: operation.id, observedAt: now,
                                                             kind: .lookup, actualUUID: nil, parentPath: [],
                                                             metadataDigest: nil, targetSHA256: nil,
                                                             matches: false, detailDigest: "d1"))
        #expect(try ledger.observations(operationID: operation.id).count == 1)
    }

    // MARK: - Recovery

    @Test("a restart marks in-flight operations verify_required and leaves terminals alone")
    func restartSweep() throws {
        let (ledger, _) = try makeLedger()
        let run = run()
        try ledger.startRun(run)

        let flying = try key(revision: 1)
        let finished = try key(revision: 2)
        let planned = try key(revision: 3)
        try ledger.recordIntent(try operation(run, key: flying))
        try ledger.recordIntent(try operation(run, key: finished))
        try ledger.recordIntent(try operation(run, key: planned))

        try ledger.transition(keyDigest: flying.digest, to: .preflighted, at: now)
        try ledger.transition(keyDigest: flying.digest, to: .intentPersisted, at: now)

        try ledger.transition(keyDigest: finished.digest, to: .preflighted, at: now)
        try ledger.transition(keyDigest: finished.digest, to: .intentPersisted, at: now)
        try ledger.transition(keyDigest: finished.digest, to: .recordObserved, at: now)
        try ledger.transition(keyDigest: finished.digest, to: .metadataObserved, at: now)
        try ledger.transition(keyDigest: finished.digest, to: .readbackVerified, at: now)

        #expect(try ledger.inFlightOperations().map(\.keyDigest) == [flying.digest])

        let outcome = try ImportRecovery.open(ledger, at: now)
        #expect(outcome.interrupted == 1)
        #expect(outcome.inFlight.map(\.keyDigest) == [flying.digest])
        #expect(try ledger.operation(keyDigest: flying.digest)?.phase == .verifyRequired)
        #expect(try ledger.operation(keyDigest: finished.digest)?.phase == .readbackVerified)
        #expect(try ledger.operation(keyDigest: planned.digest)?.phase == .planned)
    }

    // MARK: - Lease

    @Test("only one live owner holds the lease")
    func leaseExclusivity() throws {
        let (ledger, _) = try makeLedger()
        #expect(try ledger.acquireLease(owner: "a", at: now, duration: 60))
        #expect(try ledger.acquireLease(owner: "b", at: now, duration: 60) == false)
        #expect(try ledger.acquireLease(owner: "a", at: now, duration: 60))
        #expect(try ledger.leaseOwner(at: now) == "a")
    }

    @Test("an expired lease can be taken over")
    func leaseExpiry() throws {
        let (ledger, _) = try makeLedger()
        #expect(try ledger.acquireLease(owner: "a", at: now, duration: 60))
        let later = now.addingTimeInterval(61)
        #expect(try ledger.leaseOwner(at: later) == nil)
        #expect(try ledger.acquireLease(owner: "b", at: later, duration: 60))
        #expect(try ledger.leaseOwner(at: later) == "b")
    }

    @Test("releasing someone else's lease does nothing")
    func releaseOnlyOwn() throws {
        let (ledger, _) = try makeLedger()
        #expect(try ledger.acquireLease(owner: "a", at: now, duration: 60))
        try ledger.releaseLease(owner: "b")
        #expect(try ledger.leaseOwner(at: now) == "a")
        try ledger.releaseLease(owner: "a")
        #expect(try ledger.leaseOwner(at: now) == nil)
    }
}

private extension ImportOperationRecord {
    /// The outcome the phase carries, for assertions that read a stored row.
    var outcomeForPhase: ImportOutcome? { phase.outcome }
}
