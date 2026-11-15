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

    func save(budgetUsage: ImportWriteBudgetUsage, identity: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        if writesFail { throw FormaError.storage }
        rows[identity] = budgetUsage
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
