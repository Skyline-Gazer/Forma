import Foundation
import Testing
@testable import FormaCore

struct ProviderTests {
    @Test(arguments: ProbeProvider.allCases)
    func nativeStructuredRequestAndUsage(provider: ProbeProvider) async throws {
        let fixture = ProviderFixture(provider: provider, hasKey: false) { _ in
            .response(body: provider.successBody())
        }
        try fixture.probe.saveKey(" \(fixture.key)\n", for: provider)
        let result = await fixture.run()

        #expect(result.error == nil)
        #expect(result.output?.classification == .vendorLibrary)
        #expect(result.output?.hasProject == false)
        #expect(result.modelID == provider.reportedModel)
        #expect(result.inputTokens == 31)
        #expect(result.outputTokens == 12)
        #expect(result.cacheReadInputTokens == 7)
        #expect(result.cacheCreationInputTokens == (provider == .anthropic ? 3 : nil))
        #expect(result.latencyMilliseconds >= 0)

        let observed = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(observed.request.httpMethod == "POST")
        #expect(observed.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: observed.body) as? [String: Any])
        #expect(body["model"] as? String == provider.configuredModel)
        #expect(!String(decoding: observed.body, as: UTF8.self).contains(fixture.key))

        let format: [String: Any]
        switch provider {
        case .openAI:
            #expect(observed.request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(observed.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.key)")
            #expect(body["input"] as? String == ProviderProbe.syntheticPrompt)
            #expect(body["max_output_tokens"] as? Int == 256)
            #expect(body["store"] as? Bool == false)
            format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
            #expect(format["name"] as? String == "forma_probe")
            #expect(format["strict"] as? Bool == true)
        case .anthropic:
            #expect(observed.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(observed.request.value(forHTTPHeaderField: "x-api-key") == fixture.key)
            #expect(observed.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(body["messages"] as? [[String: String]] == [["role": "user", "content": ProviderProbe.syntheticPrompt]])
            #expect(body["max_tokens"] as? Int == 256)
            format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        }
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["classification", "has_project"])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["classification"]?["type"] as? String == "string")
        #expect(properties["classification"]?["enum"] as? [String] == ["project_archive", "vendor_library"])
        #expect(properties["has_project"]?["type"] as? String == "boolean")
    }

    @Test(arguments: ProbeProvider.allCases)
    func requiresExplicitConsentAndKey(provider: ProbeProvider) async {
        let fixture = ProviderFixture(provider: provider, hasKey: false) { _ in
            .response(body: provider.successBody())
        }
        let denied = await fixture.run(allowCloud: false)
        #expect(denied.error == .unauthorized)
        #expect(fixture.keyStore.loadCount == 0)
        let missingKey = await fixture.run()
        #expect(missingKey.error == .credentialMissing)
        #expect(fixture.keyStore.loadCount == 1)
        #expect(fixture.requests.isEmpty)
    }

    @Test(arguments: ProbeProvider.allCases, [
        #"{"classification":"vendor_library","has_project":false,"unrecognized":"value"}"#,
        #"{"classification":"unrecognized","has_project":false}"#,
        #"{"classification":"vendor_library","has_project":0}"#,
        #"{"classification":"vendor_library","has_project":"false"}"#,
        #"{"classification":"vendor_library","has_project":null}"#,
        #"{"classification":"vendor_library"}"#,
        #"[{"classification":"vendor_library","has_project":false}]"#,
        "```json\n{}\n```",
    ])
    func rejectsOutputOutsideTheSchema(provider: ProbeProvider, text: String) async {
        let fixture = ProviderFixture(provider: provider) { _ in .response(body: provider.successBody(text: text)) }
        let result = await fixture.run()
        #expect(result.error == .invalidOutput)
        #expect(result.output == nil)
        #expect(result.inputTokens == 31)
    }

    @Test(arguments: ProbeProvider.allCases)
    func distinguishesRefusalAndTruncation(provider: ProbeProvider) async {
        let refusal = ProviderFixture(provider: provider) { key in
            var response = provider.successEnvelope()
            switch provider {
            case .openAI:
                response["output"] = [["type": "message", "content": [["type": "refusal", "refusal": key]]]]
            case .anthropic:
                response["stop_reason"] = "refusal"
                response["content"] = [["type": "text", "text": key]]
            }
            return .response(body: json(response))
        }
        let refused = await refusal.run()
        #expect(refused.error == .refused)
        #expect(refused.output == nil)
        #expect(refused.outputTokens == 12)
        #expect(!String(reflecting: refused).contains(refusal.key))

        let truncation = ProviderFixture(provider: provider) { _ in
            var response = provider.successEnvelope()
            switch provider {
            case .openAI:
                response["status"] = "incomplete"
                response["incomplete_details"] = ["reason": "max_output_tokens"]
            case .anthropic:
                response["stop_reason"] = "max_tokens"
            }
            return .response(body: json(response))
        }
        let truncated = await truncation.run()
        #expect(truncated.error == .invalidOutput)
        #expect(truncated.output == nil)
    }

    @Test(arguments: [false, true])
    func capsResponseBody(withContentLength: Bool) async {
        let fixture = ProviderFixture(provider: .openAI) { _ in
            var body = ProbeProvider.openAI.successBody()
            body.append(Data(repeating: 0x20, count: ProviderTransport.maximumResponseBytes + 1 - body.count))
            return .response(
                body: body,
                headers: withContentLength ? ["Content-Length": String(body.count)] : [:]
            )
        }
        let result = await fixture.run()
        #expect(result.error == .invalidResponse)
        #expect(result.output == nil)
    }

    @Test
    func retainsOnlySafeUsageAndModel() async {
        let fixture = ProviderFixture(provider: .anthropic) { key in
            var response = ProbeProvider.anthropic.successEnvelope()
            response["model"] = key
            response["usage"] = [
                "input_tokens": true,
                "output_tokens": -1,
                "cache_read_input_tokens": 1.5,
                "cache_creation_input_tokens": "5",
            ] as [String: Any]
            return .response(body: json(response))
        }
        let result = await fixture.run()
        #expect(result.error == nil)
        #expect(result.modelID == ProbeProvider.anthropic.configuredModel)
        #expect(result.inputTokens == nil)
        #expect(result.outputTokens == nil)
        #expect(result.cacheReadInputTokens == nil)
        #expect(result.cacheCreationInputTokens == nil)
        #expect(!String(reflecting: result).contains(fixture.key))
    }

    @Test
    func restoresLatestMetricsWithoutCredentials() async throws {
        let suite = "FormaProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let successful = ProviderFixture(provider: .openAI, defaults: defaults) { key in
            var response = ProbeProvider.openAI.successEnvelope()
            response["model"] = key
            response["unrecognized"] = ProviderProbe.syntheticPrompt
            return .response(body: json(response))
        }
        let live = await successful.run()
        #expect(live.error == nil)
        #expect(live.output != nil)

        let reader = ProviderFixture(provider: .openAI, hasKey: false, defaults: defaults) { _ in .failure(.cancelled) }
        let restored = try #require(reader.probe.lastResult(for: .openAI))
        #expect(restored.output == nil)
        #expect(restored.modelID == ProbeProvider.openAI.configuredModel)
        #expect(restored.inputTokens == 31)
        #expect(restored.outputTokens == 12)
        #expect(restored.cacheReadInputTokens == 7)
        #expect(restored.latencyMilliseconds == live.latencyMilliseconds)
        #expect(reader.probe.lastResult(for: .anthropic) == nil)
        #expect(reader.keyStore.loadCount == 0)

        let failed = ProviderFixture(provider: .openAI, defaults: defaults) { key in
            .response(status: 429, body: Data(key.utf8))
        }
        _ = await failed.run()
        #expect(reader.probe.lastResult(for: .openAI)?.error == .remoteStatus(429))
        _ = await reader.run(allowCloud: false)
        #expect(reader.probe.lastResult(for: .openAI)?.error == .remoteStatus(429))

        let domain = try #require(defaults.persistentDomain(forName: suite))
        #expect(domain.count == 1)
        let entry = try #require(domain.values.first as? [String: Any])
        #expect(Set(entry.keys) == ["modelID", "latencyMilliseconds", "errorCode", "httpStatus"])
        let stored = String(reflecting: entry)
        #expect(!stored.contains(successful.key))
        #expect(!stored.contains(failed.key))
        #expect(!stored.contains(ProviderProbe.syntheticPrompt))
    }

    @Test(arguments: [401, 403, 429, 500])
    func reportsHTTPStatusWithoutResponseBody(status: Int) async {
        let fixture = ProviderFixture(provider: .openAI) { key in
            .response(status: status, body: Data(key.utf8))
        }
        let result = await fixture.run()
        #expect(result.error == ((status == 401 || status == 403) ? .unauthorized : .remoteStatus(status)))
        #expect(result.modelID == ProbeProvider.openAI.configuredModel)
        #expect(result.output == nil)
        #expect(!String(reflecting: result).contains(fixture.key))
    }

    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet, .cancelled])
    func reportsTransportFailure(code: URLError.Code) async {
        let fixture = ProviderFixture(provider: .openAI) { _ in .failure(code) }
        let result = await fixture.run()
        let expected: FormaError = switch code {
        case .timedOut: .timeout
        case .cancelled: .cancelled
        default: .network
        }
        #expect(result.error == expected)
    }

    /// Runs one mapping request against a stub that always answers with
    /// `status`, and returns what the client reported about it.
    private func mappingAttempt(status: Int, headers: [String: String] = [:]) async throws -> MappingAttempt {
        let key = "probe-test-\(UUID().uuidString)"
        let stub = HTTPStub(response: .response(status: status, body: Data(#"{"error":{"message":"stub"}}"#.utf8),
                                                headers: headers))
        ProbeURLProtocol.register(stub, for: key)
        defer { ProbeURLProtocol.unregister(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let client = ProviderMappingClient(session: URLSession(configuration: configuration),
                                           keyStore: MemoryKeyStore(keys: [.openAI: key]))
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
        return await client.map(provider: .openAI, model: "gpt-4o-mini", allowCloud: true, profile: profile,
                                context: context, casePack: try CasePack.shipped(), batch: batch, redaction: .none)
    }

    @Test("a rate limit buys exactly one retry and is then reported as the status")
    func mappingRateLimitGetsOneRetry() async throws {
        let attempt = try await mappingAttempt(status: 429, headers: ["Retry-After": "0"])
        #expect(attempt.requests == 2, "one rate limit must buy exactly one retry, got \(attempt.requests)")
        #expect(attempt.rateLimitRetries == 1,
                "the retry must be distinguishable from a repair round, got \(attempt.rateLimitRetries)")
        #expect(attempt.error == .remoteStatus(429),
                "a second rate limit is reported as the status, not as a mystery")
        #expect(attempt.proposal == nil)
    }

    @Test("a failed request still reports the request it made")
    func failedMappingStillCountsRequests() async throws {
        // The report is the only place anyone can see that a provider was
        // contacted. Counting only successes made a rate-limited or
        // server-failed run look like it had never left the machine, which is
        // the opposite of what the accounting is for.
        let attempt = try await mappingAttempt(status: 500)
        #expect(attempt.requests == 1, "one request was made, got \(attempt.requests)")
        #expect(attempt.error == .remoteStatus(500))
    }

    @Test("Retry-After is read, bounded, and never guessed at")
    func retryAfterIsParsedConservatively() throws {
        func header(_ value: String?) -> HTTPURLResponse? {
            var fields: [String: String] = [:]
            if let value { fields["Retry-After"] = value }
            return HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429,
                                   httpVersion: "HTTP/1.1", headerFields: fields)
        }
        #expect(ProviderTransport.retryAfter(from: header("7")) == 7)
        #expect(ProviderTransport.retryAfter(from: header(" 12 ")) == 12)
        #expect(ProviderTransport.retryAfter(from: header("3600")) == 30,
                "an unbounded wait would outlive the user's patience")
        #expect(ProviderTransport.retryAfter(from: header("-5")) == 0)
        #expect(ProviderTransport.retryAfter(from: header("Wed, 11 Nov 2026 12:00:00 GMT")) == nil,
                "an HTTP-date is not guessed at, and the fixed backoff applies")
        #expect(ProviderTransport.retryAfter(from: header(nil)) == nil)
        #expect(ProviderTransport.retryDelay(retryAfter: 7) == 7)
        #expect(ProviderTransport.retryDelay(retryAfter: nil) == 1)
        #expect(ProviderTransport.retryDelay(retryAfter: 0) == 0,
                "a provider that says do not wait is believed")
    }
}

private extension ProbeProvider {
    var configuredModel: String {
        switch self {
        case .openAI: "gpt-4o"
        case .anthropic: "claude-sonnet-4-5"
        }
    }

    var reportedModel: String {
        switch self {
        case .openAI: "gpt-4o-2024-08-06"
        case .anthropic: "claude-sonnet-4-5-20250929"
        }
    }

    func successBody(text: String = #"{"classification":"vendor_library","has_project":false}"#) -> Data {
        json(successEnvelope(text: text))
    }

    func successEnvelope(text: String = #"{"classification":"vendor_library","has_project":false}"#) -> [String: Any] {
        switch self {
        case .openAI:
            [
                "status": "completed", "model": reportedModel,
                "output": [
                    ["type": "reasoning", "summary": [String]()],
                    ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]],
                ],
                "usage": ["input_tokens": 31, "output_tokens": 12, "input_tokens_details": ["cached_tokens": 7]],
            ]
        case .anthropic:
            [
                "stop_reason": "end_turn", "model": reportedModel,
                "content": [["type": "text", "text": text]],
                "usage": ["input_tokens": 31, "output_tokens": 12, "cache_read_input_tokens": 7, "cache_creation_input_tokens": 3],
            ]
        }
    }
}

private func json(_ object: [String: Any]) -> Data {
    // Every envelope in the fixtures is constructed from JSON types.
    try! JSONSerialization.data(withJSONObject: object)
}

private final class ProviderFixture {
    let provider: ProbeProvider
    let key: String
    let keyStore: MemoryKeyStore
    let probe: ProviderProbe
    private let session: URLSession
    private let stub: HTTPStub

    init(provider: ProbeProvider, hasKey: Bool = true, defaults: UserDefaults? = nil, response: (String) -> StubResponse) {
        let key = "probe-test-\(UUID().uuidString)"
        self.provider = provider
        self.key = key
        self.keyStore = MemoryKeyStore(keys: hasKey ? [provider: key] : [:])
        self.stub = HTTPStub(response: response(key))
        ProbeURLProtocol.register(stub, for: key)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeURLProtocol.self]
        self.session = URLSession(configuration: config)
        self.probe = ProviderProbe(session: session, keyStore: keyStore, defaults: defaults)
    }

    deinit {
        session.invalidateAndCancel()
        ProbeURLProtocol.unregister(key)
    }

    var requests: [ObservedRequest] { stub.requests }

    func run(allowCloud: Bool = true) async -> ProviderProbeResult {
        await probe.run(provider: provider, model: provider.configuredModel, allowCloud: allowCloud)
    }
}

private final class MemoryKeyStore: ProviderKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [ProbeProvider: String]
    private var reads = 0

    init(keys: [ProbeProvider: String]) { self.keys = keys }

    var loadCount: Int { lock.withLock { reads } }

    func save(_ key: String, for provider: ProbeProvider) {
        lock.withLock { keys[provider] = key }
    }

    func load(for provider: ProbeProvider) -> String? {
        lock.withLock {
            reads += 1
            return keys[provider]
        }
    }
}

private enum StubResponse: Sendable {
    case response(status: Int = 200, body: Data, headers: [String: String] = [:])
    case failure(URLError.Code)
}

private struct ObservedRequest: Sendable {
    let request: URLRequest
    let body: Data
}

private final class HTTPStub: @unchecked Sendable {
    let response: StubResponse
    private let lock = NSLock()
    private var observed: [ObservedRequest] = []

    init(response: StubResponse) { self.response = response }

    var requests: [ObservedRequest] { lock.withLock { observed } }

    func record(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let capacity = 1024
            var buffer = [UInt8](repeating: 0, count: capacity)
            while true {
                let count = stream.read(&buffer, maxLength: capacity)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.withLock { observed.append(ObservedRequest(request: request, body: body)) }
    }
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = StubRegistry()

    static func register(_ stub: HTTPStub, for key: String) { registry.set(stub, for: key) }
    static func unregister(_ key: String) { registry.set(nil, for: key) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        let key = request.value(forHTTPHeaderField: "x-api-key") ?? bearer.map { String($0.dropFirst(7)) }
        guard let key, let stub = Self.registry.get(key), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        stub.record(request)
        switch stub.response {
        case .response(let status, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: HTTPStub] = [:]

    func get(_ key: String) -> HTTPStub? { lock.withLock { stubs[key] } }

    func set(_ stub: HTTPStub?, for key: String) {
        lock.withLock { stubs[key] = stub }
    }
}
