import Foundation
import Testing

@testable import FormaCore

/// The offline planner is a deterministic draft, not a model. These tests fix
/// three promises: the proposal is the conservative one, the manifest identity
/// says `offline`, and no request can be made under that identity.
@Suite("Offline planner")
struct OfflinePlannerAnswererTests {
    private func entryRef(path: String = "2026_项目/01_招标/公告.pdf",
                          extensionName: String = "pdf") -> MappingEntryRef {
        MappingEntryRef(ref: "ref-1", sourceID: UUID(), relativePath: path,
                        sizeBytes: 1_024, extensionName: extensionName,
                        hydrationPending: false, provider: "local")
    }

    private func batch(_ refs: [MappingEntryRef]) -> MappingBatch {
        MappingBatch(id: "batch-1", candidateID: nil, entries: refs, evidence: [])
    }

    private func context(_ profile: MappingProfile) async throws -> ProjectContext {
        let fixture = try SourceFixture()
        let url = fixture.root.appendingPathComponent("2026_项目/01_招标")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: url.appendingPathComponent("公告.pdf"))
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        _ = try await workspace.scan(scope)
        return try await workspace.buildContext(scope: scope, profile: profile)
    }

    @Test("the proposal claims nothing it cannot cite")
    func proposalIsTheConservativeDraft() async throws {
        let profile = try MappingProfile.projectArchive()
        let answerer = OfflinePlannerAnswerer()
        let attempt = await answerer.answer(
            provider: .offline, model: OfflinePlannerAnswerer.modelID, allowCloud: false,
            profile: profile, context: try await context(profile),
            casePack: try CasePack.shipped(), batch: batch([entryRef()]),
            redaction: .none)

        #expect(attempt.error == nil)
        let proposal = try #require(attempt.proposal)
        #expect(proposal.batchID == "batch-1")
        let entry = try #require(proposal.entries.first)
        // No content was read, so nothing may be claimed - not even the
        // unclassified category, because a value without citation is rejected by
        // the validator. An extension is not a business category either.
        #expect(entry.documentCategory == nil)
        #expect(entry.documentType == nil)
        #expect(entry.evidence.isEmpty)
        #expect(entry.confidence == .low)
        #expect(entry.projectAssociation?.state == .unconfirmed)
        #expect(entry.projectAssociation?.candidateRef == nil)
        #expect(entry.unknownFields == Set(MetadataFieldID.allCases))
        #expect(entry.reasoning.contains("no document content was read"))
        // No tokens were consumed: reporting any would be an invented number.
        #expect(attempt.usage.input == nil)
        #expect(attempt.requests == 0)
        #expect(attempt.modelID == OfflinePlannerAnswerer.modelID)
        #expect(answerer.isSubstitute)
    }

    @Test("the same inputs produce the same proposal")
    func proposalIsDeterministic() async throws {
        let profile = try MappingProfile.projectArchive()
        let answerer = OfflinePlannerAnswerer()
        let ctx = try await context(profile)
        let pack = try CasePack.shipped()
        let ref = entryRef()
        let first = await answerer.answer(provider: .offline, model: OfflinePlannerAnswerer.modelID,
                                          allowCloud: false, profile: profile, context: ctx,
                                          casePack: pack, batch: batch([ref]), redaction: .none)
        let second = await answerer.answer(provider: .offline, model: OfflinePlannerAnswerer.modelID,
                                           allowCloud: false, profile: profile, context: ctx,
                                           casePack: pack, batch: batch([ref]), redaction: .none)
        #expect(first.proposal == second.proposal)
    }

    @Test("a run mislabelled as a provider is refused instead of answered")
    func mislabelledRunIsRefused() async throws {
        let profile = try MappingProfile.projectArchive()
        let answerer = OfflinePlannerAnswerer()
        let refusal = await answerer.answer(provider: .openAI, model: "gpt-4o-mini", allowCloud: false,
                                            profile: profile, context: try await context(profile),
                                            casePack: try CasePack.shipped(), batch: batch([entryRef()]),
                                            redaction: .none)
        #expect(refusal.proposal == nil)
        #expect(refusal.error == .unauthorized)

        let wrongModel = await answerer.answer(provider: .offline, model: "gpt-4o-mini", allowCloud: false,
                                               profile: profile, context: try await context(profile),
                                               casePack: try CasePack.shipped(), batch: batch([entryRef()]),
                                               redaction: .none)
        #expect(wrongModel.proposal == nil)
        #expect(wrongModel.error == .unauthorized)
    }

    @Test("an offline request cannot be turned into a wire request")
    func offlineCannotBeSent() throws {
        let transport = ProviderTransport(session: .shared)
        let request = ProviderTransport.StructuredRequest(
            provider: .offline, model: OfflinePlannerAnswerer.modelID, name: "forma_mapping",
            system: nil, payload: "{}", schema: Data("{}".utf8),
            maxOutputTokens: 16, endpoint: nil)
        // With a key present: a stored credential must not make an offline run
        // sendable either.
        #expect(throws: FormaError.self) {
            _ = try transport.makeRequest(request, key: "sk-live-looking-key")
        }
    }

    @Test("the offline endpoint is an identity, not a network address")
    func offlineEndpointIsNotRoutable() {
        let url = EgressEndpoint.provider(.offline).canonicalURL
        #expect(url.scheme == "forma")
        #expect(ProbeProvider.networkCases == [.openAI, .anthropic])
        #expect(!ProbeProvider.networkCases.contains(.offline))
        #expect(ProbeProvider.offline.isNetworkProvider == false)
    }
}

@Suite("Offline planner artifact")
struct OfflinePlannerArtifactTests {
    @Test("a manifest produced offline validates against the shipped artifact schema")
    func offlineProviderIsAcceptedByTheSchema() throws {
        // The artifact schema enumerates the provider values a manifest may carry.
        // The offline planner produces a new one, so the schema has to know it:
        // otherwise an offline manifest would export and then fail its own
        // revalidation, which is the opposite of useful.
        let schema = try ArtifactSchemaValidator.manifest
        let envelope = #"{"schema_version":"1.0","manifest_id":"m","revision":1,"scope_id":"s",
            "source_root_id":"r","profile_id":"project-archive","profile_version":"1.0",
            "case_pack_id":"c","case_pack_version":"1.0","model_provider":"offline",
            "model_id":"offline-planner.v1","context_revision":1,"prompt_version":"p",
            "extractor_version":"e","input_digest":"i","context_digest":"c","created_at":
            "2026-01-01T00:00:00Z","state":"draft","grants_execution":false}"#
        let violations = try schema.violations(Data(envelope.utf8))
        #expect(violations.isEmpty, "the offline provider is not accepted: \(violations)")
    }
}
