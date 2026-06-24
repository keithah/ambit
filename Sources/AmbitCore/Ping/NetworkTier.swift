import Foundation

// Integration-internal network-perspective tiers (pingscope only). Ordered from the local
// link outward; diagnosis blames the innermost failing tier.

public enum NetworkTier: String, CaseIterable, Codable, Sendable {
    case localGateway   // the default gateway / local network
    case ispEdge        // ISP edge (e.g. a dish/modem)
    case upstream       // the wider internet (public DNS, etc.)
    case remoteService  // a specific remote host/service

    public var depth: Int {
        switch self {
        case .localGateway: return 0
        case .ispEdge: return 1
        case .upstream: return 2
        case .remoteService: return 3
        }
    }

    public var displayName: String {
        switch self {
        case .localGateway: return "Local network"
        case .ispEdge: return "ISP path"
        case .upstream: return "Upstream"
        case .remoteService: return "Remote service"
        }
    }
}

/// Infers a host's tier from its address, honoring an explicit override. A private IPv4 is the
/// local gateway; any other IPv4 literal is upstream internet; a hostname is a remote service.
public struct NetworkTierClassifier: Sendable {
    public init() {}

    public func tier(for host: PingHostConfig) -> NetworkTier {
        host.tier ?? Self.infer(address: host.address)
    }

    public static func infer(address: String) -> NetworkTier {
        guard let octets = ipv4Octets(address) else { return .remoteService }
        return isPrivate(octets) ? .localGateway : .upstream
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivate(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true   // link-local
        case (127, _): return true     // loopback
        default: return false
        }
    }
}
