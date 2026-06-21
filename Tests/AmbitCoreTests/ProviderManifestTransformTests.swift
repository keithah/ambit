import Foundation
import XCTest
@testable import AmbitCore

final class ProviderManifestTransformTests: XCTestCase {
    func testAppliesNumericTransformsWhenMappingMetrics() async {
        let client = TransformStubManifestHTTPClient(responses: [.success(#"{ "battery": 0.42, "state": "online" }"#)])
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.transform",
            displayName: "Transform Demo",
            pollInterval: 30,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(
                    id: "battery_percent",
                    label: "Battery",
                    value: .init(type: .percent, path: "battery", transforms: [.multiply(100), .round])
                )
            ]
        )
        let provider = ManifestProvider(manifest: manifest, httpClient: client)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metric("battery_percent")?.value, .percent(42))
    }
}

private final class TransformStubManifestHTTPClient: ManifestHTTPClient, @unchecked Sendable {
    enum Response {
        case success(String)
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: ManifestHTTPRequest) async throws -> Data {
        switch responses.removeFirst() {
        case .success(let json):
            return Data(json.utf8)
        }
    }
}
