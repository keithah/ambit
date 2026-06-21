import XCTest
@testable import AmbitCore

final class ProviderDisplayModelTests: XCTestCase {
    func testBuildsMissingCredentialDisplayModel() {
        let model = ProviderDisplayModel.make(
            providerID: "demo.secure",
            providerName: "Secure Demo",
            state: SourceState(value: ProviderSnapshot(health: .down, error: "Manifest credential api_token is not configured.")),
            commands: []
        )

        XCTAssertEqual(model.title, "Secure Demo")
        XCTAssertEqual(model.health, .down)
        XCTAssertEqual(model.primaryMessage, "Manifest credential api_token is not configured.")
        XCTAssertEqual(model.action, .configureCredentials)
    }

    func testCommandSummariesIncludeParametersAndConfirmation() {
        let model = ProviderDisplayModel.make(
            providerID: "demo.secure",
            providerName: "Secure Demo",
            state: SourceState(value: ProviderSnapshot(health: .ok)),
            commands: [
                CommandDescriptor(
                    id: "demo.run",
                    label: "Run",
                    parameters: [CommandParameter(id: "host", label: "Host", kind: .text)],
                    requiresConfirmation: true
                )
            ]
        )

        XCTAssertEqual(model.commands, [
            ProviderCommandDisplayModel(id: "demo.run", label: "Run", detail: "1 param · confirmation")
        ])
    }

    func testDisplayModelUsesLayoutPrimaryMetric() {
        let model = ProviderDisplayModel.make(
            providerID: "demo.layout",
            providerName: "Layout Demo",
            state: SourceState(value: ProviderSnapshot(health: .ok, metrics: [
                Metric(id: "latency", label: "Latency", value: .latency(ms: 20)),
                Metric(id: "battery_percent", label: "Battery", value: .percent(81))
            ])),
            commands: [],
            layout: ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent")
        )

        XCTAssertEqual(model.primaryMetric?.id, "battery_percent")
        XCTAssertEqual(model.icon, "bolt")
        XCTAssertEqual(model.accent, "green")
    }
}
