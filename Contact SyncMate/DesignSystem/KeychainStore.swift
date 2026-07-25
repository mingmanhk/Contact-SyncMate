//
//  KeychainStore.swift
//  Contact SyncMate
//
//  Lightweight wrapper around the macOS Keychain for storing user secrets
//  (Anthropic API keys, OAuth client secrets, etc.). Replaces ad-hoc
//  UserDefaults usage for any value that should not be readable in plain
//  text on disk.
//
//  Items are scoped to the app's keychain access group declared in the
//  entitlements file (`keychain-access-groups`). All values are stored as
//  `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock` so
//  they survive reboots but require the device to be unlocked at least once.
//

import Foundation
import Security

public struct KeychainStore {

    /// Logical service identifier — the project's bundle ID.
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.victorlam.ContactSyncMate") {
        self.service = service
    }

    // MARK: - Public API

    /// Read a string value previously stored under `account`.
    public func string(for account: String) -> String? {
        guard let data = data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persist a string value under `account`. Pass `nil` to delete the entry.
    @discardableResult
    public func setString(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else {
            return delete(account: account)
        }
        return setData(Data(value.utf8), for: account)
    }

    /// Delete the value stored under `account`.
    @discardableResult
    public func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Internals

    private func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func setData(_ data: Data, for account: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update if present; insert if not.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}

// MARK: - Account name registry

public extension KeychainStore {
    /// Centralised account names. Adding a new secret means adding a constant
    /// here so we never typo a key.
    enum Account {
        public static let anthropicAPIKey   = "ai.anthropic.apiKey"
        public static let googleClientSecret = "com.google.oauth.clientSecret"
    }
}
