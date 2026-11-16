import CryptoKit
import Foundation
import Testing

@testable import FormaCore

/// Slice 1 of the approved Contract Delta (ELIGIBILITY-CONTRACT-DELTA §5.1,
/// SPEC v0.1.2 §6.1-1): the context fingerprint gains an *optional*
/// eligibility binding, and the compatibility path is proven — not assumed.
/// A renamed API with a default argument is source-compatible, so the only
/// thing that can regress is the digest bytes; the first test pins those to
/// the exact pre-v0.1.2 formula.
@Suite("Context eligibility binding")
struct ContextEligibilityBindingTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-0000000000F2")!
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!

    private func entry(_ path: String, id: UUID? = nil,
                       snapshot: String = String(repeating: "a", count: 64)) -> SourceEntry {
        SourceEntry(id: id ?? UUID(), rootID: rootID, relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                    provider: .local, snapshotFingerprint: snapshot, sizeBytes: 10,
                    modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func profile() throws -> MappingProfile { try MappingProfile.projectArchive() }

    private func listing(_ entries: [SourceEntry]) -> SourceListing {
        SourceListing(scope: SourceScope(id: UUID(), rootID: rootID, relativePath: "",
                                         displayName: "Synthetic"),
                      scanID: UUID(), state: .complete, entries: entries, issues: [],
                      statistics: nil)
    }

    private func view(_ entries: [SourceEntry],
                      rules: [EligibilityRule]? = nil) throws -> EligibilityView {
        let all = rules ?? [EligibilityRule(ruleID: "default", priority: 0, decision: .include,
                                            evidenceStrength: .contextual,
                                            explanationCode: "default_mapping_candidate",
                                            all: [EligibilityPredicate(entryStates: ["present"])])]
        let selected = try profile()
        return EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries), profile: selected,
            policy: EligibilityPolicy(policyVersion: EligibilityPolicy.currentVersion, rules: all),
            kind: .simulated))
    }

    private let binding = ContextEligibilityBinding(
        policyID: "forma-import-eligibility", policyVersion: "eligibility.v2",
        policyDigest: String(repeating: "1", count: 64),
        decisionsDigest: String(repeating: "2", count: 64))

    // MARK: - The compatibility path

    @Test("full-list mode hashes exactly the pre-v0.1.2 context.v1 formula")
    func fullListFormulaIsByteIdentical() throws {
        let entries = [entry("Project/公告.pdf"), entry("Project/2024/报价.docx"),
                       entry("Vendor/datasheet.xlsx", snapshot: String(repeating: "b", count: 64))]
        let selected = try profile()
        // Independent reimplementation of the original function: header plus one
        // line per entry sorted by normalized path. If this ever stops matching
        // the production call, full-list contexts changed meaning.
        var hasher = SHA256()
        hasher.update(data: Data("context.v1|\(scopeID.sourceKey)|\(selected.versionKey)\n".utf8))
        for item in entries.sorted(by: { $0.normalizedRelativePath < $1.normalizedRelativePath }) {
            hasher.update(data: Data("\(item.id.sourceKey)|\(item.normalizedRelativePath)|\(item.state.rawValue)\n".utf8))
        }
        let legacy = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let produced = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected, entries: entries)
        let producedNil = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected, entries: entries,
                                                     eligibility: nil)
        #expect(produced == legacy)
        #expect(producedNil == legacy)
    }

    @Test("build() without a binding stores the v1 digest and is revision-reusable")
    func buildKeepsLegacyDigest() throws {
        let entries = [entry("Project/公告.pdf")]
        let selected = try profile()
        let context = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: entries),
            revision: 1, builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        let expected = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected, entries: entries)
        #expect(context.inputDigest == expected)
    }

    // MARK: - The binding

    @Test("a binding changes the digest and every one of its fields is load-bearing")
    func bindingFieldsMatter() throws {
        let entries = [entry("Project/公告.pdf"), entry("Project/报价.docx")]
        let selected = try profile()
        let base = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected, entries: entries)
        let bound = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected, entries: entries,
                                               eligibility: binding)
        #expect(bound != base, "filtered mode must not collide with full-list mode")
        let alteredBindings = [
            ContextEligibilityBinding(policyID: "other", policyVersion: binding.policyVersion,
                                      policyDigest: binding.policyDigest, decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: "eligibility.v3",
                                      policyDigest: binding.policyDigest, decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: binding.policyVersion,
                                      policyDigest: String(repeating: "3", count: 64), decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: binding.policyVersion,
                                      policyDigest: binding.policyDigest, decisionsDigest: String(repeating: "4", count: 64)),
        ]
        for altered in alteredBindings {
            let digest = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected,
                                                    entries: entries, eligibility: altered)
            #expect(digest != bound, "binding field did not change the digest: \(altered)")
        }
    }

    @Test("build() with a binding feeds the revision identity")
    func buildUsesBinding() throws {
        let candidates = [entry("Project/公告.pdf")]
        let selected = try profile()
        let bound = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: candidates,
                                eligibility: binding),
            revision: 2, builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        let expected = ContextBuilder.inputDigest(scopeID: scopeID, profile: selected,
                                                  entries: candidates, eligibility: binding)
        #expect(bound.inputDigest == expected)
    }

    // MARK: - decisionsDigest

    @Test("the decisions fingerprint ignores ordering and path text")
    func decisionsDigestIsOrderIndependent() throws {
        let first = UUID(uuidString: "00000000-0000-4000-8000-00000000A101")!
        let second = UUID(uuidString: "00000000-0000-4000-8000-00000000A102")!
        let a1 = entry("Alpha/one.pdf", id: first)
        let b1 = entry("Beta/two.pdf", id: second)
        let a2 = entry("Gamma/three.pdf", id: first)   // same identity, different path
        let b2 = entry("Delta/four.pdf", id: second)
        let ordered = try view([a1, b1]).decisionsDigest()
        let reordered = try view([b1, a1]).decisionsDigest()
        let renamed = try view([a2, b2]).decisionsDigest()
        #expect(ordered == reordered)
        #expect(ordered == renamed, "renaming alone must not change the decisions fingerprint")
    }

    @Test("the decisions fingerprint reacts to decisions, snapshots and policy identity")
    func decisionsDigestIsSensitive() throws {
        let entryOne = entry("Project/公告.pdf")
        let baseline = try view([entryOne]).decisionsDigest()
        let noise = EligibilityRule(ruleID: "noise", priority: 5, decision: .exclude,
                                    evidenceStrength: .strong, explanationCode: "technical_noise",
                                    all: [EligibilityPredicate(basenames: ["公告.pdf"])])
        // Same basename, unknown protection facts => include flips to review.
        let flipped = try view([entryOne], rules: [noise]).decisionsDigest()
        #expect(flipped != baseline)
        let resnapshot = entry("Project/公告.pdf", snapshot: String(repeating: "c", count: 64))
        let moved = try view([resnapshot]).decisionsDigest()
        #expect(moved != baseline, "a snapshot change must move the fingerprint")
        let selected = try profile()
        let changedPolicy = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing([entryOne]), profile: selected,
            policy: EligibilityPolicy(policyVersion: "eligibility.v3",
                                      rules: [EligibilityRule(ruleID: "default", priority: 0, decision: .include,
                                                              evidenceStrength: .contextual,
                                                              explanationCode: "default_mapping_candidate")]),
            kind: .simulated))
        #expect(changedPolicy.decisionsDigest() != baseline)
    }

    @Test("the binding a filtered context must carry mirrors the view identity")
    func bindingMirrorsView() throws {
        let built = try view([entry("Project/公告.pdf"), entry("Vendor/datasheet.xlsx")])
        let stamped = built.contextBinding
        #expect(stamped.policyID == built.policyID)
        #expect(stamped.policyVersion == built.policyVersion)
        #expect(stamped.policyDigest == built.policyDigest)
        #expect(stamped.decisionsDigest == built.decisionsDigest())
        #expect(stamped.decisionsDigest.count == 64)
    }
}
