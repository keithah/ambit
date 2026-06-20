import XCTest
@testable import AmbitCore

final class ProviderAdapterTests: XCTestCase {
    func testReachabilityProviderWrapsProbeStatus() async {
        let provider = ReachabilityProvider(
            probe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.042)))
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(provider.id, ProviderIDs.reachability)
        XCTAssertEqual(provider.displayName, "Internet")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("latency_ms"), .latency(ms: 42))
        XCTAssertEqual(snapshot.detail, .reachability(ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.042))))
    }

    func testStarlinkProviderWrapsReachableStatus() async {
        let provider = StarlinkProvider { path in
            XCTAssertEqual(path, "/usr/local/bin/grpcurl")
            return StarlinkStatus(isReachable: true, state: "Online", downlinkThroughputBps: 100_000, popPingLatencyMs: 31)
        }

        let snapshot = await provider.poll(
            context: EnvironmentContext(routerHost: nil, settings: AppSettings(grpcurlPath: "/usr/local/bin/grpcurl"))
        )

        XCTAssertEqual(provider.id, ProviderIDs.starlink)
        XCTAssertEqual(provider.displayName, "Starlink")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("pop_latency_ms"), .latency(ms: 31))
        XCTAssertEqual(snapshot.metricValue("downlink_bps"), .throughput(bitsPerSecond: 100_000))
    }

    func testStarlinkProviderPreservesUnavailableStatusAsErrorDetail() async {
        let provider = StarlinkProvider { _ in
            StarlinkStatus(isReachable: false, state: "grpc unavailable")
        }

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .down)
        XCTAssertEqual(snapshot.error, "grpc unavailable")
        XCTAssertEqual(snapshot.detail, .starlink(StarlinkStatus(isReachable: false, state: "grpc unavailable")))
    }

    func testSpeedifyProviderPollsRouterSpeedifyStatus() async {
        let client = StubRouterSpeedifyClient(
            status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected", server: "Seattle")
        )
        let provider = SpeedifyProvider(client: client)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: "router.local", settings: AppSettings()))

        XCTAssertEqual(provider.id, ProviderIDs.speedify)
        XCTAssertEqual(provider.displayName, "Speedify")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("connected"), .bool(true))
        XCTAssertEqual(snapshot.detail, .speedify(SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected", server: "Seattle")))
        XCTAssertEqual(client.statusHosts, ["router.local"])
    }

    func testSpeedifyProviderToggleCommandConnectsWhenDisconnected() async throws {
        let client = StubRouterSpeedifyClient(
            status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected")
        )
        let provider = SpeedifyProvider(client: client)

        try await provider.execute(
            commandID: ProviderCommandIDs.speedifyToggle,
            arguments: CommandArguments(),
            context: EnvironmentContext(routerHost: "router.local", settings: AppSettings())
        )

        XCTAssertEqual(client.connectHosts, ["router.local"])
    }

    func testSpeedifyProviderSetBondingModeCommand() async throws {
        let client = StubRouterSpeedifyClient(
            status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")
        )
        let provider = SpeedifyProvider(client: client)

        try await provider.execute(
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            arguments: CommandArguments(values: ["mode": .string("STR")]),
            context: EnvironmentContext(routerHost: "router.local", settings: AppSettings())
        )

        XCTAssertEqual(client.bondingModeRequests, [.init(mode: .streaming, host: "router.local")])
    }

    func testSpeedifyProviderSetNetworkPriorityCommand() async throws {
        let client = StubRouterSpeedifyClient(
            status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")
        )
        let provider = SpeedifyProvider(client: client)

        try await provider.execute(
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            arguments: CommandArguments(values: ["priority": .number(100), "networkID": .string("eth0")]),
            context: EnvironmentContext(routerHost: "router.local", settings: AppSettings())
        )

        XCTAssertEqual(client.networkPriorityRequests, [.init(priority: .never, networkID: "eth0", host: "router.local")])
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}

private struct StubReachabilityProbe: ReachabilityProbeProtocol {
    var status: ReachabilityStatus

    func probe() async -> ReachabilityStatus {
        status
    }
}

private final class StubRouterSpeedifyClient: RouterSpeedifyClientProtocol, @unchecked Sendable {
    struct BondingModeRequest: Equatable {
        var mode: SpeedifyBondingMode
        var host: String
    }

    struct NetworkPriorityRequest: Equatable {
        var priority: SpeedifyNetworkPriority
        var networkID: String
        var host: String
    }

    var statusResult: SpeedifyStatus
    private(set) var statusHosts: [String] = []
    private(set) var connectHosts: [String] = []
    private(set) var bondingModeRequests: [BondingModeRequest] = []
    private(set) var networkPriorityRequests: [NetworkPriorityRequest] = []

    init(status: SpeedifyStatus) {
        self.statusResult = status
    }

    func status(host: String) async throws -> SpeedifyStatus {
        statusHosts.append(host)
        return statusResult
    }

    func connect(host: String, server: String) async throws {
        connectHosts.append(host)
    }

    func disconnect(host: String) async throws {}
    func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws {
        bondingModeRequests.append(BondingModeRequest(mode: mode, host: host))
    }

    func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws {
        networkPriorityRequests.append(NetworkPriorityRequest(priority: priority, networkID: networkID, host: host))
    }
}
