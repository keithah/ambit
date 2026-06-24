import Foundation

// The eight built-ins as degenerate single-instance integrations. Each wraps the existing
// provider construction with its injected dependencies and is behavior-identical to the old
// BuiltInProviderFactory.providers(settings:) output. gl.inet stands up two providers
// (router + vpn) from its one install, matching integration-model.md §5.

public struct GLiNetIntegration: Integration {
    public let id = IntegrationIDs.glinet
    public let displayName = "GL.iNet"
    let routerClientFactory: RouterClientFactory
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [GLiNetRouterProvider(clientFactory: routerClientFactory),
         GLiNetVPNProvider(clientFactory: routerClientFactory)]
    }
}

public struct ReachabilityIntegration: Integration {
    public let id = IntegrationIDs.reachability
    public let displayName = "Internet"
    let probe: ReachabilityProbeProtocol
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [ReachabilityProvider(probe: probe)]
    }
}

public struct SpeedifyIntegration: Integration {
    public let id = IntegrationIDs.speedify
    public let displayName = "Speedify"
    let client: any RouterSpeedifyClientProtocol
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [SpeedifyProvider(client: client)]
    }
}

public struct StarlinkIntegration: Integration {
    public let id = IntegrationIDs.starlink
    public let displayName = "Starlink"
    let statusProvider: StarlinkStatusProvider
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [StarlinkProvider(statusProvider: statusProvider)]
    }
}

public struct EcoFlowIntegration: Integration {
    public let id = IntegrationIDs.ecoflow
    public let displayName = "EcoFlow"
    let clientFactory: EcoFlowClientFactory
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [EcoFlowProvider(clientFactory: clientFactory)]
    }
}

public struct Iperf3Integration: Integration {
    public let id = IntegrationIDs.iperf3
    public let displayName = "iperf3"
    let processRunner: any ProcessRunner
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [Iperf3Provider(processRunner: processRunner)]
    }
}

/// Dependency-free metadata for the built-in integration instances (canonical order), used
/// both by the Engine's default seed and by the app to seed/list the registry without
/// constructing clients.
public enum BuiltInIntegrationSeed {
    public static func records(ecoflowEnabled: Bool, includeActiveMeasurement: Bool) -> [IntegrationInstanceRecord] {
        func record(_ integration: IntegrationID, _ instance: IntegrationInstanceID, _ name: String, enabled: Bool = true) -> IntegrationInstanceRecord {
            IntegrationInstanceRecord(id: instance, integrationID: integration, displayName: name, enabled: enabled, origin: .builtIn)
        }
        var seed: [IntegrationInstanceRecord] = [
            record(IntegrationIDs.glinet, IntegrationInstanceIDs.glinet, "GL.iNet"),
            record(IntegrationIDs.reachability, IntegrationInstanceIDs.reachability, "Internet"),
            record(IntegrationIDs.speedify, IntegrationInstanceIDs.speedify, "Speedify"),
            record(IntegrationIDs.starlink, IntegrationInstanceIDs.starlink, "Starlink"),
            record(IntegrationIDs.ecoflow, IntegrationInstanceIDs.ecoflow, "EcoFlow", enabled: ecoflowEnabled)
        ]
        if includeActiveMeasurement {
            seed.append(record(IntegrationIDs.iperf3, IntegrationInstanceIDs.iperf3, "iperf3"))
        }
        return seed
    }

    public static let integrationIDs: Set<IntegrationID> = [
        IntegrationIDs.glinet, IntegrationIDs.reachability, IntegrationIDs.speedify,
        IntegrationIDs.starlink, IntegrationIDs.ecoflow, IntegrationIDs.iperf3
    ]
}
