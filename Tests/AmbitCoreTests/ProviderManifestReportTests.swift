import XCTest
@testable import AmbitCore

final class ProviderManifestReportTests: XCTestCase {
    func testFormatsManifestPackageCapabilities() {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.secure",
            displayName: "Secure Demo",
            pollInterval: 30,
            credentials: [
                ProviderManifest.Credential(id: "api_token", label: "API Token", kind: .bearerToken)
            ],
            endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(id: "ok", label: "OK", value: .init(type: .bool, path: "ok"))
            ],
            commands: [
                ProviderManifest.Command(id: "demo.metadata", label: "Metadata Only"),
                ProviderManifest.Command(
                    id: "demo.run",
                    label: "Run",
                    endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/run")
                )
            ]
        )

        XCTAssertEqual(ProviderManifestReport.lines(manifest: manifest), [
            "Manifest valid: Secure Demo (demo.secure)",
            "Endpoint: POST https://example.test/status",
            "Credentials: 1 declared",
            "  api_token: API Token (bearerToken, required)",
            "Metrics: 1",
            "Commands: 2 declared, 1 executable"
        ])
    }
}
