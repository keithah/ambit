import XCTest
@testable import AmbitCore

final class ManifestAlertCompilerTests: XCTestCase {
    func testCompilesThresholdAlertDeclarations() throws {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.alerts",
            displayName: "Alerts Demo",
            pollInterval: 30,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(id: "battery_percent", label: "Battery", value: .init(type: .percent, path: "battery"))
            ],
            alerts: [
                ProviderManifest.Alert(
                    id: "battery.low",
                    metricID: "battery_percent",
                    kind: .threshold(comparison: .lessThan, value: 20),
                    title: "Battery low",
                    message: "Battery is below 20%.",
                    severity: .warning
                )
            ]
        )

        XCTAssertEqual(ManifestAlertCompiler.rules(from: manifest), [
            .threshold(ThresholdAlertRule(
                id: "demo.alerts.battery.low",
                providerID: "demo.alerts",
                metricID: "battery_percent",
                comparison: .lessThan,
                threshold: 20,
                title: "Battery low",
                message: "Battery is below 20%.",
                severity: .warning
            ))
        ])
    }
}
