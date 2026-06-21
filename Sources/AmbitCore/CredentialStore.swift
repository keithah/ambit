import Foundation
import Security

public struct CredentialKey: Codable, Equatable, Hashable, Sendable {
    public var providerID: ProviderID
    public var id: String
    public var account: String?

    public init(providerID: ProviderID, id: String, account: String? = nil) {
        self.providerID = providerID
        self.id = id
        self.account = account
    }

    public static func routerPassword(account: String) -> CredentialKey {
        CredentialKey(providerID: ProviderIDs.router, id: "password", account: account)
    }

    var storageAccount: String {
        [providerID, id, account].compactMap { $0 }.joined(separator: ":")
    }
}

public protocol CredentialStore: Sendable {
    func credential(_ key: CredentialKey) throws -> String?
    func setCredential(_ value: String?, for key: CredentialKey) throws
}

public extension CredentialStore {
    func password(account: String) throws -> String? {
        try credential(.routerPassword(account: account))
    }

    func setPassword(_ password: String?, account: String) throws {
        try setCredential(password, for: .routerPassword(account: account))
    }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.glinet.travel.router") {
        self.service = service
    }

    public func password(account: String) throws -> String? {
        try credential(.routerPassword(account: account))
    }

    public func setPassword(_ password: String?, account: String) throws {
        try setCredential(password, for: .routerPassword(account: account))
    }

    public func credential(_ key: CredentialKey) throws -> String? {
        var query = baseQuery(account: key.storageAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setCredential(_ value: String?, for key: CredentialKey) throws {
        let query = baseQuery(account: key.storageAccount)
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        "Keychain operation failed with status \(status)."
    }
}
