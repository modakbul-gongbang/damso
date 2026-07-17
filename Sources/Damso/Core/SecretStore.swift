import Foundation
import Security

protocol SecretStore {
    func read(service: String, account: String) throws -> Data?
    func write(_ value: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

enum DamsoSecrets {
    static let service = "com.damso.app"
    static let plaudSessionAccount = "plaud.session"
}

/// The Plaud session is intentionally opaque to the rest of the app. It is not
/// part of the canonical meeting store, operation ledger, or diagnostics export.
final class PlaudSessionSecretStore {
    private let backing: SecretStore

    init(backing: SecretStore = KeychainSecretStore()) {
        self.backing = backing
    }

    func load() throws -> Data? {
        try backing.read(service: DamsoSecrets.service, account: DamsoSecrets.plaudSessionAccount)
    }

    func save(_ session: Data) throws {
        try backing.write(session, service: DamsoSecrets.service, account: DamsoSecrets.plaudSessionAccount)
    }

    func clear() throws {
        try backing.delete(service: DamsoSecrets.service, account: DamsoSecrets.plaudSessionAccount)
    }
}

final class KeychainSecretStore: SecretStore {
    func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return result as? Data
    }

    func write(_ value: Data, service: String, account: String) throws {
        try delete(service: service, account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

final class InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        values["\(service):\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        values["\(service):\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service):\(account)")
    }
}
