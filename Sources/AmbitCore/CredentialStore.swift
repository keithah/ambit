import Foundation
import Security

public protocol CredentialStore: Sendable {
    func password(account: String) throws -> String?
    func setPassword(_ password: String?, account: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.glinet.travel.router") {
        self.service = service
    }

    public func password(account: String) throws -> String? {
        var query = baseQuery(account: account)
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

    public func setPassword(_ password: String?, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        guard let password else { return }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
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
