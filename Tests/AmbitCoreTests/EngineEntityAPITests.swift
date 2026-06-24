import XCTest
@testable import AmbitCore

final class EngineEntityAPITests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingScopeHostConfig) async -> ProbeResult { result }
    }
    private let latencyID = EntityID(rawValue: "pingscope@1.1.1.1:443/probe.latency_ms")
    private let providerInstance = ProviderInstanceID(rawValue: "pingscope@1.1.1.1:443/probe")

    private func engine(latencyMs: Double?) -> Engine {
        let host = PingScopeHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let provider = PingScopeProvider(host: host, integrationInstanceID: host.integrationInstanceID,
                                         probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: latencyMs)))
        return Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
                      providers: [provider], registerBuiltInProviders: false)
    }

    func testExposesDescriptors() async {
        let engine = engine(latencyMs: 20)
        let descriptors = await engine.entityDescriptors()
        XCTAssertTrue(descriptors[providerInstance]?.contains { $0.id == latencyID } ?? false)
    }

    func testExposesProjectedStatesAfterPoll() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()
        let states = await engine.entityStates()
        XCTAssertEqual(states[latencyID]?.value, .number(20))
        XCTAssertEqual(states[latencyID]?.availability, .online)
    }
}
