import Foundation

public struct ProviderProbeResult: Sendable {
    public let provider: ProbeProvider
    /// The reported model identifier when usable, otherwise the configured identifier.
    public internal(set) var modelID: String?
    /// The provider's reported input count. Anthropic reports cache counts separately.
    public internal(set) var inputTokens: Int?
    public internal(set) var outputTokens: Int?
    public internal(set) var cacheReadInputTokens: Int?
    public internal(set) var cacheCreationInputTokens: Int?
    public internal(set) var latencyMilliseconds: Int = 0
    public internal(set) var error: FormaError?
    public internal(set) var output: ProviderProbeOutput?
}

// UserDefaults serializes its individual reads and writes across threads.
struct ProviderProbeTelemetry: @unchecked Sendable {
    let defaults: UserDefaults

    func save(_ result: ProviderProbeResult) {
        var entry: [String: Any] = ["latencyMilliseconds": result.latencyMilliseconds]
        entry["modelID"] = result.modelID
        entry["inputTokens"] = result.inputTokens
        entry["outputTokens"] = result.outputTokens
        entry["cacheReadInputTokens"] = result.cacheReadInputTokens
        entry["cacheCreationInputTokens"] = result.cacheCreationInputTokens
        entry["errorCode"] = result.error?.code
        if case .remoteStatus(let status)? = result.error {
            entry["httpStatus"] = status
        }
        defaults.set(entry, forKey: key(for: result.provider))
    }

    func lastResult(for provider: ProbeProvider) -> ProviderProbeResult? {
        guard let entry = defaults.dictionary(forKey: key(for: provider)),
              let latency = entry["latencyMilliseconds"] as? Int, latency >= 0 else { return nil }

        let error: FormaError?
        switch entry["errorCode"] as? String {
        case nil: error = nil
        case "cancelled": error = .cancelled
        case "invalid_response": error = .invalidResponse
        case "timeout": error = .timeout
        case "unauthorized": error = .unauthorized
        case "network": error = .network
        case "refused": error = .refused
        case "invalid_output": error = .invalidOutput
        case "remote_status":
            guard let status = entry["httpStatus"] as? Int, (100...599).contains(status) else { return nil }
            error = .remoteStatus(status)
        default: return nil
        }

        return ProviderProbeResult(
            provider: provider,
            modelID: entry["modelID"] as? String,
            inputTokens: entry["inputTokens"] as? Int,
            outputTokens: entry["outputTokens"] as? Int,
            cacheReadInputTokens: entry["cacheReadInputTokens"] as? Int,
            cacheCreationInputTokens: entry["cacheCreationInputTokens"] as? Int,
            latencyMilliseconds: latency,
            error: error
        )
    }

    private func key(for provider: ProbeProvider) -> String {
        "forma.providerProbe.lastRun.v1.\(provider.rawValue)"
    }
}
