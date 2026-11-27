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

/// Secure credential storage using macOS Keychain (`Security.framework`).
public struct KeychainCredentialStore: CredentialStoring {
    public let serviceName: String

    public init(serviceName: String = "com.ablyler.MeuralSync") {
        self.serviceName = serviceName
    }

    public func getCredentials(for instanceName: String) throws -> MeuralCredentials {
        guard let email = readPassword(account: "\(instanceName)_email"),
              let password = readPassword(account: "\(instanceName)_password"),
              !email.isEmpty, !password.isEmpty
        else {
            throw CredentialError.missingCredentials(instanceName: instanceName)
        }
        return MeuralCredentials(email: email, password: password)
    }

    public func setCredentials(_ credentials: MeuralCredentials, for instanceName: String) throws {
        try savePassword(credentials.email, account: "\(instanceName)_email")
        try savePassword(credentials.password, account: "\(instanceName)_password")
        clearCachedToken(for: instanceName)
    }

    public func hasCredentials(for instanceName: String) -> Bool {
        guard let email = readPassword(account: "\(instanceName)_email"),
              let password = readPassword(account: "\(instanceName)_password")
        else {
            return false
        }
        return !email.isEmpty && !password.isEmpty
    }

    public func deleteCredentials(for instanceName: String) throws {
        deletePassword(account: "\(instanceName)_email")
        deletePassword(account: "\(instanceName)_password")
        deletePassword(account: "\(instanceName)_token")
    }

    public func getCachedToken(for instanceName: String) -> String? {
        readPassword(account: "\(instanceName)_token")
    }

    public func setCachedToken(_ token: String, for instanceName: String) throws {
        try savePassword(token, account: "\(instanceName)_token")
    }

    public func clearCachedToken(for instanceName: String) {
        deletePassword(account: "\(instanceName)_token")
    }

    // MARK: - SecItem Helpers

    private func readPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ value: String, account: String) throws {
        let encoded = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.keychainFailure(status: addStatus)
            }
            return
        }
        throw CredentialError.keychainFailure(status: updateStatus)
    }

    private func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
