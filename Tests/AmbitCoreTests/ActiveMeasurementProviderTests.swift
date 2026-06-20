import Foundation
import XCTest
@testable import AmbitCore

final class ActiveMeasurementProviderTests: XCTestCase {
    func testPingProviderParsesMacOSPingOutputIntoMetrics() async {
        let output = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=12.100 ms
        64 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=10.900 ms
        64 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=11.000 ms

        --- 1.1.1.1 ping statistics ---
        3 packets transmitted, 3 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 10.900/11.333/12.100/0.543 ms
        """
        let provider = PingProvider(
            host: "1.1.1.1",
            processRunner: StubProcessRunner(results: ["-c 3 -W 1000 1.1.1.1": ProcessResult(exitCode: 0, stdout: output, stderr: "")])
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("latency_ms"), .latency(ms: 11.333))
        XCTAssertEqual(snapshot.metricValue("loss_percent"), .percent(0))
        XCTAssertEqual(snapshot.metricValue("received_packets"), .level(3))
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
