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

/// Where spent budget is recorded so a new process cannot start from zero.
///
/// The journal is keyed by the authorization digest. A run that constructs a new
/// `ImportWriteAuthorization` for the same digest restores what was already
/// spent; a run under a different authorization has its own row.
///
/// Both methods throw. A journal that cannot be read or written fails the
/// request closed: an unrecorded grant would be budget the ledger never saw.
public protocol ImportWriteBudgetJournal: Sendable {
    func budgetUsage(identity: String) throws -> ImportWriteBudgetUsage?
    func save(budgetUsage: ImportWriteBudgetUsage, identity: String, at date: Date) throws
}
