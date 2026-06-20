import XCTest
@testable import AmbitCore

final class ProviderSnapshotReportTests: XCTestCase {
    func testFormatsGenericProviderSnapshotWithMetricsAndCommands() {
        let snapshot = ProviderSnapshot(
            health: .ok,
            metrics: [
                Metric(id: "latency", label: "Latency", value: .latency(ms: 42.25)),
                Metric(id: "download", label: "Download", value: .throughput(bitsPerSecond: 12_500_000)),
                Metric(id: "loss", label: "Loss", value: .percent(2.5)),
                Metric(id: "battery", label: "Battery", value: .level(81)),
                Metric(id: "online", label: "Online", value: .bool(true)),
                Metric(id: "state", label: "State", value: .text("connected"))
            ]
        )

        let lines = ProviderSnapshotReport.lines(
            providerID: "demo.provider",
            providerName: "Demo Provider",
            snapshot: snapshot,
            commands: [
                CommandDescriptor(id: "demo.run", label: "Run")
            ]
        )

        XCTAssertEqual(lines, [
            "Provider: Demo Provider (demo.provider)",
            "Health: ok",
            "Latency: 42.25 ms",
            "Download: 12.50 Mbps",
            "Loss: 2.5%",
            "Battery: 81",
            "Online: Yes",
            "State: connected",
            "Commands: demo.run"
        ])
    }

    func testFormatsSnapshotErrorAndEmptyMetricList() {
        let lines = ProviderSnapshotReport.lines(
            providerID: "demo.provider",
            providerName: "Demo Provider",
            snapshot: ProviderSnapshot(health: .down, error: "context deadline\n\nexceeded")
        )

        XCTAssertEqual(lines, [
            "Provider: Demo Provider (demo.provider)",
            "Health: down",
            "Error: context deadline exceeded",
            "Metrics: none"
        ])
    }
}
