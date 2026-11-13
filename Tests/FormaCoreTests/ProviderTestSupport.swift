import Foundation
@testable import FormaCore

/// The one HTTP stub and the provider envelope builders used by the provider,
/// egress and privacy suites. Extracted from `ProviderTests` so a new suite
/// cannot grow a second, subtly different notion of "a request was observed".
/// `ProbeURLProtocol` answers every request locally; nothing here reaches a
/// network.

extension ProbeProvider {
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

func json(_ object: [String: Any]) -> Data {
    // Every envelope in the fixtures is constructed from JSON types.
    try! JSONSerialization.data(withJSONObject: object)
}

final class ProviderFixture {
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

final class MemoryKeyStore: ProviderKeyStore, @unchecked Sendable {
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

enum StubResponse: Sendable {
    case response(status: Int = 200, body: Data, headers: [String: String] = [:])
    case failure(URLError.Code)
}

struct ObservedRequest: Sendable {
    let request: URLRequest
    let body: Data
}

final class HTTPStub: @unchecked Sendable {
    private let lock = NSLock()
    private let single: StubResponse?
    private var queue: [StubResponse]
    private var observed: [ObservedRequest] = []

    init(response: StubResponse) {
        self.single = response
        self.queue = []
    }

    /// A queued sequence is what the repair round needs: the first answer breaks
    /// the schema, the second is valid, and the test can inspect both bodies.
    init(responses: [StubResponse]) {
        self.single = nil
        self.queue = responses
    }

    var requests: [ObservedRequest] { lock.withLock { observed } }

    func nextResponse() -> StubResponse {
        lock.withLock {
            guard let single else {
                guard !queue.isEmpty else { return .failure(.resourceUnavailable) }
                return queue.removeFirst()
            }
            return single
        }
    }

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

final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
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
        switch stub.nextResponse() {
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

final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: HTTPStub] = [:]

    func get(_ key: String) -> HTTPStub? { lock.withLock { stubs[key] } }

    func set(_ stub: HTTPStub?, for key: String) {
        lock.withLock { stubs[key] = stub }
    }
}
