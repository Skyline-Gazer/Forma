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
        return EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries), profile: try profile(),
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
        // Independent reimplementation of the original function: header plus one
        // line per entry sorted by normalized path. If this ever stops matching
        // the production call, full-list contexts changed meaning.
        var hasher = SHA256()
        hasher.update(data: Data("context.v1|\(scopeID.sourceKey)|\(try profile().versionKey)\n".utf8))
        for item in entries.sorted(by: { $0.normalizedRelativePath < $1.normalizedRelativePath }) {
            hasher.update(data: Data("\(item.id.sourceKey)|\(item.normalizedRelativePath)|\(item.state.rawValue)\n".utf8))
        }
        let legacy = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(ContextBuilder.inputDigest(scopeID: scopeID, profile: try profile(), entries: entries) == legacy)
        #expect(ContextBuilder.inputDigest(scopeID: scopeID, profile: try profile(), entries: entries,
                                           eligibility: nil) == legacy)
    }

    @Test("build() without a binding stores the v1 digest and is revision-reusable")
    func buildKeepsLegacyDigest() throws {
        let entries = [entry("Project/公告.pdf")]
        let context = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: try profile(), entries: entries),
            revision: 1, builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(context.inputDigest == ContextBuilder.inputDigest(
            scopeID: scopeID, profile: try profile(), entries: entries))
    }

    // MARK: - The binding

    @Test("a binding changes the digest and every one of its fields is load-bearing")
    func bindingFieldsMatter() throws {
        let entries = [entry("Project/公告.pdf"), entry("Project/报价.docx")]
        let base = try ContextBuilder.inputDigest(scopeID: scopeID, profile: profile(), entries: entries)
        let bound = try ContextBuilder.inputDigest(scopeID: scopeID, profile: profile(), entries: entries,
                                                   eligibility: binding)
        #expect(bound != base, "filtered mode must not collide with full-list mode")
        for altered in [
            ContextEligibilityBinding(policyID: "other", policyVersion: binding.policyVersion,
                                      policyDigest: binding.policyDigest, decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: "eligibility.v3",
                                      policyDigest: binding.policyDigest, decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: binding.policyVersion,
                                      policyDigest: String(repeating: "3", count: 64), decisionsDigest: binding.decisionsDigest),
            ContextEligibilityBinding(policyID: binding.policyID, policyVersion: binding.policyVersion,
                                      policyDigest: binding.policyDigest, decisionsDigest: String(repeating: "4", count: 64)),
        ] {
            let digest = try ContextBuilder.inputDigest(scopeID: scopeID, profile: profile(),
                                                        entries: entries, eligibility: altered)
            #expect(digest != bound, "binding field did not change the digest: \(altered)")
        }
    }

    @Test("build() with a binding feeds the revision identity")
    func buildUsesBinding() throws {
        let candidates = [entry("Project/公告.pdf")]
        let bound = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: try profile(), entries: candidates,
                                eligibility: binding),
            revision: 2, builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(bound.inputDigest == try ContextBuilder.inputDigest(
            scopeID: scopeID, profile: profile(), entries: candidates, eligibility: binding))
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
        #expect(try view([a1, b1]).decisionsDigest() == try view([a1, b1]).decisionsDigest())
        #expect(try view([a1, b1]).decisionsDigest() == try view([b1, a1]).decisionsDigest())
        #expect(try view([a1, b1]).decisionsDigest() == try view([a2, b2]).decisionsDigest(),
                "renaming alone must not change the decisions fingerprint")
    }

    @Test("the decisions fingerprint reacts to decisions, snapshots and policy identity")
    func decisionsDigestIsSensitive() throws {
        let entryOne = entry("Project/公告.pdf")
        let baseline = try view([entryOne]).decisionsDigest()
        let noise = EligibilityRule(ruleID: "noise", priority: 5, decision: .exclude,
                                    evidenceStrength: .strong, explanationCode: "technical_noise",
                                    all: [EligibilityPredicate(basenames: ["公告.pdf"])])
        // Same basename, unknown protection facts => include flips to review.
        #expect(try view([entryOne], rules: [noise]).decisionsDigest() != baseline)
        #expect(try view([entry("Project/公告.pdf", snapshot: String(repeating: "c", count: 64))])
            .decisionsDigest() != baseline, "a snapshot change must move the fingerprint")
        let changedPolicy = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing([entryOne]), profile: try profile(),
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
        // The digest binds the candidate subset's identity, not paths: candidates with the same
        // decisions but renamed files keep one decisions fingerprint while the context.v2 entry
        // lines change — together they cover both contract obligations.
        #expect(stamped.decisionsDigest.count == 64)
    }
}
