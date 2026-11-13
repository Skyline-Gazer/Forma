import Foundation
import Testing
@testable import FormaCore

/// The single egress gate: pure decisions over stated facts. No test here opens
/// a socket; `PrivacyEgressTests` covers the stub-observed send paths.
@Suite("Egress authorization")
struct EgressContractTests {
    private let canary = "CANARY-客户甲-7f3a91@example.invalid"
    private let semantic = String(repeating: "a", count: 64)
    private let wire = String(repeating: "b", count: 64)
    private let model = "gpt-4o-mini"
    private let provider = ProbeProvider.openAI
    private let endpoint = EgressEndpoint.provider(.openAI)
    private let categories: Set<EgressDataCategory> = [
        .filePaths, .evidenceExcerpts, .projectContext, .casePackExamples,
        .profileRules, .systemPrompt, .repairInstructions,
    ]

    private func scope(provider: ProbeProvider? = .openAI,
                       model: String = "gpt-4o-mini",
                       endpoint: EgressEndpoint = .provider(.openAI),
                       mode: EgressMode = .cloud,
                       categories: Set<EgressDataCategory>? = nil,
                       redactionVersion: String = RedactionPlan.version,
                       identitySubstitution: Bool = true,
                       version: String = EgressContract.version,
                       scopeVersion: String = EgressContract.scopeVersion) -> EgressScope {
        EgressScope(provider: provider, model: model, endpoint: endpoint, mode: mode,
                    categories: categories ?? self.categories, redactionVersion: redactionVersion,
                    identitySubstitution: identitySubstitution, version: version,
                    scopeVersion: scopeVersion)
    }

    private func grant(_ scope: EgressScope? = nil, previewDigest: String? = nil,
                       binding: EgressBinding = .dataRange,
                       allowsReview: Bool = false,
                       expiresAt: Date? = nil) -> EgressAuthorization {
        EgressAuthorization(scope: scope ?? self.scope(), expiresAt: expiresAt,
                            previewDigest: previewDigest, binding: binding,
                            allowsReviewRequiredContent: allowsReview)
    }

    private func request(assessment: SensitiveContentAssessment = .allowed,
                         categories: Set<EgressDataCategory>? = nil,
                         semanticDigest: String? = nil, wireDigest: String? = nil,
                         kind: EgressRequestKind = .firstAsk,
                         mode: EgressMode = .cloud,
                         endpoint: EgressEndpoint = .provider(.openAI),
                         endpointURL: URL? = nil,
                         credentialPresent: Bool = true,
                         identitySubstitution: Bool = true,
                         redactionVersion: String = RedactionPlan.version,
                         model: String = "gpt-4o-mini",
                         provider: ProbeProvider = .openAI) -> EgressRequest {
        EgressRequest(provider: provider, model: model, endpoint: endpoint, mode: mode,
                      categories: categories ?? self.categories,
                      redactionVersion: redactionVersion,
                      identitySubstitution: identitySubstitution,
                      semanticDigest: semanticDigest ?? semantic,
                      wireDigest: wireDigest ?? wire, kind: kind, assessment: assessment,
                      credentialPresent: credentialPresent,
                      endpointURL: endpointURL ?? endpoint.canonicalURL)
    }

    private func decide(_ request: EgressRequest, _ grant: EgressAuthorization? = nil,
                        allowCloud: Bool = true, previewDigest: String? = nil) -> EgressDecision {
        EgressGate.decide(request: request, authorization: grant ?? self.grant(),
                          allowCloud: allowCloud, previewDigest: previewDigest)
    }

    // MARK: - Authorization

    @Test("cloud egress is denied by default")
    func cloudDeniedByDefault() {
        let decision = decide(request(), allowCloud: false)
        #expect(!decision.isAllowed)
        #expect(decision.denial?.reason == .cloudDisabled)
    }

    @Test("consent without a grant is not an authorization")
    func authorizationMissing() {
        let decision = EgressGate.decide(request: request(), authorization: nil, allowCloud: true,
                                         previewDigest: nil)
        #expect(decision.denial?.reason == .authorizationMissing)
    }

    @Test("no credential means no request")
    func credentialMissing() {
        let decision = decide(request(credentialPresent: false))
        #expect(decision.denial?.reason == .credentialMissing)
    }

    @Test("a mismatched scope version cannot be used silently")
    func scopeVersionMismatch() {
        #expect(decide(request(), grant(scope(version: "egress.v0"))).denial?.reason == .scopeVersionMismatch)
        #expect(decide(request(), grant(scope(scopeVersion: "scope.v0"))).denial?.reason == .scopeVersionMismatch)
    }

    @Test("revocation and expiry invalidate the grant")
    func revocationAndExpiry() {
        #expect(decide(request(), grant().revoking()).denial?.reason == .scopeRevoked)
        let expired = grant(expiresAt: Date(timeIntervalSinceNow: -60))
        #expect(decide(request(), expired).denial?.reason == .scopeExpired)
    }

    @Test("provider, model, endpoint and mode mismatches are refused")
    func scopeIdentityMismatches() {
        #expect(decide(request(provider: .anthropic), grant()).denial?.reason == .providerMismatch)
        #expect(decide(request(model: "other-model"), grant()).denial?.reason == .modelMismatch)
        #expect(decide(request(endpoint: .provider(.anthropic)), grant()).denial?.reason == .endpointMismatch)
        #expect(decide(request(mode: .local), grant()).denial?.reason == .modeMismatch)
    }

    @Test("a rewritten endpoint URL cannot escape the authorized scope")
    func redirectCannotEscapeScope() async throws {
        let elsewhere = URL(string: "https://evil.invalid/v1/messages")!
        let decision = decide(request(endpointURL: elsewhere))
        #expect(decision.denial?.reason == .endpointMismatch)
        // The transport repeats the comparison immediately before the wire call.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProbeURLProtocol.self]
        let transport = ProviderTransport(session: URLSession(configuration: sessionConfiguration))
        let ticket = EgressTicket(authorizationID: "x", scopeDigest: "s", scopeVersion: "scope.v1",
                                  provider: "openai", model: model, endpoint: endpoint.identity,
                                  mode: .cloud, semanticDigest: semantic, wireDigest: wire,
                                  kind: .firstAsk, assessment: .allowed, categories: categories,
                                  redactionVersion: RedactionPlan.version, identitySubstitution: true,
                                  decidedAt: Date())
        var urlRequest = URLRequest(url: elsewhere)
        urlRequest.httpMethod = "POST"
        do {
            _ = try await transport.response(urlRequest, limit: 1024, ticket: ticket)
            Issue.record("a mismatched endpoint must never reach session.bytes")
        } catch let error as FormaError {
            #expect(error == .unauthorized)
        }
    }

    @Test("a local URL is not safe just because the user named it")
    func localModeContract() {
        let local = EgressEndpoint.local(URL(string: "http://127.0.0.1:8080/v1/messages")!)
        let localRequest = request(categories: [.syntheticProbe], mode: .local, endpoint: local,
                                   endpointURL: local.canonicalURL)
        // No grant at all: a URL is never an authorization.
        #expect(EgressGate.decide(request: localRequest, authorization: nil, allowCloud: false,
                                  previewDigest: nil).denial?.reason == .authorizationMissing)
        // A cloud grant cannot be reused for local mode.
        #expect(!decide(localRequest, allowCloud: false).isAllowed)
        // A dedicated local grant with the same exact endpoint is allowed.
        let localGrant = grant(scope(provider: nil, endpoint: local, mode: .local,
                                     categories: [.syntheticProbe]))
        let allowed = EgressGate.decide(request: localRequest, authorization: localGrant,
                                        allowCloud: false, previewDigest: nil)
        #expect(allowed.isAllowed)
    }

    @Test("a preview that no longer matches the bytes is refused under exact binding")
    func previewMismatch() {
        let exact = grant(previewDigest: String(repeating: "c", count: 64), binding: .exactPayload)
        #expect(decide(request(), exact).denial?.reason == .previewMismatch)
        let matching = grant(previewDigest: semantic, binding: .exactPayload)
        #expect(decide(request(), matching).isAllowed)
    }

    @Test("data categories outside the grant are refused")
    func categoryNotAllowed() {
        let narrow = grant(scope(categories: [.syntheticProbe]))
        #expect(decide(request(), narrow).denial?.reason == .categoryNotAllowed)
    }

    @Test("a redaction-plan change invalidates the grant and identity plans are disclosed")
    func redactionPolicyChanges() {
        #expect(decide(request(redactionVersion: "redaction.v0")).denial?.reason == .redactionVersionMismatch)
        let substituting = grant(scope(identitySubstitution: false))
        #expect(decide(request(identitySubstitution: true), substituting)
            .denial?.reason == .identityRedactionUndisclosed)
        let identity = grant(scope(identitySubstitution: true))
        let allowed = decide(request(identitySubstitution: true), identity)
        #expect(allowed.ticket?.identitySubstitution == true,
                "an identity plan must be visible in the ticket, not hidden behind a version label")
    }

    @Test("unknown sensitive content is refused unless explicitly granted")
    func unknownSensitiveContent() {
        #expect(decide(request(assessment: .reviewRequired)).denial?.reason == .unknownSensitiveContent)
        let explicitlyAllowed = grant(allowsReview: true)
        #expect(decide(request(assessment: .reviewRequired), explicitlyAllowed).isAllowed)
        #expect(decide(request(assessment: .blocked), explicitlyAllowed)
            .denial?.reason == .sensitiveContentBlocked)
    }

    @Test("the semantic digest is never passed off as a wire digest")
    func digestLayersStaySeparate() {
        #expect(decide(request(wireDigest: semantic)).denial?.reason == .wireDigestCollision)
        #expect(decide(request(semanticDigest: "", wireDigest: wire))
            .denial?.reason == .payloadIdentityMissing)
        let ticket = decide(request()).ticket
        #expect(ticket?.semanticDigest == semantic)
        #expect(ticket?.wireDigest == wire)
    }

    // MARK: - Content assessment

    @Test("the scanner separates allowed, redacted, review-required and blocked")
    func scannerClassifiesSyntheticCanaries() {
        let plan = RedactionPlan(terms: ["客户甲有限公司": .customer], salt: "workspace-s")
        #expect(SensitiveContentScanner.assess(payload: "普通正文", system: "", plan: .none) == .allowed)
        #expect(SensitiveContentScanner.assess(payload: "普通正文", system: "", plan: plan) == .redacted)
        #expect(SensitiveContentScanner.assess(payload: "客户甲有限公司", system: "", plan: plan) == .blocked)
        for highRisk in ["联系 ops@corp.example", "sk-abcdefghijklmnop", "13900000000",
                         "https://user:dummy-pass@host.invalid/path", "11010119900307771X"] {
            #expect(SensitiveContentScanner.assess(payload: highRisk, system: "", plan: .none) == .reviewRequired,
                    "unclassified shape must not be called safe: \(highRisk)")
        }
    }

    @Test("an undeclared unknown name is not claimed to be anonymized")
    func noFullAnonymizationClaim() {
        // A bare name the term list does not know cannot be detected by a regex.
        // The contract records the identity plan instead of asserting cleanliness.
        let plan = RedactionPlan.none
        let assessment = SensitiveContentScanner.assess(payload: "联系人 未登记的客户名称", system: "", plan: plan)
        #expect(assessment == .allowed)
        #expect(plan.isIdentity)
        let ticket = decide(request()).ticket
        #expect(ticket?.identitySubstitution == true)
        #expect(ticket?.assessment == .allowed)
    }

    @Test("stable placeholders keep roles distinct and do not mix scopes")
    func roleSeparationAndStability() {
        let plan = RedactionPlan(terms: ["客户甲有限公司": .customer, "示例厂商乙": .vendor,
                                         "我方投标公司丙": .bidder, "张三": .person],
                                salt: "workspace-salt")
        let first = plan.redact(text: "客户甲有限公司 示例厂商乙 我方投标公司丙 张三 报价 1,234,567.89 元")
        let second = plan.redact(text: "客户甲有限公司 示例厂商乙 我方投标公司丙 张三")
        #expect(first == plan.redact(text: "客户甲有限公司 示例厂商乙 我方投标公司丙 张三 报价 1,234,567.89 元"))
        #expect(first.contains("«客户") && first.contains("«厂商") && first.contains("«投标主体"))
        #expect(first.contains("«人员") && first.contains("«金额"))
        #expect(!first.contains("1,234,567.89"), "the amount's value must not survive")
        #expect(second.contains("«金额") == false, "no amount, no invented placeholder")
        #expect(Set([plan.placeholder(for: "客户甲有限公司"), plan.placeholder(for: "示例厂商乙")]).count == 2)
        #expect(scope().crossScopeLinking == "workspace-only",
                "placeholder linkage is an explicit policy, never an accident")
    }

    // MARK: - Log and wire safety

    @Test("tickets and denial codes cannot carry a payload or a credential")
    func logSafeDiagnostics() {
        let ticket = decide(request()).ticket!
        let summary = ticket.logSummary + " " + (EgressDenial(reason: .scopeRevoked).code)
        for forbidden in [canary, "客户甲", "sk-", "Authorization", "x-api-key", "/Users/"] {
            #expect(!summary.contains(forbidden), "a log line leaked \(forbidden)")
        }
        #expect(ticket.logSummary.contains("wire="))
        #expect(ticket.logSummary.contains("semantic="))
    }

    @Test("the redirect delegate refuses a second hop")
    func redirectRefusal() {
        let delegate = RejectProviderRedirects()
        let capture = RedirectCapture()
        let response = HTTPURLResponse(url: endpoint.canonicalURL, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://evil.invalid/collect"])!
        let task = URLSession.shared.dataTask(with: endpoint.canonicalURL)
        defer { task.cancel() }
        delegate.urlSession(URLSession.shared, task: task,
                            willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://evil.invalid/collect")!)) {
            capture.record($0)
        }
        #expect(capture.wasCalled)
        #expect(capture.followedRequest == nil, "a redirect must never produce a second request")
    }

    @Test("the wire digest records credential presence, never credential bytes")
    func wireDigestIgnoresKey() {
        func make(_ key: String) -> URLRequest {
            var request = URLRequest(url: endpoint.canonicalURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("{\"a\":1}".utf8)
            return request
        }
        let first = EgressWireIdentity.digest(of: make("sk-first-secret"))
        let second = EgressWireIdentity.digest(of: make("sk-second-secret"))
        #expect(first == second, "two keys must not change the exported wire identity")
        var changed = make("sk-first-secret")
        changed.httpBody = Data("{\"a\":2}".utf8)
        #expect(first != EgressWireIdentity.digest(of: changed), "the body is part of the wire digest")
    }
}

/// The redirect completion handler is `@Sendable` and escaping, so a captured
/// local `var` is not legal under Swift 6. This box records whether the handler
/// ran and with what value without a data race.
private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var followed: URLRequest?

    func record(_ value: URLRequest?) {
        lock.withLock { called = true; followed = value }
    }

    var wasCalled: Bool { lock.withLock { called } }
    var followedRequest: URLRequest? { lock.withLock { followed } }
}
