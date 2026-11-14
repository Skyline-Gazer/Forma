import Foundation
import Security

/// The provider-key surface the probe and mapping clients use.
///
/// It stays deliberately small: those callers only ever save and load. The wider
/// lifecycle (delete, rotate, accessibility, migration) lives on
/// `KeychainCredentialStore`, so a test double for a provider client never has to
/// pretend to be a keychain.
protocol ProviderKeyStore: Sendable {
    func save(_ key: String, for provider: ProbeProvider) throws
    func load(for provider: ProbeProvider) throws -> String?
}

/// How a stored credential may be read back.
///
/// The default is device-only: a credential that never leaves this Mac is worth
/// more than one that syncs to every device the account signs in on.
public enum KeychainAccessibility: String, Sendable, Equatable, CaseIterable {
    case whenUnlockedThisDeviceOnly = "when_unlocked_this_device_only"
    case afterFirstUnlockThisDeviceOnly = "after_first_unlock_this_device_only"

    var securityValue: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    init?(securityValue: String) {
        if securityValue == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) {
            self = .whenUnlockedThisDeviceOnly
        } else if securityValue == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            self = .afterFirstUnlockThisDeviceOnly
        } else {
            return nil
        }
    }
}

/// The keychain operations, as a protocol, so the lifecycle can be tested
/// without touching the login keychain.
protocol KeychainBackend: Sendable {
    /// Returns false when the item already exists (the caller updates it).
    func add(service: String, account: String, secret: Data,
             accessible: KeychainAccessibility) throws -> Bool
    func update(service: String, account: String, secret: Data) throws
    func read(service: String, account: String) throws -> Data?
    func attributes(service: String, account: String) throws -> [String: Any]?
    func delete(service: String, account: String) throws
}

/// `SecItem` backed by the login keychain.
///
/// Every failure is translated once, here: `errSecInteractionNotAllowed` means the
/// keychain is locked (a state the UI must explain), everything else is a storage
/// failure. Nothing in this file logs a secret.
struct SecurityKeychainBackend: KeychainBackend {
    func add(service: String, account: String, secret: Data,
             accessible: KeychainAccessibility) throws -> Bool {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessible.securityValue,
            kSecValueData as String: secret,
        ]
        switch SecItemAdd(attributes as CFDictionary, nil) {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        case errSecInteractionNotAllowed:
            throw FormaError.credentialLocked
        default:
            throw FormaError.storage
        }
    }

    func update(service: String, account: String, secret: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let value = [kSecValueData as String: secret]
        switch SecItemUpdate(query as CFDictionary, value as CFDictionary) {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw FormaError.credentialMissing
        case errSecInteractionNotAllowed:
            throw FormaError.credentialLocked
        default:
            throw FormaError.storage
        }
    }

    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { throw FormaError.storage }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw FormaError.credentialLocked
        default:
            throw FormaError.storage
        }
    }

    func attributes(service: String, account: String) throws -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            return item as? [String: Any]
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw FormaError.credentialLocked
        default:
            throw FormaError.storage
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch SecItemDelete(query as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecInteractionNotAllowed:
            throw FormaError.credentialLocked
        default:
            throw FormaError.storage
        }
    }
}

/// The provider credential lifecycle.
///
/// The service name is the one already in use. It is deliberately **not** renamed
/// to match the bundle identifier: a rename would orphan every stored key, and
/// chasing naming consistency is not worth that. A future rename has to go
/// through `migrate(from:providers:)`, which copies and verifies before anything
/// is removed.
public struct KeychainCredentialStore: Sendable {
    /// The service this build reads and writes.
    public static let serviceName = "com.skyline-gazer.forma.provider-api-key"
    public static let defaultAccessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly

    private let service: String
    private let accessibility: KeychainAccessibility
    private let backend: any KeychainBackend

    public init(service: String = KeychainCredentialStore.serviceName,
                accessibility: KeychainAccessibility = KeychainCredentialStore.defaultAccessibility) {
        self.init(service: service, accessibility: accessibility, backend: SecurityKeychainBackend())
    }

    init(service: String, accessibility: KeychainAccessibility, backend: any KeychainBackend) {
        self.service = service
        self.accessibility = accessibility
        self.backend = backend
    }

    public var serviceIdentifier: String { service }

    /// Adds a credential, or replaces the secret of an existing one. The
    /// accessibility attribute is only applied when the item is created: changing
    /// it later would require re-adding the item, which is a migration, not a save.
    public func save(_ secret: String, for provider: ProbeProvider) throws {
        let data = Data(secret.utf8)
        if try backend.add(service: service, account: provider.rawValue, secret: data,
                           accessible: accessibility) {
            return
        }
        try backend.update(service: service, account: provider.rawValue, secret: data)
    }

    public func load(for provider: ProbeProvider) throws -> String? {
        guard let data = try backend.read(service: service, account: provider.rawValue) else {
            return nil
        }
        guard let secret = String(data: data, encoding: .utf8) else { throw FormaError.storage }
        return secret
    }

    /// Removes the credential. Idempotent: deleting what is not there is success.
    public func delete(for provider: ProbeProvider) throws {
        try backend.delete(service: service, account: provider.rawValue)
    }

    /// Replaces an existing credential. A missing one is an error, not a create:
    /// rotation is a maintenance action on something the user already has.
    public func rotate(_ secret: String, for provider: ProbeProvider) throws {
        guard try load(for: provider) != nil else { throw FormaError.credentialMissing }
        try backend.update(service: service, account: provider.rawValue, secret: Data(secret.utf8))
    }

    /// The accessibility attribute actually stored, or nil when no item exists.
    public func accessibility(for provider: ProbeProvider) throws -> KeychainAccessibility? {
        guard let attributes = try backend.attributes(service: service, account: provider.rawValue),
              let raw = attributes[kSecAttrAccessible as String] as? String else { return nil }
        return KeychainAccessibility(securityValue: raw)
    }

    /// Reads a credential from another service without writing anything there.
    /// Used to check whether a legacy item exists before any migration is planned.
    public func readLegacy(_ legacyService: String, for provider: ProbeProvider) throws -> String? {
        guard let data = try backend.read(service: legacyService, account: provider.rawValue) else {
            return nil
        }
        guard let secret = String(data: data, encoding: .utf8) else { throw FormaError.storage }
        return secret
    }

    // MARK: - Migration

    /// A migration is only meaningful when the service name is actually changing.
    public static func migrationPlan(legacyService: String,
                                     currentService: String = KeychainCredentialStore.serviceName)
        -> KeychainMigrationPlan {
        KeychainMigrationPlan(legacyService: legacyService, currentService: currentService)
    }

    /// Copies legacy items into this service, verifies each copy, and leaves the
    /// legacy items in place. Nothing is deleted, so a failed migration is
    /// recoverable by doing nothing.
    public func migrate(from legacyService: String,
                        providers: [ProbeProvider]) throws -> KeychainMigrationOutcome {
        guard legacyService != service else { return .noRenameConfigured }
        var migrated: [ProbeProvider] = []
        for provider in providers {
            guard let secret = try readLegacy(legacyService, for: provider) else { continue }
            try save(secret, for: provider)
            guard try load(for: provider) == secret else {
                throw FormaError.storage
            }
            migrated.append(provider)
        }
        return migrated.isEmpty ? .nothingToMigrate : .migrated(migrated)
    }

    /// Removes the items this service holds, which is what a migration would have
    /// created. The legacy service is untouched.
    public func rollbackMigration(providers: [ProbeProvider]) throws -> KeychainMigrationOutcome {
        var removed: [ProbeProvider] = []
        for provider in providers {
            guard try load(for: provider) != nil else { continue }
            try delete(for: provider)
            removed.append(provider)
        }
        return removed.isEmpty ? .nothingToMigrate : .rolledBack(removed)
    }
}

public struct KeychainMigrationPlan: Sendable, Equatable {
    public enum Readiness: String, Sendable, Equatable {
        /// The service name is not changing; there is nothing to migrate.
        case noRenameConfigured = "no_rename_configured"
        /// A rename is configured; the caller may run `migrate(from:providers:)`.
        case ready
    }

    public let legacyService: String
    public let currentService: String
    public let readiness: Readiness

    public init(legacyService: String, currentService: String) {
        self.legacyService = legacyService
        self.currentService = currentService
        self.readiness = legacyService == currentService ? .noRenameConfigured : .ready
    }
}

public enum KeychainMigrationOutcome: Sendable, Equatable {
    case noRenameConfigured
    case nothingToMigrate
    case migrated([ProbeProvider])
    case rolledBack([ProbeProvider])
}

/// The provider-facing adapter. It uses the same store, so new writes get the
/// device-only accessibility attribute instead of the previous implicit default.
struct KeychainProviderKeyStore: ProviderKeyStore {
    private let store = KeychainCredentialStore()

    func save(_ key: String, for provider: ProbeProvider) throws {
        try store.save(key, for: provider)
    }

    func load(for provider: ProbeProvider) throws -> String? {
        try store.load(for: provider)
    }
}
