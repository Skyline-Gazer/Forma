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

    /// The probe and the mapping engine share one transport, so a provider
    /// failure means the same thing in both places.
    private let transport: ProviderTransport
    private let keyStore: any ProviderKeyStore
    private let telemetry: ProviderProbeTelemetry?

    public init() {
        self.init(session: ProviderTransport.makeSession(request: 30, resource: 30),
                  keyStore: KeychainProviderKeyStore(), defaults: .standard)
    }

    init(session: URLSession, keyStore: any ProviderKeyStore, defaults: UserDefaults? = nil) {
        self.transport = ProviderTransport(session: session)
        self.keyStore = keyStore
        self.telemetry = defaults.map(ProviderProbeTelemetry.init)
    }

    public func saveKey(_ key: String, for provider: ProbeProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderTransport.validKey(key) else { throw FormaError.credentialMissing }
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
            guard ProviderTransport.validModelID(model) else { throw FormaError.incompatible }
            guard let key = try keyStore.load(for: provider), ProviderTransport.validKey(key) else {
                result.modelID = model
                throw FormaError.credentialMissing
            }
            guard !model.contains(key) else { throw FormaError.incompatible }
            result.modelID = model

            let schema = try JSONSerialization.data(withJSONObject: ProviderProbeOutput.schema)
            let request = try transport.makeRequest(ProviderTransport.StructuredRequest(
                provider: provider, model: model, name: "forma_probe", system: nil,
                payload: Self.syntheticPrompt, schema: schema, maxOutputTokens: 256
            ), key: key)
            // A probe sends a synthetic sentence, not document data. Its grant
            // is restricted to `.syntheticProbe` and still goes through the one
            // gate: consent alone is not an authorization.
            let semanticDigest = MappingPrompt.digest(payload: Data(Self.syntheticPrompt.utf8), system: "")
            let endpoint = EgressEndpoint.provider(provider)
            let facts = EgressRequest(
                provider: provider, model: model, endpoint: endpoint, mode: .cloud,
                categories: [.syntheticProbe], redactionVersion: RedactionPlan.version,
                identitySubstitution: true, semanticDigest: semanticDigest,
                wireDigest: EgressWireIdentity.digest(of: request), kind: .firstAsk,
                assessment: SensitiveContentScanner.assess(payload: Self.syntheticPrompt, system: "",
                                                            plan: .none),
                credentialPresent: true, endpointURL: request.url ?? endpoint.canonicalURL)
            let decision = EgressGate.decide(request: facts,
                                             authorization: .probe(provider: provider, model: model),
                                             allowCloud: allowCloud, previewDigest: semanticDigest)
            guard let ticket = decision.ticket else { throw FormaError.unauthorized }
            startedRequest = true
            let (body, _) = try await transport.response(request, limit: ProviderTransport.maximumResponseBytes,
                                                         ticket: ticket)
            try Task.checkCancellation()
            guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                throw FormaError.invalidResponse
            }
            if let reported = transport.reportedModel(from: envelope, key: key) { result.modelID = reported }
            let usage = transport.usage(from: envelope, provider: provider)
            result.inputTokens = usage.input
            result.outputTokens = usage.output
            result.cacheReadInputTokens = usage.cacheRead
            result.cacheCreationInputTokens = usage.cacheCreation
            let output = try transport.outputText(from: envelope, provider: provider)
            result.output = try ProviderProbeOutput(validating: output)
        } catch is CancellationError {
            result.error = .cancelled
        } catch let limited as ProviderTransport.RateLimited {
            // The probe reports the status it was told. The wait belongs to the
            // mapping path, and the recorded diagnostic stays a plain HTTP
            // status for the settings screen and the acceptance report.
            result.error = limited.asFormaError
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
}
