import CryptoKit
import Foundation

// The import-eligibility policy: a versioned, declarative rule set that decides
// whether a discovered file may become a *mapping candidate*.
//
// Three sets are deliberately kept apart and this file only ever speaks about
// the middle one:
//
//   Discovered   - what the scanner found. `SourceListing` is the authority and
//                  nothing here changes it.
//   Mappable     - what may enter a mapping request. This policy decides it.
//   ImportEligible - what may be written to DEVONthink. Out of scope: no rule
//                  here can grant it, and `EligibilityDecision.include` says so
//                  in its own documentation.
//
// The rules are data, not code. A predicate can only compare facts the caller
// supplied; it cannot read a file, open a socket, call a model or run a shell.
// That is what makes the policy reviewable and what makes "same input + same
// policy = same decision" a property rather than a hope.

/// The four outcomes of the policy.
public enum EligibilityDecision: String, Codable, Sendable, CaseIterable {
    /// A mapping candidate. Grants no import, execution or egress authority.
    case include = "INCLUDE"
    /// High-confidence technical noise. Not a mapping candidate by default.
    case exclude = "EXCLUDE"
    /// Business value or file purpose is uncertain; a person has to confirm.
    case review = "REVIEW"
    /// A fact the decision needs is unavailable, or the scan is incomplete.
    case `defer` = "DEFER"
}

/// How much weight a rule's evidence carries.
///
/// `strong` is the only strength that may EXCLUDE. A weak signal - a directory
/// named `build`, an extension, a size - can only send a file to REVIEW, because
/// the archive value of a customer deliverable inside a build directory is not
/// something a name can disprove.
public enum EligibilityEvidenceStrength: String, Codable, Sendable {
    case strong, contextual, weak
}

/// What a person has to do next, when the decision is not final.
public enum EligibilityFollowUp: String, Codable, Sendable, CaseIterable {
    case confirmBusinessUse = "confirm_business_use"
    case confirmVendorDeliverable = "confirm_vendor_deliverable"
    case confirmNestedRepository = "confirm_nested_repository"
    case confirmSourceCode = "confirm_source_code"
    case confirmRebuildableArtifact = "confirm_rebuildable_artifact"
    case completeScan = "complete_scan"
    case restoreAccess = "restore_access"
    case resolvePathCollision = "resolve_path_collision"
    case reconcileSnapshot = "reconcile_snapshot"
    case hydrateBeforeMapping = "hydrate_before_mapping"
    case probeFacts = "probe_facts"
    case reconcileOverride = "reconcile_override"
    case resolveOverrideConflict = "resolve_override_conflict"
}

/// One declarative condition. Every populated field must match (AND); a rule can
/// additionally require one of several predicates (`any`).
public struct EligibilityPredicate: Codable, Sendable, Equatable {
    /// Lowercased extensions without the dot.
    public var extensions: [String]?
    /// Exact basenames, compared case-insensitively.
    public var basenames: [String]?
    /// Basename prefixes, compared case-insensitively (AppleDouble, Office locks).
    public var basenamePrefixes: [String]?
    /// Exact path components, compared case-insensitively.
    public var pathComponents: [String]?
    /// `SourceEntryState` raw values.
    public var entryStates: [String]?
    /// `SourceProvider` raw values.
    public var providers: [String]?
    public var hydrationPending: Bool?
    /// Fact name -> required literal. A fact that is `unknown` never satisfies a
    /// predicate that names a value: "not checked" is not "false".
    public var facts: [String: String]?
    /// `SourceScanIssue.Reason` raw values that apply to this entry.
    public var scanIssueReasons: [String]?
    public var minimumSizeBytes: Int64?
    public var maximumSizeBytes: Int64?

    public init(extensions: [String]? = nil, basenames: [String]? = nil,
                basenamePrefixes: [String]? = nil, pathComponents: [String]? = nil,
                entryStates: [String]? = nil, providers: [String]? = nil,
                hydrationPending: Bool? = nil, facts: [String: String]? = nil,
                scanIssueReasons: [String]? = nil, minimumSizeBytes: Int64? = nil,
                maximumSizeBytes: Int64? = nil) {
        self.extensions = extensions
        self.basenames = basenames
        self.basenamePrefixes = basenamePrefixes
        self.pathComponents = pathComponents
        self.entryStates = entryStates
        self.providers = providers
        self.hydrationPending = hydrationPending
        self.facts = facts
        self.scanIssueReasons = scanIssueReasons
        self.minimumSizeBytes = minimumSizeBytes
        self.maximumSizeBytes = maximumSizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case extensions, basenames
        case basenamePrefixes = "basename_prefixes"
        case pathComponents = "path_components"
        case entryStates = "entry_states"
        case providers
        case hydrationPending = "hydration_pending"
        case facts
        case scanIssueReasons = "scan_issue_reasons"
        case minimumSizeBytes = "minimum_size_bytes"
        case maximumSizeBytes = "maximum_size_bytes"
    }

    /// True when the predicate names at least one condition. An empty predicate
    /// would match everything, which is never what a rule means.
    public var isEmpty: Bool {
        extensions == nil && basenames == nil && basenamePrefixes == nil && pathComponents == nil
            && entryStates == nil && providers == nil && hydrationPending == nil && facts == nil
            && scanIssueReasons == nil && minimumSizeBytes == nil && maximumSizeBytes == nil
    }

    /// Every populated field must match.
    public func matches(_ facts: EligibilityFacts) -> Bool {
        let entry = facts.entry
        let path = entry.relativePath
        let basename = (path as NSString).lastPathComponent
        let loweredBase = basename.lowercased()
        let components = path.split(separator: "/").map { $0.lowercased() }

        if let extensions {
            let ext = (basename as NSString).pathExtension.lowercased()
            guard extensions.contains(where: { $0.lowercased() == ext }) else { return false }
        }
        if let basenames {
            guard basenames.contains(where: { $0.lowercased() == loweredBase }) else { return false }
        }
        if let basenamePrefixes {
            guard basenamePrefixes.contains(where: { loweredBase.hasPrefix($0.lowercased()) }) else { return false }
        }
        if let pathComponents {
            let wanted = Set(pathComponents.map { $0.lowercased() })
            guard components.contains(where: { wanted.contains($0) }) else { return false }
        }
        if let entryStates {
            guard entryStates.contains(entry.state.rawValue) else { return false }
        }
        if let providers {
            guard providers.contains(entry.provider.rawValue) else { return false }
        }
        if let hydrationPending {
            guard entry.hydrationPending == hydrationPending else { return false }
        }
        if let factsRequired = self.facts {
            for (name, required) in factsRequired {
                guard facts.fact(named: name)?.literal == required.lowercased() else { return false }
            }
        }
        if let scanIssueReasons {
            let reasons = Set(facts.scanIssues.map { $0.reason.rawValue })
            guard scanIssueReasons.contains(where: { reasons.contains($0) }) else { return false }
        }
        if let minimumSizeBytes {
            guard let size = entry.sizeBytes, size >= minimumSizeBytes else { return false }
        }
        if let maximumSizeBytes {
            guard let size = entry.sizeBytes, size <= maximumSizeBytes else { return false }
        }
        return true
    }
}

/// One rule: a decision, the evidence strength behind it, and the conditions.
public struct EligibilityRule: Codable, Sendable, Equatable {
    public let ruleID: String
    /// Higher runs first. Ties are broken by `ruleID`, so the order of the rules
    /// in the JSON file never changes a decision.
    public let priority: Int
    public let decision: EligibilityDecision
    public let evidenceStrength: EligibilityEvidenceStrength
    public let explanationCode: String
    public let followUp: EligibilityFollowUp?
    /// All of these must match.
    public let all: [EligibilityPredicate]?
    /// At least one of these must match.
    public let any: [EligibilityPredicate]?
    /// A rule that needs document content cannot decide a dataless file; the
    /// classifier turns that into DEFER instead of guessing.
    public let requiresContentEvidence: Bool
    /// Facts that must have been *checked* before this rule may EXCLUDE.
    ///
    /// Absent from the JSON, an EXCLUDE rule defaults to the facts that could
    /// protect a file inside a cache directory; a noise rule that is
    /// self-evidencing opts out explicitly with an empty list.
    public let protectionFacts: [String]

    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id", priority, decision
        case evidenceStrength = "evidence_strength"
        case explanationCode = "explanation_code"
        case followUp = "follow_up"
        case all, any
        case requiresContentEvidence = "requires_content_evidence"
        case protectionFacts = "protection_facts"
    }

    public init(ruleID: String, priority: Int, decision: EligibilityDecision,
                evidenceStrength: EligibilityEvidenceStrength, explanationCode: String,
                followUp: EligibilityFollowUp? = nil, all: [EligibilityPredicate]? = nil,
                any: [EligibilityPredicate]? = nil, requiresContentEvidence: Bool = false,
                protectionFacts: [String]? = nil) {
        self.ruleID = ruleID
        self.priority = priority
        self.decision = decision
        self.evidenceStrength = evidenceStrength
        self.explanationCode = explanationCode
        self.followUp = followUp
        self.all = all
        self.any = any
        self.requiresContentEvidence = requiresContentEvidence
        self.protectionFacts = protectionFacts ?? Self.defaultProtectionFacts(for: decision)
    }

    /// The guard an EXCLUDE gets when the file does not state one. Fail-safe: a
    /// new exclusion rule is assumed to need the protecting facts, and only an
    /// explicitly empty list opts out.
    static func defaultProtectionFacts(for decision: EligibilityDecision) -> [String] {
        decision == .exclude ? ["gitTracked", "nestedRepository"] : []
    }

    /// A policy file may omit `requires_content_evidence`; the default is false,
    /// so an older or hand-written rule does not fail to load over an absent
    /// optional flag.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = try container.decode(String.self, forKey: .ruleID)
        priority = try container.decode(Int.self, forKey: .priority)
        decision = try container.decode(EligibilityDecision.self, forKey: .decision)
        evidenceStrength = try container.decode(EligibilityEvidenceStrength.self, forKey: .evidenceStrength)
        explanationCode = try container.decode(String.self, forKey: .explanationCode)
        followUp = try container.decodeIfPresent(EligibilityFollowUp.self, forKey: .followUp)
        all = try container.decodeIfPresent([EligibilityPredicate].self, forKey: .all)
        any = try container.decodeIfPresent([EligibilityPredicate].self, forKey: .any)
        requiresContentEvidence = try container.decodeIfPresent(Bool.self, forKey: .requiresContentEvidence) ?? false
        protectionFacts = try container.decodeIfPresent([String].self, forKey: .protectionFacts)
            ?? Self.defaultProtectionFacts(for: decision)
    }

    public var isEmpty: Bool { (all ?? []).isEmpty && (any ?? []).isEmpty }

    /// The first protection fact this rule needs but the facts do not establish.
    /// Nil when every required fact was checked.
    public func firstUnknownProtectionFact(_ facts: EligibilityFacts) -> String? {
        protectionFacts.first { !facts.isKnown($0) }
    }

    public func matches(_ facts: EligibilityFacts) -> Bool {
        let allMatch = (all ?? []).allSatisfy { $0.matches(facts) }
        let anyMatch = any.map { list in list.contains { $0.matches(facts) } } ?? true
        return allMatch && anyMatch && !isEmpty
    }
}

/// The versioned policy document.
public struct EligibilityPolicy: Codable, Sendable, Equatable {
    public static let supportedSchemaVersion = "1.0"
    public static let currentVersion = "eligibility.v2"

    public let schemaVersion: String
    public let policyID: String
    public let policyVersion: String
    /// Profiles this policy was written for. An empty list means "all profiles",
    /// which is stated explicitly rather than left to a missing key.
    public let profiles: [String]
    public let rules: [EligibilityRule]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", policyID = "policy_id"
        case policyVersion = "policy_version", profiles, rules
    }

    public init(schemaVersion: String = EligibilityPolicy.supportedSchemaVersion,
                policyID: String = "forma-import-eligibility",
                policyVersion: String = EligibilityPolicy.currentVersion,
                profiles: [String] = [], rules: [EligibilityRule]) {
        self.schemaVersion = schemaVersion
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.profiles = profiles
        self.rules = rules
    }

    /// Stable bytes: rules in the classifier's own order, profiles sorted, keys
    /// sorted by the encoder. Two policy files that differ only in rule order
    /// therefore share one digest and one identity.
    public var canonicalData: Data {
        let canonical = EligibilityPolicy(schemaVersion: schemaVersion, policyID: policyID,
                                          policyVersion: policyVersion, profiles: profiles.sorted(),
                                          rules: orderedRules)
        return (try? FormaJSON.encode(canonical, pretty: false)) ?? Data()
    }

    public var digest: String {
        SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    public func applies(to profile: MappingProfile) -> Bool {
        profiles.isEmpty || profiles.contains(profile.profileID)
    }

    /// Rules in the only order the classifier ever uses.
    public var orderedRules: [EligibilityRule] {
        rules.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.ruleID < $1.ruleID
        }
    }

    /// Rejects a policy that could not be reviewed or could silently misfire.
    public func validated() throws -> EligibilityPolicy {
        guard schemaVersion == Self.supportedSchemaVersion else { throw FormaError.incompatible }
        guard !policyID.isEmpty, !policyVersion.isEmpty, !rules.isEmpty else { throw FormaError.incompatible }
        guard Set(rules.map(\.ruleID)).count == rules.count else { throw FormaError.incompatible }
        guard profiles.count == Set(profiles).count else { throw FormaError.incompatible }
        for rule in rules {
            guard !rule.ruleID.isEmpty, !rule.explanationCode.isEmpty, !rule.isEmpty else {
                throw FormaError.incompatible
            }
            // A weak signal may inform a person, never exclude a file on its own.
            guard !(rule.decision == .exclude && rule.evidenceStrength != .strong) else {
                throw FormaError.incompatible
            }
            for predicate in (rule.all ?? []) + (rule.any ?? []) where predicate.isEmpty {
                throw FormaError.incompatible
            }
            // A guard naming a fact the engine cannot supply would silently
            // never protect anything.
            for fact in rule.protectionFacts where !EligibilityFacts.knownFactNames.contains(fact) {
                throw FormaError.incompatible
            }
        }
        return self
    }

    public static func decode(_ data: Data) throws -> EligibilityPolicy {
        try FormaJSON.decode(EligibilityPolicy.self, from: data).validated()
    }

    public static func shipped() throws -> EligibilityPolicy {
        guard let url = Bundle.module.url(forResource: "forma-eligibility.v1", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw FormaError.unavailable }
        return try decode(data)
    }
}
