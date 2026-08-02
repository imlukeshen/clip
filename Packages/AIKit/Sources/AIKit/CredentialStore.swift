import Foundation
import Security

/// Stores provider credentials in the user's unlocked keychain.
public actor CredentialStore {
    private let service: String

    public init(service: String = "app.reel.editor.ai") { self.service = service }

    public func store(_ key: String, provider: ProviderID) throws {
        try delete(provider: provider)
        let status = SecItemAdd(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: provider.rawValue,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
                kSecValueData: Data(key.utf8),
            ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    public func key(for provider: ProviderID) throws -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: provider.rawValue,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
            let key = String(data: data, encoding: .utf8)
        else { throw CredentialError.keychain(status) }
        return key
    }

    public func delete(provider: ProviderID) throws {
        let status = SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: provider.rawValue,
            ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    public func configuredProviders() throws -> [ProviderID] {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ] as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        let rows = value as? [[CFString: Any]] ?? []
        return rows.compactMap { row in
            (row[kSecAttrAccount] as? String).map { ProviderID(rawValue: $0) }
        }.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Keychain failures without exposing credential material.
public enum CredentialError: Error, Sendable, Equatable { case keychain(OSStatus) }
