import Foundation
import Security

public enum CredentialError: Error, LocalizedError, Sendable {
    case missingCredentials(instanceName: String)
    case keychainFailure(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let instanceName):
            return "Credentials not found for '\(instanceName)'. Configure them in Settings."
        case .keychainFailure(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

public struct MeuralCredentials: Sendable, Equatable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public protocol CredentialStoring: Sendable {
    func getCredentials(for instanceName: String) throws -> MeuralCredentials
    func setCredentials(_ credentials: MeuralCredentials, for instanceName: String) throws
    func hasCredentials(for instanceName: String) -> Bool
    func deleteCredentials(for instanceName: String) throws
    func getCachedToken(for instanceName: String) -> String?
    func setCachedToken(_ token: String, for instanceName: String) throws
    func clearCachedToken(for instanceName: String)
}

/// Low-level Keychain operations, abstracted so unit tests can verify caching,
/// consolidation, migration, and prompt-free existence checks without touching
/// the user's real macOS Login Keychain.
public protocol KeychainBackend: Sendable {
    func readData(service: String, account: String) -> KeychainReadResult
    func readCommentAttribute(service: String, account: String) -> String?
    func itemExists(service: String, account: String) -> Bool
    func saveData(_ data: Data, comment: String?, service: String, account: String) throws
    func deleteItem(service: String, account: String)
}

public enum KeychainReadResult: Sendable, Equatable {
    case found(Data)
    case notFound
    case error(OSStatus)
}

public struct SystemKeychainBackend: KeychainBackend {
    public init() {}

    public func readData(service: String, account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return .found(data)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        return .error(status)
    }

    /// Reads only item metadata (`kSecReturnAttributes` without `kSecReturnData`),
    /// which does NOT trigger a macOS Keychain authorization prompt.
    public func readCommentAttribute(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let comment = attrs[kSecAttrComment as String] as? String
        else {
            return nil
        }
        return comment
    }

    /// Checks item existence using `kSecReturnAttributes` (without `kSecReturnData`),
    /// avoiding macOS Keychain password prompts.
    public func itemExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func saveData(_ data: Data, comment: String?, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        if let comment {
            attributes[kSecAttrComment as String] = comment
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            if let comment {
                addQuery[kSecAttrComment as String] = comment
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.keychainFailure(status: addStatus)
            }
            return
        }
        throw CredentialError.keychainFailure(status: updateStatus)
    }

    public func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct StoredAccount: Codable, Sendable, Equatable {
    var email: String
    var password: String
    var token: String?

    var hasValidCredentials: Bool {
        !email.isEmpty && !password.isEmpty
    }
}

private final class VaultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [String: [String: StoredAccount]] = [:]

    func get(service: String) -> [String: StoredAccount]? {
        lock.lock()
        defer { lock.unlock() }
        return vaults[service]
    }

    func withTransaction<T>(_ body: (inout [String: [String: StoredAccount]]) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&vaults)
    }
}

/// Secure credential storage using macOS Keychain (`Security.framework`).
///
/// Consolidates all instances' credentials and cached tokens into a single Keychain
/// item (`meural_credentials_v1`) with an in-memory cache and prompt-free existence
/// checks (`kSecReturnAttributes`), dramatically reducing macOS Keychain prompts.
/// Automatically migrates legacy per-field (`_email`, `_password`, `_token`) items.
public struct KeychainCredentialStore: CredentialStoring {
    public static let vaultAccountName = "meural_credentials_v1"
    private static let sharedCache = VaultCache()

    public let serviceName: String
    private let backend: any KeychainBackend
    private let cache: VaultCache

    public init(serviceName: String = "com.ablyler.MeuralSync") {
        self.serviceName = serviceName
        self.backend = SystemKeychainBackend()
        self.cache = Self.sharedCache
    }

    /// Initializer for unit testing with an isolated cache and mock Keychain backend.
    public init(serviceName: String, backend: any KeychainBackend) {
        self.serviceName = serviceName
        self.backend = backend
        self.cache = VaultCache()
    }

    public func getCredentials(for instanceName: String) throws -> MeuralCredentials {
        try cache.withTransaction { vaults in
            var vault = try loadVaultLocked(vaults: &vaults)
            if let account = vault[instanceName], account.hasValidCredentials {
                return MeuralCredentials(email: account.email, password: account.password)
            }
            if let migrated = try migrateLegacyAccountIfPresentLocked(instanceName, into: &vault, vaults: &vaults),
               migrated.hasValidCredentials
            {
                return MeuralCredentials(email: migrated.email, password: migrated.password)
            }
            throw CredentialError.missingCredentials(instanceName: instanceName)
        }
    }

    public func setCredentials(_ credentials: MeuralCredentials, for instanceName: String) throws {
        try cache.withTransaction { vaults in
            var vault = try loadVaultLocked(vaults: &vaults)
            vault[instanceName] = StoredAccount(
                email: credentials.email,
                password: credentials.password,
                token: nil
            )
            try saveVaultLocked(vault, vaults: &vaults)
            deleteLegacyItems(for: instanceName)
        }
    }

    /// Checks whether credentials exist for `instanceName` without triggering a
    /// macOS Keychain authorization prompt: uses the in-memory cache if loaded,
    /// otherwise inspects only Keychain item attributes (`kSecReturnAttributes`).
    public func hasCredentials(for instanceName: String) -> Bool {
        if let cached = cache.get(service: serviceName) {
            if let account = cached[instanceName], account.hasValidCredentials {
                return true
            }
            // Fall through to prompt-free legacy check in case this instance
            // hasn't been migrated into the consolidated vault yet.
            return hasLegacyItems(for: instanceName)
        }

        if let comment = backend.readCommentAttribute(service: serviceName, account: Self.vaultAccountName),
           let keys = Self.decodeConfiguredKeys(comment),
           keys.contains(instanceName)
        {
            return true
        }

        return hasLegacyItems(for: instanceName)
    }

    public func deleteCredentials(for instanceName: String) throws {
        try cache.withTransaction { vaults in
            var vault = try loadVaultLocked(vaults: &vaults)
            if vault.removeValue(forKey: instanceName) != nil {
                try saveVaultLocked(vault, vaults: &vaults)
            }
            deleteLegacyItems(for: instanceName)
        }
    }

    public func getCachedToken(for instanceName: String) -> String? {
        cache.withTransaction { vaults in
            guard var vault = try? loadVaultLocked(vaults: &vaults) else {
                return nil
            }
            if let account = vault[instanceName] {
                return account.token
            }
            if let migrated = try? migrateLegacyAccountIfPresentLocked(instanceName, into: &vault, vaults: &vaults) {
                return migrated.token
            }
            return nil
        }
    }

    public func setCachedToken(_ token: String, for instanceName: String) throws {
        try cache.withTransaction { vaults in
            var vault = try loadVaultLocked(vaults: &vaults)
            if var existing = vault[instanceName] {
                existing.token = token
                vault[instanceName] = existing
            } else {
                vault[instanceName] = StoredAccount(email: "", password: "", token: token)
            }
            try saveVaultLocked(vault, vaults: &vaults)
        }
    }

    public func clearCachedToken(for instanceName: String) {
        cache.withTransaction { vaults in
            guard var vault = try? loadVaultLocked(vaults: &vaults), var existing = vault[instanceName] else {
                backend.deleteItem(service: serviceName, account: "\(instanceName)_token")
                return
            }
            if existing.token != nil {
                existing.token = nil
                vault[instanceName] = existing
                try? saveVaultLocked(vault, vaults: &vaults)
            }
            backend.deleteItem(service: serviceName, account: "\(instanceName)_token")
        }
    }

    // MARK: - Vault Persistence & Migration

    private func loadVaultLocked(vaults: inout [String: [String: StoredAccount]]) throws -> [String: StoredAccount] {
        if let cached = vaults[serviceName] {
            return cached
        }
        switch backend.readData(service: serviceName, account: Self.vaultAccountName) {
        case .found(let data):
            guard let decoded = try? JSONDecoder().decode([String: StoredAccount].self, from: data) else {
                throw CredentialError.keychainFailure(status: errSecDecode)
            }
            vaults[serviceName] = decoded
            return decoded
        case .notFound:
            vaults[serviceName] = [:]
            return [:]
        case .error(let status):
            throw CredentialError.keychainFailure(status: status)
        }
    }

    private func saveVaultLocked(
        _ vault: [String: StoredAccount],
        vaults: inout [String: [String: StoredAccount]]
    ) throws {
        let encoded = try JSONEncoder().encode(vault)
        let configuredKeys = vault
            .filter { $0.value.hasValidCredentials }
            .map(\.key)
            .sorted()
        let comment = Self.encodeConfiguredKeys(configuredKeys)
        try backend.saveData(encoded, comment: comment, service: serviceName, account: Self.vaultAccountName)
        vaults[serviceName] = vault
    }

    private func hasLegacyItems(for instanceName: String) -> Bool {
        backend.itemExists(service: serviceName, account: "\(instanceName)_email")
            && backend.itemExists(service: serviceName, account: "\(instanceName)_password")
    }

    private func migrateLegacyAccountIfPresentLocked(
        _ instanceName: String,
        into vault: inout [String: StoredAccount],
        vaults: inout [String: [String: StoredAccount]]
    ) throws -> StoredAccount? {
        guard hasLegacyItems(for: instanceName) else {
            return nil
        }
        guard let email = readLegacyString(account: "\(instanceName)_email"),
              let password = readLegacyString(account: "\(instanceName)_password"),
              !email.isEmpty, !password.isEmpty
        else {
            return nil
        }
        let token: String?
        if backend.itemExists(service: serviceName, account: "\(instanceName)_token") {
            token = readLegacyString(account: "\(instanceName)_token")
        } else {
            token = nil
        }
        let account = StoredAccount(email: email, password: password, token: token)
        vault[instanceName] = account
        try saveVaultLocked(vault, vaults: &vaults)
        deleteLegacyItems(for: instanceName)
        return account
    }

    private func readLegacyString(account: String) -> String? {
        guard case .found(let data) = backend.readData(service: serviceName, account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteLegacyItems(for instanceName: String) {
        backend.deleteItem(service: serviceName, account: "\(instanceName)_email")
        backend.deleteItem(service: serviceName, account: "\(instanceName)_password")
        backend.deleteItem(service: serviceName, account: "\(instanceName)_token")
    }

    private static func encodeConfiguredKeys(_ keys: [String]) -> String {
        guard let data = try? JSONEncoder().encode(keys),
              let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    private static func decodeConfiguredKeys(_ comment: String) -> Set<String>? {
        guard let data = comment.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return Set(keys)
    }
}
