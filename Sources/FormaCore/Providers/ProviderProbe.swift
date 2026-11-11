import CoreFoundation
import Foundation

public enum ProbeProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-haiku-4-5-20251001"
        }
    }
}

public struct ProviderProbeOutput: Equatable, Sendable {
    public enum Classification: String, CaseIterable, Sendable {
        case projectArchive = "project_archive"
        case vendorLibrary = "vendor_library"
    }

    public let classification: Classification
    public let hasProject: Bool

    static let schema: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "classification": ["type": "string", "enum": Classification.allCases.map(\.rawValue)],
            "has_project": ["type": "boolean"],
        ] as [String: [String: any Sendable]],
        "required": ["classification", "has_project"],
        "additionalProperties": false,
    ]

    init(validating text: String) throws {
        // Enforce the closed object, required fields, enum, and JSON boolean from the probe schema.
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object.count == 2,
              let rawClassification = object["classification"] as? String,
              let classification = Classification(rawValue: rawClassification),
              let hasProject = object["has_project"] as? NSNumber,
              CFGetTypeID(hasProject) == CFBooleanGetTypeID() else {
            throw FormaError.invalidOutput
        }
        self.classification = classification
        self.hasProject = hasProject.boolValue
    }
}

public struct ProviderProbe: Sendable {
    public static let syntheticPrompt = "Classify this fictional document: a generic product datasheet with no associated project. Set has_project to whether a project is present."

    static let maximumResponseBytes = 64 * 1024
    private static let redirectPolicy = RejectProviderRedirects()

    private let session: URLSession
    private let keyStore: any ProviderKeyStore
    private let telemetry: ProviderProbeTelemetry?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.init(
            session: URLSession(configuration: configuration),
            keyStore: KeychainProviderKeyStore(),
            defaults: .standard
        )
    }

    init(session: URLSession, keyStore: any ProviderKeyStore, defaults: UserDefaults? = nil) {
        self.session = session
        self.keyStore = keyStore
        self.telemetry = defaults.map(ProviderProbeTelemetry.init)
    }

    public func saveKey(_ key: String, for provider: ProbeProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(key) else { throw FormaError.credentialMissing }
        try keyStore.save(key, for: provider)
    }

    /// The latest network attempt's metrics, available without reading Keychain.
    public func lastResult(for provider: ProbeProvider) -> ProviderProbeResult? {
        telemetry?.lastResult(for: provider)
    }

    public func run(provider: ProbeProvider, model: String, allowCloud: Bool) async -> ProviderProbeResult {
        let start = ContinuousClock.now
        var result = ProviderProbeResult(provider: provider)
        var startedRequest = false
        do {
            try Task.checkCancellation()
            guard allowCloud else { throw FormaError.unauthorized }
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validModelID(model) else { throw FormaError.incompatible }
            guard let key = try keyStore.load(for: provider), Self.validKey(key) else {
                result.modelID = model
                throw FormaError.credentialMissing
            }
            guard !model.contains(key) else { throw FormaError.incompatible }
            result.modelID = model

            let request = try Self.makeRequest(provider: provider, model: model, key: key)
            startedRequest = true
            let body = try await responseBody(for: request)
            try Task.checkCancellation()
            guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                throw FormaError.invalidResponse
            }
            if let reportedModel = envelope["model"] as? String,
               Self.validModelID(reportedModel), !reportedModel.contains(key) {
                result.modelID = reportedModel
            }
            if let usage = envelope["usage"] as? [String: Any] {
                result.inputTokens = Self.tokenCount(usage["input_tokens"])
                result.outputTokens = Self.tokenCount(usage["output_tokens"])
                switch provider {
                case .openAI:
                    let details = usage["input_tokens_details"] as? [String: Any]
                    result.cacheReadInputTokens = Self.tokenCount(details?["cached_tokens"])
                case .anthropic:
                    result.cacheReadInputTokens = Self.tokenCount(usage["cache_read_input_tokens"])
                    result.cacheCreationInputTokens = Self.tokenCount(usage["cache_creation_input_tokens"])
                }
            }
            let output = try Self.outputText(from: envelope, provider: provider)
            result.output = try ProviderProbeOutput(validating: output)
        } catch is CancellationError {
            result.error = .cancelled
        } catch let error as FormaError {
            result.error = error
        } catch let error as URLError {
            switch error.code {
            case .cancelled: result.error = .cancelled
            case .timedOut: result.error = .timeout
            default: result.error = .network
            }
        } catch {
            result.error = .invalidResponse
        }
        let elapsed = start.duration(to: .now).components
        result.latencyMilliseconds = Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        if startedRequest { telemetry?.save(result) }
        return result
    }

    private static func makeRequest(provider: ProbeProvider, model: String, key: String) throws -> URLRequest {
        let endpoint: URL
        let body: [String: Any]
        let format: [String: Any] = ["type": "json_schema", "schema": ProviderProbeOutput.schema]
        switch provider {
        case .openAI:
            endpoint = URL(string: "https://api.openai.com/v1/responses")!
            var format = format
            format["name"] = "forma_probe"
            format["strict"] = true
            body = [
                "model": model,
                "input": syntheticPrompt,
                "text": ["format": format],
                "max_output_tokens": 256,
                "store": false,
            ]
        case .anthropic:
            endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
            body = [
                "model": model,
                "messages": [["role": "user", "content": syntheticPrompt]],
                "output_config": ["format": format],
                "max_tokens": 256,
            ]
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func responseBody(for request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: Self.redirectPolicy)
        do {
            guard let response = response as? HTTPURLResponse else { throw FormaError.invalidResponse }
            switch response.statusCode {
            case 200...299: break
            case 401, 403: throw FormaError.unauthorized
            default: throw FormaError.remoteStatus(response.statusCode)
            }
            guard response.expectedContentLength <= Self.maximumResponseBytes else {
                throw FormaError.invalidResponse
            }
            var body = Data()
            if response.expectedContentLength > 0 {
                body.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard body.count < Self.maximumResponseBytes else { throw FormaError.invalidResponse }
                body.append(byte)
            }
            return body
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    private static func outputText(from envelope: [String: Any], provider: ProbeProvider) throws -> String {
        switch provider {
        case .openAI:
            switch envelope["status"] as? String {
            case "completed": break
            case "incomplete":
                let details = envelope["incomplete_details"] as? [String: Any]
                if details?["reason"] as? String == "content_filter" { throw FormaError.refused }
                throw FormaError.invalidOutput
            default: throw FormaError.invalidResponse
            }
            guard let items = envelope["output"] as? [[String: Any]] else { throw FormaError.invalidResponse }
            var text: String?
            for item in items where item["type"] as? String == "message" {
                guard let content = item["content"] as? [[String: Any]] else { throw FormaError.invalidResponse }
                for block in content {
                    switch block["type"] as? String {
                    case "refusal": throw FormaError.refused
                    case "output_text":
                        guard text == nil, let value = block["text"] as? String else { throw FormaError.invalidOutput }
                        text = value
                    default: throw FormaError.invalidOutput
                    }
                }
            }
            guard let text else { throw FormaError.invalidOutput }
            return text
        case .anthropic:
            switch envelope["stop_reason"] as? String {
            case "end_turn": break
            case "refusal": throw FormaError.refused
            case "max_tokens", "model_context_window_exceeded": throw FormaError.invalidOutput
            default: throw FormaError.invalidResponse
            }
            guard let content = envelope["content"] as? [[String: Any]] else { throw FormaError.invalidResponse }
            guard content.count == 1, let block = content.first,
                  block["type"] as? String == "text", let text = block["text"] as? String else {
                throw FormaError.invalidOutput
            }
            return text
        }
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(number.stringValue), count >= 0 else { return nil }
        return count
    }

    private static func validKey(_ key: String) -> Bool {
        let bytes = key.utf8
        return !bytes.isEmpty && bytes.count <= 4_096 && bytes.allSatisfy { (33...126).contains($0) }
    }

    private static func validModelID(_ model: String) -> Bool {
        let bytes = model.utf8
        return !bytes.isEmpty && bytes.count <= 128 && !model.lowercased().hasPrefix("sk-") &&
            bytes.allSatisfy { byte in
                switch byte {
                case 45...46, 48...58, 65...90, 95, 97...122: true
                default: false
                }
            }
    }
}

private final class RejectProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
