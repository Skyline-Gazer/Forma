import Foundation
import Security
import Testing
@testable import FormaCore

/// An in-memory keychain. It exists so the lifecycle — save, rotate, delete,
/// locked, legacy, migrate, roll back — is tested as behaviour rather than as
/// calls to `SecItem` that only a Mac can answer.
private final class MemoryKeychain: KeychainBackend, @unchecked Sendable {
    private struct Item {
        var secret: Data
        var accessible: KeychainAccessibility
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private(set) var locked = false

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }

    /// Simulates the keychain being locked. Named apart from the `lock` property
    /// on purpose: a method and a property cannot share a name.
    func lockDown() { lock.withLock { locked = true } }

    func add(service: String, account: String, secret: Data,
             accessible: KeychainAccessibility) throws -> Bool {
        try lock.withLock {
            if locked { throw FormaError.credentialLocked }
            let key = key(service, account)
            guard items[key] == nil else { return false }
            items[key] = Item(secret: secret, accessible: accessible)
            return true
        }
    }

    func update(service: String, account: String, secret: Data) throws {
        try lock.withLock {
            if locked { throw FormaError.credentialLocked }
            let key = key(service, account)
            guard var item = items[key] else { throw FormaError.credentialMissing }
            item.secret = secret
            items[key] = item
        }
    }

    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            if locked { throw FormaError.credentialLocked }
            return items[key(service, account)]?.secret
        }
    }

    func attributes(service: String, account: String) throws -> [String: Any]? {
        try lock.withLock {
            if locked { throw FormaError.credentialLocked }
            guard let item = items[key(service, account)] else { return nil }
            return [kSecAttrAccessible as String: item.accessible.securityValue as String]
        }
    }

    func delete(service: String, account: String) throws {
        try lock.withLock {
            if locked { throw FormaError.credentialLocked }
            items.removeValue(forKey: key(service, account))
        }
    }

    func has(service: String, account: String) -> Bool {
        lock.withLock { items[key(service, account)] != nil }
    }
}

private func store(_ backend: MemoryKeychain, service: String = "synthetic.current",
                   accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly)
    -> KeychainCredentialStore {
    KeychainCredentialStore(service: service, accessibility: accessibility, backend: backend)
}

@Suite("Keychain credential lifecycle")
struct KeychainCredentialStoreTests {
    @Test func savingRecordsTheSecretAndTheDeviceOnlyAttribute() throws {
        let backend = MemoryKeychain()
        let store = store(backend)

        try store.save("sk-synthetic", for: .openAI)
        #expect(try store.load(for: .openAI) == "sk-synthetic")
        #expect(try store.accessibility(for: .openAI) == .whenUnlockedThisDeviceOnly)
    }

    @Test func savingTwiceReplacesTheSecretWithoutDuplicating() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try store.save("first", for: .openAI)
        try store.save("second", for: .openAI)
        #expect(try store.load(for: .openAI) == "second")
    }

    @Test func deleteIsIdempotent() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try store.save("secret", for: .openAI)
        try store.delete(for: .openAI)
        #expect(try store.load(for: .openAI) == nil)
        // Deleting what is not there is success, so a retry is safe.
        try store.delete(for: .openAI)
    }

    @Test func rotationRequiresAnExistingCredential() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        #expect(throws: FormaError.credentialMissing) {
            try store.rotate("rotated", for: .openAI)
        }
        try store.save("original", for: .openAI)
        try store.rotate("rotated", for: .openAI)
        #expect(try store.load(for: .openAI) == "rotated")
    }

    @Test func aLockedKeychainIsNotReportedAsMissing() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try store.save("secret", for: .openAI)
        backend.lockDown()

        // "Locked" and "not saved" are different: one needs the user to unlock,
        // the other needs the user to save a key.
        #expect(throws: FormaError.credentialLocked) { try store.load(for: .openAI) }
        #expect(throws: FormaError.credentialLocked) { try store.save("new", for: .openAI) }
    }

    @Test func theLegacyProbeReadsWithoutWriting() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try backend.add(service: "synthetic.legacy", account: ProbeProvider.openAI.rawValue,
                        secret: Data("old".utf8), accessible: .whenUnlockedThisDeviceOnly)

        #expect(try store.readLegacy("synthetic.legacy", for: .openAI) == "old")
        #expect(try store.load(for: .openAI) == nil)
        #expect(backend.has(service: "synthetic.legacy", account: ProbeProvider.openAI.rawValue))
    }

    @Test func migrationCopiesAndKeepsTheLegacyItem() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try backend.add(service: "synthetic.legacy", account: ProbeProvider.openAI.rawValue,
                        secret: Data("old".utf8), accessible: .whenUnlockedThisDeviceOnly)

        let outcome = try store.migrate(from: "synthetic.legacy", providers: [.openAI])
        #expect(outcome == .migrated([.openAI]))
        #expect(try store.load(for: .openAI) == "old")
        // The copy is verified, and the original stays as the rollback point.
        #expect(backend.has(service: "synthetic.legacy", account: ProbeProvider.openAI.rawValue))
    }

    @Test func migrationWithoutARenameIsRefused() throws {
        let backend = MemoryKeychain()
        let store = store(backend, service: "synthetic.same")
        #expect(try store.migrate(from: "synthetic.same", providers: [.openAI]) == .noRenameConfigured)
        #expect(KeychainCredentialStore.migrationPlan(legacyService: "synthetic.same",
                                                      currentService: "synthetic.same").readiness
                == .noRenameConfigured)
        #expect(KeychainCredentialStore.migrationPlan(legacyService: "synthetic.legacy",
                                                      currentService: "synthetic.same").readiness == .ready)
    }

    @Test func migrationWithNothingToCopySaysSo() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        #expect(try store.migrate(from: "synthetic.empty", providers: [.openAI]) == .nothingToMigrate)
    }

    @Test func rollbackRemovesOnlyTheCurrentService() throws {
        let backend = MemoryKeychain()
        let store = store(backend)
        try backend.add(service: "synthetic.legacy", account: ProbeProvider.openAI.rawValue,
                        secret: Data("old".utf8), accessible: .whenUnlockedThisDeviceOnly)
        _ = try store.migrate(from: "synthetic.legacy", providers: [.openAI])

        let outcome = try store.rollbackMigration(providers: [.openAI])
        #expect(outcome == .rolledBack([.openAI]))
        #expect(try store.load(for: .openAI) == nil)
        #expect(try store.readLegacy("synthetic.legacy", for: .openAI) == "old")
    }

    /// The one test that touches the real login keychain. It uses a service name
    /// that exists only for this run, and removes it again.
    @Test func realKeychainRoundTripUsesDeviceOnlyAccessibility() throws {
        let service = "io.github.skyline-gazer.forma.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer { try? store.delete(for: .openAI) }

        try store.save("synthetic-key", for: .openAI)
        #expect(try store.load(for: .openAI) == "synthetic-key")
        #expect(try store.accessibility(for: .openAI) == .whenUnlockedThisDeviceOnly)

        try store.rotate("rotated-key", for: .openAI)
        #expect(try store.load(for: .openAI) == "rotated-key")

        try store.delete(for: .openAI)
        #expect(try store.load(for: .openAI) == nil)
    }
}
