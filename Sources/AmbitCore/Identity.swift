import Foundation

/// Shared boilerplate for the string-backed identity types in the integration/entity
/// hierarchy. All ids are deterministic, engine-independent, and encode as a bare string.
public protocol StringIdentifier:
    RawRepresentable,
    Hashable,
    Sendable,
    Codable,
    ExpressibleByStringLiteral,
    CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

public extension StringIdentifier {
    init(stringLiteral value: String) { self.init(rawValue: value) }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

/// The installable, branded unit (`integration-model.md`). 1..N providers.
public struct IntegrationID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One configured install of an integration. Deterministic from the install's target
/// (host / VIN / account). In Phase 1 the built-ins use a fixed default install id.
public struct IntegrationInstanceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A provider kind *within* an integration ("router", "vpn", "starlink").
public typealias ProviderTypeID = String

/// A provider instance scoped under its integration instance:
/// `"<IntegrationInstanceID>/<providerType>"`, e.g. `"glinet/router"`.
/// Phase 1: built-ins are scoped; everything else defaults to the bare provider id.
public struct ProviderInstanceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public extension ProviderInstanceID {
    /// The integration instance this provider is scoped under. Provider ids are
    /// `"<IntegrationInstanceID>/<providerType>"`; an unscoped id maps to itself.
    var integrationInstanceID: IntegrationInstanceID {
        guard let slash = rawValue.lastIndex(of: "/") else {
            return IntegrationInstanceID(rawValue: rawValue)
        }
        return IntegrationInstanceID(rawValue: String(rawValue[..<slash]))
    }
}

/// `"<ProviderInstanceID>.<entityKey>"`, e.g. `"glinet/vpn.connected"` (entity-model.md).
public struct EntityID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Node id — for ownership/telemetry only (`engine-topology.md`). Never part of an
/// entity/instance id.
public struct EngineID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A bare capability identifier (the full capability model lives in
/// `provider-capability-model.md`, Phase 2). Used only as an optional tag here.
public struct ProviderCapability: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The built-in integrations (`integration-model.md` §5).
public enum IntegrationIDs {
    public static let glinet: IntegrationID = "glinet"
    public static let speedify: IntegrationID = "speedify"
    public static let starlink: IntegrationID = "starlink"
    public static let ecoflow: IntegrationID = "ecoflow"
    public static let reachability: IntegrationID = "reachability"
    public static let ping: IntegrationID = "ping"
    public static let iperf3: IntegrationID = "iperf3"
    public static let system: IntegrationID = "system"
}

/// Phase 1 default install ids for the built-in integrations (one install each, no target
/// host folded in yet — that arrives with the topology phase).
public enum IntegrationInstanceIDs {
    public static let glinet: IntegrationInstanceID = "glinet"
    public static let speedify: IntegrationInstanceID = "speedify"
    public static let starlink: IntegrationInstanceID = "starlink"
    public static let ecoflow: IntegrationInstanceID = "ecoflow"
    public static let reachability: IntegrationInstanceID = "reachability"
    public static let ping: IntegrationInstanceID = "ping"
    public static let iperf3: IntegrationInstanceID = "iperf3"
    public static let systemLocal: IntegrationInstanceID = "system@local"
}

/// The scoped instance ids for the eight built-in providers. gl.inet stands up two
/// providers (router + vpn) under one integration instance; the rest are single-provider
/// integrations (the degenerate `<install>/<type>` case).
public enum ProviderInstanceIDs {
    public static let router: ProviderInstanceID = "glinet/router"
    public static let vpn: ProviderInstanceID = "glinet/vpn"
    public static let speedify: ProviderInstanceID = "speedify/speedify"
    public static let starlink: ProviderInstanceID = "starlink/starlink"
    public static let ecoflow: ProviderInstanceID = "ecoflow/ecoflow"
    public static let reachability: ProviderInstanceID = "reachability/reachability"
    public static let ping: ProviderInstanceID = "ping/ping"
    public static let iperf3: ProviderInstanceID = "iperf3/iperf3"
    public static let systemOverview: ProviderInstanceID = "system@local/overview"

    /// Maps a built-in provider *type* id ("router", "speedify", …) to its scoped instance
    /// id, so callers that still address built-ins by type id (the menubar, compatibility
    /// accessors) resolve to the re-keyed storage. Returns nil for non-built-in ids, which
    /// default to a bare instance id (`instanceID == id`).
    public static func builtIn(forType providerID: ProviderID) -> ProviderInstanceID? {
        switch providerID {
        case ProviderIDs.router: return router
        case ProviderIDs.vpn: return vpn
        case ProviderIDs.speedify: return speedify
        case ProviderIDs.starlink: return starlink
        case ProviderIDs.ecoflow: return ecoflow
        case ProviderIDs.reachability: return reachability
        case ProviderIDs.ping: return ping
        case ProviderIDs.iperf3: return iperf3
        case ProviderIDs.systemOverview: return systemOverview
        default: return nil
        }
    }

    /// Resolves any provider id string to the instance id used as its storage key:
    /// the scoped id for built-ins, the bare id otherwise.
    public static func resolve(_ providerID: ProviderID) -> ProviderInstanceID {
        builtIn(forType: providerID) ?? ProviderInstanceID(rawValue: providerID)
    }
}
