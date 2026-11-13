import CryptoKit
import Foundation

// The single provider-egress contract.
//
// Before P3-A Slice 2d the only question a send asked was `allowCloud == true`.
// That boolean cannot say *which* provider, model, endpoint, data categories or
// redaction policy a person approved, cannot be revoked, and cannot tell an
// approved preview from a later byte-different request. This file replaces that
// question with one gate: no HTTP request leaves through `ProviderTransport`
// without an `EgressTicket` produced here.
//
// Three layers are deliberately kept apart (PLAN §8.3, P3-A 2d §2.2):
//
//   1. Semantic payload  - `MappingPrompt.payload` bytes + the system prompt.
//   2. Provider body      - the semantic payload plus model, schema, token cap
//                           and the provider's own envelope.
//   3. Wire metadata      - URL, method, headers (never their secret values).
//
// `semanticDigest` covers (1), `wireDigest` covers (2)+(3) with credentials
// reduced to "a credential header was present". A preview digest is never
// presented as a digest of the full HTTP request.
//
public enum EgressContract {
    public static let version = "egress.v1"
    public static let scopeVersion = "scope.v1"

    static func digest(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}


/// Cloud and local are two different authorizations, not two spellings of one.
/// A URL that happens to point at a machine the user named is not thereby safe,
/// offline, or free of egress: `.local` still needs a grant and an exact target.
public enum EgressMode: String, Codable, Sendable, Equatable {
    case cloud
    case local
}

/// The only endpoints a send may target. `ProviderTransport` hard-codes the two
/// cloud hosts; recording them here makes an endpoint change a *scope mismatch*
/// rather than an unnoticed edit in a URL literal.
public enum EgressEndpoint: Codable, Sendable, Equatable {
    case provider(ProbeProvider)
    case local(URL)

    public var canonicalURL: URL {
        switch self {
        case .provider(.openAI): return URL(string: "https://api.openai.com/v1/responses")!
        case .provider(.anthropic): return URL(string: "https://api.anthropic.com/v1/messages")!
        case .local(let url): return url
        }
    }

    /// A stable identity for the endpoint, used in digests and tickets.
    public var identity: String { canonicalURL.absoluteString }
}

/// What a payload is made of. A scope authorizes *categories*, not a UI toggle:
/// a run that re-reads evidence between preview and send keeps its categories
/// even when the bytes change.
public enum EgressDataCategory: String, Codable, Sendable, CaseIterable {
    case filePaths
    case evidenceExcerpts
    case projectContext
    case casePackExamples
    case profileRules
    case systemPrompt
    case repairInstructions
    case syntheticProbe
}

public enum EgressRequestKind: String, Codable, Sendable, Equatable {
    case firstAsk
    case repair
    case rateLimitRetry
}

/// Whether the grant covers a byte-identical payload or a data *range*.
///
/// Forma's product contract says a preview is not a receipt: `runMapping`
/// re-reads file bodies before dispatch, so excerpts can differ. The shipped
/// grant therefore binds to `.dataRange`; `.exactPayload` exists for callers
/// that can prove their bytes cannot change (and for the strict-mode tests).
public enum EgressBinding: String, Codable, Sendable, Equatable {
    case dataRange
    case exactPayload
}

/// Known-term substitution and unknown-data detection are different problems.
/// `allowed` means "no declared term survived and no high-risk shape was
/// detected" - it is explicitly not a 100% anonymization claim.
public enum SensitiveContentAssessment: String, Codable, Sendable, Equatable {
    case allowed
    case redacted
    case reviewRequired
    case blocked
}

/// What was approved. An `EgressAuthorization` is a value, not a live UI
/// binding: it is built once at consent from the preview and settings snapshot.
public struct EgressScope: Codable, Sendable, Equatable {
    public let version: String
    public let scopeVersion: String
    public let provider: ProbeProvider?
    public let model: String
    public let endpoint: EgressEndpoint
    public let mode: EgressMode
    public let categories: Set<EgressDataCategory>
    public let redactionVersion: String
    /// An identity plan substitutes no known terms. Recording it in the grant is
    /// what keeps "no term was replaced" from being read as "no data is sensitive",
    /// and lets the gate refuse a run whose plan changed after consent.
    public let identitySubstitution: Bool
    /// Placeholders are salt-derived and therefore stable across requests that
    /// share a salt. Forma permits that linkage *within one workspace only* and
    /// never exports the salt or the term→placeholder table.
    public let crossScopeLinking: String

    public init(provider: ProbeProvider?, model: String, endpoint: EgressEndpoint, mode: EgressMode,
                categories: Set<EgressDataCategory>, redactionVersion: String,
                identitySubstitution: Bool,
                crossScopeLinking: String = "workspace-only",
                version: String = EgressContract.version,
                scopeVersion: String = EgressContract.scopeVersion) {
        self.version = version
        self.scopeVersion = scopeVersion
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.mode = mode
        self.categories = categories
        self.redactionVersion = redactionVersion
        self.identitySubstitution = identitySubstitution
        self.crossScopeLinking = crossScopeLinking
    }

    /// The digest of the range, not of a payload. Included in every ticket so a
    /// reviewer can tell which scope produced it.
    public var material: String {
        "forma.egress.scope.v1|\(version)|\(scopeVersion)|\(provider?.rawValue ?? "-")|\(model)"
            + "|\(endpoint.identity)|\(mode.rawValue)|\(categories.map(\.rawValue).sorted().joined(separator: ","))"
            + "|\(redactionVersion)|\(identitySubstitution)|\(crossScopeLinking)"
    }

    public var digest: String { EgressContract.digest(material) }
}

public struct EgressAuthorization: Codable, Sendable, Equatable {
    public let scope: EgressScope
    public let grantedAt: Date
    public let expiresAt: Date?
    /// Digest of the semantic payload shown at consent. Recorded for auditing;
    /// only `.exactPayload` binding requires the sent bytes to match it.
    public let previewDigest: String?
    public let binding: EgressBinding
    /// An explicit, separately granted choice. Without it, content the scanner
    /// cannot classify is refused rather than assumed safe.
    public let allowsReviewRequiredContent: Bool
    public let revoked: Bool

    public init(scope: EgressScope, grantedAt: Date = Date(), expiresAt: Date? = nil,
                previewDigest: String? = nil, binding: EgressBinding = .dataRange,
                allowsReviewRequiredContent: Bool = false, revoked: Bool = false) {
        self.scope = scope
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.previewDigest = previewDigest
        self.binding = binding
        self.allowsReviewRequiredContent = allowsReviewRequiredContent
        self.revoked = revoked
    }

    public var id: String {
        EgressContract.digest("\(scope.digest)|\(grantedAt.timeIntervalSince1970)|\(binding.rawValue)"
            + "|\(allowsReviewRequiredContent)|\(revoked)|\(previewDigest ?? "-")")
    }

    public func revoking() -> EgressAuthorization {
        EgressAuthorization(scope: scope, grantedAt: grantedAt, expiresAt: expiresAt,
                            previewDigest: previewDigest, binding: binding,
                            allowsReviewRequiredContent: allowsReviewRequiredContent, revoked: true)
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    /// The restricted grant a connectivity probe uses. It carries no document
    /// categories at all: a probe can never authorize a mapping request.
    public static func probe(provider: ProbeProvider, model: String) -> EgressAuthorization {
        EgressAuthorization(
            scope: EgressScope(provider: provider, model: model, endpoint: .provider(provider),
                               mode: .cloud, categories: [.syntheticProbe],
                               redactionVersion: RedactionPlan.version,
                               identitySubstitution: true),
            binding: .exactPayload, allowsReviewRequiredContent: false)
    }
}

/// The facts about one actual wire request, stated by the caller at send time.
public struct EgressRequest: Sendable, Equatable {
    public let provider: ProbeProvider
    public let model: String
    public let endpoint: EgressEndpoint
    public let mode: EgressMode
    public let categories: Set<EgressDataCategory>
    public let redactionVersion: String
    public let identitySubstitution: Bool
    public let semanticDigest: String
    public let wireDigest: String
    public let kind: EgressRequestKind
    public let assessment: SensitiveContentAssessment
    public let credentialPresent: Bool
    public let endpointURL: URL

    public init(provider: ProbeProvider, model: String, endpoint: EgressEndpoint, mode: EgressMode,
                categories: Set<EgressDataCategory>, redactionVersion: String,
                identitySubstitution: Bool, semanticDigest: String,
                wireDigest: String, kind: EgressRequestKind, assessment: SensitiveContentAssessment,
                credentialPresent: Bool, endpointURL: URL) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.mode = mode
        self.categories = categories
        self.redactionVersion = redactionVersion
        self.identitySubstitution = identitySubstitution
        self.semanticDigest = semanticDigest
        self.wireDigest = wireDigest
        self.kind = kind
        self.assessment = assessment
        self.credentialPresent = credentialPresent
        self.endpointURL = endpointURL
    }
}

/// A stable, log-safe reason. No reason carries a payload, path, key or model
/// response body, so a denial can be recorded in diagnostics as a code.
public enum EgressDenialReason: String, Codable, Sendable, CaseIterable {
    case cloudDisabled = "cloud_disabled"
    case authorizationMissing = "authorization_missing"
    case scopeVersionMismatch = "scope_version_mismatch"
    case scopeRevoked = "scope_revoked"
    case scopeExpired = "scope_expired"
    case providerMismatch = "provider_mismatch"
    case modelMismatch = "model_mismatch"
    case endpointMismatch = "endpoint_mismatch"
    case modeMismatch = "mode_mismatch"
    case categoryNotAllowed = "category_not_allowed"
    case redactionVersionMismatch = "redaction_version_mismatch"
    case identityRedactionUndisclosed = "identity_redaction_undisclosed"
    case previewMismatch = "preview_mismatch"
    case credentialMissing = "credential_missing"
    case payloadIdentityMissing = "payload_identity_missing"
    case wireDigestCollision = "wire_digest_collision"
    case unknownSensitiveContent = "unknown_sensitive_content"
    case sensitiveContentBlocked = "sensitive_content_blocked"
    case cancellation = "cancellation"
}

public struct EgressDenial: Codable, Sendable, Equatable {
    public let reason: EgressDenialReason
    public var code: String { reason.rawValue }
}

/// Proof that a specific wire request passed the gate. Every field is safe to
/// log or export: digests, identifiers, versions and counts only.
public struct EgressTicket: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let scopeDigest: String
    public let scopeVersion: String
    public let provider: String
    public let model: String
    public let endpoint: String
    public let mode: EgressMode
    public let semanticDigest: String
    public let wireDigest: String
    public let kind: EgressRequestKind
    public let assessment: SensitiveContentAssessment
    public let categories: Set<EgressDataCategory>
    public let redactionVersion: String
    public let identitySubstitution: Bool
    public let decidedAt: Date

    /// The one-line form diagnostics may record. It cannot carry a payload.
    public var logSummary: String {
        "egress=\(kind.rawValue) scope=\(scopeDigest.prefix(12)) semantic=\(semanticDigest.prefix(12)) "
            + "wire=\(wireDigest.prefix(12)) assessment=\(assessment.rawValue)"
    }
}

public struct EgressDecision: Sendable, Equatable {
    public let ticket: EgressTicket?
    public let denial: EgressDenial?
    public var isAllowed: Bool { ticket != nil }
}

/// The single pre-send gate. Pure: it never reads Keychain, never opens a
/// socket and never mutates the authorization. `ProviderTransport.response`
/// refuses to run without the ticket it returns.
public enum EgressGate {
    public static func decide(request: EgressRequest, authorization: EgressAuthorization?,
                              allowCloud: Bool, previewDigest: String?,
                              now: Date = Date()) -> EgressDecision {
        func deny(_ reason: EgressDenialReason) -> EgressDecision {
            EgressDecision(ticket: nil, denial: EgressDenial(reason: reason))
        }

        if request.mode == .cloud, !allowCloud { return deny(.cloudDisabled) }
        guard let grant = authorization else { return deny(.authorizationMissing) }
        let scope = grant.scope
        guard scope.version == EgressContract.version,
              scope.scopeVersion == EgressContract.scopeVersion else { return deny(.scopeVersionMismatch) }
        if grant.revoked { return deny(.scopeRevoked) }
        if grant.isExpired(at: now) { return deny(.scopeExpired) }
        if let scopeProvider = scope.provider, scopeProvider != request.provider {
            return deny(.providerMismatch)
        }
        if scope.model != request.model { return deny(.modelMismatch) }
        if scope.endpoint != request.endpoint { return deny(.endpointMismatch) }
        if request.endpointURL.absoluteString != scope.endpoint.identity { return deny(.endpointMismatch) }
        if scope.mode != request.mode { return deny(.modeMismatch) }
        if !request.categories.isSubset(of: scope.categories) { return deny(.categoryNotAllowed) }
        if scope.redactionVersion != request.redactionVersion { return deny(.redactionVersionMismatch) }
        // If the redaction plan changed after consent - in particular from a
        // substituting plan to an identity one - the grant no longer describes
        // the data range. Refuse rather than silently using the old authorization.
        if scope.identitySubstitution != request.identitySubstitution {
            return deny(.identityRedactionUndisclosed)
        }
        if grant.binding == .exactPayload {
            guard let expected = previewDigest ?? grant.previewDigest,
                  expected == request.semanticDigest else { return deny(.previewMismatch) }
        }
        switch request.assessment {
        case .blocked: return deny(.sensitiveContentBlocked)
        case .reviewRequired:
            if !grant.allowsReviewRequiredContent { return deny(.unknownSensitiveContent) }
        case .allowed, .redacted: break
        }
        if !request.credentialPresent { return deny(.credentialMissing) }
        if request.semanticDigest.isEmpty || request.wireDigest.isEmpty {
            return deny(.payloadIdentityMissing)
        }
        // A "wire" digest equal to the semantic digest would mean the caller is
        // trying to pass a payload digest off as a whole-request digest.
        if request.semanticDigest == request.wireDigest { return deny(.wireDigestCollision) }

        let ticket = EgressTicket(
            authorizationID: grant.id, scopeDigest: scope.digest, scopeVersion: scope.scopeVersion,
            provider: request.provider.rawValue, model: request.model,
            endpoint: scope.endpoint.identity, mode: request.mode,
            semanticDigest: request.semanticDigest, wireDigest: request.wireDigest,
            kind: request.kind, assessment: request.assessment, categories: request.categories,
            redactionVersion: request.redactionVersion,
            identitySubstitution: request.identitySubstitution, decidedAt: now)
        return EgressDecision(ticket: ticket, denial: nil)
    }
}

// MARK: - Content assessment

/// A deliberately narrow scanner. It answers "did a declared term survive, or
/// is there a shape we cannot classify?", never "this text is fully anonymous".
/// Regex and dictionaries cannot guarantee anonymization of unknown names,
/// addresses or internal codes; those produce `.reviewRequired`, which the gate
/// refuses unless the grant explicitly allowed it.
public enum SensitiveContentScanner {
    private static let highRiskPatterns = [
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        #"(?i)\b(?:sk|api|token|secret|bearer)[-_][A-Za-z0-9]{12,}\b"#,
        #"(?i)\b(?:1[3-9]\d{9}|(?:\+?86[-\s]?)?1[3-9]\d{9})\b"#,
        #"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"#,
        #"\b\d{17}[\dXx]\b"#,
    ]

    public static func assess(payload: String, system: String, plan: RedactionPlan) -> SensitiveContentAssessment {
        let text = system + "\n" + payload
        if !plan.leaks(text).isEmpty { return .blocked }
        for pattern in highRiskPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            if !expression.matches(in: text, range: range).isEmpty { return .reviewRequired }
        }
        // A identity plan still replaces amounts and identifiers, but no known
        // names. Saying "redacted" here would overstate what happened.
        if plan.isIdentity { return .allowed }
        return .redacted
    }
}

// MARK: - Wire identity

public enum EgressWireIdentity {
    /// Digest of the provider body + wire metadata. Credential values are never
    /// hashed: only the fact that a credential header was present is recorded,
    /// so the digest can be exported without exporting the key.
    public static func digest(of request: URLRequest) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("wire.v1|\(request.httpMethod ?? "GET")|\(request.url?.absoluteString ?? "-")".utf8))
        let secretHeaders: Set<String> = ["authorization", "x-api-key"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let lowered = name.lowercased()
            let safe = secretHeaders.contains(lowered) ? "present" : value
            hasher.update(data: Data("|\(lowered)=\(safe)".utf8))
        }
        hasher.update(data: Data("|body=".utf8))
        hasher.update(data: request.httpBody ?? Data())
        return hasher.finalize().hexadecimalDigest
    }
}
