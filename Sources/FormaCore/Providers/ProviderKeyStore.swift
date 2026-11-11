import Foundation
import Security

protocol ProviderKeyStore: Sendable {
    func save(_ key: String, for provider: ProbeProvider) throws
    func load(for provider: ProbeProvider) throws -> String?
}

struct KeychainProviderKeyStore: ProviderKeyStore {
    func save(_ key: String, for provider: ProbeProvider) throws {
        let query = query(for: provider)
        let data = Data(key.utf8)
        var item = query
        item[kSecValueData as String] = data

        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let value = [kSecValueData as String: data]
            guard SecItemUpdate(query as CFDictionary, value as CFDictionary) == errSecSuccess else {
                throw FormaError.storage
            }
        default:
            throw FormaError.storage
        }
    }

    func load(for provider: ProbeProvider) throws -> String? {
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?

        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw FormaError.storage
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw FormaError.storage
        }
    }

    private func query(for provider: ProbeProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.skyline-gazer.forma.provider-api-key",
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
