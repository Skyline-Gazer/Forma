import Foundation
import Testing

@testable import FormaCore

/// Slice 3 of the approved Contract Delta (ELIGIBILITY-CONTRACT-DELTA §5.3,
/// SPEC v0.1.2 §6.3): the eligibility decision is recorded in the Manifest
/// artifact, the artifact version moves with it, and everything written
/// before it keeps validating unchanged.
///
/// The compatibility half is the one that matters: an artifact from before
/// the filter existed must still load, still validate and still export —
/// nothing may demand the new block from it (PLAN §7.1, SPEC §13).
@Suite("Manifest eligibility block")
struct ManifestEligibilityBlockTests {
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private let digest = String(repeating: "a", count: 64)

    private func profile() throws -> MappingProfile { try MappingProfile.projectArchive() }

    private func envelope(profile: MappingProfile,
                           eligibility: ManifestEligibility? = nil) -> ManifestEnvelope {
        ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!,
            sourceRootID: UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!,
            profile: profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: nil, contextRevision: 1, promptVersion: "mapping.v1",
            extractorVersion: "evidence.v1", redactionVersion: nil,
            inputDigest: String(repeating: "b", count: 64), contextDigest: String(repeating: "c", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft, eligibility: eligibility)
    }

    private func block() -> ManifestEligibility {
        ManifestEligibility(policyID: "forma-import-eligibility", policyVersion: "eligibility.v2",
                            policyDigest: digest, decisionsDigest: digest,
                            discoveredCount: 12, mappedCount: 9, unmappedCount: 3)
    }

    private func entry() -> ManifestEntry {
        ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: digest, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "项目/公告.pdf", state: .hold,
            target: ManifestTarget(databaseName: "库", groupPath: ["组"], resolved: false),
            metadata: MetadataValues.allUnknown,
            fields: MetadataFieldID.allCases.map { field in
                FieldOutcome(field: field, value: nil, status: .unknown, conflicts: [])
            },
            associations: [], invalidatedReason: nil, providerReasoning: nil)
    }

    // MARK: - The block

    @Test("a filtered manifest carries the decision and moves to artifact version 1.1")
    func filteredManifestCarriesTheDecision() throws {
        let selected = try profile()
        let manifest = Manifest(envelope: envelope(profile: selected, eligibility: block()), entries: [entry()])
        #expect(manifest.schemaVersion == "1.1")
        #expect(manifest.envelope.schemaVersion == "1.1")
        let recorded = try #require(manifest.envelope.eligibility)
        #expect(recorded.policyID == "forma-import-eligibility")
        #expect(recorded.policyVersion == "eligibility.v2")
        #expect(recorded.discoveredCount == 12)
        #expect(recorded.mappedCount == 9)
        #expect(recorded.unmappedCount == 3)
    }

    @Test("a full-listing manifest stays a 1.0 artifact, byte for byte")
    func fullListingManifestIsUnchanged() throws {
        let selected = try profile()
        let manifest = Manifest(envelope: envelope(profile: selected), entries: [entry()])
        #expect(manifest.schemaVersion == "1.0")
        #expect(manifest.envelope.schemaVersion == "1.0")
        #expect(manifest.envelope.eligibility == nil)
        let data = try FormaJSON.encode(manifest)
        let violations = try ArtifactSchemaValidator.manifest(forSchemaVersion: "1.0").violations(data)
        #expect(violations.isEmpty, "violations: \(violations.map { $0.logSummary })")
        // The 1.0 artifact must not carry the new key at all: a 1.0 payload
        // with an eligibility block is not a 1.0 payload.
        #expect(!String(decoding: data, as: UTF8.self).contains("eligibility"))
    }

    // MARK: - Schema versions

    @Test("each artifact is validated against the schema it declares")
    func eachArtifactUsesItsOwnSchema() throws {
        let selected = try profile()
        let legacy = try FormaJSON.encode(Manifest(envelope: envelope(profile: selected), entries: [entry()]))
        let filtered = try FormaJSON.encode(
            Manifest(envelope: envelope(profile: selected, eligibility: block()), entries: [entry()]))
        #expect(try ArtifactSchemaValidator.manifest(forSchemaVersion: "1.0").violations(legacy).isEmpty)
        #expect(try ArtifactSchemaValidator.manifest(forSchemaVersion: "1.1").violations(filtered).isEmpty)
        // A 1.1 artifact does not pass as a 1.0 one, and an unknown version has
        // no schema at all.
        #expect(try !ArtifactSchemaValidator.manifest(forSchemaVersion: "1.0").violations(filtered).isEmpty)
        #expect(throws: FormaError.self) { try ArtifactSchemaValidator.manifest(forSchemaVersion: "2.0") }
    }

    @Test("a 1.1 artifact with an incomplete eligibility block is refused")
    func incompleteEligibilityBlockIsRefused() throws {
        let selected = try profile()
        var document = try #require(
            JSONSerialization.jsonObject(with: try FormaJSON.encode(
                Manifest(envelope: envelope(profile: selected, eligibility: block()), entries: [entry()]))) as? [String: Any])
        var envelope = try #require(document["envelope"] as? [String: Any])
        var block = try #require(envelope["eligibility"] as? [String: Any])
        block.removeValue(forKey: "policy_digest")
        envelope["eligibility"] = block
        document["envelope"] = envelope
        let data = try JSONSerialization.data(withJSONObject: document)
        let violations = try ArtifactSchemaValidator.manifest(forSchemaVersion: "1.1").violations(data)
        #expect(!violations.isEmpty, "a block without the policy digest must not validate")
    }

    // MARK: - Backwards compatibility

    @Test("an artifact written before the block existed still loads and validates")
    func legacyArtifactStillLoads() throws {
        let selected = try profile()
        // A 1.0 artifact, byte for byte what the program wrote before the
        // filter existed: no eligibility key anywhere in the payload.
        let data = try FormaJSON.encode(Manifest(envelope: envelope(profile: selected), entries: [entry()]))
        #expect(!String(decoding: data, as: UTF8.self).contains("eligibility"))
        let violations = try ArtifactSchemaValidator.manifest(forSchemaVersion: "1.0").violations(data)
        #expect(violations.isEmpty, "violations: \(violations.map { $0.logSummary })")
        let decoded = try FormaJSON.decode(Manifest.self, from: data)
        #expect(decoded.schemaVersion == "1.0")
        #expect(decoded.envelope.eligibility == nil)
    }

    @Test("a filtered manifest round-trips through the store and keeps its block")
    func filteredManifestSurvivesStorage() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let selected = try profile()
        let manifest = Manifest(envelope: envelope(profile: selected, eligibility: block()), entries: [entry()])
        let stored = try await workspace.saveManifest(manifest, scopeID: scope.id)
        #expect(stored.envelope.eligibility != nil)
        #expect(stored.envelope.schemaVersion == "1.1")
        let fetched = try #require(try await workspace.currentManifest(scope: scope, profile: selected))
        #expect(fetched.envelope.eligibility?.policyVersion == "eligibility.v2")
        #expect(fetched.envelope.eligibility?.unmappedCount == 3)
    }
}
