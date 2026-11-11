import Foundation
import Security

/// Secrets live ONLY in the macOS Keychain (never UserDefaults, never plain files).
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus) }
    public let service: String
    public init(service: String = "com.jarvisos.app") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var q = baseQuery(account)
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecSuccess {
            let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard s == errSecSuccess else { throw KeychainError.unexpectedStatus(s) }
        } else {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly   // no iCloud sync, no backups
            let s = SecItemAdd(q as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainError.unexpectedStatus(s) }
        }
    }
    public func get(account: String) throws -> String? {
        var q = baseQuery(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw KeychainError.unexpectedStatus(s) }
        return String(data: d, encoding: .utf8)
    }
    public func delete(account: String) throws {
        let s = SecItemDelete(baseQuery(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError.unexpectedStatus(s) }
    }
}
