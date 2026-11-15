import Foundation

@testable import FormaCore

/// A journal that records spends in memory and can be told to fail, so the
/// "journal unavailable" branch is testable without a database.
final class MemoryBudgetJournal: ImportWriteBudgetJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: ImportWriteBudgetUsage] = [:]
    private var readsFail = false
    private var writesFail = false
    private var writes = 0

    func budgetUsage(identity: String) throws -> ImportWriteBudgetUsage? {
        lock.lock()
        defer { lock.unlock() }
        if readsFail { throw FormaError.storage }
        return rows[identity]
    }

    /// The check and the increment happen under the same lock, matching the
    /// SQLite journal's single-transaction contract.
    func spend(_ spend: ImportWriteBudgetSpend, limits: ImportWriteBudgetLimits,
               identity: String, at date: Date) throws -> ImportWriteBudgetUsage {
        lock.lock()
        defer { lock.unlock() }
        if readsFail { throw FormaError.storage }
        var usage = rows[identity] ?? .zero
        switch spend {
        case .importRecord:
            guard usage.importsGranted < limits.imports else {
                throw ImportWriteBudgetRejection(reason: .importsExhausted, usage: usage)
            }
            usage.importsGranted += 1
        case .group:
            guard usage.groupsGranted < limits.groups else {
                throw ImportWriteBudgetRejection(reason: .groupsExhausted, usage: usage)
            }
            usage.groupsGranted += 1
        case .metadata(let record):
            let key = record.uppercased()
            guard usage.metadataCalls < limits.metadataCalls else {
                throw ImportWriteBudgetRejection(reason: .metadataExhausted, usage: usage)
            }
            guard usage.calls(forRecord: key) < limits.metadataCallsPerRecord else {
                throw ImportWriteBudgetRejection(reason: .metadataRecordExhausted, usage: usage)
            }
            usage.metadataCalls += 1
            usage.metadataCallsByRecord[key, default: 0] += 1
        }
        if writesFail { throw FormaError.storage }
        writes += 1
        rows[identity] = usage
        return usage
    }

    func setReadsFail(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        readsFail = value
    }

    func setWritesFail(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        writesFail = value
    }

    func writeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    func usage(identity: String) -> ImportWriteBudgetUsage? {
        lock.lock(); defer { lock.unlock() }
        return rows[identity]
    }
}
