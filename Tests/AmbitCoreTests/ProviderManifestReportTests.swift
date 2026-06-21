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
            "  ok: OK (bool at ok)",
            "Alerts: 0",
            "Commands: 2 declared, 1 executable",
            "  demo.metadata: Metadata Only (0 params, metadata only)",
            "  demo.run: Run (0 params, executable)"
        ])
    }

    func testFormatsRichGenericProviderMetadata() {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.power",
            displayName: "Demo Power",
            pollInterval: 30,
            credentials: [
                ProviderManifest.Credential(id: "api_token", label: "API Token", kind: .bearerToken)
            ],
            layout: ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent"),
            endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(
                    id: "battery_percent",
                    label: "Battery",
                    value: .init(type: .percent, path: "battery", transforms: [.multiply(100), .round])
                )
            ],
            alerts: [
                ProviderManifest.Alert(
                    id: "battery.low",
                    metricID: "battery_percent",
                    kind: .threshold(comparison: .lessThan, value: 20),
                    title: "Battery low",
                    message: "Battery is low",
                    severity: .warning
                )
            ],
            commands: [
                ProviderManifest.Command(
                    id: "demo.reset",
                    label: "Reset",
                    parameters: [
                        ProviderManifest.CommandParameter(id: "mode", label: "Mode", kind: .option(["soft", "hard"]))
                    ],
                    requiresConfirmation: true,
                    endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/reset")
                )
            ]
        )

        XCTAssertEqual(ProviderManifestReport.lines(manifest: manifest), [
            "Manifest valid: Demo Power (demo.power)",
            "Layout: icon bolt, accent green, primary battery_percent",
            "Endpoint: POST https://example.test/status",
            "Credentials: 1 declared",
            "  api_token: API Token (bearerToken, required)",
            "Metrics: 1",
            "  battery_percent: Battery (percent at battery, transforms: multiply, round)",
            "Alerts: 1",
            "  battery.low: Battery low (battery_percent lessThan 20, warning)",
            "Commands: 1 declared, 1 executable",
            "  demo.reset: Reset (1 param, confirmation, executable)"
        ])
    }
}
