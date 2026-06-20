import Foundation

public struct ReachabilityProvider: Provider {
    public let id: ProviderID = ProviderIDs.reachability
    public let displayName = "Internet"
    public let pollInterval: TimeInterval

    private let probe: ReachabilityProbeProtocol

    public init(probe: ReachabilityProbeProtocol = ReachabilityProbe(), pollInterval: TimeInterval = 5) {
        self.probe = probe
        self.pollInterval = pollInterval
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        ProviderSnapshot.reachability(await probe.probe())
    }
}

public struct StarlinkProvider: Provider {
    public let id: ProviderID = ProviderIDs.starlink
    public let displayName = "Starlink"
    public let pollInterval: TimeInterval

    private let statusProvider: StarlinkStatusProvider

    public init(
        pollInterval: TimeInterval = 5,
        statusProvider: @escaping StarlinkStatusProvider = { path in
            await StarlinkClient(path: path).status()
        }
    ) {
        self.pollInterval = pollInterval
        self.statusProvider = statusProvider
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let status = await statusProvider(context.settings.grpcurlPath)
        var snapshot = ProviderSnapshot.starlink(status)
        if !status.isReachable {
            snapshot.error = status.state
        }
        return snapshot
    }
}
