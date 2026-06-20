import XCTest
@testable import AmbitCore

final class StarlinkClientTests: XCTestCase {
    func testMissingGrpcurlReturnsUnavailableStatus() async {
        let client = StarlinkClient(path: "/not/installed/grpcurl", processRunner: StubProcessRunner(results: [:]))

        let status = await client.status()

        XCTAssertFalse(status.isReachable)
        XCTAssertEqual(status.state, "grpcurl not installed")
    }

    func testParsesStatusAndHistoryPayloads() async {
        let statusJSON = """
        {
          "dishGetStatus": {
            "deviceInfo": {"hardwareVersion":"mini1_panda_prod1","softwareVersion":"2026.06.04"},
            "deviceState": {"uptimeS":"1076"},
            "obstructionStats": {"fractionObstructed":0.016363636},
            "downlinkThroughputBps":1377971.5,
            "uplinkThroughputBps":9833151.0,
            "popPingLatencyMs":18.558447,
            "gpsStats": {"gpsValid":true,"gpsSats":16},
            "ethSpeedMbps":1000,
            "disablementCode":"OKAY",
            "softwareUpdateState":"IDLE"
          }
        }
        """
        let historyJSON = """
        {
          "dishGetHistory": {
            "popPingDropRate":[0,0.2,0.5],
            "popPingLatencyMs":[20,30,40],
            "downlinkThroughputBps":[1000,2000,3000],
            "uplinkThroughputBps":[400,500,600],
            "powerIn":[12.5,13.5],
            "outages":[{"cause":"NO_PINGS","durationNs":"900000000"}]
          }
        }
        """
        let client = StarlinkClient(
            path: "/opt/homebrew/bin/grpcurl",
            processRunner: StubProcessRunner(results: [
                "-plaintext -max-time 5 -d {\"get_status\":{}} 192.168.100.1:9200 SpaceX.API.Device.Device/Handle": ProcessResult(exitCode: 0, stdout: statusJSON, stderr: ""),
                "-plaintext -max-time 5 -d {\"get_history\":{}} 192.168.100.1:9200 SpaceX.API.Device.Device/Handle": ProcessResult(exitCode: 0, stdout: historyJSON, stderr: "")
            ])
        )

        let status = await client.status()

        XCTAssertTrue(status.isReachable)
        XCTAssertEqual(status.state, "Online")
        XCTAssertEqual(status.hardwareVersion, "mini1_panda_prod1")
        XCTAssertEqual(status.softwareVersion, "2026.06.04")
        XCTAssertEqual(status.uptimeSeconds, 1076)
        XCTAssertEqual(status.downlinkThroughputBps, 1_377_971)
        XCTAssertEqual(status.uplinkThroughputBps, 9_833_151)
        XCTAssertEqual(status.popPingLatencyMs, 18.558447)
        XCTAssertEqual(status.obstructionPercent ?? -1, 1.6363636, accuracy: 0.0001)
        XCTAssertEqual(status.gpsSats, 16)
        XCTAssertEqual(status.ethSpeedMbps, 1000)
        XCTAssertEqual(status.recentDropRate, 0.5)
        XCTAssertEqual(status.recentLatencyMs, 40)
        XCTAssertEqual(status.recentDownlinkThroughputBps, 3000)
        XCTAssertEqual(status.recentUplinkThroughputBps, 600)
        XCTAssertEqual(status.outageCount, 1)
    }
}
