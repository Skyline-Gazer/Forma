import CoreFoundation
import Foundation

/// The shared HTTP surface for every provider call: the ephemeral session that
/// refuses redirects and stores no cookies, the bounded response read, the
/// status-to-error mapping, the native structured-output request bodies and the
/// per-provider response parsing.
///
/// PLAN §6.2 requires one thin transport over the two native APIs rather than a
/// third abstraction, and the probe and the mapping engine must not drift into
/// two different notions of "a provider failed".
struct ProviderTransport: Sendable {
    static let maximumResponseBytes = 64 * 1024
    /// A mapping answer for a batch is larger than a probe answer, so the
    /// response bound scales with the request; the ceiling stays explicit.
    static let maximumMappingResponseBytes = 2 * 1024 * 1024

    let session: URLSession

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    struct StructuredRequest: Sendable {
        let provider: ProbeProvider
        let model: String
        /// The schema name the provider records for this format, so a probe and
        /// a mapping request stay distinguishable in provider-side history.
        let name: String
        let system: String?
        let payload: String
        let schema: Data
        let maxOutputTokens: Int
    }

    func makeRequest(_ request: StructuredRequest, key: String) throws -> URLRequest {
        let schema = try JSONSerialization.jsonObject(with: request.schema)
        // Strict mode is what makes `additionalProperties: false` binding on the
        // provider side as well: a permissive format lets a model add identity
        // fields back in.
        var format: [String: Any] = ["type": "json_schema", "schema": schema, "strict": true]
        let endpoint: URL
        let body: [String: Any]
        let text = request.system.map { "\($0)\n\n" + request.payload } ?? request.payload
        switch request.provider {
        case .openAI:
            endpoint = URL(string: "https://api.openai.com/v1/responses")!
            format["name"] = request.name
            body = [
                "model": request.model,
                "input": text,
                "text": ["format": format],
                "max_output_tokens": request.maxOutputTokens,
                // Nothing may be retained server-side: the payload carries file
                // names and short excerpts from a private archive.
                "store": false,
            ]
        case .anthropic:
            endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
            var message: [String: Any] = [
                "model": request.model,
                "max_tokens": request.maxOutputTokens,
                "messages": [["role": "user", "content": request.payload]],
                "output_config": ["format": format],
            ]
            if let system = request.system { message["system"] = system }
            body = message
        }
        var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        switch request.provider {
        case .openAI:
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    func response(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: Self.redirectPolicy)
        do {
            guard let http = response as? HTTPURLResponse else { throw FormaError.invalidResponse }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw FormaError.unauthorized
            case 429: throw FormaError.remoteStatus(429)
            default: throw FormaError.remoteStatus(http.statusCode)
            }
            guard http.expectedContentLength <= Int64(limit) else { throw FormaError.invalidResponse }
            var body = Data()
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard body.count < limit else { throw FormaError.invalidResponse }
                body.append(byte)
            }
            return (body, http)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    /// The text a provider returned, or a specific failure. Refusal, truncation
    /// and an unparseable envelope are different outcomes with different
    /// recovery rules, so they must not collapse into one error.
    func outputText(from envelope: [String: Any], provider: ProbeProvider) throws -> String {
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

    struct Usage: Sendable, Equatable {
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheCreation: Int?
    }

    func usage(from envelope: [String: Any], provider: ProbeProvider) -> Usage {
        guard let values = envelope["usage"] as? [String: Any] else { return Usage() }
        switch provider {
        case .openAI:
            let details = values["input_tokens_details"] as? [String: Any]
            return Usage(input: Self.count(values["input_tokens"]), output: Self.count(values["output_tokens"]),
                         cacheRead: Self.count(details?["cached_tokens"]), cacheCreation: nil)
        case .anthropic:
            return Usage(input: Self.count(values["input_tokens"]), output: Self.count(values["output_tokens"]),
                         cacheRead: Self.count(values["cache_read_input_tokens"]),
                         cacheCreation: Self.count(values["cache_creation_input_tokens"]))
        }
    }

    /// The model that actually answered, when the provider reports one and the
    /// reported id cannot carry the key.
    func reportedModel(from envelope: [String: Any], key: String) -> String? {
        guard let model = envelope["model"] as? String, Self.validModelID(model), !model.contains(key) else {
            return nil
        }
        return model
    }

    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let parsed = Int(number.stringValue), parsed >= 0 else { return nil }
        return parsed
    }

    static func validKey(_ key: String) -> Bool {
        let bytes = key.utf8
        return !bytes.isEmpty && bytes.count <= 4_096 && bytes.allSatisfy { (33...126).contains($0) }
    }

    static func validModelID(_ model: String) -> Bool {
        let bytes = model.utf8
        return !bytes.isEmpty && bytes.count <= 128 && !model.lowercased().hasPrefix("sk-")
            && bytes.allSatisfy { byte in
                switch byte {
                case 45...46, 48...58, 65...90, 95, 97...122: true
                default: false
                }
            }
    }

    /// `Retry-After` is honoured only inside a bounded window: an unbounded wait
    /// turns a rate limit into a task the user cannot cancel.
    static func retryDelay(after response: HTTPURLResponse?, attempt: Int) -> TimeInterval? {
        guard attempt < 2 else { return nil }
        if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
            return min(max(seconds, 0), 30)
        }
        return attempt == 0 ? 1 : 4
    }

    private static let redirectPolicy = RejectProviderRedirects()
}

final class RejectProviderRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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
