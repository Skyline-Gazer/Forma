import Foundation
import Testing

@testable import FormaCore

/// OneDrive / FileProvider states, exercised through the policy seam on DevBox.
///
/// A Linux box cannot set `SF_DATALESS` on a real file, so these scenarios are
/// simulated at the layer that actually decides: synthetic `SourceEntry` values
/// plus synthetic probe facts, run through the **shipped** policy. That proves
/// how the engine treats each state; it does not prove how a real FileProvider
/// behaves, which stays a Mac-side item (Issue #129,
/// `docs/M11-ONEDRIVE-FILEPROVIDER-ACCEPTANCE.md`).
///
/// Two claims this suite deliberately keeps separate:
///   * a dataless record is still *classified* from metadata, so metadata-only
///     rules behave the same as for a hydrated record;
///   * a rule that needs file content cannot be satisfied by a dataless record,
///     and the engine must not guess its way to an exclusion.
@Suite("OneDrive FileProvider simulation")
struct OneDriveFileProviderSimulationTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-0000000000F2")!

    // MARK: - 1. Dataless records and metadata-only rules

    @Test("a verified cache marker still excludes a dataless record")
    func verifiedCacheMarkerStillExcludesDatalessRecord() throws {
        // The marker itself could be read and verified, the protecting facts were
        // probed and came back negative, and the record underneath is dataless.
        // Today that combination excludes, and the Level 4 census is what
        // evidences it. Changing this is Issue #129 territory, not a drive-by
        // edit: it would move OneDrive exclusions into REVIEW.
        let dataless = entry("Project/cache/artifact.bin", hydrationPending: true)
        let sibling = entry("Project/docs/tender.pdf")
        let result = try view([dataless, sibling], facts: [
            dataless.id: facts(dataless, gitTracked: .no, nested: .no, cache: .verifiedSignature),
            sibling.id: facts(sibling, gitTracked: .no, nested: .no),
        ])

        let decided = try #require(result.entry(for: dataless.id))
        #expect(decided.decision == .exclude)
        #expect(decided.decidedByRuleID == "verified-cache-directory")
        #expect(decided.entry.hydrationPending == true)
        #expect(result.entry(for: sibling.id)?.decision == .include)
        #expect(result.summary.isConserved)
    }

    @Test("an unprobed protecting fact stops the cache exclusion")
    func unknownProtectionFactDowngradesToReview() throws {
        // Same marker, but the scan never established whether the file is
        // tracked: a strong rule with an UNKNOWN protection fact must downgrade
        // to REVIEW rather than exclude on an assumption. This is the branch
        // Issue #129 can widen — it is already the behaviour on any root that is
        // not a repository.
        let dataless = entry("Project/cache/artifact.bin", hydrationPending: true)
        let result = try view([dataless], facts: [
            dataless.id: facts(dataless, cache: .verifiedSignature),
        ])
        let decided = try #require(result.entry(for: dataless.id))
        #expect(decided.decision == .review)
        #expect(decided.decidedByRuleID == "verified-cache-directory")
        #expect(result.summary.exclude == 0)
    }

    @Test("a marker that could not be verified never excludes anything")
    func unverifiedMarkerNeverExcludes() throws {
        // Three ways a marker read can fail on a FileProvider volume, and none of
        // them may turn into an exclusion: the signature could not be read
        // because the marker is dataless, the marker is present but unverifiable,
        // and a probe that never ran at all. `notChecked` must not be read as
        // "no marker", and an unreadable marker must not be read as "no cache".
        for marker in [EligibilityCacheMarker.unreadable, .presentUnverified, .notChecked] {
            let artifact = entry("Project/cache/artifact.bin", hydrationPending: true)
            let result = try view([artifact], facts: [
                artifact.id: facts(artifact, gitTracked: .no, nested: .no, cache: marker),
            ])
            let decided = try #require(result.entry(for: artifact.id))
            #expect(decided.decision != .exclude, "\(marker.rawValue) must not exclude")
            #expect(decided.decision == .include,
                    "an unverifiable marker leaves the record on the default candidate")
        }
    }

    @Test("a dataless record and a hydrated one reach the same decision")
    func metadataOnlyDecisionsMatchAcrossHydrationStates() throws {
        // The claim Level 4 makes is that a placeholder is judged the way the
        // real file would be, from metadata alone. The two records do come out
        // INCLUDE / INCLUDE, and that is the invariant. The *rule* differs
        // (`dataless-metadata-only` wins on the placeholder, `default-mapping-candidate`
        // on the materialized file), which is recorded here rather than
        // papered over: a future rule change that made the decision itself depend
        // on hydration state would break this test, and that is the point.
        let dataless = entry("Project/docs/tender.pdf", hydrationPending: true)
        let hydrated = entry("Project/docs/tender.pdf")
        let result = try view([dataless, hydrated])

        let first = try #require(result.entry(for: dataless.id))
        let second = try #require(result.entry(for: hydrated.id))
        #expect(first.decision == second.decision)
        #expect(first.decision == .include)
        #expect(first.decidedByRuleID == "dataless-metadata-only")
        #expect(second.decidedByRuleID == "default-mapping-candidate")
        #expect(result.summary.isConserved)
    }

    // MARK: - 2. Access failure, offline, cancellation

    @Test("a FileProvider access failure defers instead of excluding")
    func accessFailureDefers() throws {
        let blocked = entry("Project/ops/月度报表.xlsx")
        let issue = SourceScanIssue(relativePath: "Project/ops/月度报表.xlsx",
                                    reason: .authorization,)
        let result = try view([blocked],
                              facts: [blocked.id: facts(blocked, issues: [issue], scanState: .incomplete)],
                              issues: [issue], listingState: .incomplete)

        let decided = try #require(result.entry(for: blocked.id))
        #expect(decided.decision == .defer)
        #expect(decided.decision != .exclude)
        #expect(result.summary.exclude == 0)
        #expect(result.summary.isConserved)
    }

    @Test("an offline tree is reported, not guessed")
    func offlineTreeIsReported() throws {
        // Offline: metadata is listed but content is unavailable, and the scan
        // could not be completed. Every record defers; nothing is dropped.
        let entries = [entry("Project/offline/a.pdf", hydrationPending: true),
                       entry("Project/offline/b.docx", hydrationPending: true)]
        let issues = entries.map {
            SourceScanIssue(relativePath: $0.relativePath, reason: .hydrationPending)
        }
        var probeFacts: [UUID: EligibilityFacts] = [:]
        for item in entries {
            probeFacts[item.id] = facts(item, cache: .notChecked, issues: issues, scanState: .incomplete)
        }
        let result = try view(entries, facts: probeFacts, issues: issues, listingState: .incomplete)

        #expect(result.entries.allSatisfy { $0.decision == .defer })
        #expect(result.summary.exclude == 0)
        #expect(result.summary.deferred == 2)
        #expect(result.summary.isConserved)
    }

    @Test("an interrupted scan cannot exclude protected content")
    func cancelledScanNeverExcludesProtectedContent() throws {
        // A cancelled scan is not a census. Two facts are stated here exactly as
        // the classifier behaves, because the difference is what Issue #129 has
        // to reason about:
        //
        // * protected content never falls to EXCLUDE while a fact says otherwise
        //   (git-tracked beats the verified cache marker);
        // * everything that is not decided by a strong noise rule defers, so an
        //   interrupted run cannot quietly finish the classification.
        let entries = [entry("Project/notes.txt"), entry("Project/report.pdf")]
        var probeFacts: [UUID: EligibilityFacts] = [:]
        for item in entries {
            probeFacts[item.id] = facts(item, gitTracked: .yes, cache: .verifiedSignature,
                                        scanState: .cancelled)
        }
        let result = try view(entries, facts: probeFacts, listingState: .cancelled)

        #expect(result.summary.exclude == 0)
        #expect(result.entries.allSatisfy { $0.decision == .review })
        #expect(result.summary.review == 2)
        #expect(result.scanState == .cancelled)
        #expect(result.summary.isConserved)
    }

    @Test("a strong noise exclusion does not wait for a complete scan")
    func strongNoiseSurvivesAnIncompleteScan() throws {
        // The deliberate asymmetry, recorded as a test: a `.DS_Store` is
        // technical noise even when another directory could not be read. That is
        // safe only because the noise rules match exact basenames and declare no
        // protection facts — a future extension-based rule would inherit this
        // path with an incomplete census, which is one reason Issue #131 rejects
        // candidate D. The run still reports PARTIAL, so the count is not read
        // as a finished census.
        let noise = entry("Project/01-项目/.DS_Store")
        let blocked = entry("Project/01-项目/投标-说明.pdf")
        let issue = SourceScanIssue(relativePath: blocked.relativePath, reason: .unreadable)
        let result = try view([noise, blocked], facts: [
            noise.id: facts(noise, gitTracked: .no, nested: .no),
            blocked.id: facts(blocked, issues: [issue], scanState: .incomplete),
        ], issues: [issue], listingState: .incomplete)

        #expect(result.entry(for: noise.id)?.decision == .exclude)
        #expect(result.entry(for: noise.id)?.decidedByRuleID == "technical-noise-ds-store")
        #expect(result.entry(for: blocked.id)?.decision == .defer)
        #expect(result.scanState == .incomplete)
        #expect(result.summary.exclude == 1)
        #expect(result.summary.isConserved)
    }

    // MARK: - 3. Verdict binding across a hydration transition

    @Test("the verdict binding moves with metadata and never with hydration state")
    func snapshotFingerprintBindsMetadataOnly() {
        // The inputs of the binding are the parameters of
        // `SourceSnapshot.fingerprint` (`SourceStore.swift:291`): ID, revision,
        // size, mtime, kind, stable identity, provider version, and the content
        // hash when one exists. `hydration_pending` is not a parameter at all,
        // and reconciliation deliberately refuses to treat a placeholder turning
        // into an entity as a change (`SourceReconciliation.swift:103`, and the
        // hydration-only update at `:173-176` writes no new revision). A verdict
        // bound to a dataless record therefore keeps its binding after hydration.
        // Issue #20 and Issue #129 are the measurements that have to confirm
        // that is what actually happens on a real volume.
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000F3")!
        func binding(size: Int64?, mtime: Int64?, kind: String?, identity: String?,
                     providerVersion: String?, sha256: String?) -> String {
            SourceSnapshot.fingerprint(id: id, version: 1, size: size, mtime: mtime, kind: kind,
                                       identity: identity, providerVersion: providerVersion,
                                       sha256: sha256)
        }
        let base = binding(size: 1_024, mtime: 1_700_000_000, kind: "regular",
                           identity: "obj-key", providerVersion: "oneDrive", sha256: nil)
        // Deterministic: the same inputs twice, as a rerun would produce.
        #expect(base == binding(size: 1_024, mtime: 1_700_000_000, kind: "regular",
                                identity: "obj-key", providerVersion: "oneDrive", sha256: nil))
        // Every metadata input moves it, so none of them is decorative.
        #expect(binding(size: 2_048, mtime: 1_700_000_000, kind: "regular",
                        identity: "obj-key", providerVersion: "oneDrive", sha256: nil) != base)
        #expect(binding(size: 1_024, mtime: 1_700_000_001, kind: "regular",
                        identity: "obj-key", providerVersion: "oneDrive", sha256: nil) != base)
        #expect(binding(size: 1_024, mtime: 1_700_000_000, kind: "directory",
                        identity: "obj-key", providerVersion: "oneDrive", sha256: nil) != base)
        #expect(binding(size: 1_024, mtime: 1_700_000_000, kind: "regular",
                        identity: "other-key", providerVersion: "oneDrive", sha256: nil) != base)
        #expect(binding(size: 1_024, mtime: 1_700_000_000, kind: "regular",
                        identity: "obj-key", providerVersion: "local", sha256: nil) != base)
        // A content hash binds differently from a metadata-only verdict — which
        // is exactly the distinction a dataless record cannot cross by itself.
        #expect(binding(size: 1_024, mtime: 1_700_000_000, kind: "regular",
                        identity: "obj-key", providerVersion: "oneDrive",
                        sha256: String(repeating: "c", count: 64)) != base)
    }

    // MARK: - Fixture seam

    private func entry(_ path: String, hydrationPending: Bool = false,
                       provider: SourceProvider = .oneDrive) -> SourceEntry {
        SourceEntry(id: UUID(), rootID: rootID, relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: hydrationPending, sourceVersion: 1, snapshotRevision: 1,
                    provider: provider, snapshotFingerprint: String(repeating: "b", count: 64),
                    sizeBytes: 1_024, modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func listing(_ entries: [SourceEntry], state: SourceScanState,
                         issues: [SourceScanIssue]) -> SourceListing {
        SourceListing(scope: SourceScope(id: UUID(), rootID: rootID, relativePath: "",
                                         displayName: "Synthetic"),
                      scanID: UUID(), state: state, entries: entries, issues: issues,
                      statistics: nil)
    }

    private func facts(_ entry: SourceEntry,
                       gitTracked: EligibilityTriState = .unknown,
                       cache: EligibilityCacheMarker = .absent,
                       nested: EligibilityTriState = .unknown,
                       business: EligibilityBusinessEvidence = .unknown,
                       issues: [SourceScanIssue] = [],
                       scanState: SourceScanState = .complete) -> EligibilityFacts {
        EligibilityFacts(entry: entry, scanState: scanState, scanIssues: issues,
                         gitTracked: gitTracked, cacheMarker: cache, nestedRepository: nested,
                         businessEvidence: business, sourceCodeOrDeployment: .unknown,
                         rebuildableArtifact: .unknown, pathCollision: false,
                         snapshotChanged: false)
    }

    private func view(_ entries: [SourceEntry], facts: [UUID: EligibilityFacts] = [:],
                      issues: [SourceScanIssue] = [],
                      listingState: SourceScanState = .complete) throws -> EligibilityView {
        try EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries, state: listingState, issues: issues),
            profile: try MappingProfile.projectArchive(),
            policy: try EligibilityPolicy.shipped(),
            facts: facts, overrides: [], protectedSampleIDs: [],
            kind: .simulated, tokensPerExcludedFile: nil))
    }
}
