import Foundation
import OSLog
import Security

enum KeychainError: Error, Equatable {
    case itemNotFound
    case accessDenied
    case unexpectedStatus(OSStatus)
}

/// Thin wrapper around the iOS Keychain for storing short strings (tokens,
/// API keys). One instance per logical secret namespace — pass the
/// `service` identifier at init. Items are pinned to the device
/// (`AfterFirstUnlockThisDeviceOnly`) and never sync via iCloud.
struct KeychainSecretStore {
    let service: String

    /// Returns the stored value, `nil` when not found, or throws `KeychainError`
    /// when the Keychain itself is inaccessible (e.g. `.accessDenied`).
    func readOrThrow(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func read(account: String) -> String? {
        do {
            return try readOrThrow(account: account)
        } catch KeychainError.itemNotFound {
            return nil
        } catch {
            // .accessDenied or .unexpectedStatus — device locked or Keychain
            // unavailable. Log for diagnostics but do not silently drop the key.
            AppLogger.persistence.warning("Keychain read failed for '\(account, privacy: .public)': \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            for (key, value) in attributes { insert[key] = value }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
