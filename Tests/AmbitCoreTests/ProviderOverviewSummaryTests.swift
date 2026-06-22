import XCTest
@testable import AmbitCore

final class ProviderOverviewSummaryTests: XCTestCase {
    func testGenericSummariesIncludeUnknownProviderMetricsAndCommandsName() {
        let snapshot = StatusSnapshot(providers: [
            "demo.ping": SourceState(value: ProviderSnapshot(
                health: .ok,
                metrics: [
                    Metric(id: "latency", label: "Latency", value: .latency(ms: 38)),
                    Metric(id: "loss", label: "Loss", value: .percent(0))
                ]
            ))
        ])

        let summaries = ProviderOverviewSummary.genericSummaries(
            from: snapshot,
            providerNames: ["demo.ping": "Demo Ping"]
        )

        XCTAssertEqual(summaries, [
            ProviderOverviewSummary(
                providerID: "demo.ping",
                title: "Demo Ping",
                detail: "Latency 38 ms · Loss 0%",
                badge: "OK",
                health: .ok,
                errorMessage: nil
            )
        ])
    }

    func testGenericSummariesIncludeErrorOnlyProviders() {
        let snapshot = StatusSnapshot(providers: [
            "demo.power": SourceState<ProviderSnapshot>(errorMessage: "connection\n\nrefused")
        ])

        let summaries = ProviderOverviewSummary.genericSummaries(from: snapshot)

        XCTAssertEqual(summaries, [
            ProviderOverviewSummary(
                providerID: "demo.power",
                title: "demo.power",
                detail: "connection refused",
                badge: "Down",
                health: .down,
                errorMessage: "connection refused"
            )
        ])
    }

    func testGenericSummariesExcludeDedicatedOverviewProviders() {
        let snapshot = StatusSnapshot(providers: [
            ProviderInstanceIDs.starlink: SourceState(value: ProviderSnapshot(health: .down, error: "offline")),
            ProviderInstanceIDs.ping: SourceState(value: ProviderSnapshot.ping(PingSnapshot(host: "1.1.1.1"))),
            "demo.provider": SourceState(value: ProviderSnapshot(health: .unknown))
        ])

        let summaries = ProviderOverviewSummary.genericSummaries(from: snapshot)

        XCTAssertEqual(summaries.map(\.providerID), ["demo.provider"])
    }
}
