import Foundation

/// The snapshot a citation has to describe.
///
/// A registered row names the snapshot it was read from. The manifest entry
/// names the snapshot its values describe. A citation is only evidence when
/// the two are the same snapshot, and the review screen has to be able to
/// say so before the reviewer ticks a row - otherwise the screen presents an
/// old version of a file as if it were the one in front of them.
public struct EvidenceSnapshotBinding: Equatable, Sendable {
    /// The snapshot revision the rows were read from.
    public let revision: Int
    /// The fingerprint of that snapshot: the same file can be read twice and
    /// hash the same, and the revision alone would not say so.
    public let fingerprint: String

    public init(revision: Int, fingerprint: String) {
        self.revision = revision
        self.fingerprint = fingerprint
    }
}

/// Whether a registered row can still be cited.
public enum EvidenceCurrency: String, Equatable, Sendable {
    /// The row describes the snapshot under correction.
    case current
    /// The row was read from a snapshot the file has since left. It is not
    /// wrong - it describes an older version faithfully - but it cannot
    /// support a value about the current one.
    case expired
    /// The row could not be read as text, so it cannot support any value.
    case unusable

    /// The currency of one row against the snapshot under correction.
    public static func currency(of record: EvidenceRecord, against binding: EvidenceSnapshotBinding) -> EvidenceCurrency {
        if !record.isUsable { return .unusable }
        if record.snapshotRevision == binding.revision,
           record.snapshotFingerprint == binding.fingerprint { return .current }
        return .expired
    }
}

/// What the review screen says about a row's currency.
///
/// The sentences are here rather than in a view because the same wording is
/// needed in two places - the evidence card and the correction sheet - and
/// one reviewer's screen must not call the same row current in one place and
/// expired in the other.
public enum EvidenceCurrencyCopy {
    /// The badge on a row that no longer describes the file.
    public static let expiredBadge = "已过期"
    /// What to do about it.
    public static let expiredSentence = "这份证据读自文件的旧版本，不能用来支持对当前文件的修订。"
    /// The action that produces current rows.
    public static let rereadAction = "重新读取证据"
    /// What the action reports.
    public static let rereadHint = "重新读取会按当前版本重新提取正文；读取后请重新选择要引用的证据。"
    /// The badge on a row the program could not read.
    public static let unusableBadge = "不可读取"
}
