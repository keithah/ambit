import Foundation
import XCTest
@testable import AmbitCore

final class ManifestProviderTests: XCTestCase {
    func testPollFetchesEndpointAndMapsJSONMetrics() async {
        let client = StubManifestHTTPClient(responses: [
            .success("""
            {
              "latency": { "avg": 41.5 },
              "wan": {
                "download_bps": 1200000,
                "loss_percent": 2.5,
                "healthy": true,
                "state": "online"
              }
            }
            """)
        ])
        let manifest = Self.manifest()
        let provider = ManifestProvider(manifest: manifest, httpClient: client)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(client.requests, [
            ManifestHTTPRequest(method: .get, url: URL(string: "https://example.test/status")!)
        ])
        XCTAssertEqual(provider.id, "demo.runtime")
        XCTAssertEqual(provider.displayName, "Runtime Demo")
        XCTAssertEqual(provider.pollInterval, 12)
        XCTAssertEqual(provider.commands, [])
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.metrics, [
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 41.5)),
            Metric(id: "download", label: "Download", value: .throughput(bitsPerSecond: 1_200_000)),
            Metric(id: "loss", label: "Loss", value: .percent(2.5)),
            Metric(id: "healthy", label: "Healthy", value: .bool(true)),
            Metric(id: "state", label: "State", value: .text("online"))
        ])
    }

    func testPollDegradesWhenMetricPathCannotBeMapped() async {
        let client = StubManifestHTTPClient(responses: [
            .success(#"{ "latency": {} }"#)
        ])
        let provider = ManifestProvider(
            manifest: ProviderManifest(
                schemaVersion: 1,
                id: "demo.runtime",
                displayName: "Runtime Demo",
                pollInterval: 12,
                endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
                metrics: [
                    ProviderManifest.MetricMapping(id: "latency_ms", label: "Latency", value: .init(type: .latency, path: "latency.avg"))
                ]
            ),
            httpClient: client
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .degraded)
        XCTAssertEqual(snapshot.metrics, [])
        XCTAssertEqual(snapshot.error, "Could not map metrics: latency_ms")
    }

    func testPollReturnsDownSnapshotWhenEndpointFetchFails() async {
        let client = StubManifestHTTPClient(responses: [
            .failure(StubManifestHTTPClient.Error.unavailable)
        ])
        let provider = ManifestProvider(manifest: Self.manifest(), httpClient: client)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .down)
        XCTAssertEqual(snapshot.metrics, [])
        XCTAssertEqual(snapshot.error, "unavailable")
    }

    func testOnlyExecutableManifestCommandsArePublishedByRuntime() {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.runtime",
            displayName: "Runtime Demo",
            pollInterval: 12,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [],
            commands: [
                ProviderManifest.Command(id: "demo.metadata", label: "Metadata Only"),
                ProviderManifest.Command(
                    id: "demo.reboot",
                    label: "Reboot",
                    requiresConfirmation: true,
                    endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/reboot")
                )
            ]
        )

        let provider = ManifestProvider(manifest: manifest, httpClient: StubManifestHTTPClient(responses: []))

        XCTAssertEqual(provider.commands, [
            CommandDescriptor(id: "demo.reboot", label: "Reboot", requiresConfirmation: true)
        ])
    }

    func testExecutesManifestCommandEndpointWithURLArguments() async throws {
        let client = StubManifestHTTPClient(responses: [
            .success(#"{ "ok": true }"#)
        ])
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.runtime",
            displayName: "Runtime Demo",
            pollInterval: 12,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [],
            commands: [
                ProviderManifest.Command(
                    id: "demo.output",
                    label: "Set Output",
                    parameters: [
                        ProviderManifest.CommandParameter(id: "target", label: "Target", kind: .text),
                        ProviderManifest.CommandParameter(id: "enabled", label: "Enabled", kind: .bool)
                    ],
                    endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/output/{target}/{enabled}")
                )
            ]
        )
        let provider = ManifestProvider(manifest: manifest, httpClient: client)

        try await provider.execute(
            commandID: "demo.output",
            arguments: CommandArguments(values: ["target": .string("ac/outlet"), "enabled": .bool(true)]),
            context: EnvironmentContext(routerHost: nil, settings: AppSettings())
        )

        XCTAssertEqual(client.requests, [
            ManifestHTTPRequest(method: .post, url: URL(string: "https://example.test/output/ac%2Foutlet/true")!)
        ])
    }

    private static func manifest() -> ProviderManifest {
        ProviderManifest(
            schemaVersion: 1,
            id: "demo.runtime",
            displayName: "Runtime Demo",
            pollInterval: 12,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(id: "latency_ms", label: "Latency", value: .init(type: .latency, path: "latency.avg")),
                ProviderManifest.MetricMapping(id: "download", label: "Download", value: .init(type: .throughput, path: "wan.download_bps")),
                ProviderManifest.MetricMapping(id: "loss", label: "Loss", value: .init(type: .percent, path: "wan.loss_percent")),
                ProviderManifest.MetricMapping(id: "healthy", label: "Healthy", value: .init(type: .bool, path: "wan.healthy")),
                ProviderManifest.MetricMapping(id: "state", label: "State", value: .init(type: .text, path: "wan.state"))
            ],
            commands: [
                ProviderManifest.Command(id: "demo.refresh", label: "Refresh")
            ]
        )
    }
}

private final class StubManifestHTTPClient: ManifestHTTPClient, @unchecked Sendable {
    enum Response {
        case success(String)
        case failure(Swift.Error)
    }

    enum Error: Swift.Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "unavailable"
        }
    }

    var requests: [ManifestHTTPRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: ManifestHTTPRequest) async throws -> Data {
        requests.append(request)
        switch responses.removeFirst() {
        case .success(let json):
            return Data(json.utf8)
        case .failure(let error):
            throw error
        }
    }
}
