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

    func testEcoFlowProviderPollsResolvedDaemonEndpoint() async {
        let client = StubEcoFlowClient(status: Self.ecoFlowStatus(batteryPercent: 67, outputWatts: 22))
        let provider = EcoFlowProvider { baseURL in
            XCTAssertEqual(baseURL.absoluteString, "http://router.local:8787")
            return client
        }

        let snapshot = await provider.poll(
            context: EnvironmentContext(
                routerHost: "router.local",
                settings: AppSettings(ecoflowEnabled: true, ecoflowHost: "auto", ecoflowPort: 8787)
            )
        )

        XCTAssertEqual(provider.id, ProviderIDs.ecoflow)
        XCTAssertEqual(provider.displayName, "EcoFlow")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("battery_percent"), .level(67))
        XCTAssertEqual(snapshot.metricValue("output_watts"), .level(22))
        XCTAssertEqual(snapshot.detail, .ecoflow(EcoFlowSnapshot(status: Self.ecoFlowStatus(batteryPercent: 67, outputWatts: 22))))
        XCTAssertEqual(client.statusCallCount, 1)
    }

    func testEcoFlowProviderReturnsUnresolvedErrorWhenAutoHostHasNoRouterHost() async {
        let provider = EcoFlowProvider { _ in
            XCTFail("Provider should not build a client without a resolved endpoint.")
            return StubEcoFlowClient(status: Self.ecoFlowStatus(batteryPercent: 67, outputWatts: 22))
        }

        let snapshot = await provider.poll(
            context: EnvironmentContext(
                routerHost: nil,
                settings: AppSettings(ecoflowEnabled: true, ecoflowHost: "auto", ecoflowPort: 8787)
            )
        )

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertEqual(snapshot.error, "EcoFlow daemon endpoint unresolved.")
    }

    func testEcoFlowProviderSetOutputCommand() async throws {
        let client = StubEcoFlowClient(status: Self.ecoFlowStatus(batteryPercent: 67, outputWatts: 22))
        let provider = EcoFlowProvider { _ in client }

        try await provider.execute(
            commandID: ProviderCommandIDs.ecoFlowSetOutput,
            arguments: CommandArguments(values: ["target": .string("ac"), "state": .string("on")]),
            context: EnvironmentContext(
                routerHost: "router.local",
                settings: AppSettings(ecoflowEnabled: true, ecoflowHost: "auto", ecoflowPort: 8787)
            )
        )

        XCTAssertEqual(client.outputRequests, [.init(target: .ac, state: .on)])
    }

    func testGLiNetRouterProviderPollsRouterStatus() async {
        let client = StubGLiNetClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem, publicIP: "203.0.113.10"),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        let provider = GLiNetRouterProvider(
            clientFactory: Self.routerClientFactory(expectedHost: "router.local", client: client),
            passwordProvider: { "secret" }
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: "router.local", settings: AppSettings(username: "root")))

        XCTAssertEqual(provider.id, ProviderIDs.router)
        XCTAssertEqual(provider.displayName, "Router")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("active_wan"), .text("Modem"))
        XCTAssertEqual(snapshot.detail, .router(RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem, publicIP: "203.0.113.10")))
        XCTAssertEqual(client.routerStatusCallCount, 1)
    }

    func testGLiNetVPNProviderPollsVPNStatusAndTogglesFromCurrentState() async throws {
        let client = StubGLiNetClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000"),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        let provider = GLiNetVPNProvider(
            clientFactory: Self.routerClientFactory(expectedHost: "router.local", client: client),
            passwordProvider: { "secret" }
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: "router.local", settings: AppSettings(username: "root")))
        try await provider.execute(
            commandID: ProviderCommandIDs.vpnToggle,
            arguments: CommandArguments(),
            context: EnvironmentContext(routerHost: "router.local", settings: AppSettings(username: "root"))
        )

        XCTAssertEqual(provider.id, ProviderIDs.vpn)
        XCTAssertEqual(provider.displayName, "VPN")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("connected"), .bool(true))
        XCTAssertEqual(snapshot.detail, .vpn(VPNStatus(protocol: .wireGuard, isConnected: true)))
        XCTAssertEqual(client.vpnStatusCallCount, 2)
        XCTAssertEqual(client.vpnEnabledRequests, [false])
    }

    private static func routerClientFactory(expectedHost: String, client: StubGLiNetClient) -> RouterClientFactory {
        { endpoint, username, passwordProvider in
            XCTAssertEqual(endpoint, URL.routerRPC(host: expectedHost))
            XCTAssertEqual(username, "root")
            XCTAssertEqual(try? passwordProvider(), "secret")
            return client
        }
    }

    private static func ecoFlowStatus(batteryPercent: Int, outputWatts: Int) -> EcoFlowDeviceStatus {
        EcoFlowDeviceStatus(
            battery: EcoFlowBatteryStatus(percent: batteryPercent, state: .discharging),
            power: EcoFlowPowerStatus(inputWatts: 0, outputWatts: outputWatts, netWatts: -outputWatts),
            outputs: EcoFlowOutputMap(
                ac: EcoFlowOutputStatus(state: .off, watts: 0),
                dc: EcoFlowOutputStatus(state: .off, watts: 0),
                usb: EcoFlowOutputStatus(state: .on, watts: outputWatts)
            ),
            updatedAt: "2026-06-20T07:00:00Z"
        )
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

private final class StubGLiNetClient: GLiNetClientProtocol, @unchecked Sendable {
    var routerStatusResult: RouterStatus
    var vpnStatusResult: VPNStatus
    private(set) var routerStatusCallCount = 0
    private(set) var vpnStatusCallCount = 0
    private(set) var vpnEnabledRequests: [Bool] = []

    init(routerStatus: RouterStatus, vpnStatus: VPNStatus) {
        self.routerStatusResult = routerStatus
        self.vpnStatusResult = vpnStatus
    }

    func call(service: String, method: String, args: JSONObject) async throws -> JSONObject {
        [:]
    }

    func routerStatus() async throws -> RouterStatus {
        routerStatusCallCount += 1
        return routerStatusResult
    }

    func vpnStatus() async throws -> VPNStatus {
        vpnStatusCallCount += 1
        return vpnStatusResult
    }

    func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol) async throws {
        vpnEnabledRequests.append(enabled)
    }
}

private final class StubEcoFlowClient: EcoFlowClientProtocol, @unchecked Sendable {
    struct OutputRequest: Equatable {
        var target: EcoFlowOutputTarget
        var state: EcoFlowOutputState
    }

    var statusResult: EcoFlowDeviceStatus
    private(set) var statusCallCount = 0
    private(set) var outputRequests: [OutputRequest] = []

    init(status: EcoFlowDeviceStatus) {
        self.statusResult = status
    }

    func device() async throws -> EcoFlowDeviceInfo {
        throw EcoFlowClientError.invalidResponse(statusCode: 404)
    }

    func status() async throws -> EcoFlowDeviceStatus {
        statusCallCount += 1
        return statusResult
    }

    func stats() async throws -> EcoFlowDeviceStats {
        throw EcoFlowClientError.invalidResponse(statusCode: 404)
    }

    func outputs() async throws -> EcoFlowOutputsSnapshot {
        throw EcoFlowClientError.invalidResponse(statusCode: 404)
    }

    func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async throws -> EcoFlowControlResponse {
        outputRequests.append(OutputRequest(target: target, state: state))
        return EcoFlowControlResponse(
            target: EcoFlowControlTarget(rawValue: target.rawValue) ?? .device,
            requestedState: EcoFlowRequestedControlState(rawValue: state.rawValue) ?? .shutdown,
            result: .applied,
            observedState: state
        )
    }

    func diagnostics() async throws -> EcoFlowDiagnosticsSnapshot {
        throw EcoFlowClientError.invalidResponse(statusCode: 404)
    }
}
