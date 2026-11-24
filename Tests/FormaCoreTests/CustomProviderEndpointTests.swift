import Foundation
import Testing
@testable import FormaCore

/// The OpenAI-compatible endpoint contract: base-URL normalization, loopback
/// identity, grant↔target consistency, and the refusal paths a configured
/// endpoint must never paper over with a guess. Everything here answers
/// locally through `ProbeURLProtocol`; nothing reaches a network.
struct CustomProviderEndpointTests {
    // MARK: - Normalization

    @Test(arguments: [
        ("http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/chat/completions"),
        ("http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"),
        ("http://[::1]:11434/v1", "http://[::1]:11434/v1/chat/completions"),
        ("https://relay.example.com/v1", "https://relay.example.com/v1/chat/completions"),
        ("https://relay.example.com", "https://relay.example.com/v1/chat/completions"),
        ("https://relay.example.com/v1/chat/completions", "https://relay.example.com/v1/chat/completions"),
        ("  https://relay.example.com/v1/  ", "https://relay.example.com/v1/chat/completions"),
        ("https://relay.example.com/openai/v1", "https://relay.example.com/openai/v1/chat/completions"),
        // Refused: not the Chat Completions operation, or not safe to save.
        ("https://relay.example.com/v2", nil),
        ("https://relay.example.com/path/to/api", nil),
        ("http://relay.example.com/v1", nil),
        ("ftp://127.0.0.1/v1", nil),
        ("127.0.0.1:11434/v1", nil),
        ("/v1", nil),
        ("", nil),
        ("   ", nil),
        ("http://127.0.0.1@evil.invalid/v1", nil),
        ("https://evil.invalid/v1?user=me", nil),
        ("https://evil.invalid/v1#frag", nil),
        ("http://127.0.1/v1", nil),
    ])
    func normalizesBaseURL(input: String, expected: String?) {
        let resolved = CustomProviderEndpoint.chatCompletionsURL(from: input)
        if let expected {
            #expect(resolved?.absoluteString == expected, "\(input)")
        } else {
            #expect(resolved == nil, "\(input) must not resolve to a send target")
        }
    }

    @Test(arguments: [
        ("127.0.0.1", true), ("127.5.6.7", true), ("localhost", true), ("Localhost", true),
        ("::1", true), ("[::1]", true), ("0:0:0:0:0:0:0:1", true),
        ("example.invalid", false), ("10.0.0.1", false), ("127.0.0.1.evil.invalid", false),
        ("127.0.0.999", false), ("", false), ("127.1", false), ("[::2]", false),
    ])
    func loopbackIdentity(host: String, expected: Bool) {
        #expect(CustomProviderEndpoint.isLoopback(host: host) == expected)
    }

    @Test("loopback and public configured targets differ in egress mode, both exact")
    func customEndpointModes() throws {
        let loopback = try #require(CustomProviderEndpoint.chatCompletionsURL(from: "http://127.0.0.1:11434/v1"))
        let publicURL = try #require(CustomProviderEndpoint.chatCompletionsURL(from: "https://relay.example.com/v1"))
        #expect(EgressEndpoint.custom(loopback).egressMode == .local)
        #expect(EgressEndpoint.custom(publicURL).egressMode == .cloud)
        #expect(EgressEndpoint.provider(.openAI).egressMode == .cloud)
        // The sentinel for an unresolved compatible provider is non-routable by
        // construction: `.invalid` is reserved and the transport refuses to
        // build a request from it at all.
        #expect(EgressEndpoint.provider(.openAICompatible).canonicalURL.host?.hasSuffix(".invalid") == true)
    }

    @Test("only the compatible provider resolves through the base URL")
    func targetResolution() throws {
        #expect(try EgressEndpoint.target(provider: .openAI, customBaseURL: nil).get() == .provider(.openAI))
        #expect(try EgressEndpoint.target(provider: .anthropic, customBaseURL: "nonsense").get()
                == .provider(.anthropic))
        let resolved = try #require(CustomProviderEndpoint.chatCompletionsURL(from: "http://127.0.0.1:11434/v1"))
        #expect(try EgressEndpoint.target(provider: .openAICompatible, customBaseURL: " http://127.0.0.1:11434/v1 ").get()
                == .custom(resolved))
        var unconfigured = false
        switch EgressEndpoint.target(provider: .openAICompatible, customBaseURL: nil) {
        case .success: break
        case .failure(let error): unconfigured = error == .incompatible
        }
        #expect(unconfigured, "a missing Base URL fails closed with FormaError.incompatible")
    }

    // MARK: - Gate mode separation

    @Test("a loopback grant is honored with cloud consent off; a public one is not")
    func gateModeSeparation() throws {
        let loopback = EgressEndpoint.custom(
            try #require(CustomProviderEndpoint.chatCompletionsURL(from: "http://127.0.0.1:11434/v1")))
        let grant = EgressAuthorization(
            scope: EgressScope(provider: .openAICompatible, model: "m", endpoint: loopback, mode: .local,
                               categories: [.syntheticProbe], redactionVersion: RedactionPlan.version,
                               identitySubstitution: true),
            binding: .dataRange)
        let facts = EgressRequest(
            provider: .openAICompatible, model: "m", endpoint: loopback, mode: .local,
            categories: [.syntheticProbe], redactionVersion: RedactionPlan.version,
            identitySubstitution: true,
            semanticDigest: String(repeating: "a", count: 64),
            wireDigest: String(repeating: "b", count: 64),
            kind: .firstAsk, assessment: .allowed,
            credentialPresent: true, endpointURL: loopback.canonicalURL)
        // `.local` still needs a grant - but not the cloud one.
        #expect(EgressGate.decide(request: facts, authorization: nil, allowCloud: true, previewDigest: nil)
                .denial?.reason == .authorizationMissing)
        #expect(EgressGate.decide(request: facts, authorization: grant, allowCloud: false, previewDigest: nil)
                .isAllowed)

        let publicEndpoint = EgressEndpoint.custom(
            try #require(CustomProviderEndpoint.chatCompletionsURL(from: "https://relay.example.com/v1")))
        let publicGrant = EgressAuthorization(
            scope: EgressScope(provider: .openAICompatible, model: "m", endpoint: publicEndpoint, mode: .cloud,
                               categories: [.syntheticProbe], redactionVersion: RedactionPlan.version,
                               identitySubstitution: true),
            binding: .dataRange)
        let publicFacts = EgressRequest(
            provider: .openAICompatible, model: "m", endpoint: publicEndpoint, mode: .cloud,
            categories: [.syntheticProbe], redactionVersion: RedactionPlan.version,
            identitySubstitution: true,
            semanticDigest: String(repeating: "a", count: 64),
            wireDigest: String(repeating: "b", count: 64),
            kind: .firstAsk, assessment: .allowed,
            credentialPresent: true, endpointURL: publicEndpoint.canonicalURL)
        #expect(EgressGate.decide(request: publicFacts, authorization: publicGrant,
                                 allowCloud: false, previewDigest: nil).denial?.reason == .cloudDisabled)
        #expect(EgressGate.decide(request: publicFacts, authorization: publicGrant,
                                 allowCloud: true, previewDigest: nil).isAllowed)

        // Consent for one server is not consent for another: the same request
        // under the loopback grant is refused for the public target before any
        // other comparison - the endpoint identity is exact, not a host family.
        let stale = EgressGate.decide(request: publicFacts, authorization: grant,
                                      allowCloud: true, previewDigest: nil)
        #expect(stale.denial?.reason == .endpointMismatch)
    }

    // MARK: - Probe and client behavior

    @Test("an unconfigured compatible endpoint fails before any request exists")
    func unconfiguredFailsClosed() async {
        let fixture = ProviderFixture(provider: .openAICompatible, baseURL: nil) { _ in
            .response(body: ProbeProvider.openAICompatible.successBody())
        }
        let result = await fixture.run()
        #expect(result.error == .incompatible)
        #expect(fixture.requests.isEmpty)
    }

    @Test("a redirect status is reported, never followed, for a configured target")
    func redirectRefusedNotFollowed() async {
        let fixture = ProviderFixture(provider: .openAICompatible) { _ in
            .response(status: 307, body: Data())
        }
        let result = await fixture.run()
        #expect(result.error == .remoteStatus(307))
        #expect(fixture.requests.count == 1, "one request left; a redirect is not a second hop")
    }

    @Test(arguments: [
        ("org/model", true), ("Qwen/Qwen2.5-7B-Instruct", true), ("model:v1", true),
        ("bad model", false), ("model?x", false), ("", false), ("sk-abcdef", false),
        ("model#", false),
    ])
    func modelIDCharsetAcceptsEndpointStyleIDs(model: String, expected: Bool) {
        #expect(ProviderTransport.validModelID(model) == expected)
    }

    @Test("a mapping request goes to the URL its grant names, never a recomputed default")
    func clientFollowsTheGrant() async throws {
        let key = "custom-map-\(UUID().uuidString)"
        let stub = HTTPStub(response: .response(status: 200, body: ProbeProvider.openAICompatible.successBody()))
        ProbeURLProtocol.register(stub, for: key)
        defer { ProbeURLProtocol.unregister(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let resolved = try #require(CustomProviderEndpoint.chatCompletionsURL(from: "http://127.0.0.1:11434/v1"))
        let grant = try EgressAuthorization.mapping(
            provider: .openAICompatible, model: "custom-model",
            customBaseURL: "http://127.0.0.1:11434/v1",
            previewDigest: nil,
            redactionVersion: MappingPrompt.redactionVersion(for: .none),
            identitySubstitution: true).get()
        // The grant is built from one string and carries the resolved target:
        // mode included, because the *host literal* decides the authority.
        #expect(grant.scope.endpoint == .custom(resolved))
        #expect(grant.scope.mode == .local)
        let client = ProviderMappingClient(session: URLSession(configuration: configuration),
                                           keyStore: MemoryKeyStore(keys: [.openAICompatible: key]),
                                           authorization: grant)
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID()
        let batch = MappingBatch(id: "b1", candidateID: "c1",
                                 entries: [MappingEntryRef(ref: "e1", sourceID: sourceID,
                                                            relativePath: "示例项目_2026/公告.pdf",
                                                            sizeBytes: 1_024, extensionName: "pdf",
                                                            hydrationPending: false, provider: "local")],
                                 evidence: [])
        let context = ProjectContext(
            revision: 1, scopeID: UUID(), profileID: profile.profileID, profileVersion: profile.profileVersion,
            inputDigest: String(repeating: "d", count: 64),
            candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: nil,
                                          basis: [.directory], memberSourceIDs: [sourceID], confidence: .low)],
            unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now
        )
        let attempt = await client.map(provider: .openAICompatible, model: "custom-model",
                                       allowCloud: true, profile: profile, context: context,
                                       casePack: try CasePack.shipped(), batch: batch, redaction: .none)
        // The stub's probe-schema answer is not a mapping proposal, so the run
        // ends in an output failure - the point is what left the machine and
        // where. Every attempt (first ask, repair) must carry the same
        // authorized URL and the bearer scheme; nothing recomputes a host.
        #expect(attempt.egressDenial == nil)
        #expect(!stub.requests.isEmpty)
        #expect(stub.requests.allSatisfy {
            $0.request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions"
        }, "every request must address the grant's exact URL, got \(stub.requests.map { $0.request.url?.absoluteString ?? "nil" })")
        #expect(stub.requests.allSatisfy {
            $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)"
        })
    }
}
