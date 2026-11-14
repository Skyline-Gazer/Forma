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

/// What the keychain can say about an item's accessibility attribute.
///
/// Three answers, because on macOS there are three situations and collapsing them
/// would make "not observable" look like "not stored" or like the value we asked
/// for. The last case is a claim; the middle one is explicitly not a claim.
public enum KeychainAccessibilityObservation: Sendable, Equatable {
    case missing
    /// The item exists, but this keychain does not report the attribute. The
    /// stored value is neither confirmed nor contradicted.
    case presentUnobservable
    case verified(KeychainAccessibility)
}

/// Whether the data-protection keychain is usable here, and whether it exposes
/// the attribute.
///
/// The field run found items in the data-protection keychain still reported no
/// `pdmn`. This probe makes that an observation instead of an assumption: it
/// writes, reads and deletes one synthetic item under a throwaway service, so
/// `.usable` is never claimed without a successful round trip.
public enum DataProtectionKeychainProbe {
    public struct Report: Sendable, Equatable {
        public let usable: Bool
        /// The `OSStatus` that stopped the probe, when it was not usable.
        public let status: Int32?
        /// True only when `kSecAttrAccessible` came back from the same keychain.
        public let accessibilityVisible: Bool
    }

    public static func run(service: String) -> Report {
        let account = "attribute-probe"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        defer { SecItemDelete(base as CFDictionary) }
        guard addStatus == errSecSuccess else {
            return Report(usable: false, status: addStatus, accessibilityVisible: false)
        }

        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, data == Data("probe".utf8) else {
            return Report(usable: false, status: errSecInternalError, accessibilityVisible: false)
        }

        var attributesQuery = base
        attributesQuery[kSecReturnAttributes as String] = true
        attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var attributes: CFTypeRef?
        guard SecItemCopyMatching(attributesQuery as CFDictionary, &attributes) == errSecSuccess,
              let dictionary = attributes as? [String: Any] else {
            return Report(usable: true, status: nil, accessibilityVisible: false)
        }
        let visible = dictionary[kSecAttrAccessible as String] as? String != nil
        return Report(usable: true, status: nil, accessibilityVisible: visible)
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

    /// What can be said about the stored accessibility attribute.
    ///
    /// On macOS the file-based login keychain returns only `acct / cdat / class /
    /// labl / mdat / svce` from `SecItemCopyMatching` — no `pdmn` — so "the item
    /// exists" and "the item has the attribute we asked for" are different facts.
    /// The field run proved this on macOS 27, and `security find-generic-password -g`
    /// does not print the attribute either. Reporting `nil` for an existing item
    /// would have meant "not verified" and "no item" were the same answer, which
    /// is exactly the kind of conflation this project forbids.
    public func accessibility(for provider: ProbeProvider) throws -> KeychainAccessibilityObservation {
        guard let attributes = try backend.attributes(service: service, account: provider.rawValue) else {
            return .missing
        }
        guard let raw = attributes[kSecAttrAccessible as String] as? String,
              let observed = KeychainAccessibility(securityValue: raw) else {
            // Present, but this keychain does not expose the attribute (or exposes
            // a value this build does not recognise). Never substituted with the
            // value we requested.
            return .presentUnobservable
        }
        return .verified(observed)
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
