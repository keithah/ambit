import XCTest
@testable import AmbitCore

final class ProviderSurfaceModelTests: XCTestCase {
    func testMakeBuildsCompactProviderSurfaceFromDisplayInputs() {
        let model = ProviderSurfaceModel.make(
            providerID: "demo.power",
            providerName: "Power Station",
            state: SourceState(value: ProviderSnapshot(health: .ok, metrics: [
                Metric(id: "battery_percent", label: "Battery", value: .percent(81)),
                Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 24))
            ])),
            commands: [
                CommandDescriptor(id: "refresh", label: "Refresh")
            ],
            layout: ProviderManifest.Layout(icon: "battery.100", accent: "green", primaryMetric: "battery_percent"),
            activeAlertCount: 1
        )

        XCTAssertEqual(model.id, "demo.power")
        XCTAssertEqual(model.title, "Power Station")
        XCTAssertEqual(model.health, .ok)
        XCTAssertEqual(model.tone, .good)
        XCTAssertEqual(model.icon, "battery.100")
        XCTAssertEqual(model.accent, "green")
        XCTAssertEqual(model.primaryMetric, Metric(id: "battery_percent", label: "Battery", value: .percent(81)))
        XCTAssertEqual(model.primaryValueText, "81%")
        XCTAssertEqual(model.shortMessage, "Battery 81% · Latency 24 ms")
        XCTAssertEqual(model.commandCount, 1)
        XCTAssertEqual(model.activeAlertCount, 1)
    }

    func testSurfaceSnapshotMakeSortsProvidersByTitleAndMapsDownHealthToBadTone() {
        let snapshot = StatusSnapshot(
            providers: [
                "provider.z": SourceState(value: ProviderSnapshot(health: .ok)),
                "provider.a": SourceState(value: ProviderSnapshot(health: .down))
            ],
            lastUpdated: Date(timeIntervalSince1970: 123)
        )

        let model = SurfaceSnapshot.make(
            snapshot: snapshot,
            providerNames: [
                "provider.z": "Zulu",
                "provider.a": "Alpha"
            ],
            providerCommands: [
                "provider.z": [CommandDescriptor(id: "restart", label: "Restart")]
            ],
            providerLayouts: [
                "provider.a": ProviderManifest.Layout(icon: "xmark.octagon", accent: "red")
            ],
            activeAlertCounts: [
                "provider.a": 2
            ]
        )

        XCTAssertEqual(model.lastUpdated, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(model.providers.map(\.title), ["Alpha", "Zulu"])
        XCTAssertEqual(model.providers.map(\.id), ["provider.a", "provider.z"])
        XCTAssertEqual(model.providers.first?.health, .down)
        XCTAssertEqual(model.providers.first?.tone, .bad)
    }

    func testNotificationSurfaceModelMapsAlertEventFields() {
        let event = AlertEvent(
            id: "event-1",
            ruleID: "battery.low",
            providerID: "demo.power",
            title: "Battery Low",
            message: "Battery is below 20%.",
            severity: .critical,
            triggeredAt: Date(timeIntervalSince1970: 456)
        )

        let model = NotificationSurfaceModel(event: event, providerName: "Power Station")

        XCTAssertEqual(model.id, "event-1")
        XCTAssertEqual(model.providerID, "demo.power")
        XCTAssertEqual(model.title, "Battery Low")
        XCTAssertEqual(model.subtitle, "Power Station")
        XCTAssertEqual(model.body, "Battery is below 20%.")
        XCTAssertEqual(model.severity, .critical)
        XCTAssertEqual(model.triggeredAt, Date(timeIntervalSince1970: 456))
    }
}
