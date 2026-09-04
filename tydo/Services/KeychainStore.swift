import Foundation
import Security

/// Minimal generic-password Keychain wrapper (Security.framework — no new
/// dependency). Used for provider API keys that shouldn't live in UserDefaults.
enum KeychainStore {
    struct Error: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "Keychain \(operation) failed (OSStatus \(status))." }
    }

    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw Error(operation: "read", status: status)
        }
        return value
    }

    static func write(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else if existing == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        } else {
            throw Error(operation: "lookup", status: existing)
        }
        guard status == errSecSuccess else { throw Error(operation: "write", status: status) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(operation: "delete", status: status)
        }
    }
}
