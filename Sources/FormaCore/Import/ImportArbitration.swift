import Foundation

/// The three-way arbitration of PLAN §10.2, plus the fourth answer for "I do not
/// know yet".
///
/// The order of the checks is the whole point: an unknown outcome is answered
/// before any conclusion about absence, because "the request timed out" is
/// compatible with "the record exists". A search that found nothing is only
/// evidence of absence when the search itself is conclusive.
public enum ImportArbitration {
    public static func decide(_ facts: ImportFacts) -> ImportDecision {
        // 1. Anything unknown about the request or the search wins over every
        //    conclusion. This is the guard that makes blind retry impossible.
        if facts.requestOutcome.isUnknown {
            return ImportDecision(.verifyRequired, .outcomeUnknown,
                                  "the write or lookup result is unknown")
        }
        if facts.candidateCount > 1 {
            return ImportDecision(.verifyRequired, .candidatesAmbiguous,
                                  "the lookup returned more than one candidate")
        }
        if facts.observedUUID != nil && !facts.lookupConclusive {
            return ImportDecision(.verifyRequired, .searchInconclusive,
                                  "a record was observed but the search cannot prove it is unique")
        }

        // 2. A confirmed business record is either already correct or in conflict.
        if facts.businessIdentity.isConfirmed {
            // Without a verifiable digest the target cannot be shown to hold the
            // bytes the decision was made from, so neither "matches" nor
            // "differs" can be claimed: the record stays unverified.
            guard facts.targetHashVerified else {
                return ImportDecision(.verifyRequired, .hashUnverified,
                                      "the target cannot prove the content digest")
            }
            if facts.contentMatchesManifest && facts.metadataMatchesManifest {
                return ImportDecision(.skipVerified, .alreadyVerified,
                                      "the record matches the manifest")
            }
            return ImportDecision(.conflictHold, .confirmedButDiffers,
                                  "the record is confirmed but differs from the manifest")
        }

        // 3. Only a conclusive search that found nothing permits an import.
        if facts.observedUUID == nil && facts.lookupConclusive && facts.candidateCount == 0 {
            return ImportDecision(.importRecord, .absentAndConclusive,
                                  "no record exists and the search could prove it")
        }

        // 4. Everything else needs a person or a better readback.
        return ImportDecision(.verifyRequired, .identityUnconfirmed,
                              "the evidence does not confirm or exclude a business record")
    }
}

/// What the read-only side observed, stated as facts rather than as a verdict.
public struct ImportFacts: Sendable, Equatable {
    public enum RequestOutcome: String, Codable, Sendable {
        /// The call returned and its result is trustworthy.
        case succeeded
        /// Sent, but no answer arrived.
        case timedOut
        /// Sent, and the connection dropped before an answer.
        case disconnected
        /// The call failed in a way that says nothing about the target.
        case failed
        /// Not attempted at all (for example: the record already exists).
        case notAttempted

        /// True when the target may have changed without us knowing.
        public var isUnknown: Bool {
            switch self {
            case .timedOut, .disconnected, .failed:
                return true
            case .succeeded, .notAttempted:
                return false
            }
        }
    }

    /// The UUID the read-only lookup found, if any.
    public let observedUUID: String?
    /// Records the lookup returned. More than one is ambiguity, not a choice.
    public let candidateCount: Int
    /// Whether the search's pagination, scope and semantics are enough to prove
    /// that *nothing* matches. A single empty page is not proof.
    public let lookupConclusive: Bool
    public let requestOutcome: RequestOutcome
    public let businessIdentity: BusinessRecordIdentity
    /// Observed location and fields against the manifest.
    public let contentMatchesManifest: Bool
    public let metadataMatchesManifest: Bool
    /// Whether the target exposed a digest that can be compared with the source
    /// bytes. False means "cannot be proven", never "matches".
    public let targetHashVerified: Bool

    public init(observedUUID: String?, candidateCount: Int, lookupConclusive: Bool,
                requestOutcome: RequestOutcome, businessIdentity: BusinessRecordIdentity,
                contentMatchesManifest: Bool, metadataMatchesManifest: Bool,
                targetHashVerified: Bool) {
        self.observedUUID = observedUUID
        self.candidateCount = candidateCount
        self.lookupConclusive = lookupConclusive
        self.requestOutcome = requestOutcome
        self.businessIdentity = businessIdentity
        self.contentMatchesManifest = contentMatchesManifest
        self.metadataMatchesManifest = metadataMatchesManifest
        self.targetHashVerified = targetHashVerified
    }
}

public struct ImportDecision: Sendable, Equatable {
    public let outcome: ImportOutcome
    public let reason: ImportReason
    /// Non-sensitive: no paths, no field values.
    public let detail: String

    public init(_ outcome: ImportOutcome, _ reason: ImportReason, _ detail: String) {
        self.outcome = outcome
        self.reason = reason
        self.detail = detail
    }
}

public enum ImportReason: String, Codable, Sendable, CaseIterable {
    case outcomeUnknown = "outcome_unknown"
    case candidatesAmbiguous = "candidates_ambiguous"
    case searchInconclusive = "search_inconclusive"
    case alreadyVerified = "already_verified"
    case writeVerified = "write_verified"
    case confirmedButDiffers = "confirmed_but_differs"
    case absentAndConclusive = "absent_and_conclusive"
    case identityUnconfirmed = "identity_unconfirmed"
    /// The target cannot prove the content digest, so nothing is verified.
    case hashUnverified = "hash_unverified"
    /// The ledger holds no operation to continue.
    case intentMissing = "intent_missing"
    /// The clearance was decided for other facts than this operation's.
    case clearanceMismatch = "clearance_mismatch"
    /// Somebody changed the record while the operation was interrupted.
    case externalModification = "external_modification"
    /// The source bytes or their snapshot changed under the operation.
    case sourceChanged = "source_changed"
}
