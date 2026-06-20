import Foundation

public actor GLiNetClientPool {
    private struct Key: Hashable {
        var endpoint: URL
        var username: String
    }

    private var clients: [Key: GLiNetClient] = [:]

    public init() {}

    public func client(
        endpoint: URL,
        username: String,
        passwordProvider: @escaping @Sendable () throws -> String?
    ) -> GLiNetClient {
        let key = Key(endpoint: endpoint, username: username)
        if let existing = clients[key] {
            return existing
        }
        let client = GLiNetClient(endpoint: endpoint, username: username, passwordProvider: passwordProvider)
        clients[key] = client
        return client
    }

    public func remove(endpoint: URL, username: String) {
        clients.removeValue(forKey: Key(endpoint: endpoint, username: username))
    }

    public func removeAll() {
        clients.removeAll()
    }
}
