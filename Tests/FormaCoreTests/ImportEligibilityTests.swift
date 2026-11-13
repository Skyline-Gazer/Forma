import Foundation
import Testing
@testable import FormaCore

/// The import-eligibility policy: decisions, precedence, overrides and the
/// false-exclusion property that matters more than any exclusion count.
///
/// Everything here is a synthetic fixture. A pass proves the rule engine is
/// deterministic and that a protected business file is not excluded; it does not
/// claim a real business false-exclusion rate.
@Suite("Import eligibility")
struct ImportEligibilityTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!

    private func entry(_ path: String, state: SourceEntryState = .present, hydrationPending: Bool = false,
                       provider: SourceProvider = .local, size: Int64? = 1_024) -> SourceEntry {
        SourceEntry(id: UUID(), rootID: rootID, relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: state,
                    hydrationPending: hydrationPending, sourceVersion: 1, snapshotRevision: 1,
                    provider: provider, snapshotFingerprint: String(repeating: "a", count: 64),
                    sizeBytes: size, modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func listing(_ entries: [SourceEntry], state: SourceScanState = .complete,
                         issues: [SourceScanIssue] = []) -> SourceListing {
        SourceListing(scope: SourceScope(id: UUID(), rootID: rootID, relativePath: "",
                                         displayName: "Synthetic"),
                      scanID: UUID(), state: state, entries: entries, issues: issues,
                      statistics: nil)
    }

    private func policy(_ rules: [EligibilityRule], profiles: [String] = [],
                        version: String = EligibilityPolicy.currentVersion) -> EligibilityPolicy {
        EligibilityPolicy(policyVersion: version, profiles: profiles, rules: rules)
    }

    private func defaultInclude(priority: Int = 0) -> EligibilityRule {
        EligibilityRule(ruleID: "default", priority: priority, decision: .include,
                        evidenceStrength: .contextual, explanationCode: "default_mapping_candidate",
                        all: [EligibilityPredicate(entryStates: ["present"])])
    }

    private func view(_ entries: [SourceEntry], facts: [UUID: EligibilityFacts] = [:],
                      overrides: [EligibilityOverride] = [], protected: Set<UUID> = [],
                      policy: EligibilityPolicy? = nil, listingState: SourceScanState = .complete,
                      issues: [SourceScanIssue] = [], tokensPerFile: Int? = nil,
                      profile: MappingProfile? = nil) throws -> EligibilityView {
        EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries, state: listingState, issues: issues),
            profile: try profile ?? MappingProfile.projectArchive(),
            policy: try policy ?? EligibilityPolicy.shipped(),
            facts: facts, overrides: overrides, protectedSampleIDs: protected,
            kind: .simulated, tokensPerExcludedFile: tokensPerFile))
    }

    private func facts(_ entry: SourceEntry, gitTracked: EligibilityTriState = .unknown,
                       cache: EligibilityCacheMarker = .absent,
                       nested: EligibilityTriState = .unknown,
                       business: EligibilityBusinessEvidence = .unknown,
                       sourceCode: EligibilityTriState = .unknown,
                       rebuildable: EligibilityTriState = .unknown,
                       collision: Bool = false, snapshotChanged: Bool = false,
                       issues: [SourceScanIssue] = [], scanState: SourceScanState = .complete)
        -> EligibilityFacts {
        EligibilityFacts(entry: entry, scanState: scanState, scanIssues: issues,
                         gitTracked: gitTracked, cacheMarker: cache, nestedRepository: nested,
                         businessEvidence: business, sourceCodeOrDeployment: sourceCode,
                         rebuildableArtifact: rebuildable, pathCollision: collision,
                         snapshotChanged: snapshotChanged)
    }

    // MARK: - Deterministic technical noise

    @Test("deterministic technical noise is excluded, with its rule named")
    func technicalNoiseIsExcluded() throws {
        let dsStore = entry("Project/.DS_Store")
        let appleDouble = entry("Project/._report.pdf")
        let lock = entry("Project/~$报价单.xlsx")
        let result = try view([dsStore, appleDouble, lock])

        #expect(result.entries.allSatisfy { $0.decision == .exclude })
        #expect(result.entry(for: dsStore.id)?.decidedByRuleID == "technical-noise-ds-store")
        #expect(result.entry(for: appleDouble.id)?.decidedByRuleID == "technical-noise-appledouble")
        #expect(result.entry(for: lock.id)?.decidedByRuleID == "technical-noise-office-lock")
        #expect(result.entries.allSatisfy { $0.matchedRuleIDs.contains($0.decidedByRuleID ?? "") })
        #expect(result.summary.isConserved)
        #expect(result.summary.exclude == 3)
        #expect(result.summary.mappingCandidates == 0)
    }

    @Test("a verified cache marker excludes; an invalid or unreadable one does not")
    func cacheMarkerSemantics() throws {
        let verified = entry("Project/cache/blob.bin")
        let unverified = entry("Project/cache/other.bin")
        let unreadable = entry("Project/cache/third.bin")
        let result = try view([verified, unverified, unreadable], facts: [
            verified.id: facts(verified, cache: .verifiedSignature),
            unverified.id: facts(unverified, cache: .presentUnverified),
            unreadable.id: facts(unreadable, cache: .unreadable),
        ])
        #expect(result.entry(for: verified.id)?.decision == .exclude)
        #expect(result.entry(for: verified.id)?.decidedByRuleID == "verified-cache-directory")
        // "not verified" and "could not be read" are not "absent", and neither is
        // evidence for a cache: both fall through to the default candidate.
        #expect(result.entry(for: unverified.id)?.decision == .include)
        #expect(result.entry(for: unreadable.id)?.decision == .include)
        #expect(result.entry(for: unreadable.id)?.explanationCode == "default_mapping_candidate")
    }

    // MARK: - Protected business material

    @Test("a business document inside build, dist or vendor is never excluded")
    func businessMaterialInWeakDirectoriesIsProtected() throws {
        let cases = [
            ("Project/build/客户交付-验收报告.pdf", "generated_directory"),
            ("Project/dist/已提交发布包-v2.zip", "generated_directory"),
            ("Project/vendor/原厂技术白皮书.pdf", "vendor_directory"),
            ("Project/bin/招标附件.docx", "generated_directory"),
            ("Project/coverage/报价单.xlsx", "generated_directory"),
        ]
        let entries = cases.map { entry($0.0) }
        let result = try view(entries, protected: Set(entries.map(\.id)))
        for (index, item) in entries.enumerated() {
            let view = try #require(result.entry(for: item.id))
            #expect(view.decision == .review,
                    "a weak directory name may only send \(cases[index].0) to REVIEW")
            #expect(view.decidedByRuleID == cases[index].1)
            #expect(view.followUp != nil, "a person has to confirm the deliverable")
        }
        #expect(result.metrics.falseExclusionRate.numerator == 0)
        #expect(result.metrics.falseExclusionRate.denominator == cases.count)
        #expect(result.metrics.falseExclusionRate.value == 0)
    }

    @Test("confirmed business evidence overrides a strong exclusion")
    func businessEvidenceBeatsExclusion() throws {
        let noise = entry("Project/.DS_Store")
        let result = try view([noise], facts: [noise.id: facts(noise, business: .confirmed)])
        let view = try #require(result.entry(for: noise.id))
        #expect(view.decision == .review)
        #expect(view.explanationCode == "business_evidence_overrides_exclusion")
        #expect(view.followUp == .confirmBusinessUse)
        #expect(view.matchedRuleIDs.contains("technical-noise-ds-store"),
                "the exclusion is still visible as a matched rule")
    }

    @Test("tracked content, a nested repository and source files survive a cache marker")
    func structuralProtectionsBeatExclusion() throws {
        let tracked = entry("Project/cache/a.bin")
        let nested = entry("Project/cache/b.bin")
        let source = entry("Project/cache/c.bin")
        let result = try view([tracked, nested, source], facts: [
            tracked.id: facts(tracked, gitTracked: .yes, cache: .verifiedSignature),
            nested.id: facts(nested, cache: .verifiedSignature, nested: .yes),
            source.id: facts(source, cache: .verifiedSignature, sourceCode: .yes),
        ])
        #expect(result.entry(for: tracked.id)?.decision == .review)
        #expect(result.entry(for: tracked.id)?.explanationCode == "git_tracked_protected")
        #expect(result.entry(for: nested.id)?.explanationCode == "nested_repository_protected")
        #expect(result.entry(for: source.id)?.explanationCode == "source_code_protected")
    }

    @Test("git tracked and nested repository content is REVIEW, not excluded")
    func trackedAndNestedAreReview() throws {
        let tracked = entry("Project/scripts/deploy.sh")
        let nested = entry("Project/vendor/lib/README.md")
        let result = try view([tracked, nested], facts: [
            tracked.id: facts(tracked, gitTracked: .yes),
            nested.id: facts(nested, nested: .yes),
        ])
        #expect(result.entry(for: tracked.id)?.decision == .review)
        #expect(result.entry(for: tracked.id)?.decidedByRuleID == "git-tracked-review")
        #expect(result.entry(for: nested.id)?.decision == .review)
        #expect(result.entry(for: nested.id)?.decidedByRuleID == "nested-repository-review")
    }

    @Test("multiple business versions are all candidates and all retained")
    func multipleVersionsAreRetained() throws {
        let entries = [entry("Project/公告-v1.pdf"), entry("Project/公告-v2.docx"),
                       entry("Project/报价-v3.xlsx")]
        let result = try view(entries)
        #expect(result.entries.count == 3, "the view never drops a discovered record")
        #expect(result.entries.allSatisfy { $0.decision == .include })
        #expect(Set(result.entries.map(\.sourceID)) == Set(entries.map(\.id)))
        #expect(result.mappingCandidates().count == 3)
        // Stable order, independent of input order.
        let reversed = try view(Array(entries.reversed()))
        #expect(reversed.entries.map(\.sourceID) == result.entries.map(\.sourceID))
    }

    @Test("an unhydrated OneDrive file stays a candidate and says content was not read")
    func datalessFileIsMetadataOnly() throws {
        let dataless = entry("Project/OneDrive/公告.pdf", hydrationPending: true, provider: .oneDrive)
        let result = try view([dataless])
        let view = try #require(result.entry(for: dataless.id))
        #expect(view.decision == .include)
        #expect(view.explanationCode == "dataless_metadata_only")
        #expect(view.notes.contains("content_not_hydrated"),
                "the decision must not pretend the body was read")
        #expect(result.entries.count == 1)
    }

    @Test("a rule that needs content defers on a dataless file")
    func contentRuleDefersOnDataless() throws {
        let rule = EligibilityRule(ruleID: "content-required", priority: 10, decision: .review,
                                   evidenceStrength: .contextual, explanationCode: "needs_content",
                                   followUp: .confirmBusinessUse,
                                   all: [EligibilityPredicate(extensions: ["pdf"])],
                                   requiresContentEvidence: true)
        let dataless = entry("Project/公告.pdf", hydrationPending: true, provider: .oneDrive)
        let result = try view([dataless], policy: policy([rule, defaultInclude()]))
        let view = try #require(result.entry(for: dataless.id))
        #expect(view.decision == .defer)
        #expect(view.explanationCode == "content_not_read")
        #expect(view.followUp == .hydrateBeforeMapping)
    }

    // MARK: - DEFER

    @Test("missing, moved, colliding or unreadable sources defer with a reason")
    func structuralDeferCases() throws {
        let missing = entry("Project/gone.pdf", state: .missing)
        let moved = entry("Project/moved.pdf")
        let colliding = entry("Project/collision.pdf")
        let unreadable = entry("Project/denied.pdf")
        let result = try view([missing, moved, colliding, unreadable], facts: [
            moved.id: facts(moved, snapshotChanged: true),
            colliding.id: facts(colliding, collision: true),
            unreadable.id: facts(unreadable,
                                 issues: [.init(relativePath: "Project/denied.pdf", reason: .authorization)]),
        ])
        #expect(result.entry(for: missing.id)?.explanationCode == "source_missing")
        #expect(result.entry(for: moved.id)?.explanationCode == "snapshot_changed")
        #expect(result.entry(for: colliding.id)?.explanationCode == "path_collision")
        #expect(result.entry(for: unreadable.id)?.explanationCode == "access_failed")
        #expect(result.entries.allSatisfy { $0.decision == .defer })
        #expect(result.summary.deferred == 4)
        #expect(result.summary.mappingCandidates == 0)
    }

    @Test("an incomplete scan defers everything except strong technical noise")
    func incompleteScanDefers() throws {
        let normal = entry("Project/公告.pdf")
        let noise = entry("Project/.DS_Store")
        let result = try view([normal, noise], listingState: .incomplete)
        #expect(result.entry(for: normal.id)?.decision == .defer)
        #expect(result.entry(for: normal.id)?.explanationCode == "scan_incomplete")
        #expect(result.entry(for: noise.id)?.decision == .exclude,
                "a .DS_Store does not become ambiguous because another directory was unreadable")
    }

    @Test("scan issues without a discovered entry are reported, never swallowed")
    func unaccountedScanIssues() throws {
        let present = entry("Project/公告.pdf")
        let result = try view([present], listingState: .incomplete, issues: [
            .init(relativePath: "Project/locked", reason: .authorization),
            .init(relativePath: "Project/unknown", reason: .unknownVolumeSemantics),
        ])
        #expect(result.unaccountedIssues.count == 2)
        #expect(result.summary.unaccounted == 2)
        #expect(result.summary.scanIssueCount == 2)
        #expect(result.summary.discovered == 1, "an unreadable subtree is not a discovered file")
        #expect(result.summary.isConserved)
    }

    // MARK: - Overrides

    @Test("a precise include turns a REVIEW into a candidate, but not a DEFER")
    func includeOverride() throws {
        let deliverable = entry("Project/build/客户交付.pdf")
        let missing = entry("Project/build/gone.pdf", state: .missing)
        let includeDeliverable = EligibilityOverride(
            sourceID: deliverable.id, snapshotFingerprint: deliverable.snapshotFingerprint,
            policyVersion: EligibilityPolicy.currentVersion, decision: .include,
            authorCode: "owner", note: "confirmed delivery")
        let includeMissing = EligibilityOverride(
            sourceID: missing.id, snapshotFingerprint: missing.snapshotFingerprint,
            policyVersion: EligibilityPolicy.currentVersion, decision: .include, authorCode: "owner")
        let result = try view([deliverable, missing], overrides: [includeDeliverable, includeMissing])

        let included = try #require(result.entry(for: deliverable.id))
        #expect(included.decision == .include)
        #expect(included.explanationCode == "owner_include_override")
        #expect(included.overrideState == .applied)

        let deferred = try #require(result.entry(for: missing.id))
        #expect(deferred.decision == .defer, "an include cannot invent a fact the scan lacks")
        #expect(deferred.explanationCode == "override_blocked_by_defer")
    }

    @Test("an explicit exclude applies, except over confirmed business evidence")
    func excludeOverride() throws {
        let plain = entry("Project/公告.pdf")
        let business = entry("Project/公告-重要.pdf")
        let overrides = [
            EligibilityOverride(sourceID: plain.id, snapshotFingerprint: plain.snapshotFingerprint,
                                policyVersion: EligibilityPolicy.currentVersion, decision: .exclude,
                                authorCode: "owner"),
            EligibilityOverride(sourceID: business.id, snapshotFingerprint: business.snapshotFingerprint,
                                policyVersion: EligibilityPolicy.currentVersion, decision: .exclude,
                                authorCode: "owner"),
        ]
        let result = try view([plain, business], facts: [
            business.id: facts(business, business: .confirmed),
        ], overrides: overrides)
        #expect(result.entry(for: plain.id)?.decision == .exclude)
        #expect(result.entry(for: plain.id)?.explanationCode == "owner_exclude_override")
        #expect(result.entry(for: business.id)?.decision == .review)
        #expect(result.entry(for: business.id)?.explanationCode == "override_blocked_by_business_evidence")
    }

    @Test("a stale or conflicting override is reported, never silently applied")
    func staleOverrides() throws {
        let entry = entry("Project/公告.pdf")
        let staleSnapshot = EligibilityOverride(
            sourceID: entry.id, snapshotFingerprint: String(repeating: "b", count: 64),
            policyVersion: EligibilityPolicy.currentVersion, decision: .include, authorCode: "owner")
        let stalePolicy = EligibilityOverride(
            sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
            policyVersion: "eligibility.v0", decision: .exclude, authorCode: "owner")

        let snapshotView = try view([entry], overrides: [staleSnapshot])
        #expect(snapshotView.entry(for: entry.id)?.overrideState == .staleSnapshot)
        #expect(snapshotView.entry(for: entry.id)?.followUp == .reconcileOverride)
        #expect(snapshotView.entry(for: entry.id)?.decision == .include)

        let policyView = try view([entry], overrides: [stalePolicy])
        #expect(policyView.entry(for: entry.id)?.overrideState == .stalePolicy)
        #expect(policyView.entry(for: entry.id)?.decision == .include,
                "a policy change invalidates the old instruction")

        let conflicting = try view([entry], overrides: [staleSnapshot, stalePolicy])
        #expect(conflicting.entry(for: entry.id)?.overrideState == .conflicting)
        #expect(conflicting.entry(for: entry.id)?.followUp == .resolveOverrideConflict)
        #expect(conflicting.entry(for: entry.id)?.decision == .include)
    }

    // MARK: - Policy contract

    @Test("the shipped policy loads, validates, and has a stable digest")
    func shippedPolicyContract() throws {
        let policy = try EligibilityPolicy.shipped()
        #expect(policy.schemaVersion == EligibilityPolicy.supportedSchemaVersion)
        #expect(policy.policyVersion == EligibilityPolicy.currentVersion)
        #expect(policy.digest.count == 64)
        #expect(policy.digest == (try EligibilityPolicy.shipped()).digest)
        #expect(policy.orderedRules.first?.priority == 100)
        #expect(policy.orderedRules.last?.priority == 0)
        // Every fact a rule names is a fact the engine can supply.
        for rule in policy.rules {
            for predicate in (rule.all ?? []) + (rule.any ?? []) {
                for name in (predicate.facts ?? [:]).keys {
                    #expect(EligibilityFacts.knownFactNames.contains(name), "unknown fact \(name)")
                }
            }
        }
    }

    @Test("rule order in the JSON file does not change the decision or the digest")
    func ruleOrderIsNotSemantic() throws {
        let a = EligibilityRule(ruleID: "a", priority: 10, decision: .review,
                                evidenceStrength: .weak, explanationCode: "weak_review",
                                all: [EligibilityPredicate(extensions: ["pdf"])])
        let b = defaultInclude()
        let first = policy([a, b])
        let second = policy([b, a])
        #expect(first.digest == second.digest)
        #expect(first.orderedRules.map(\.ruleID) == second.orderedRules.map(\.ruleID))

        let entry = entry("Project/公告.pdf")
        let one = try view([entry], policy: first)
        let two = try view([entry], policy: second)
        #expect(one.entries.map(\.decision) == two.entries.map(\.decision))
        #expect(one.entries.map(\.decidedByRuleID) == two.entries.map(\.decidedByRuleID))
    }

    @Test("a policy that could exclude on weak evidence is refused at load")
    func weakExclusionIsRefused() throws {
        let weak = EligibilityRule(ruleID: "weak-exclude", priority: 10, decision: .exclude,
                                   evidenceStrength: .weak, explanationCode: "nope",
                                   all: [EligibilityPredicate(pathComponents: ["build"])])
        #expect(throws: FormaError.incompatible) { _ = try policy([weak, defaultInclude()]).validated() }
    }

    @Test("duplicate rule ids and empty predicates are refused")
    func malformedPolicyIsRefused() throws {
        let duplicate = defaultInclude()
        #expect(throws: FormaError.incompatible) {
            _ = try policy([duplicate, duplicate]).validated()
        }
        let empty = EligibilityRule(ruleID: "empty", priority: 1, decision: .review,
                                    evidenceStrength: .weak, explanationCode: "empty")
        #expect(throws: FormaError.incompatible) { _ = try policy([empty]).validated() }
        let badSchema = EligibilityPolicy(schemaVersion: "9.9", rules: [defaultInclude()])
        #expect(throws: FormaError.incompatible) { _ = try badSchema.validated() }
    }

    @Test("a policy written for other profiles defers instead of guessing")
    func profileApplicability() throws {
        let entry = entry("Project/公告.pdf")
        let vendorOnly = policy([defaultInclude()], profiles: [VendorLibraryContract.id])
        let result = try view([entry], policy: vendorOnly)
        #expect(result.entry(for: entry.id)?.decision == .defer)
        #expect(result.entry(for: entry.id)?.explanationCode == "policy_not_applicable")
        #expect(result.entry(for: entry.id)?.matchedRuleIDs.isEmpty == true)
    }

    @Test("priority decides a conflict and every matching rule stays visible")
    func priorityAndConflictVisibility() throws {
        let high = EligibilityRule(ruleID: "high-review", priority: 50, decision: .review,
                                   evidenceStrength: .contextual, explanationCode: "high_review",
                                   all: [EligibilityPredicate(extensions: ["pdf"])])
        let low = EligibilityRule(ruleID: "low-include", priority: 5, decision: .include,
                                  evidenceStrength: .contextual, explanationCode: "low_include",
                                  all: [EligibilityPredicate(extensions: ["pdf"])])
        let entry = entry("Project/公告.pdf")
        let result = try view([entry], policy: policy([low, high]))
        let view = try #require(result.entry(for: entry.id))
        #expect(view.decision == .review)
        #expect(view.decidedByRuleID == "high-review")
        #expect(view.matchedRuleIDs == ["high-review", "low-include"])
    }

    // MARK: - Dry run and metrics

    @Test("the dry run conserves counts and reports what it cannot know")
    func dryRunConservation() throws {
        let noise = entry("Project/.DS_Store", size: 1_024)
        let noiseUnknownSize = entry("Other/.DS_Store", size: nil)
        let business = entry("Project/公告.pdf", size: 2_048)
        let vendor = entry("Project/vendor/白皮书.pdf", size: 4_096)
        let missing = entry("Project/gone.pdf", state: .missing)
        let result = try view([noise, noiseUnknownSize, business, vendor, missing],
                              protected: [business.id])

        let summary = result.summary
        #expect(summary.discovered == 5)
        #expect(summary.isConserved)
        #expect(summary.include == 1 && summary.exclude == 2 && summary.review == 1 && summary.deferred == 1)
        #expect(summary.mappingCandidates == 1)
        #expect(summary.estimatedExcludedLogicalBytes == 1_024)
        #expect(summary.unknownSizeRecords == 1)
        #expect(summary.perRule["technical-noise-ds-store"] == 2)
        #expect(summary.perProfile[ProjectArchiveContract.id]?.include == 1)

        #expect(result.metrics.mappingCandidatesReduction.numerator == 4)
        #expect(result.metrics.mappingCandidatesReduction.denominator == 5)
        #expect(result.metrics.reviewRate.value == 0.2)
        #expect(result.metrics.falseExclusionRate.value == 0)
        #expect(result.metrics.falseExclusionRate.kind == .simulated,
                "a synthetic fixture never publishes a measured rate")
        #expect(result.metrics.tokenReduction.kind == .unavailable)
        #expect(result.metrics.tokenReduction.value == nil)
        #expect(result.metrics.estimatedImportBytesReduction.kind == .extrapolated)
        #expect(result.metrics.estimatedImportBytesReduction.assumption?.contains("physical") == true)
    }

    @Test("token reduction is only reported as an explicit extrapolation")
    func tokenReductionAssumption() throws {
        let noise = entry("Project/.DS_Store")
        let business = entry("Project/公告.pdf")
        let result = try view([noise, business], tokensPerFile: 500)
        let metric = result.metrics.tokenReduction
        #expect(metric.kind == .extrapolated)
        #expect(metric.numerator == 500)
        #expect(metric.denominator == 1_000)
        #expect(metric.value == 0.5)
        #expect(metric.assumption?.contains("500 tokens per file") == true)
    }

    @Test("zero denominators are N/A, not zero percent")
    func zeroDenominator() throws {
        let result = try view([])
        #expect(result.summary.discovered == 0)
        #expect(result.summary.isConserved)
        #expect(result.metrics.falseExclusionRate.value == nil)
        #expect(result.metrics.reviewRate.value == nil)
        #expect(result.metrics.mappingCandidatesReduction.value == nil)
        #expect(result.metrics.falseExclusionRate.unavailableReason != nil)
    }

    @Test("the exported dry run carries no path or file name")
    func exportIsPathFree() throws {
        let business = entry("客户甲有限公司/2026/投标报价-机密.pdf")
        let result = try view([business])
        let data = try FormaJSON.encode(result.export, pretty: true)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["客户甲", "投标报价", "2026/", ".pdf", "/Users/"] {
            #expect(!text.contains(forbidden), "the export leaked \(forbidden)")
        }
        #expect(text.contains("policy_digest"))
        #expect(text.contains("false_exclusion_rate"))
        let decoded = try FormaJSON.decode(EligibilityExport.self, from: data)
        #expect(decoded.records.count == 1)
        #expect(decoded.summary.discovered == 1)
    }

    // MARK: - Scale

    @Test("ten thousand synthetic entries classify deterministically")
    func tenThousandEntries() throws {
        let entries: [SourceEntry] = (0..<10_000).map { index in
            switch index % 10 {
            case 0: return entry("Project/\(index)/.DS_Store")
            case 1: return entry("Project/\(index)/._附件.pdf")
            case 2: return entry("Project/\(index)/~$报价.xlsx")
            case 3: return entry("Project/build/交付-\(index).pdf")
            case 4: return entry("Project/vendor/白皮书-\(index).pdf")
            default: return entry("Project/\(index)/公告-\(index).pdf")
            }
        }
        let start = ContinuousClock.now
        let first = try view(entries)
        let second = try view(entries)
        let elapsed = start.duration(to: .now)

        #expect(first.summary.discovered == 10_000)
        #expect(first.summary.isConserved)
        #expect(first.entries.map(\.decision) == second.entries.map(\.decision))
        #expect(first.summary == second.summary)
        #expect(elapsed < .seconds(20), "the classifier is linear in rules × entries; 10k took \(elapsed)")
        // 1,000 .DS_Store + 1,000 AppleDouble + 1,000 locks excluded; 1,000 build and
        // 1,000 vendor records are REVIEW; the remaining 5,000 are candidates.
        #expect(first.summary.exclude == 3_000)
        #expect(first.summary.review == 2_000)
        #expect(first.summary.include == 5_000)
    }
}
