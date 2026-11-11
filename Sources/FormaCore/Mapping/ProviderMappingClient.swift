import Foundation

/// One provider mapping attempt and everything a report needs about it.
public struct MappingAttempt: Sendable, Equatable {
    /// Non-nil only when the answer satisfied the artifact schema.
    public let proposal: MappingProposal?
    /// The schema rules the answer broke, used for the single repair call and
    /// for the exception record.
    public let violations: [ArtifactSchema.Violation]
    public let error: FormaError?
    public let modelID: String?
    public let usage: MappingUsage
    public let latencyMilliseconds: Int
    /// Provider requests actually made for this batch, including the repair call.
    public let requests: Int
    public let payloadDigest: String

    public init(proposal: MappingProposal?, violations: [ArtifactSchema.Violation] = [], error: FormaError? = nil,
                modelID: String? = nil, usage: MappingUsage = MappingUsage(), latencyMilliseconds: Int = 0,
                requests: Int = 0, payloadDigest: String = "") {
        self.proposal = proposal
        self.violations = violations
        self.error = error
        self.modelID = modelID
        self.usage = usage
        self.latencyMilliseconds = latencyMilliseconds
        self.requests = requests
        self.payloadDigest = payloadDigest
    }

    public var outcome: MappingOutcome {
        if let error {
            switch error {
            case .refused: return .refused
            case .invalidOutput: return .invalidOutput
            case .timeout: return .timeout
            case .cancelled: return .cancelled
            case .unauthorized: return .unauthorized
            case .credentialMissing: return .credentialMissing
            case .remoteStatus: return .remoteStatus
            default: return .network
            }
        }
        return proposal == nil ? .truncated : .ok
    }
}

/// Requests a structured mapping answer from a configured provider.
///
/// It reuses the P0 transport, key storage and consent gate rather than opening
/// a second HTTP path, and it is the only place a provider response becomes a
/// `MappingProposal`: the artifact schema is applied before any decoding, so a
/// model that returns identity fields, extra slots or a malformed enum never
/// reaches the validator as data.
public struct ProviderMappingClient: Sendable {
    public static let maximumOutputTokens = 8_000
    public static let repairSuffix = """
        The previous answer broke these output rules. Answer again with the same \
        entry_ref values, correcting only what is listed. Do not add fields.
        """

    private let transport: ProviderTransport
    private let keyStore: any ProviderKeyStore

    public init() {
        self.init(session: ProviderTransport.makeSession(), keyStore: KeychainProviderKeyStore())
    }

    init(session: URLSession, keyStore: any ProviderKeyStore) {
        self.transport = ProviderTransport(session: session)
        self.keyStore = keyStore
    }

    public func saveKey(_ key: String, for provider: ProbeProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderTransport.validKey(trimmed) else { throw FormaError.credentialMissing }
        try keyStore.save(trimmed, for: provider)
    }

    /// The exact bytes a request would send, shown before anything is allowed to
    /// leave the machine.
    public static func preview(profile: MappingProfile, context: ProjectContext, casePack: CasePack,
                               batch: MappingBatch, redaction: RedactionPlan) throws -> Preview {
        let system = MappingPrompt.system(profile: profile, casePack: casePack)
        let payload = try MappingPrompt.payload(profile: profile, context: context, casePack: casePack,
                                                batch: batch, redaction: redaction)
        return Preview(system: system, payload: payload, digest: MappingPrompt.digest(payload: payload,
                                                                                       system: system))
    }

    public struct Preview: Sendable, Equatable {
        public let system: String
        public let payload: Data
        public let digest: String

        /// What the preview screen shows: byte size plus the role inventory, so
        /// a user can judge the exposure without reading their own documents.
        public var byteCount: Int { system.utf8.count + payload.count }
    }

    public func map(provider: ProbeProvider, model: String, allowCloud: Bool,
                    profile: MappingProfile, context: ProjectContext, casePack: CasePack,
                    batch: MappingBatch, redaction: RedactionPlan) async -> MappingAttempt {
        let start = ContinuousClock.now
        let preview: Preview
        do {
            preview = try Self.preview(profile: profile, context: context, casePack: casePack,
                                        batch: batch, redaction: redaction)
        } catch {
            return MappingAttempt(proposal: nil, error: .incompatible)
        }
        guard let schema = Self.proposalSchemaData() else {
            return MappingAttempt(proposal: nil, error: .incompatible, payloadDigest: preview.digest)
        }

        var usage = MappingUsage()
        var requests = 0
        var reportedModel: String?
        var violations: [ArtifactSchema.Violation] = []
        var answer: String?
        var failure: FormaError?

        do {
            try Task.checkCancellation()
            guard allowCloud else { throw FormaError.unauthorized }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ProviderTransport.validModelID(trimmed) else { throw FormaError.incompatible }
            guard let key = try keyStore.load(for: provider), ProviderTransport.validKey(key) else {
                throw FormaError.credentialMissing
            }
            guard !trimmed.contains(key) else { throw FormaError.incompatible }

            var payload = preview.payload
            for round in 0...1 {
                let sent = try await send(provider: provider, model: trimmed, key: key, system: preview.system,
                                          payload: payload, schema: schema)
                usage = usage + sent.usage
                requests += sent.requests
                reportedModel = sent.reportedModel ?? reportedModel
                let broken = try Self.violations(of: sent.text, schema: schema)
                guard !broken.isEmpty else {
                    violations = []
                    answer = sent.text
                    break
                }
                violations = broken
                guard round == 0 else { break }
                // Exactly one repair call, carrying the rule violations and
                // nothing else. A second failure is a hold, not another attempt.
                payload = try Self.repairPayload(original: preview.payload, violations: broken)
            }
        } catch is CancellationError {
            failure = .cancelled
        } catch let error as FormaError {
            failure = error
        } catch {
            failure = .invalidResponse
        }

        var proposal: MappingProposal?
        if failure == nil, violations.isEmpty, let answer {
            do {
                proposal = try JSONDecoder().decode(MappingProposal.self, from: Data(answer.utf8))
            } catch {
                failure = .invalidOutput
            }
        } else if failure == nil, !violations.isEmpty {
            failure = .invalidOutput
        }

        let elapsed = start.duration(to: .now).components
        return MappingAttempt(
            proposal: proposal, violations: violations, error: failure, modelID: reportedModel, usage: usage,
            latencyMilliseconds: Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000),
            requests: requests, payloadDigest: preview.digest
        )
    }

    /// The outcome of one semantic request.
    struct Sent {
        let text: String
        let usage: MappingUsage
        let requests: Int
        let reportedModel: String?
    }

    /// One semantic request, with the transport's own bounded rate-limit retry
    /// inside it. That retry cannot reach into the repair round: a rate limit
    /// and a schema violation are different failures needing different
    /// budgets, and sharing one loop turned "request plus one repair" into
    /// "request only", so an answer that was merely non-compliant came back as
    /// an unexplained hold.
    private func send(provider: ProbeProvider, model: String, key: String, system: String,
                      payload: Data, schema: Data) async throws -> Sent {
        var usage = MappingUsage()
        var requests = 0
        var reportedModel: String?
        var rateLimitRetried = false
        while true {
            let request = try transport.makeRequest(ProviderTransport.StructuredRequest(
                provider: provider, model: model, name: "forma_mapping", system: system,
                payload: String(decoding: payload, as: UTF8.self), schema: schema,
                maxOutputTokens: Self.maximumOutputTokens
            ), key: key)
            requests += 1
            do {
                let (body, _) = try await transport.response(
                    request, limit: ProviderTransport.maximumMappingResponseBytes
                )
                guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    throw FormaError.invalidResponse
                }
                reportedModel = transport.reportedModel(from: envelope, key: key) ?? reportedModel
                usage = usage + MappingUsage(transport.usage(from: envelope, provider: provider))
                return Sent(text: try transport.outputText(from: envelope, provider: provider), usage: usage,
                            requests: requests, reportedModel: reportedModel)
            } catch let error as FormaError {
                // A rate limit is retried once, here and nowhere else.
                guard !rateLimitRetried, case .remoteStatus(let code) = error, code == 429,
                      let delay = ProviderTransport.retryDelay(attempt: 0) else { throw error }
                rateLimitRetried = true
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Schema violations in an answer, or an empty list when it is acceptable.
    static func violations(of text: String, schema: Data) throws -> [ArtifactSchema.Violation] {
        try ArtifactSchema(id: "proposal-runtime", schemaVersion: "1.0", data: schema)
            .violations(Data(text.utf8))
    }

    static func proposalSchemaData() -> Data? {
        guard let url = Bundle.module.url(forResource: "proposal-1.0.schema", withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func repairPayload(original: Data, violations: [ArtifactSchema.Violation]) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw FormaError.invalidOutput
        }
        root["repair_instructions"] = [repairSuffix] + violations.prefix(20).map(\.logSummary)
        guard JSONSerialization.isValidJSONObject(root) else { throw FormaError.invalidOutput }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// The transport's accounting re-exported in the mapping type. This is the
/// only conversion: the probe and a mapping run parse a provider's usage with
/// the same code, so "the provider reported N tokens" means one thing in both
/// paths and a field rename is repaired once.
extension MappingUsage {
    init(_ usage: ProviderTransport.Usage) {
        self.init(input: usage.input, output: usage.output,
                  cacheRead: usage.cacheRead, cacheCreation: usage.cacheCreation)
    }
}
