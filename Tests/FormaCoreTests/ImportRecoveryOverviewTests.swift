import Foundation
import Testing
@testable import FormaCore

private let databaseID = "AAAAAAAA-0000-4000-8000-000000000001"
private let otherDatabaseID = "BBBBBBBB-0000-4000-8000-000000000002"
private let groupPath = ["Forma_I1B2", "r1"]
private let sha = String(repeating: "c", count: 64)

@Suite("Import recovery overview")
struct ImportRecoveryOverviewTests {
    @Test("every phase maps to the recovery state a person is told about")
    func phaseMapping() {
        let expected: [ImportPhase: ImportRecoveryEntry.State] = [
            .planned: .notStarted,
            .preflighted: .notStarted,
            .deferred: .notStarted,
            .intentPersisted: .intentRecorded,
            .recordObserved: .recordCreated,
            .metadataObserved: .metadataAnswered,
            .verifyRequired: .outcomeUnknown,
            .readbackVerified: .settled,
            .skippedVerified: .settled,
            .conflictHold: .settled,
            .failed: .settled,
            .cancelled: .settled,
        ]
        for phase in ImportPhase.allCases {
            #expect(ImportRecoveryPresenter.state(for: phase) == expected[phase],
                    "\(phase.rawValue)")
        }
        #expect(expected.count == ImportPhase.allCases.count)
    }

    @Test("the overview reports what the previous process had actually done")
    func overviewKeepsTheLastKnownPhase() throws {
        let runID = UUID()
        let interruptedFromIntent = try record(runID: runID, phase: .intentPersisted, revision: 1)
        let interruptedFromMetadata = try record(runID: runID, phase: .metadataObserved, revision: 2)
        let alreadyUnknown = try record(runID: runID, phase: .verifyRequired, revision: 3)
        #expect(Set([interruptedFromIntent.keyDigest, interruptedFromMetadata.keyDigest,
                     alreadyUnknown.keyDigest]).count == 3)

        // What the ledger held before the sweep.
        let before = [interruptedFromIntent, interruptedFromMetadata, alreadyUnknown]
        // What the sweep leaves behind: all three are verify_required now.
        let after = before.map { swept($0) }

        let overview = ImportRecoveryPresenter.overview(before: before, after: after)
        #expect(overview.count == 3)
        #expect(overview.counts[.intentRecorded] == 1)
        #expect(overview.counts[.metadataAnswered] == 1)
        #expect(overview.counts[.outcomeUnknown] == 1)
        #expect(overview.requiresReview)

        let entry = try #require(overview.entries.first {
            $0.keyDigest == interruptedFromMetadata.keyDigest
        })
        #expect(entry.state == .metadataAnswered)
        #expect(entry.phase == .verifyRequired)
        #expect(entry.lastKnownPhase == .metadataObserved)
        #expect(entry.intendedSHA256 == sha)
    }

    @Test("an empty overview is idle, not a failure")
    func emptyOverview() {
        #expect(ImportRecoveryOverview.empty.isEmpty)
        #expect(ImportRecoveryOverview.empty.requiresReview == false)
    }

    // MARK: - Read-only recheck

    @Test("a recheck for another database reads nothing")
    func recheckOutsideScopeDoesNotRead() async {
        let transport = FakeImportTransport()
        let entry = self.entry(database: otherDatabaseID)
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .outsideScope)
        #expect(result.reason == "scope_mismatch")
        #expect(result.readAttempted == false)
        #expect(await transport.readCalls == 0)
    }

    @Test("a recheck for another group reads nothing")
    func recheckOutsideGroupDoesNotRead() async {
        let transport = FakeImportTransport()
        let entry = self.entry(group: ["Forma_I1B2", "other"])
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .outsideScope)
        #expect(await transport.readCalls == 0)
    }

    @Test("an operation without a record UUID stays unknown, with no read")
    func recheckWithoutUUIDDoesNotRead() async {
        let transport = FakeImportTransport()
        let entry = self.entry(uuid: nil)
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .unverifiable)
        #expect(result.reason == "no_record_uuid")
        #expect(await transport.readCalls == 0)
    }

    @Test("a matching record is verified from the independent read")
    func recheckMatches() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: groupPath,
                                   metadata: ["projectname": "FORMA-SYNTHETIC"], sha256: sha,
                                   associationBasis: nil))
        let entry = self.entry(uuid: "uuid-1")
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .verified)
        #expect(result.reason == "readback_matches")
        #expect(await transport.readCalls == 1)
    }

    @Test("a record whose bytes cannot be proven is unverifiable, never verified")
    func recheckUnverifiedBytes() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: groupPath,
                                   metadata: [:], sha256: sha, associationBasis: nil,
                                   shaVerified: false))
        let entry = self.entry(uuid: "uuid-1")
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .unverifiable)
        #expect(result.reason == "hash_unverified")
    }

    @Test("a record that moved is a hold, not a rewrite")
    func recheckLocationChanged() async {
        let transport = FakeImportTransport()
        await transport.seed(.init(uuid: "uuid-1", database: databaseID, parentPath: ["moved"],
                                   metadata: [:], sha256: sha, associationBasis: nil))
        let entry = self.entry(uuid: "uuid-1")
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .differs)
        #expect(result.reason == "target_location_changed")
    }

    @Test("a read failure is reported as unverifiable with its code")
    func recheckReadFailure() async {
        let transport = FakeImportTransport()
        await transport.setFault(.readback)
        let entry = self.entry(uuid: "uuid-1")
        let result = await ImportRecoveryReviewer(read: transport)
            .review(entry, scope: ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath))

        #expect(result.outcome == .unverifiable)
        #expect(result.reason == FormaError.disconnected.code)
        #expect(result.readAttempted)
    }

    // MARK: - Helpers

    private func entry(database: String = databaseID, group: [String] = groupPath,
                       uuid: String? = "uuid-1", sha256: String? = sha) -> ImportRecoveryEntry {
        ImportRecoveryEntry(keyDigest: "k1", state: .outcomeUnknown, phase: .verifyRequired,
                            lastKnownPhase: .verifyRequired, targetDatabase: database,
                            groupPath: group, actualUUID: uuid, intendedSHA256: sha256,
                            errorCode: "timeout")
    }

    private func record(runID: UUID, phase: ImportPhase, revision: Int) throws -> ImportOperationRecord {
        ImportOperationRecord(
            runID: runID,
            key: try ImportOperationKey(
                sourceID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
                snapshotFingerprint: String(repeating: "a", count: 64),
                manifestRevision: revision,
                targetAssociationID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
                operationKind: .createRecord),
            phase: phase, targetDatabase: databaseID, targetGroupPath: groupPath,
            intendedMetadataDigest: "d", intendedMetadataJSON: "{}",
            actualUUID: "uuid-1", sourceSHA256: sha,
            authorizationDigest: "auth", createdAt: Date(timeIntervalSince1970: 0))
    }

    private func swept(_ record: ImportOperationRecord) -> ImportOperationRecord {
        var copy = record
        copy.phase = .verifyRequired
        return copy
    }
}
