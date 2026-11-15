import Foundation
import GRDB
import Testing

@testable import FormaCore

/// The journal's atomicity, tested where the race would happen: several callers
/// sharing one authorization identity.
///
/// `ImportWriteAuthorization.permit` used to read the spend, decide, and then
/// save a whole new snapshot. Two instances sharing an identity could both read
/// the same old value and each save `old + 1`, losing one increment. The journal
/// now checks and increments inside one SQLite transaction, so the tests below
/// assert a property the old shape could not guarantee: the number of successful
/// spends never exceeds the limit, regardless of how many instances race.
@Suite("Import write budget concurrency")
struct ImportBudgetConcurrencyTests {
    private static let database = "AAAAAAAA-0000-4000-8000-0000000000C1"
    private static let prefix = ["Forma_M05", "race-1"]
    private static let sourcePath = "/tmp/forma-m05-race/m05-t1.md"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let identifiers: Set<String> = ["projectname", "issuer"]

    private static func limits(imports: Int = 1, groups: Int = 1,
                               metadata: Int = 1, perRecord: Int = 1) -> ImportWriteBudgetLimits {
        ImportWriteBudgetLimits(imports: imports, groups: groups,
                                metadataCalls: metadata, metadataCallsPerRecord: perRecord)
    }

    private static func scope(imports: Int = 1, groups: Int = 1,
                              metadata: Int = 1, perRecord: Int = 1) -> ImportWriteScope {
        ImportWriteScope(
            databaseID: database, groupPrefix: prefix,
            tools: Set(ImportWriteTool.allCases), metadataIdentifiers: identifiers,
            sourcePaths: [sourcePath], recordLimit: imports, groupLimit: groups,
            metadataCallLimit: metadata, metadataCallsPerRecordLimit: perRecord)
    }

    private static func ledger() throws -> ImportLedger {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        ImportLedgerMigrations.register(into: &migrator)
        try migrator.migrate(queue)
        return ImportLedger(database: queue)
    }

    private static func source() -> ImportSourceBinding {
        ImportSourceBinding(
            sourceID: UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-0000000000C2")!,
            relativePath: "m05-t1.md",
            snapshotFingerprint: String(repeating: "a", count: 64),
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 64, readSessionID: "race-session")
    }

    private static func importRequest(path: String = sourcePath) -> ImportWriteRequest {
        .importFile(path: path, destination: prefix.joined(separator: "/"),
                    database: database, mode: "import")
    }

    /// The raw journal property: eight concurrent spends, one unit of budget.
    @Test func concurrentJournalSpendsGrantExactlyOnce() async throws {
        let ledger = try Self.ledger()
        let limits = Self.limits(imports: 1)
        let grants = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try ledger.spend(.importRecord, limits: limits,
                                             identity: "race", at: Self.now)
                        return true
                    } catch is ImportWriteBudgetRejection {
                        return false
                    }
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(grants == 1)
        let usage = try #require(try ledger.budgetUsage(identity: "race"))
        #expect(usage.importsGranted == 1)
    }

    /// The authorization path two runtimes would take: distinct actors, one
    /// journal row, one unit of budget.
    @Test func concurrentAuthorizationsGrantExactlyOnce() async throws {
        let ledger = try Self.ledger()
        let scope = Self.scope(imports: 1)
        let grants = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let authorization = ImportWriteAuthorization(
                        scope: scope, journal: ledger, identity: "race",
                        clock: { Self.now })
                    do {
                        _ = try await authorization.permit(Self.importRequest())
                        return true
                    } catch is ImportWriteRefusal {
                        return false
                    }
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(grants == 1)
        let usage = try #require(try ledger.budgetUsage(identity: "race"))
        #expect(usage.importsGranted == 1)
    }

    /// A metadata total of one cannot become one call per record.
    @Test func concurrentMetadataSpendsRespectTotalAndPerRecord() async throws {
        let ledger = try Self.ledger()
        let limits = Self.limits(metadata: 2, perRecord: 1)
        let grants = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                let record = index.isMultiple(of: 2) ? "uuid-a" : "uuid-b"
                group.addTask {
                    do {
                        _ = try ledger.spend(.metadata(record: record), limits: limits,
                                             identity: "race", at: Self.now)
                        return 1
                    } catch is ImportWriteBudgetRejection {
                        return 0
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        // Two records × one call each: exactly two, never one record twice and
        // never more than the total.
        #expect(grants == 2)
        let usage = try #require(try ledger.budgetUsage(identity: "race"))
        #expect(usage.metadataCalls == 2)
        #expect(usage.calls(forRecord: "uuid-a") == 1)
        #expect(usage.calls(forRecord: "uuid-b") == 1)
    }
}
