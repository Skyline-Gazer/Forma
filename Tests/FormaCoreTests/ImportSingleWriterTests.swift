import Foundation
import GRDB
import Testing

@testable import FormaCore

/// One writer at a time, and no lease left behind by a failed attempt.
///
/// The lease is the only thing standing between two processes sharing a database
/// file and two creates of the same record. These tests exercise exclusivity,
/// reservation, and the release-on-every-exit-path rule that makes cancellation
/// safe.
@Suite("Import single writer")
struct ImportSingleWriterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Captured by value: a `@Sendable` clock may not capture the test struct.
    private var fixedNow: Date { now }

    private func makeLedger() throws -> ImportLedger {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(database)
        return ImportLedger(database: database)
    }

    @Test("the first writer wins and the second is refused")
    func exclusivity() async throws {
        let ledger = try makeLedger()
        let clock = fixedNow
        let first = ImportSingleWriter(ledger: ledger, owner: "a", clock: { clock })
        let second = ImportSingleWriter(ledger: ledger, owner: "b", clock: { clock })

        #expect(try await first.acquire())
        #expect(try await second.acquire() == false)
        #expect(await first.isWriter)
        #expect(await second.isWriter == false)

        try await first.release()
        #expect(try await second.acquire())
        #expect(try ledger.leaseOwner(at: now) == "b")
    }

    @Test("reservations are exclusive and require the lease")
    func reservations() async throws {
        let ledger = try makeLedger()
        let clock = fixedNow
        let writer = ImportSingleWriter(ledger: ledger, owner: "a", clock: { clock })

        #expect(await writer.reserve(["source:1"]) == false)
        #expect(try await writer.acquire())
        #expect(await writer.reserve(["source:1", "record:g1"]))
        #expect(await writer.reserve(["source:1"]) == false)
        #expect(await writer.reservedKeys() == ["record:g1", "source:1"])
        await writer.releaseReservation(["source:1"])
        #expect(await writer.reserve(["source:1"]))
    }

    @Test("the body runs under the lease and both are released afterwards")
    func withWriterReleases() async throws {
        let ledger = try makeLedger()
        let clock = fixedNow
        let writer = ImportSingleWriter(ledger: ledger, owner: "a", clock: { clock })

        let value = try await writer.withWriter(keys: ["source:1"]) { _ in 42 }
        #expect(value == 42)
        #expect(await writer.isWriter == false)
        #expect(await writer.reservedKeys().isEmpty)
        #expect(try ledger.leaseOwner(at: now) == nil)
    }

    @Test("a thrown body still releases the lease")
    func withWriterReleasesOnThrow() async throws {
        let ledger = try makeLedger()
        let clock = fixedNow
        let writer = ImportSingleWriter(ledger: ledger, owner: "a", clock: { clock })

        await #expect(throws: CancellationError.self) {
            try await writer.withWriter(keys: ["source:1"]) { _ in
                throw CancellationError()
            }
        }
        #expect(await writer.isWriter == false)
        #expect(await writer.reservedKeys().isEmpty)
        #expect(try ledger.leaseOwner(at: now) == nil)
    }

    @Test("a second writer cannot run while the lease is held elsewhere")
    func secondWriterRefused() async throws {
        let ledger = try makeLedger()
        let clock = fixedNow
        let first = ImportSingleWriter(ledger: ledger, owner: "a", clock: { clock })
        let second = ImportSingleWriter(ledger: ledger, owner: "b", clock: { clock })
        #expect(try await first.acquire())

        await #expect(throws: FormaError.self) {
            try await second.withWriter(keys: ["source:1"]) { _ in 1 }
        }
        #expect(await second.isWriter == false)
    }
}
