import Foundation
import Testing
@testable import FormaCore

private let databaseID = "AAAAAAAA-0000-4000-8000-000000000001"
private let otherDatabaseID = "BBBBBBBB-0000-4000-8000-000000000002"
private let groupPath = ["Forma_I1B2", "r1"]
private let sha = String(repeating: "c", count: 64)
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func confirmation(database: String = databaseID, group: [String] = groupPath,
                          name: String = "Sandbox") -> ImportRecoveryScopeConfirmation {
    ImportRecoveryScopeConfirmation(databaseID: database, databaseName: name,
                                    groupPath: group, confirmedAt: now,
                                    confirmedBy: "operator")!
}

private func entry(database: String = databaseID, group: [String] = groupPath,
                   uuid: String? = "uuid-1") -> ImportRecoveryEntry {
    ImportRecoveryEntry(keyDigest: "k1", state: .outcomeUnknown, phase: .verifyRequired,
                        lastKnownPhase: .verifyRequired, targetDatabase: database,
                        groupPath: group, actualUUID: uuid, intendedSHA256: sha,
                        errorCode: "timeout")
}

@Suite("Import recovery wiring")
struct ImportRecoveryCoordinatorTests {
    @Test func aScopeConfirmationIsOnlyValidWhenItNamesEverything() {
        #expect(ImportRecoveryScopeConfirmation(databaseID: "not-a-uuid", databaseName: "Sandbox",
                                                groupPath: groupPath, confirmedAt: now,
                                                confirmedBy: "operator") == nil)
        #expect(ImportRecoveryScopeConfirmation(databaseID: databaseID, databaseName: " ",
                                                groupPath: groupPath, confirmedAt: now,
                                                confirmedBy: "operator") == nil)
        #expect(ImportRecoveryScopeConfirmation(databaseID: databaseID, databaseName: "Sandbox",
                                                groupPath: [], confirmedAt: now,
                                                confirmedBy: "operator") == nil)
        #expect(ImportRecoveryScopeConfirmation(databaseID: databaseID, databaseName: "Sandbox",
                                                groupPath: groupPath, confirmedAt: now,
                                                confirmedBy: "  ") == nil)

        // The stored form is the canonical uppercase UUID the read adapter uses.
        let lower = databaseID.lowercased()
        let confirmed = ImportRecoveryScopeConfirmation(
            databaseID: lower, databaseName: "Sandbox", groupPath: groupPath,
            confirmedAt: now, confirmedBy: "operator")
        #expect(confirmed?.databaseID == databaseID)
    }

    @Test func entriesOutsideTheConfirmedScopeCostNoRead() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: groupPath,
                                   metadata: [:], sha256: sha, associationBasis: nil))
        let coordinator = ImportRecoveryCoordinator(read: transport)

        let report = await coordinator.review(
            [entry(), entry(database: otherDatabaseID), entry(group: ["elsewhere"])],
            scope: confirmation(), at: now)

        #expect(report.results.map(\.outcome) == [.verified, .outsideScope, .outsideScope])
        #expect(report.results[1].readAttempted == false)
        #expect(report.results[2].readAttempted == false)
        // Exactly one read: the in-scope entry.
        #expect(await transport.readCalls == 1)
    }

    @Test func aReviewOnlyEverReads() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: groupPath,
                                   metadata: [:], sha256: sha, associationBasis: nil))
        let coordinator = ImportRecoveryCoordinator(read: transport)

        _ = await coordinator.review([entry()], scope: confirmation(), at: now)

        // The coordinator holds only a read transport; these counters prove the
        // fake's write side was never touched either.
        #expect(await transport.createCalls == 0)
        #expect(await transport.metadataCalls == 0)
        #expect(await transport.lookupCalls == 0)
        #expect(await transport.readCalls == 1)
    }

    @Test func anUnverifiableEntryKeepsTheReportInconclusive() async {
        let transport = FakeImportTransport()
        let coordinator = ImportRecoveryCoordinator(read: transport)

        let report = await coordinator.review([entry(uuid: nil)], scope: confirmation(), at: now)

        #expect(report.results.map(\.outcome) == [.unverifiable])
        #expect(report.results.first?.reason == "no_record_uuid")
        #expect(report.isConclusive == false)
        #expect(await transport.readCalls == 0)
    }

    @Test func aConclusiveReportCountsItsOutcomes() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: groupPath,
                                   metadata: [:], sha256: sha, associationBasis: nil))
        let coordinator = ImportRecoveryCoordinator(read: transport)

        let report = await coordinator.review([entry()], scope: confirmation(), at: now)

        #expect(report.counts[.verified] == 1)
        #expect(report.isConclusive)
        #expect(report.databaseName == "Sandbox")
        #expect(report.groupPath == groupPath)
    }

    @Test func anEmptyRunIsConclusiveAndSilent() async {
        let transport = FakeImportTransport()
        let coordinator = ImportRecoveryCoordinator(read: transport)
        let report = await coordinator.review([], scope: confirmation(), at: now)

        #expect(report.results.isEmpty)
        #expect(report.isConclusive)
        #expect(await transport.readCalls == 0)
    }
}
