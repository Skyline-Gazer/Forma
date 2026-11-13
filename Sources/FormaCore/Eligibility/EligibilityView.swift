import Foundation

// The derived view: a non-destructive projection of one `SourceListing`.
//
// `SourceListing` stays the authority for what was discovered. This view adds a
// decision to every discovered entry, keeps the original state beside it, and
// never writes to the listing, the store, a context revision or a manifest.
// `mappingCandidates()` is a pure function a future, separately authorised
// integration can call; nothing in this slice calls it from the production
// mapping path.

public struct EligibilityEntryView: Sendable, Equatable {
    /// The entry exactly as the scanner produced it.
    public let entry: SourceEntry
    /// The scanner's own state, kept beside the decision so a reader never has to
    /// infer discovery state from an eligibility verdict.
    public let originalState: SourceEntryState
    public let decision: EligibilityDecision
    public let decidedByRuleID: String?
    public let matchedRuleIDs: [String]
    public let policyVersion: String
    public let explanationCode: String
    public let followUp: EligibilityFollowUp?
    public let overrideState: EligibilityOverrideState
    public let notes: [String]

    public var sourceID: UUID { entry.id }
    public var isMappingCandidate: Bool { decision == .include }
}

/// The counts a dry run reports. Every field is path-free, so the summary can be
/// exported without carrying a customer's directory names.
public struct EligibilitySummary: Codable, Sendable, Equatable {
    public let discovered: Int
    public let include: Int
    public let exclude: Int
    public let review: Int
    public let deferred: Int
    /// Scan issues that never produced a discovered entry. They are reported so
    /// a failed subtree cannot vanish from the numbers.
    public let unaccounted: Int
    public let scanIssueCount: Int
    public let mappingCandidates: Int
    /// Sum of `size_bytes` over EXCLUDE entries that reported a size.
    public let estimatedExcludedLogicalBytes: Int64
    /// EXCLUDE entries whose size was not measured.
    public let unknownSizeRecords: Int
    public let perProfile: [String: EligibilityProfileCounts]
    public let perRule: [String: Int]

    enum CodingKeys: String, CodingKey {
        case discovered, include, exclude, review
        case deferred = "defer", unaccounted
        case scanIssueCount = "scan_issue_count", mappingCandidates = "mapping_candidates"
        case estimatedExcludedLogicalBytes = "estimated_excluded_logical_bytes"
        case unknownSizeRecords = "unknown_size_records"
        case perProfile = "per_profile", perRule = "per_rule"
    }

    /// The conservation identity a dry run must satisfy.
    public var isConserved: Bool { discovered == include + exclude + review + deferred }
}

public struct EligibilityProfileCounts: Codable, Sendable, Equatable {
    public let include: Int
    public let exclude: Int
    public let review: Int
    public let deferred: Int

    enum CodingKeys: String, CodingKey {
        case include, exclude, review, deferred = "defer"
    }
}

/// One metric, with the arithmetic a reader needs to check it.
public struct EligibilityMetric: Codable, Sendable, Equatable {
    public let numerator: Int
    public let denominator: Int
    public let unit: String
    public let kind: MeasurementKind
    /// What the denominator counts, in words.
    public let population: String
    public let unavailableReason: String?
    /// The scaling assumption behind an extrapolated figure, if any.
    public let assumption: String?

    enum CodingKeys: String, CodingKey {
        case numerator, denominator, unit, kind, population
        case unavailableReason = "unavailable_reason", assumption
    }

    /// Nil when the denominator is zero: N/A, never 0%.
    public var value: Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    static func unavailable(_ population: String, reason: String, unit: String) -> EligibilityMetric {
        EligibilityMetric(numerator: 0, denominator: 0, unit: unit, kind: .unavailable,
                          population: population, unavailableReason: reason, assumption: nil)
    }
}

public struct EligibilityMetrics: Codable, Sendable, Equatable {
    public let falseExclusionRate: EligibilityMetric
    public let reviewRate: EligibilityMetric
    public let mappingCandidatesReduction: EligibilityMetric
    public let tokenReduction: EligibilityMetric
    public let estimatedImportBytesReduction: EligibilityMetric

    enum CodingKeys: String, CodingKey {
        case falseExclusionRate = "false_exclusion_rate", reviewRate = "review_rate"
        case mappingCandidatesReduction = "mapping_candidates_reduction"
        case tokenReduction = "token_reduction"
        case estimatedImportBytesReduction = "estimated_import_bytes_reduction"
    }
}

/// A path-free record for an exported dry run.
public struct EligibilityExportRecord: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let decision: EligibilityDecision
    public let decidedByRuleID: String?
    public let explanationCode: String
    public let followUp: EligibilityFollowUp?
    public let overrideState: EligibilityOverrideState
    public let sizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", decision
        case decidedByRuleID = "decided_by_rule_id"
        case explanationCode = "explanation_code"
        case followUp = "follow_up"
        case overrideState = "override_state"
        case sizeBytes = "size_bytes"
    }
}

public struct EligibilityExport: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let policyID: String
    public let policyVersion: String
    public let policyDigest: String
    public let scanState: SourceScanState
    public let summary: EligibilitySummary
    public let metrics: EligibilityMetrics
    public let records: [EligibilityExportRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", policyID = "policy_id"
        case policyVersion = "policy_version", policyDigest = "policy_digest"
        case scanState = "scan_state", summary, metrics, records
    }
}


public struct EligibilityView: Sendable, Equatable {
    public let scope: SourceScope
    public let scanState: SourceScanState
    public let policyID: String
    public let policyVersion: String
    public let policyDigest: String
    /// Every discovered entry, in a stable order.
    public let entries: [EligibilityEntryView]
    public let summary: EligibilitySummary
    public let metrics: EligibilityMetrics
    public let scanIssues: [SourceScanIssue]
    /// Issues whose path never became a discovered entry.
    public let unaccountedIssues: [SourceScanIssue]

    /// The mapping-candidate projection. Pure: it reads this view and nothing
    /// else, and the production mapping path does not call it in this slice.
    public func mappingCandidates() -> [SourceEntry] {
        entries.filter(\.isMappingCandidate).map(\.entry)
    }

    public func entry(for sourceID: UUID) -> EligibilityEntryView? {
        entries.first { $0.sourceID == sourceID }
    }

    public var export: EligibilityExport {
        EligibilityExport(
            schemaVersion: "1.0", policyID: policyID, policyVersion: policyVersion,
            policyDigest: policyDigest, scanState: scanState, summary: summary, metrics: metrics,
            records: entries.map {
                EligibilityExportRecord(sourceID: $0.sourceID, decision: $0.decision,
                                        decidedByRuleID: $0.decidedByRuleID,
                                        explanationCode: $0.explanationCode, followUp: $0.followUp,
                                        overrideState: $0.overrideState, sizeBytes: $0.entry.sizeBytes)
            })
    }
}

public struct EligibilityViewRequest: Sendable {
    public let listing: SourceListing
    public let profile: MappingProfile
    public let policy: EligibilityPolicy
    /// Facts the caller established. An entry with no facts is evaluated with
    /// every optional fact `unknown`, which can never produce an EXCLUDE.
    public let facts: [UUID: EligibilityFacts]
    public let overrides: [EligibilityOverride]
    /// Independently labelled business samples, used only for the false-exclusion
    /// numerator and denominator.
    public let protectedSampleIDs: Set<UUID>
    /// Provenance of the input. A synthetic fixture must never publish a metric
    /// as `measured`.
    public let kind: MeasurementKind
    /// Supplied only when a caller wants an explicitly extrapolated token figure.
    public let tokensPerExcludedFile: Int?

    public init(listing: SourceListing, profile: MappingProfile, policy: EligibilityPolicy,
                facts: [UUID: EligibilityFacts] = [:], overrides: [EligibilityOverride] = [],
                protectedSampleIDs: Set<UUID> = [], kind: MeasurementKind = .simulated,
                tokensPerExcludedFile: Int? = nil) {
        self.listing = listing
        self.profile = profile
        self.policy = policy
        self.facts = facts
        self.overrides = overrides
        self.protectedSampleIDs = protectedSampleIDs
        self.kind = kind
        self.tokensPerExcludedFile = tokensPerExcludedFile
    }
}

public enum EligibilityViewBuilder {
    public static func build(_ request: EligibilityViewRequest) -> EligibilityView {
        let listing = request.listing
        let policy = request.policy
        let applicable = policy.applies(to: request.profile)
        let ordered = listing.entries.sorted {
            $0.normalizedRelativePath != $1.normalizedRelativePath
                ? $0.normalizedRelativePath < $1.normalizedRelativePath
                : $0.id.uuidString < $1.id.uuidString
        }
        let discoveredPaths = Set(ordered.map(\.relativePath))

        var views: [EligibilityEntryView] = []
        views.reserveCapacity(ordered.count)
        for entry in ordered {
            let entryIssues = listing.issues.filter { $0.relativePath == entry.relativePath }
            let facts = request.facts[entry.id]
                ?? .unknown(for: entry, scanState: listing.state, scanIssues: entryIssues)
            let base = applicable
                ? EligibilityClassifier.classify(facts, policy: policy)
                : EligibilityClassifier.notApplicable()
            let resolved = EligibilityOverrides.resolve(entry: entry, overrides: request.overrides,
                                                        policyVersion: policy.policyVersion)
            let outcome = applyOverride(base, entry: entry, facts: facts, resolution: resolved)
            views.append(EligibilityEntryView(
                entry: entry, originalState: entry.state, decision: outcome.decision,
                decidedByRuleID: outcome.decidedByRuleID, matchedRuleIDs: outcome.matchedRuleIDs,
                policyVersion: policy.policyVersion, explanationCode: outcome.explanationCode,
                followUp: outcome.followUp, overrideState: resolved.state, notes: outcome.notes))
        }

        let unaccounted = listing.issues.filter { !discoveredPaths.contains($0.relativePath) }
        let summary = summarize(views: views, listing: listing, unaccounted: unaccounted,
                                profile: request.profile)
        let metrics = metrics(views: views, listing: listing, request: request, summary: summary)
        return EligibilityView(scope: listing.scope, scanState: listing.state,
                               policyID: policy.policyID, policyVersion: policy.policyVersion,
                               policyDigest: policy.digest, entries: views, summary: summary,
                               metrics: metrics, scanIssues: listing.issues,
                               unaccountedIssues: unaccounted)
    }

    /// Applies a person's instruction to a classification.
    ///
    /// Safety outranks the override: an EXCLUDE cannot bury confirmed business
    /// evidence, and an INCLUDE cannot turn a DEFER (a fact is missing) into a
    /// mapping candidate. Both become REVIEW/keep DEFER with a stated reason.
    private static func applyOverride(_ base: EligibilityClassification, entry: SourceEntry,
                                      facts: EligibilityFacts,
                                      resolution: EligibilityOverrideResolution) -> EligibilityClassification {
        switch resolution.state {
        case .none:
            return base
        case .stalePolicy, .staleSnapshot, .unknownSource:
            return EligibilityClassification(decision: base.decision, matchedRules: base.matchedRules,
                                             decidedByRuleID: base.decidedByRuleID,
                                             explanationCode: base.explanationCode,
                                             followUp: .reconcileOverride,
                                             notes: base.notes + ["override_not_applied"])
        case .conflicting:
            return EligibilityClassification(decision: base.decision, matchedRules: base.matchedRules,
                                             decidedByRuleID: base.decidedByRuleID,
                                             explanationCode: base.explanationCode,
                                             followUp: .resolveOverrideConflict,
                                             notes: base.notes + ["override_conflict"])
        case .applied:
            guard let decision = resolution.decision else { return base }
            switch decision {
            case .include:
                guard base.decision != .defer else {
                    return EligibilityClassification(decision: .defer, matchedRules: base.matchedRules,
                                                     decidedByRuleID: base.decidedByRuleID,
                                                     explanationCode: EligibilityClassifier.Reason.overrideBlockedByDefer,
                                                     followUp: base.followUp,
                                                     notes: base.notes + ["include_override_blocked"])
                }
                return EligibilityClassification(decision: .include, matchedRules: base.matchedRules,
                                                 decidedByRuleID: base.decidedByRuleID,
                                                 explanationCode: EligibilityClassifier.Reason.ownerIncludeOverride,
                                                 followUp: nil,
                                                 notes: base.notes + ["owner_include"])
            case .exclude:
                guard facts.businessEvidence != .confirmed else {
                    return EligibilityClassification(
                        decision: .review, matchedRules: base.matchedRules,
                        decidedByRuleID: base.decidedByRuleID,
                        explanationCode: EligibilityClassifier.Reason.overrideBlockedByBusinessEvidence,
                        followUp: .confirmBusinessUse, notes: base.notes + ["exclude_override_blocked"])
                }
                return EligibilityClassification(decision: .exclude, matchedRules: base.matchedRules,
                                                 decidedByRuleID: base.decidedByRuleID,
                                                 explanationCode: EligibilityClassifier.Reason.ownerExcludeOverride,
                                                 followUp: nil,
                                                 notes: base.notes + ["owner_exclude"])
            }
        }
    }

    private static func summarize(views: [EligibilityEntryView], listing: SourceListing,
                                  unaccounted: [SourceScanIssue], profile: MappingProfile) -> EligibilitySummary {
        var include = 0, exclude = 0, review = 0, deferred = 0
        var bytes: Int64 = 0
        var unknownSize = 0
        var perRule: [String: Int] = [:]
        for view in views {
            switch view.decision {
            case .include: include += 1
            case .exclude:
                exclude += 1
                if let size = view.entry.sizeBytes { bytes += size } else { unknownSize += 1 }
            case .review: review += 1
            case .defer: deferred += 1
            }
            if let rule = view.decidedByRuleID { perRule[rule, default: 0] += 1 }
        }
        let counts = EligibilityProfileCounts(include: include, exclude: exclude, review: review,
                                              deferred: deferred)
        return EligibilitySummary(
            discovered: views.count, include: include, exclude: exclude, review: review,
            deferred: deferred, unaccounted: unaccounted.count,
            scanIssueCount: listing.issues.count, mappingCandidates: include,
            estimatedExcludedLogicalBytes: bytes, unknownSizeRecords: unknownSize,
            perProfile: [profile.profileID: counts], perRule: perRule)
    }

    private static func metrics(views: [EligibilityEntryView], listing: SourceListing,
                                request: EligibilityViewRequest,
                                summary: EligibilitySummary) -> EligibilityMetrics {
        let discovered = summary.discovered
        let protected = views.filter { request.protectedSampleIDs.contains($0.sourceID) }
        let protectedExcluded = protected.filter { $0.decision == .exclude }.count
        let falseExclusion = protected.isEmpty
            ? EligibilityMetric.unavailable("independently labelled protected business samples",
                                            reason: "no protected samples in this fixture",
                                            unit: "records")
            : EligibilityMetric(numerator: protectedExcluded, denominator: protected.count,
                                unit: "records", kind: request.kind,
                                population: "independently labelled protected business samples",
                                unavailableReason: nil, assumption: nil)

        let review = discovered > 0
            ? EligibilityMetric(numerator: summary.review, denominator: discovered, unit: "records",
                                kind: request.kind, population: "discovered records",
                                unavailableReason: nil, assumption: nil)
            : EligibilityMetric.unavailable("discovered records", reason: "no discovered records",
                                            unit: "records")

        let reduction = discovered > 0
            ? EligibilityMetric(numerator: discovered - summary.include, denominator: discovered,
                                unit: "records", kind: request.kind, population: "discovered records",
                                unavailableReason: nil, assumption: nil)
            : EligibilityMetric.unavailable("discovered records", reason: "no discovered records",
                                            unit: "records")

        let tokenReduction: EligibilityMetric
        if let tokensPerFile = request.tokensPerExcludedFile, discovered > 0, tokensPerFile > 0 {
            tokenReduction = EligibilityMetric(
                numerator: summary.exclude * tokensPerFile, denominator: discovered * tokensPerFile,
                unit: "tokens", kind: .extrapolated, population: "discovered records × supplied tokens-per-file",
                unavailableReason: nil,
                assumption: "\(tokensPerFile) tokens per file, held constant across included and excluded records")
        } else {
            tokenReduction = .unavailable("no token measurement is available offline",
                                          reason: "no provider usage and no tokens-per-file assumption supplied",
                                          unit: "tokens")
        }

        let totalBytes = views.compactMap(\.entry.sizeBytes).reduce(Int64(0), +)
        let bytesReduction: EligibilityMetric
        if totalBytes > 0 {
            bytesReduction = EligibilityMetric(
                numerator: Int(summary.estimatedExcludedLogicalBytes), denominator: Int(totalBytes),
                unit: "logical_bytes", kind: .extrapolated,
                population: "sum of measured logical size_bytes",
                unavailableReason: nil,
                assumption: "logical file size, not physical disk use; hard links, APFS clones, "
                    + "OneDrive placeholders and compression make the physical saving unknown")
        } else {
            bytesReduction = .unavailable("logical file size",
                                          reason: "no discovered record reported a size", unit: "logical_bytes")
        }

        return EligibilityMetrics(falseExclusionRate: falseExclusion, reviewRate: review,
                                  mappingCandidatesReduction: reduction, tokenReduction: tokenReduction,
                                  estimatedImportBytesReduction: bytesReduction)
    }
}
