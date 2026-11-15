import Foundation

/// How much of each write tool one authorization may spend.
///
/// The limits live on `ImportWriteScope` because they are part of the approval,
/// not part of a run: a run cannot widen them, and a second run under the same
/// authorization cannot reset them.
public struct ImportWriteBudgetLimits: Sendable, Equatable, Codable {
    /// `import_file` grants (one record each).
    public let imports: Int
    /// `create_group_path` grants.
    public let groups: Int
    /// `set_record_custom_metadata` grants, across all records.
    public let metadataCalls: Int
    /// `set_record_custom_metadata` grants for any single record.
    public let metadataCallsPerRecord: Int

    public init(imports: Int, groups: Int, metadataCalls: Int, metadataCallsPerRecord: Int) {
        self.imports = imports
        self.groups = groups
        self.metadataCalls = metadataCalls
        self.metadataCallsPerRecord = metadataCallsPerRecord
    }
}

/// What an authorization has already spent.
///
/// One counter per tool, so the three budgets can be reconciled separately. The
/// per-record map is the second half of the metadata limit: a total of six calls
/// must not become six calls against one record.
public struct ImportWriteBudgetUsage: Sendable, Equatable, Codable {
    public var importsGranted: Int
    public var groupsGranted: Int
    public var metadataCalls: Int
    public var metadataCallsByRecord: [String: Int]

    public init(importsGranted: Int = 0, groupsGranted: Int = 0, metadataCalls: Int = 0,
                metadataCallsByRecord: [String: Int] = [:]) {
        self.importsGranted = importsGranted
        self.groupsGranted = groupsGranted
        self.metadataCalls = metadataCalls
        self.metadataCallsByRecord = metadataCallsByRecord
    }

    public static let zero = ImportWriteBudgetUsage()

    public func calls(forRecord uuid: String) -> Int {
        metadataCallsByRecord[uuid.uppercased()] ?? 0
    }

    /// JSON with a stable shape, suitable for persistence and evidence.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"importsGranted":0,"groupsGranted":0,"metadataCalls":0,"metadataCallsByRecord":{}}"#
        }
        return text
    }
}

/// One budget unit a permit wants to spend.
public enum ImportWriteBudgetSpend: Sendable, Equatable {
    case importRecord
    case group
    /// The record key is stored uppercase, as observed everywhere else.
    case metadata(record: String)
}

/// A refusal produced inside the journal transaction, together with the
/// authoritative usage at that moment. Carrying the snapshot lets the caller
/// report the real spend without a second read.
public struct ImportWriteBudgetRejection: Error, Equatable, Sendable {
    public enum Reason: String, Sendable, Equatable, Codable {
        case importsExhausted = "imports_exhausted"
        case groupsExhausted = "groups_exhausted"
        case metadataExhausted = "metadata_exhausted"
        case metadataRecordExhausted = "metadata_record_exhausted"
    }

    public let reason: Reason
    public let usage: ImportWriteBudgetUsage

    public init(reason: Reason, usage: ImportWriteBudgetUsage) {
        self.reason = reason
        self.usage = usage
    }
}

/// Where spent budget is recorded so a new process cannot start from zero.
///
/// The journal is keyed by the authorization digest. A run that constructs a new
/// `ImportWriteAuthorization` for the same digest restores what was already
/// spent; a run under a different authorization has its own row.
///
/// `spend` is the only mutator: the limit check and the increment happen inside
/// one transaction, so two authorization objects sharing the same identity
/// cannot both pass a check against the same old snapshot. Every method throws;
/// a journal that cannot be read or written fails the request closed.
public protocol ImportWriteBudgetJournal: Sendable {
    func budgetUsage(identity: String) throws -> ImportWriteBudgetUsage?
    /// Atomically checks `limits`, increments one unit, persists it, and returns
    /// the new usage. Throws `ImportWriteBudgetRejection` when a limit is hit.
    func spend(_ spend: ImportWriteBudgetSpend, limits: ImportWriteBudgetLimits,
               identity: String, at date: Date) throws -> ImportWriteBudgetUsage
}
