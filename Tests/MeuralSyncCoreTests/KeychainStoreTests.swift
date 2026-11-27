import Foundation
import Security
import Testing
@testable import MeuralSyncCore

private final class MockKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (data: Data, comment: String?)] = [:]
    var readDataCalls: Int = 0
    var forcedReadError: OSStatus?

    private func key(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    var storedAccounts: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(items.keys.compactMap { $0.components(separatedBy: "::").last })
    }

    func seed(service: String, account: String, string: String, comment: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        items[key(service: service, account: account)] = (Data(string.utf8), comment)
    }

    func readData(service: String, account: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        readDataCalls += 1
        if let forcedReadError {
            return .error(forcedReadError)
        }
        guard let item = items[key(service: service, account: account)] else {
            return .notFound
        }
        return .found(item.data)
    }

    func readCommentAttribute(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service: service, account: account)]?.comment
    }

    func itemExists(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service: service, account: account)] != nil
    }

    func saveData(_ data: Data, comment: String?, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let existingComment = items[key(service: service, account: account)]?.comment
        items[key(service: service, account: account)] = (data, comment ?? existingComment)
    }

    func deleteItem(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: key(service: service, account: account))
    }
}

@Suite("KeychainCredentialStore")
struct KeychainStoreTests {
    @Test("Consolidates all instances into one Keychain item with prompt-free hasCredentials and single read")
    func consolidationCachingAndPromptFreeChecks() throws {
        let backend = MockKeychainBackend()
        let service = "com.ablyler.MeuralSync.test"

        let writer = KeychainCredentialStore(serviceName: service, backend: backend)
        try writer.setCredentials(MeuralCredentials(email: "a@example.com", password: "pw1"), for: "inst-1")
        try writer.setCachedToken("tok-1", for: "inst-1")
        try writer.setCredentials(MeuralCredentials(email: "b@example.com", password: "pw2"), for: "inst-2")

        // Only ONE Keychain item is stored for all instances and tokens.
        #expect(backend.storedAccounts == [KeychainCredentialStore.vaultAccountName])

        // Cold store simulating a fresh app launch.
        backend.readDataCalls = 0
        let reader = KeychainCredentialStore(serviceName: service, backend: backend)

        // hasCredentials must not read secret data (0 Keychain prompts).
        #expect(reader.hasCredentials(for: "inst-1") == true)
        #expect(reader.hasCredentials(for: "inst-2") == true)
        #expect(reader.hasCredentials(for: "inst-missing") == false)
        #expect(backend.readDataCalls == 0)

        // Reading credentials and tokens across both instances hits Keychain data only ONCE.
        #expect(try reader.getCredentials(for: "inst-1") == MeuralCredentials(email: "a@example.com", password: "pw1"))
        #expect(reader.getCachedToken(for: "inst-1") == "tok-1")
        #expect(try reader.getCredentials(for: "inst-2") == MeuralCredentials(email: "b@example.com", password: "pw2"))
        #expect(reader.getCachedToken(for: "inst-2") == nil)
        #expect(backend.readDataCalls == 1)
    }

    @Test("Migrates legacy _email/_password/_token items automatically and deletes them")
    func legacyMigration() throws {
        let backend = MockKeychainBackend()
        let service = "com.ablyler.MeuralSync.test"
        backend.seed(service: service, account: "Living Room_email", string: "user@example.com")
        backend.seed(service: service, account: "Living Room_password", string: "secret")
        backend.seed(service: service, account: "Living Room_token", string: "legacy-jwt")

        let store = KeychainCredentialStore(serviceName: service, backend: backend)

        // Prompt-free check detects legacy credentials without reading secret data.
        #expect(store.hasCredentials(for: "Living Room") == true)
        #expect(backend.readDataCalls == 0)

        // First secret read migrates all 3 fields into the single vault item and deletes legacy items.
        let creds = try store.getCredentials(for: "Living Room")
        #expect(creds == MeuralCredentials(email: "user@example.com", password: "secret"))
        #expect(store.getCachedToken(for: "Living Room") == "legacy-jwt")
        #expect(backend.storedAccounts == [KeychainCredentialStore.vaultAccountName])
    }

    @Test("Keychain read error does not overwrite existing vault on save")
    func authErrorDoesNotOverwriteVault() throws {
        let backend = MockKeychainBackend()
        let service = "com.ablyler.MeuralSync.test"

        let writer = KeychainCredentialStore(serviceName: service, backend: backend)
        try writer.setCredentials(MeuralCredentials(email: "a@example.com", password: "pw1"), for: "inst-1")

        backend.forcedReadError = errSecAuthFailed
        let coldStore = KeychainCredentialStore(serviceName: service, backend: backend)

        #expect(throws: CredentialError.self) {
            try coldStore.setCredentials(MeuralCredentials(email: "b@example.com", password: "pw2"), for: "inst-2")
        }

        // Original vault remains intact once Keychain is accessible again.
        backend.forcedReadError = nil
        let verifyStore = KeychainCredentialStore(serviceName: service, backend: backend)
        #expect(try verifyStore.getCredentials(for: "inst-1") == MeuralCredentials(email: "a@example.com", password: "pw1"))
    }

    @Test("Corrupt vault JSON fails closed and deleteCredentials propagates read errors")
    func corruptVaultFailsClosedAndDeletePropagatesErrors() throws {
        let backend = MockKeychainBackend()
        let service = "com.ablyler.MeuralSync.corrupt"
        backend.seed(service: service, account: KeychainCredentialStore.vaultAccountName, string: "{not valid json")

        let store = KeychainCredentialStore(serviceName: service, backend: backend)
        #expect(throws: CredentialError.self) {
            try store.setCredentials(MeuralCredentials(email: "a@example.com", password: "pw"), for: "inst-1")
        }
        #expect(throws: CredentialError.self) {
            try store.deleteCredentials(for: "inst-1")
        }
    }
}
