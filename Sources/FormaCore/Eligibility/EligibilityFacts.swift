import Foundation

// The facts a decision may rest on, stated by the caller.
//
// Two rules shape this file. First, every fact is tri-state: `unknown` is a
// distinct value, because "Git tracked was not checked" must never be read as
// "untracked" and a cache marker that could not be read must never be read as
// absent. Second, nothing here is derived from the file system: `SourceEntry`
// already carries identity, version, snapshot, path and hydration state, and
// everything else is supplied explicitly so a rule cannot invent a fact.

public enum EligibilityTriState: String, Codable, Sendable, CaseIterable {
    case yes, no, unknown

    /// The literal a rule may require. `unknown` yields nil so a predicate that
    /// names `true` or `false` can never be satisfied by an unchecked fact.
    var literal: String? {
        switch self {
        case .yes: return "true"
        case .no: return "false"
        case .unknown: return nil
        }
    }
}

/// What was found at a cache marker, when the caller looked.
///
/// `presentUnverified` and `unreadable` are not `absent`: a `CACHEDIR.TAG` whose
/// signature does not match the standard, or one that could not be read, is not
/// evidence that the directory is a cache.
public enum EligibilityCacheMarker: String, Codable, Sendable, CaseIterable {
    /// Nobody looked. Distinct from `absent`, which says a check ran and found
    /// no marker; a probe that never ran must not be read as evidence of absence.
    case notChecked = "not_checked"
    case verifiedSignature = "verified"
    case presentUnverified = "present_unverified"
    case absent
    case unreadable
}

/// Whether a trusted source says this file is business material.
///
/// `confirmed` is the one fact that can override an exclusion; `unknown` is not
/// a weaker `none` and is reported as such.
public enum EligibilityBusinessEvidence: String, Codable, Sendable, CaseIterable {
    case confirmed, none, unknown
}

/// The literal form a predicate compares against.
public struct EligibilityFactLiteral: Sendable, Equatable {
    public let literal: String
}

public struct EligibilityFacts: Sendable, Equatable {
    public let entry: SourceEntry
    public let scanState: SourceScanState
    /// Issues whose path covers this entry, in the listing's own order.
    public let scanIssues: [SourceScanIssue]
    public let gitTracked: EligibilityTriState
    public let cacheMarker: EligibilityCacheMarker
    public let nestedRepository: EligibilityTriState
    public let businessEvidence: EligibilityBusinessEvidence
    public let sourceCodeOrDeployment: EligibilityTriState
    public let rebuildableArtifact: EligibilityTriState
    /// Two discovered paths collapsed onto one identity during the scan.
    public let pathCollision: Bool
    /// The entry's snapshot moved between discovery and this evaluation.
    public let snapshotChanged: Bool

    public init(entry: SourceEntry, scanState: SourceScanState = .complete,
                scanIssues: [SourceScanIssue] = [], gitTracked: EligibilityTriState = .unknown,
                cacheMarker: EligibilityCacheMarker = .notChecked,
                nestedRepository: EligibilityTriState = .unknown,
                businessEvidence: EligibilityBusinessEvidence = .unknown,
                sourceCodeOrDeployment: EligibilityTriState = .unknown,
                rebuildableArtifact: EligibilityTriState = .unknown,
                pathCollision: Bool = false, snapshotChanged: Bool = false) {
        self.entry = entry
        self.scanState = scanState
        self.scanIssues = scanIssues
        self.gitTracked = gitTracked
        self.cacheMarker = cacheMarker
        self.nestedRepository = nestedRepository
        self.businessEvidence = businessEvidence
        self.sourceCodeOrDeployment = sourceCodeOrDeployment
        self.rebuildableArtifact = rebuildableArtifact
        self.pathCollision = pathCollision
        self.snapshotChanged = snapshotChanged
    }

    /// Everything unknown. A caller that supplies no facts gets no exclusions:
    /// the default path is the safe one.
    public static func unknown(for entry: SourceEntry, scanState: SourceScanState = .complete,
                               scanIssues: [SourceScanIssue] = []) -> EligibilityFacts {
        EligibilityFacts(entry: entry, scanState: scanState, scanIssues: scanIssues,
                         gitTracked: .unknown, cacheMarker: .notChecked, nestedRepository: .unknown,
                         businessEvidence: .unknown, sourceCodeOrDeployment: .unknown,
                         rebuildableArtifact: .unknown)
    }

    /// The value a rule may name, or nil when the fact is unknown.
    public func fact(named name: String) -> EligibilityFactLiteral? {
        switch name {
        case "gitTracked": return gitTracked.literal.map(EligibilityFactLiteral.init)
        case "cacheMarker": return EligibilityFactLiteral(literal: cacheMarker.rawValue)
        case "nestedRepository": return nestedRepository.literal.map(EligibilityFactLiteral.init)
        case "businessEvidence":
            return businessEvidence == .unknown ? nil : EligibilityFactLiteral(literal: businessEvidence.rawValue)
        case "sourceCodeOrDeployment": return sourceCodeOrDeployment.literal.map(EligibilityFactLiteral.init)
        case "rebuildableArtifact": return rebuildableArtifact.literal.map(EligibilityFactLiteral.init)
        default: return nil
        }
    }

    /// Whether a protection fact was actually established.
    /// `unknown` is not "no": a cache-directory exclusion may only stand when the
    /// facts that could protect the file - tracked content, a nested repository,
    /// source or deployment material - have been checked. The classifier asks
    /// this before it emits an EXCLUDE, so a probe that never ran (or failed)
    /// cannot silently authorise one.
    public func isKnown(_ name: String) -> Bool {
        switch name {
        case "gitTracked": return gitTracked != .unknown
        case "nestedRepository": return nestedRepository != .unknown
        case "sourceCodeOrDeployment": return sourceCodeOrDeployment != .unknown
        case "rebuildableArtifact": return rebuildableArtifact != .unknown
        case "businessEvidence": return businessEvidence != .unknown
        case "cacheMarker": return cacheMarker != .notChecked
        default: return false
        }
    }

    /// Facts a rule may name. Kept as data so a policy typo is a test failure
    /// rather than a silently never-matching rule.
    public static let knownFactNames: Set<String> = [
        "gitTracked", "cacheMarker", "nestedRepository", "businessEvidence",
        "sourceCodeOrDeployment", "rebuildableArtifact",
    ]
}

// MARK: - Owner override

public enum EligibilityOverrideDecision: String, Codable, Sendable {
    /// A mapping candidate, and nothing more.
    case include = "INCLUDE"
    /// Not a mapping candidate by default.
    case exclude = "EXCLUDE"
}

/// A person's precise instruction about one discovered source.
///
/// The override is bound to the source identity, the snapshot it was made
/// against and the policy version that was in force. When either moves, the
/// override is stale: it is reported, never silently applied to a file that
/// happens to reuse an id or to a snapshot nobody reviewed.
public struct EligibilityOverride: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let policyVersion: String
    public let decision: EligibilityOverrideDecision
    public let authorCode: String
    public let createdAt: Date
    public let note: String?

    public init(id: UUID = UUID(), sourceID: UUID, snapshotFingerprint: String, policyVersion: String,
                decision: EligibilityOverrideDecision, authorCode: String, createdAt: Date = Date(),
                note: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.snapshotFingerprint = snapshotFingerprint
        self.policyVersion = policyVersion
        self.decision = decision
        self.authorCode = authorCode
        self.createdAt = createdAt
        self.note = note
    }
}

public enum EligibilityOverrideState: String, Codable, Sendable, CaseIterable {
    case none, applied, staleSnapshot = "stale_snapshot", stalePolicy = "stale_policy"
    case unknownSource = "unknown_source", conflicting
}

/// The outcome of resolving a source's overrides against one entry.
public struct EligibilityOverrideResolution: Sendable, Equatable {
    public let state: EligibilityOverrideState
    public let decision: EligibilityOverrideDecision?
    public let note: String?

    public static let none = EligibilityOverrideResolution(state: .none, decision: nil, note: nil)
}

public enum EligibilityOverrides {
    /// Overrides grouped by source once, so a 10k-entry view does not rescan a
    /// 10k-entry override list for every record. The semantics are unchanged:
    /// more than one override for the same source is still a conflict, not a
    /// "last one wins", because the two instructions disagree about the same
    /// bytes and guessing which one the person meant is exactly the silent
    /// behaviour the contract forbids.
    public struct Index: Sendable, Equatable {
        private let bySource: [UUID: [EligibilityOverride]]

        public init(_ overrides: [EligibilityOverride]) {
            bySource = Dictionary(grouping: overrides, by: \.sourceID)
        }

        public var count: Int { bySource.values.reduce(0) { $0 + $1.count } }

        public func resolve(entry: SourceEntry, policyVersion: String) -> EligibilityOverrideResolution {
            guard let matching = bySource[entry.id], !matching.isEmpty else { return .none }
            guard matching.count == 1 else {
                return EligibilityOverrideResolution(state: .conflicting, decision: nil,
                                                     note: "\(matching.count) overrides name this source")
            }
            let override = matching[0]
            guard override.policyVersion == policyVersion else {
                return EligibilityOverrideResolution(state: .stalePolicy, decision: nil,
                                                     note: "override was made under \(override.policyVersion)")
            }
            guard override.snapshotFingerprint == entry.snapshotFingerprint else {
                return EligibilityOverrideResolution(state: .staleSnapshot, decision: nil,
                                                     note: "override was made against another snapshot")
            }
            return EligibilityOverrideResolution(state: .applied, decision: override.decision,
                                                 note: override.note)
        }
    }
}
