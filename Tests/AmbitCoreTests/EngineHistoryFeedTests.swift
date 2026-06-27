import XCTest
import Network
@testable import AmbitCore

final class EngineHistoryFeedTests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult { result }
    }

    private let epoch = Date(timeIntervalSince1970: 0)
    private let latencyID = EntityID(rawValue: "ping@1.1.1.1:443/probe.latency_ms")
    private let healthID = EntityID(rawValue: "ping@1.1.1.1:443/probe.health")

    private func engine(latencyMs: Double?, failure: ProbeFailureReason? = nil) -> Engine {
        let host = PingHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let result = ProbeResult(timestamp: Date(), latencyMs: latencyMs, failureReason: failure)
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: FixedProbe(result: result))
        return Engine(
            settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
            providers: [provider],
            registerBuiltInProviders: false
        )
    }

    func testEngineRecordsStateClassEntityToHistoryOnPoll() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()

        let samples = await engine.historySamples(latencyID, since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 20)
        XCTAssertEqual(samples.first?.ok, true)
    }

    func testEngineDoesNotRecordEntitiesWithoutStateClass() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()

        // health/config entities carry no stateClass → never historized.
        let healthSamples = await engine.historySamples(healthID, since: epoch)
        XCTAssertTrue(healthSamples.isEmpty)
    }

    func testEngineRecordsLossSampleOnProbeFailure() async {
        let engine = engine(latencyMs: nil, failure: .timeout)
        await engine.refresh()

        let samples = await engine.historySamples(latencyID, since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples.first?.value)
        XCTAssertEqual(samples.first?.ok, false)
    }

    func testHistoryStatsAggregateAcrossPolls() async {
        let host = PingHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443, interval: 0.25)
        // Probe alternates aren't easy with a fixed probe; use three engines is overkill —
        // instead poll the same engine repeatedly with a fixed latency (interval small).
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: 30)))
        let engine = Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote), providers: [provider], registerBuiltInProviders: false)
        await engine.refresh()

        let stats = await engine.historyStats(latencyID, since: epoch)
        XCTAssertEqual(stats.received, 1)
        XCTAssertEqual(stats.avg, 30)
        XCTAssertEqual(stats.lossPercent, 0)
    }

    func testRealTCPProbeSuccessAndFailureBothPersistHistorySamples() async throws {
        let server = try await LocalTCPProbeServer.start()
        let successHost = PingHostConfig(
            displayName: "Local TCP",
            address: "127.0.0.1",
            method: .tcp,
            port: server.port,
            interval: 0.25,
            timeout: 1
        )
        let successProvider = PingProvider(host: successHost, integrationInstanceID: successHost.integrationInstanceID)
        let successEngine = Engine(
            settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
            providers: [successProvider],
            registerBuiltInProviders: false
        )

        await successEngine.refresh()

        let successID = EntityID(rawValue: "\(successHost.integrationInstanceID.rawValue)/probe.latency_ms")
        let successSamples = await successEngine.historySamples(successID, since: epoch)
        XCTAssertEqual(successSamples.count, 1)
        XCTAssertEqual(successSamples.first?.ok, true)
        XCTAssertNotNil(successSamples.first?.value)

        server.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        let failureHost = PingHostConfig(
            displayName: "Closed TCP",
            address: "127.0.0.1",
            method: .tcp,
            port: server.port,
            interval: 0.25,
            timeout: 0.25
        )
        let failureProvider = PingProvider(host: failureHost, integrationInstanceID: failureHost.integrationInstanceID)
        let failureEngine = Engine(
            settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
            providers: [failureProvider],
            registerBuiltInProviders: false
        )

        await failureEngine.refresh()

        let failureID = EntityID(rawValue: "\(failureHost.integrationInstanceID.rawValue)/probe.latency_ms")
        let failureSamples = await failureEngine.historySamples(failureID, since: epoch)
        XCTAssertEqual(failureSamples.count, 1)
        XCTAssertEqual(failureSamples.first?.ok, false)
        XCTAssertNil(failureSamples.first?.value)
    }

    func testRefreshPicksUpNewRegistryTCPHostAndRecordsHistoryWithoutExplicitReload() async throws {
        let registry = InMemoryIntegrationRegistry(records: [])
        let engine = Engine(
            settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
            integrationRegistry: registry
        )

        let server = try await LocalTCPProbeServer.start()
        defer { server.cancel() }
        let host = PingHostConfig(
            displayName: "Local TCP",
            address: "127.0.0.1",
            method: .tcp,
            port: server.port,
            interval: 0.25,
            timeout: 1
        )
        try registry.upsert(.ping(host))

        await engine.refresh()

        let latencyID = EntityID(rawValue: "\(host.integrationInstanceID.rawValue)/probe.latency_ms")
        let samples = await engine.historySamples(latencyID, since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.ok, true)
    }
}

private final class LocalTCPProbeServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LocalTCPProbeServer {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
        }
        let once = LocalOnce()
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, once.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        return LocalTCPProbeServer(listener: listener, port: port)
    }

    func cancel() {
        listener.cancel()
    }
}

private final class LocalOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
