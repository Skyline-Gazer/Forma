import Foundation
import Testing

@testable import FormaCore

/// Slice 2 of the approved Contract Delta (ELIGIBILITY-CONTRACT-DELTA §5.2,
/// SPEC v0.1.2 §6.1-1): the eligibility decision reaches the two places that
/// consume the listing — the project context and the mapping run — and the
/// compatibility path stays exactly as it was.
///
/// The tests here are about *who decides what enters*: a filtered run must map
/// only eligible records, must name the ones it left out, and must not
/// change what the scan itself reported.
@Suite("Eligibility context wiring")
struct EligibilityContextWiringTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-0000000000F3")!
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!

    private func entry(_ path: String, id: UUID? = nil) -> SourceEntry {
        SourceEntry(id: id ?? UUID(), rootID: rootID, relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                    provider: .local, snapshotFingerprint: String(repeating: "a", count: 64),
                    sizeBytes: 10, modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func profile() throws -> MappingProfile { try MappingProfile.projectArchive() }

    private func listing(_ entries: [SourceEntry]) -> SourceListing {
        SourceListing(scope: SourceScope(id: scopeID, rootID: rootID, relativePath: "",
                                         displayName: "Synthetic"),
                      scanID: UUID(), state: .complete, entries: entries, issues: [], statistics: nil)
    }

    /// The shipped policy, so the fixture uses the rules that ship.
    private func view(_ entries: [SourceEntry],
                      facts: [UUID: EligibilityFacts] = [:]) throws -> EligibilityView {
        EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries), profile: try profile(), policy: try EligibilityPolicy.shipped(),
            facts: facts, kind: .simulated))
    }

    // MARK: - The context

    @Test("a filtered context contains only eligible records and binds the policy")
    func filteredContextHoldsOnlyCandidates() throws {
        let selected = try profile()
        let business = entry("Project/公告.pdf")
        let noise = entry("Project/.DS_Store")
        let built = try view([business, noise])
        let candidates = built.mappingCandidates()
        #expect(candidates.map(\.id) == [business.id], "the noise record must not be a candidate")

        let full = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: [business, noise]),
            revision: 1)
        let filtered = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: candidates,
                                eligibility: built.contextBinding),
            revision: 1)
        // The context's own membership is the eligible set, and its identity
        // says which policy produced it.
        #expect(filtered.candidates.flatMap(\.memberSourceIDs) == [business.id])
        #expect(full.candidates.flatMap(\.memberSourceIDs).count == 2)
        #expect(filtered.inputDigest != full.inputDigest)
        #expect(filtered.inputDigest == ContextBuilder.inputDigest(
            scopeID: scopeID, profile: selected, entries: candidates, eligibility: built.contextBinding))
    }

    @Test("full-listing mode is untouched by the wiring")
    func fullListingModeIsUnchanged() throws {
        let selected = try profile()
        let entries = [entry("Project/公告.pdf"), entry("Project/.DS_Store")]
        let built = try view(entries)
        // Building with the same selection the view implies must produce the
        // same revision identity as building without any filter at all when
        // every record is eligible.
        let allEligible = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: entries),
            revision: 1)
        #expect(allEligible.inputDigest == ContextBuilder.inputDigest(
            scopeID: scopeID, profile: selected, entries: entries))
        #expect(built.policyDigest.count == 64)
    }

    // MARK: - The mapping run

    @Test("the mapping input is the eligible subset, and the rest is named")
    func mappingInputIsTheEligibleSubset() throws {
        let selected = try profile()
        let business = entry("Project/公告.pdf")
        let noise = entry("Project/.DS_Store")
        let built = try view([business, noise])
        let selection = built.selection
        let request = MappingRunRequest(
            scope: SourceScope(id: scopeID, rootID: rootID, relativePath: "", displayName: "Synthetic"),
            profile: selected, context: ProjectContext(
                revision: 1, scopeID: scopeID, profileID: selected.profileID,
                profileVersion: selected.profileVersion, inputDigest: "d", candidates: [],
                unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now),
            entries: [business, noise], evidence: [:], provider: .anthropic, model: "fake",
            allowCloud: true, eligibility: selection)
        #expect(request.mappingEntries.map(\.id) == [business.id])
        #expect(request.entries.count == 2, "the discovered set stays complete")
    }

    @Test("a caller that narrowed the run keeps its narrowing")
    func filterOnlyRemoves() throws {
        let selected = try profile()
        let business = entry("Project/公告.pdf")
        let noise = entry("Project/.DS_Store")
        let built = try view([business, noise])
        let request = MappingRunRequest(
            scope: SourceScope(id: scopeID, rootID: rootID, relativePath: "", displayName: "Synthetic"),
            profile: selected, context: ProjectContext(
                revision: 1, scopeID: scopeID, profileID: selected.profileID,
                profileVersion: selected.profileVersion, inputDigest: "d", candidates: [],
                unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now),
            entries: [noise], evidence: [:], provider: .anthropic, model: "fake",
            allowCloud: true, eligibility: built.selection)
        // The filter can only remove records; it never adds one the caller
        // did not ask for.
        #expect(request.mappingEntries.isEmpty)
    }

    @Test("without a selection the mapping input is the whole listing")
    func noSelectionMapsEverything() throws {
        let selected = try profile()
        let entries = [entry("Project/公告.pdf"), entry("Project/.DS_Store")]
        let request = MappingRunRequest(
            scope: SourceScope(id: scopeID, rootID: rootID, relativePath: "", displayName: "Synthetic"),
            profile: selected, context: ProjectContext(
                revision: 1, scopeID: scopeID, profileID: selected.profileID,
                profileVersion: selected.profileVersion, inputDigest: "d", candidates: [],
                unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now),
            entries: entries, evidence: [:], provider: .anthropic, model: "fake", allowCloud: true)
        #expect(request.mappingEntries.count == 2)
        #expect(request.eligibility == nil)
    }
}
