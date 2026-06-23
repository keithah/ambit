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

public struct PingIntegration: Integration {
    public let id = IntegrationIDs.ping
    public let displayName = "Ping"
    let processRunner: any ProcessRunner
    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [PingProvider(processRunner: processRunner)]
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
