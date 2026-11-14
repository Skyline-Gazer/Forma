import Foundation

/// A read scope a person has explicitly confirmed for a recovery check.
///
/// It is a value with a timestamp and a named confirmer, because "look at this
/// database" is an act, not a default. Nothing here can be derived from the
/// manifest, the ledger or the presence of an isolated-looking database name.
public struct ImportRecoveryScopeConfirmation: Sendable, Equatable {
    /// Canonical uppercase UUID string.
    public let databaseID: String
    /// The human label, shown in the confirmation UI and in the result summary.
    public let databaseName: String
    public let groupPath: [String]
    public let confirmedAt: Date
    /// Who confirmed it. Free text, but never empty: an unattributed scope is not
    /// a confirmation.
    public let confirmedBy: String

    public init?(databaseID: String, databaseName: String, groupPath: [String],
                 confirmedAt: Date, confirmedBy: String) {
        guard let id = UUID(uuidString: databaseID) else { return nil }
        guard !databaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !groupPath.isEmpty, !groupPath.contains(where: { $0.isEmpty }) else { return nil }
        guard !confirmedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.databaseID = id.uuidString
        self.databaseName = databaseName
        self.groupPath = groupPath
        self.confirmedAt = confirmedAt
        self.confirmedBy = confirmedBy
    }

    public var scope: ImportRecoveryScope {
        ImportRecoveryScope(databaseID: databaseID, groupPath: groupPath)
    }
}

public struct ImportRecoveryReviewReport: Sendable, Equatable {
    public let reviewedAt: Date
    public let databaseName: String
    public let groupPath: [String]
    public let results: [ImportRecoveryReviewResult]

    public init(reviewedAt: Date, databaseName: String, groupPath: [String],
                results: [ImportRecoveryReviewResult]) {
        self.reviewedAt = reviewedAt
        self.databaseName = databaseName
        self.groupPath = groupPath
        self.results = results
    }

    public var counts: [ImportRecoveryReviewResult.Outcome: Int] {
        results.reduce(into: [:]) { counts, result in counts[result.outcome, default: 0] += 1 }
    }

    /// True when every operation was either proven correct or proven to differ.
    /// Anything unverifiable or out of scope keeps the operation in
    /// `verify_required`; the report never claims otherwise.
    public var isConclusive: Bool {
        results.allSatisfy { $0.outcome == .verified || $0.outcome == .differs }
    }
}

/// Runs the read-only recovery check for a confirmed scope.
///
/// Two properties matter and both are structural:
///
/// 1. **It only has a read transport.** There is no write surface in this type,
///    so a recovery check cannot create a record or write metadata even by
///    mistake.
/// 2. **Out-of-scope work never reaches the transport.** The reviewer refuses a
///    database or group mismatch before it reads anything, and this type does not
///    widen the scope on its own.
///
/// It also does not write the ledger: a conclusion is shown to a person, and the
/// operation stays `verify_required` until somebody decides what to do.
public struct ImportRecoveryCoordinator: Sendable {
    private let reviewer: ImportRecoveryReviewer

    public init(read: any ImportReadTransport) {
        reviewer = ImportRecoveryReviewer(read: read)
    }

    public func review(_ entries: [ImportRecoveryEntry],
                       scope: ImportRecoveryScopeConfirmation,
                       at date: Date = Date()) async -> ImportRecoveryReviewReport {
        var results: [ImportRecoveryReviewResult] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            // The reviewer checks the database and the group before reading; an
            // entry that does not belong to the confirmed scope is reported as
            // such and costs no call.
            let result = await reviewer.review(entry, scope: scope.scope)
            results.append(result)
        }
        return ImportRecoveryReviewReport(reviewedAt: date, databaseName: scope.databaseName,
                                          groupPath: scope.groupPath, results: results)
    }
}
