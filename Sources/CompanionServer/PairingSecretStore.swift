import Foundation
import Security

/// Persists the pairing secrets (base64, keyed by device id) that paired
/// phones prove they hold. Injected so tests never touch the real Keychain.
@MainActor
public protocol PairingSecretStore: AnyObject {
    /// Returns nil when nothing has been stored yet.
    func loadSecrets() throws -> [String: String]?
    func saveSecrets(_ secrets: [String: String]) throws
}

public enum PairingSecretStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case corruptItem

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .corruptItem:
            return "Stored pairing secrets could not be read."
        }
    }
}

/// Keeps all pairing secrets in one generic-password item in the login
/// keychain. It deliberately sets no access group and does not opt into the
/// data protection keychain: both need the keychain-access-groups entitlement,
/// which neither the sandboxed App Store build nor the dev build has. Without
/// them a sandboxed app can still read and write its own generic passwords.
@MainActor
public final class KeychainPairingSecretStore: PairingSecretStore {
    public static let defaultService = "com.replaycap.companion.pairing-secrets"
    private static let account = "pairedDeviceSecrets"

    private let service: String

    public init(service: String = KeychainPairingSecretStore.defaultService) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }

    public func loadSecrets() throws -> [String: String]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw PairingSecretStoreError.corruptItem }
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                throw PairingSecretStoreError.corruptItem
            }
        case errSecItemNotFound:
            return nil
        default:
            throw PairingSecretStoreError.keychain(status)
        }
    }

    public func saveSecrets(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ReplayCap companion pairing"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PairingSecretStoreError.keychain(addStatus) }
        default:
            throw PairingSecretStoreError.keychain(updateStatus)
        }
    }
}

/// Process-local store for tests and previews.
@MainActor
public final class InMemoryPairingSecretStore: PairingSecretStore {
    public private(set) var storedSecrets: [String: String]?
    /// When set, `saveSecrets` throws it instead of storing anything.
    public var saveError: Error?

    public init(secrets: [String: String]? = nil) {
        self.storedSecrets = secrets
    }

    public func loadSecrets() throws -> [String: String]? {
        storedSecrets
    }

    public func saveSecrets(_ secrets: [String: String]) throws {
        if let saveError { throw saveError }
        storedSecrets = secrets
    }
}
