import Foundation

/// A device found on the network that the user can add.
public struct FoundDevice: Sendable, Equatable, Identifiable {
    public var kind: DeviceKind
    public var host: String

    public var id: String { "\(kind.rawValue) \(host)" }

    public init(kind: DeviceKind, host: String) {
        self.kind = kind
        self.host = host
    }
}

public enum Discovery {
    /// Asks the dish's fixed address for its status and the Mac's router for a login challenge.
    /// Neither request needs a password or changes anything.
    public static func find(gateway: String?, session: URLSession = .shared, timeout: TimeInterval = 3) async -> [FoundDevice] {
        async let dish = answersAsStarlink(host: StarlinkClient.defaultHost, session: session, timeout: timeout)
        async let router = answersAsRouter(host: gateway, session: session, timeout: timeout)
        var found: [FoundDevice] = []
        if await dish { found.append(FoundDevice(kind: .starlink, host: StarlinkClient.defaultHost)) }
        if await router, let gateway { found.append(FoundDevice(kind: .glinet, host: gateway)) }
        return found
    }

    public static func answersAsStarlink(host: String, session: URLSession = .shared, timeout: TimeInterval = 3) async -> Bool {
        (try? await StarlinkClient(host: host, session: session, timeout: timeout).status()) != nil
    }

    public static func answersAsRouter(host: String?, session: URLSession = .shared, timeout: TimeInterval = 3) async -> Bool {
        guard let host, let client = try? GLiNetClient(host: host, password: { nil }, session: session, timeout: timeout) else { return false }
        return await client.answersLikeARouter()
    }
}
