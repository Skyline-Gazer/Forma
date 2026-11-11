import Foundation
import Testing

@testable import FormaCore

/// The invariant the CNB review of `17929d7` asked for: the length limits in
/// the artifact schemas must also hold for values Forma itself constructs,
/// otherwise a program-built manifest can fail the schema it ships with.
@Suite("Artifact bounds")
struct ArtifactBoundsTests {
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000080")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func envelope(profile: MappingProfile) -> ManifestEnvelope {
        ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000081")!,
            sourceRootID: UUID(uuidString: "00000000-0000-4000-8000-000000000082")!,
            profile: profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: nil, contextRevision: 1, promptVersion: "mapping.v1",
            extractorVersion: "evidence.v1", redactionVersion: nil,
            inputDigest: String(repeating: "b", count: 64), contextDigest: String(repeating: "c", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft
        )
    }

    @Test("oversized program-built strings are clipped to the schema limits")
    func oversizedValuesAreClipped() throws {
        let profile = try MappingProfile.projectArchive()
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "/绝对路径/前缀/文件.pdf", state: .hold,
            target: ManifestTarget(databaseName: String(repeating: "库", count: 400),
                                   groupPath: [String(repeating: "段", count: 400)], resolved: false),
            metadata: {
                var values = MetadataValues.allUnknown
                values[.tenderreference] = String(repeating: "编", count: 900)
                return values
            }(),
            fields: MetadataFieldID.allCases.map { field in
                FieldOutcome(field: field, value: field == .tenderreference ? String(repeating: "编", count: 900) : nil,
                             status: .unknown,
                             conflicts: field == .issuer ? [String(repeating: "冲", count: 900)] : [])
            },
            associations: [ManifestAssociation(kind: .projectCandidate, sourceID: sourceID,
                                               basis: String(repeating: "依", count: 900))],
            invalidatedReason: String(repeating: "失效", count: 900),
            providerReasoning: String(repeating: "理由", count: 900)
        )
        let manifest = Manifest(envelope: envelope(profile: profile), entries: [entry])
        let data = try FormaJSON.encode(manifest)
        let violations = try ArtifactSchemaValidator.manifest.violations(data)
        #expect(violations.isEmpty, "violations: \(violations.map(\.logSummary))")
        let decoded = try FormaJSON.decode(Manifest.self, from: data)
        let stored = decoded.entries[0]
        #expect(!stored.relativePath.hasPrefix("/"), "an absolute path must not survive into an artifact")
        #expect(stored.invalidatedReason?.count == 300)
        #expect(stored.providerReasoning?.count == 600)
        #expect(stored.target.databaseName?.count == 128)
        #expect(stored.target.groupPath[0].count == 256)
        #expect(stored.outcome(for: .tenderreference)?.value?.count == 512)
        #expect(stored.metadata[.tenderreference]?.count == 512, "metadata slots are bounded too")
        #expect(stored.outcome(for: .issuer)?.conflicts.first?.count == 300)
        #expect(stored.associations.first?.basis.count == 300)
    }

    @Test("short legitimate values survive untouched")
    func shortValuesSurvive() throws {
        let profile = try MappingProfile.projectArchive()
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "项目/公告.pdf", state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive", groupPath: ["2026", "项目", "01_招标文件"],
                                   resolved: true),
            metadata: {
                var values = MetadataValues.allUnknown
                values[.tenderreference] = "A1"
                values[.bsdcode] = "7"
                return values
            }()
        )
        let data = try FormaJSON.encode(Manifest(envelope: envelope(profile: profile), entries: [entry]))
        #expect(try ArtifactSchemaValidator.manifest.violations(data).isEmpty)
        let decoded = try FormaJSON.decode(Manifest.self, from: data)
        #expect(decoded.entries[0].metadata[.tenderreference] == "A1")
        #expect(decoded.entries[0].metadata[.bsdcode] == "7")
    }

    @Test("a reason shorter than the schema minimum is recorded as unknown")
    func stubReasonsAreDropped() throws {
        let profile = try MappingProfile.projectArchive()
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "项目/公告.pdf", state: .hold,
            target: ManifestTarget(databaseName: nil, groupPath: ["01_招标文件"], resolved: false),
            invalidatedReason: "abc"
        )
        #expect(entry.invalidatedReason == nil, "a three-character stub is not a reason")
        let data = try FormaJSON.encode(Manifest(envelope: envelope(profile: profile), entries: [entry]))
        #expect(try ArtifactSchemaValidator.manifest.violations(data).isEmpty)
    }

    @Test("a proposal keeps the reasoning bound the provider schema declares")
    func proposalReasoningBound() throws {
        let entry = ProposalEntry(
            entryRef: "e1", projectAssociation: nil, documentCategory: nil, documentType: nil,
            metadata: .allUnknown, evidence: [], unknownFields: Set(MetadataFieldID.allCases), conflicts: [],
            confidence: .low, reasoning: String(repeating: "理", count: 5_000)
        )
        #expect(entry.reasoning.count == 600)
        let data = try FormaJSON.encode(MappingProposal(batchID: "b1", entries: [entry]))
        #expect(try ArtifactSchemaValidator.proposal.violations(data).isEmpty)
        let conflict = ProposalConflict(field: .issuer, detail: "x")
        #expect(conflict.detail == "unspecified conflict", "an empty detail cannot satisfy minLength 4")
    }
}
