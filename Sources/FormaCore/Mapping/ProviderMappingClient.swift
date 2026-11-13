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
    /// Provider requests actually made for this batch: the first ask, any
    /// rate-limit retry inside it, and the single repair call.
    public let requests: Int
    /// How many of those requests were transport retries after a 429. Kept
    /// apart from `requests` so a report can tell "the provider pushed back"
    /// from "the answer needed fixing" instead of reading one number.
    public let rateLimitRetries: Int
    public let payloadDigest: String
    /// Milliseconds until the first token, when a streaming call observed one.
    ///
    /// Nil for every non-streaming request, which is the whole point of the field
    /// being separate from `latencyMilliseconds`: a request that returns its whole
    /// answer at once has exactly one observation, and reporting it as a first-token
    /// latency would make a slow provider look like it answered immediately. The
    /// live client never sets this; only an answerer that really streams can.
    public let timeToFirstTokenMilliseconds: Int?
    /// One ticket per wire request that actually left, in order. Each carries
    /// its own semantic (layer 1) and wire (layers 2+3) digest, so a repair or
    /// retry is never confused with the previewed first ask.
    public let requestIdentities: [EgressTicket]
    /// The reason the gate refused a send. Nil when every send was allowed.
    public let egressDenial: EgressDenial?

    public init(proposal: MappingProposal?, violations: [ArtifactSchema.Violation] = [], error: FormaError? = nil,
                modelID: String? = nil, usage: MappingUsage = MappingUsage(), latencyMilliseconds: Int = 0,
                requests: Int = 0, rateLimitRetries: Int = 0, payloadDigest: String = "",
                timeToFirstTokenMilliseconds: Int? = nil, requestIdentities: [EgressTicket] = [],
                egressDenial: EgressDenial? = nil) {
        self.proposal = proposal
        self.violations = violations
        self.error = error
        self.modelID = modelID
        self.usage = usage
        self.latencyMilliseconds = latencyMilliseconds
        self.requests = requests
        self.rateLimitRetries = rateLimitRetries
        self.payloadDigest = payloadDigest
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.requestIdentities = requestIdentities
        self.egressDenial = egressDenial
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
    /// The grant under which this client may send. A client built without one
    /// can save keys and build previews, but every cloud send is refused.
    private let authorization: EgressAuthorization?

    public init() {
        self.init(session: ProviderTransport.makeSession(), keyStore: KeychainProviderKeyStore())
    }

    public init(authorization: EgressAuthorization) {
        self.init(session: ProviderTransport.makeSession(), keyStore: KeychainProviderKeyStore(),
                  authorization: authorization)
    }

    init(session: URLSession, keyStore: any ProviderKeyStore,
         authorization: EgressAuthorization? = nil) {
        self.transport = ProviderTransport(session: session)
        self.keyStore = keyStore
        self.authorization = authorization
    }

    public func saveKey(_ key: String, for provider: ProbeProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderTransport.validKey(trimmed) else { throw FormaError.credentialMissing }
        try keyStore.save(trimmed, for: provider)
    }

    /// Layer-1 (semantic) bytes a request would send, shown before anything is
    /// allowed to leave. `map` rebuilds this through the same function and the
    /// gate checks its digest at send time. It is deliberately *not* the wire
    /// body: model, schema, token cap and headers are added by the transport.
    public static func preview(profile: MappingProfile, context: ProjectContext, casePack: CasePack,
                               batch: MappingBatch, redaction: RedactionPlan) throws -> Preview {
        let system = MappingPrompt.system(profile: profile, casePack: casePack, redaction: redaction)
        let payload = try MappingPrompt.payload(profile: profile, context: context, casePack: casePack,
                                                batch: batch, redaction: redaction)
        return Preview(system: system, payload: payload, digest: MappingPrompt.digest(payload: payload,
                                                                                       system: system),
                       redactionVersion: MappingPrompt.redactionVersion(for: redaction))
    }

    public struct Preview: Sendable, Equatable {
        public let system: String
        public let payload: Data
        public let digest: String
        /// "identity" when no known-term substitution was applied. The UI shows
        /// this instead of claiming a redaction policy that was not used.
        public let redactionVersion: String

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
        var rateLimitRetries = 0
        var reportedModel: String?
        var violations: [ArtifactSchema.Violation] = []
        var answer: String?
        var failure: FormaError?
        var identities: [EgressTicket] = []
        var denial: EgressDenial?

        do {
            try Task.checkCancellation()
            guard allowCloud else { throw FormaError.unauthorized }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ProviderTransport.validModelID(trimmed) else { throw FormaError.incompatible }
            guard let key = try keyStore.load(for: provider), ProviderTransport.validKey(key) else {
                throw FormaError.credentialMissing
            }
            guard !trimmed.contains(key) else { throw FormaError.incompatible }

            // One assessment over the semantic payload; every round states its
            // own identity, so a repair cannot reuse the first ask's ticket.
            let assessment = SensitiveContentScanner.assess(
                payload: String(decoding: preview.payload, as: UTF8.self),
                system: preview.system, plan: redaction)
            var payload = preview.payload
            for round in 0...1 {
                let semanticDigest = MappingPrompt.digest(payload: payload, system: preview.system)
                var categories: Set<EgressDataCategory> = [
                    .filePaths, .evidenceExcerpts, .projectContext, .casePackExamples,
                    .profileRules, .systemPrompt,
                ]
                if round == 1 { categories.insert(.repairInstructions) }
                let sent = await send(provider: provider, model: trimmed, key: key, system: preview.system,
                                      payload: payload, schema: schema, semanticDigest: semanticDigest,
                                      categories: categories, assessment: assessment, redaction: redaction,
                                      kind: round == 0 ? .firstAsk : .repair,
                                      previewDigest: preview.digest, allowCloud: allowCloud)
                // Accounting first, always. A request that failed still reached
                // the provider and still cost something; dropping the count on
                // the error path reported a rate-limited run as making no
                // requests at all, which is the opposite of what a report is for.
                usage = usage + sent.usage
                requests += sent.requests
                rateLimitRetries += sent.rateLimitRetries
                reportedModel = sent.reportedModel ?? reportedModel
                identities += sent.identities
                if let refused = sent.denial { denial = refused }
                if let error = sent.error { throw error }
                let text = sent.text ?? ""
                let broken = try Self.violations(of: text, schema: schema)
                guard !broken.isEmpty else {
                    violations = []
                    answer = text
                    break
                }
                violations = broken
                guard round == 0 else { break }
                // Exactly one repair call, carrying the rule violations and
                // nothing else. It cannot widen the data range: repair_instructions
                // holds rule names and JSON pointers, never the model's answer.
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
            requests: requests, rateLimitRetries: rateLimitRetries, payloadDigest: preview.digest,
            requestIdentities: identities, egressDenial: denial
        )
    }

    /// The outcome of one semantic request: the answer if there was one, the
    /// accounting either way, and the failure if the request did not succeed.
    struct Sent {
        let text: String?
        let usage: MappingUsage
        let requests: Int
        let rateLimitRetries: Int
        let reportedModel: String?
        let error: FormaError?
        let identities: [EgressTicket]
        let denial: EgressDenial?

        init(text: String?, usage: MappingUsage, requests: Int, rateLimitRetries: Int,
             reportedModel: String?, error: FormaError?,
             identities: [EgressTicket] = [], denial: EgressDenial? = nil) {
            self.text = text
            self.usage = usage
            self.requests = requests
            self.rateLimitRetries = rateLimitRetries
            self.reportedModel = reportedModel
            self.error = error
            self.identities = identities
            self.denial = denial
        }
    }

    /// One semantic request, with the transport's own bounded rate-limit retry
    /// inside it. That retry cannot reach into the repair round: a rate limit
    /// and a schema violation are different failures needing different
    /// budgets, and sharing one loop turned "request plus one repair" into
    /// "request only", so an answer that was merely non-compliant came back as
    /// an unexplained hold.
    ///
    /// It returns rather than throws, because every path out of here has made
    /// at least one request, and the count must survive the failure.
    private func send(provider: ProbeProvider, model: String, key: String, system: String,
                      payload: Data, schema: Data, semanticDigest: String,
                      categories: Set<EgressDataCategory>, assessment: SensitiveContentAssessment,
                      redaction: RedactionPlan, kind: EgressRequestKind,
                      previewDigest: String, allowCloud: Bool) async -> Sent {
        var usage = MappingUsage()
        var requests = 0
        var rateLimitRetries = 0
        var reportedModel: String?
        var identities: [EgressTicket] = []
        var denial: EgressDenial?
        var rateLimitAttempt = 0
        let endpoint = EgressEndpoint.provider(provider)
        while true {
            // Cancellation or a revoked grant must never produce a补发 after a
            // rate limit: re-check before every wire request, not only at entry.
            if Task.isCancelled {
                return Sent(text: nil, usage: usage, requests: requests,
                            rateLimitRetries: rateLimitRetries, reportedModel: reportedModel,
                            error: .cancelled, identities: identities, denial: denial)
            }
            let wireKind: EgressRequestKind = rateLimitAttempt > 0 ? .rateLimitRetry : kind
            let request: URLRequest
            do {
                request = try transport.makeRequest(ProviderTransport.StructuredRequest(
                    provider: provider, model: model, name: "forma_mapping", system: system,
                    payload: String(decoding: payload, as: UTF8.self), schema: schema,
                    maxOutputTokens: Self.maximumOutputTokens
                ), key: key)
            } catch let error as FormaError {
                return Sent(text: nil, usage: usage, requests: requests, rateLimitRetries: rateLimitRetries,
                            reportedModel: reportedModel, error: error,
                            identities: identities, denial: denial)
            } catch {
                return Sent(text: nil, usage: usage, requests: requests, rateLimitRetries: rateLimitRetries,
                            reportedModel: reportedModel, error: .network,
                            identities: identities, denial: denial)
            }

            // Layer 1 identity is the semantic payload digest; layer 2+3 identity
            // is a digest of the provider body and wire metadata with credentials
            // reduced to "present". They are never the same value.
            let facts = EgressRequest(
                provider: provider, model: model, endpoint: endpoint, mode: .cloud,
                categories: categories, redactionVersion: MappingPrompt.redactionVersion(for: redaction),
                identitySubstitution: redaction.isIdentity, semanticDigest: semanticDigest,
                wireDigest: EgressWireIdentity.digest(of: request), kind: wireKind,
                assessment: assessment, credentialPresent: true,
                endpointURL: request.url ?? endpoint.canonicalURL)
            let decision = EgressGate.decide(request: facts, authorization: authorization,
                                             allowCloud: allowCloud, previewDigest: previewDigest)
            FormaDiagnostics.egress(decision)
            guard let ticket = decision.ticket else {
                denial = decision.denial
                return Sent(text: nil, usage: usage, requests: requests,
                            rateLimitRetries: rateLimitRetries, reportedModel: reportedModel,
                            error: .unauthorized, identities: identities, denial: denial)
            }
            // A denied gate made no request; an allowed one is counted even if
            // the network then fails. This is the 2b accounting rule, unchanged.
            requests += 1
            identities.append(ticket)
            do {
                let (body, _) = try await transport.response(
                    request, limit: ProviderTransport.maximumMappingResponseBytes, ticket: ticket
                )
                guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    throw FormaError.invalidResponse
                }
                reportedModel = transport.reportedModel(from: envelope, key: key) ?? reportedModel
                usage = usage + MappingUsage(transport.usage(from: envelope, provider: provider))
                return Sent(text: try transport.outputText(from: envelope, provider: provider), usage: usage,
                            requests: requests, rateLimitRetries: rateLimitRetries,
                            reportedModel: reportedModel, error: nil,
                            identities: identities, denial: denial)
            } catch let limited as ProviderTransport.RateLimited {
                // A rate limit gets one retry, and the provider's own wait when
                // it gave one. A second rate limit is reported as the status it
                // is, because a mapping run that waits indefinitely cannot be
                // cancelled by the person watching it.
                guard rateLimitAttempt == 0 else {
                    return Sent(text: nil, usage: usage, requests: requests,
                                rateLimitRetries: rateLimitRetries,
                                reportedModel: reportedModel, error: limited.asFormaError,
                                identities: identities, denial: denial)
                }
                let delay = ProviderTransport.retryDelay(retryAfter: limited.retryAfter)
                rateLimitAttempt += 1
                rateLimitRetries += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // A cancelled wait ends the attempt; it must not fall
                    // through into another request.
                    return Sent(text: nil, usage: usage, requests: requests,
                                rateLimitRetries: rateLimitRetries,
                                reportedModel: reportedModel, error: .cancelled,
                                identities: identities, denial: denial)
                }
            } catch let error as FormaError {
                return Sent(text: nil, usage: usage, requests: requests, rateLimitRetries: rateLimitRetries,
                            reportedModel: reportedModel, error: error,
                            identities: identities, denial: denial)
            } catch {
                return Sent(text: nil, usage: usage, requests: requests, rateLimitRetries: rateLimitRetries,
                            reportedModel: reportedModel, error: .network,
                            identities: identities, denial: denial)
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
