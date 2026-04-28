import Foundation
import Security

/// Lightweight Keychain wrapper for storing API keys and credentials.
///
/// Each `KeychainStore` instance is scoped to a `service` name (e.g.
/// `"com.example.dictation"` or `"com.example.meetings"`). Keys within the
/// service are identified by an account name string.
///
/// All operations are synchronous (the Keychain is internally thread-safe).
public struct KeychainStore: Sendable {

    private let service: String

    // MARK: - Init

    public init(service: String) {
        self.service = service
    }

    // MARK: - Public API

    /// Save a string value for `key`. Overwrites any existing value.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first to allow overwrite.
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Load the string value stored for `key`. Returns `nil` if not found.
    public func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    /// Delete the stored value for `key`.
    @discardableResult
    public func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
