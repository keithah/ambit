import Foundation
import Security

/// Device passwords in the user's Keychain: one generic password per device.
public struct PasswordStore: Sendable {
    public let service: String
    /// Set for the UI tests: passwords are then held here until the app quits, and the Keychain is
    /// neither read nor written.
    private let memory: Memory?

    public init(service: String = "com.hadm.ambit", inMemory: Bool = false) {
        self.service = service
        self.memory = inMemory ? Memory() : nil
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var passwords: [UUID: String] = [:]

        subscript(device: UUID) -> String? {
            get { lock.withLock { passwords[device] } }
            set { lock.withLock { passwords[device] = newValue } }
        }
    }

    public struct Failure: Error, Equatable, Sendable {
        public var status: OSStatus
    }

    private func query(_ device: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: device.uuidString]
    }

    public func password(for device: UUID) -> String? {
        if let memory { return memory[device] }
        var query = query(device)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ password: String, for device: UUID) throws {
        if let memory { return memory[device] = password }
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(device) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(device)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Ambit device password"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func remove(for device: UUID) throws {
        if let memory { return memory[device] = nil }
        let status = SecItemDelete(query(device) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
