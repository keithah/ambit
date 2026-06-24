import Foundation
import XCTest
@testable import AmbitCore

final class ActiveMeasurementProviderTests: XCTestCase {
    // Basic ICMP "ping" active-measurement provider retired (superseded by the ping integration
    // / socket probes); its summary + parse tests were removed with it. iperf3 coverage stays.
    func testActiveMeasurementSummariesExposeIperf3Metrics() {
        let snapshot = StatusSnapshot(providers: [
            ProviderInstanceIDs.iperf3: SourceState(value: ProviderSnapshot.iperf3(Iperf3Snapshot(
                host: "iperf.example",
                downloadBps: 11_000_000,
                uploadBps: 8_000_000
            )))
        ])

        let summaries = ActiveMeasurementSummary.summaries(from: snapshot)

        XCTAssertEqual(summaries.map(\.providerID), [ProviderIDs.iperf3])
        XCTAssertEqual(summaries.map(\.title), ["iperf3"])
        XCTAssertEqual(summaries[0].subtitle, "iperf.example")
        XCTAssertEqual(summaries[0].primaryMetric?.id, "download_bps")
        XCTAssertEqual(summaries[0].secondaryMetrics.map(\.id), ["upload_bps"])
    }

    func testIperf3ProviderRunCommandStoresLatestThroughput() async throws {
        let output = """
        {
          "end": {
            "sum_sent": { "bits_per_second": 50000000 },
            "sum_received": { "bits_per_second": 47000000 }
          }
        }
        """
        let provider = Iperf3Provider(
            defaultHost: "iperf.example",
            executable: "/usr/bin/iperf3",
            processRunner: StubProcessRunner(results: ["-J -t 5 -c iperf.example": ProcessResult(exitCode: 0, stdout: output, stderr: "")])
        )

        let commandIDs = await provider.commands.map(\.id)
        XCTAssertEqual(commandIDs, [ProviderCommandIDs.iperf3Run])

        try await provider.execute(commandID: ProviderCommandIDs.iperf3Run, arguments: CommandArguments(), context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("download_bps"), .throughput(bitsPerSecond: 47_000_000))
        XCTAssertEqual(snapshot.metricValue("upload_bps"), .throughput(bitsPerSecond: 50_000_000))
    }

    func testIperf3ProviderIdleStateIsNeutralUntilRunCompletes() async {
        let provider = Iperf3Provider(defaultHost: "iperf.example")

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertEqual(snapshot.detail, .iperf3(Iperf3Snapshot(host: "iperf.example")))
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.metrics, [])
    }

    func testIperf3ParserHandlesSingleDirectionSummary() {
        let output = #"{"end":{"sum":{"bits_per_second":123456}}}"#

        let snapshot = Iperf3Provider.parse(host: "host", output: output)

        XCTAssertEqual(snapshot.downloadBps, 123_456)
        XCTAssertNil(snapshot.uploadBps)
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}
