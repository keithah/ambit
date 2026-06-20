import XCTest
@testable import AmbitCore

final class SpeedifyClientTests: XCTestCase {
    func testMergingLiveSamplesKeepsRollingHistory() {
        let previous = SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            state: "Connected",
            graphSamples: [
                SpeedifyGraphSample(totalBps: 100),
                SpeedifyGraphSample(totalBps: 200)
            ]
        )
        let current = SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            state: "Connected",
            graphSamples: [
                SpeedifyGraphSample(totalBps: 300),
                SpeedifyGraphSample(totalBps: 400)
            ]
        )

        let merged = current.mergingLiveSamples(from: previous, limit: 3)

        XCTAssertEqual(merged.graphSamples.map(\.totalBps), [200, 300, 400])
    }

    func testMissingBinaryReturnsUnavailableStatus() async {
        let client = SpeedifyClient(path: "/not/installed/speedify_cli", processRunner: StubProcessRunner(results: [:]))

        let status = await client.status()

        XCTAssertFalse(status.isInstalled)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.state, "Not installed")
    }

    func testDaemonConnectionErrorReturnsInstalledUnavailableStatus() async {
        let errorJSON = """
        {"errorCode":3845,"errorMessage":"Unable to connect","errorType":"Not able to establish connection to daemon"}
        """
        let client = SpeedifyClient(
            path: "/Applications/Speedify.app/Contents/Resources/speedify_cli",
            processRunner: StubProcessRunner(results: [
                "state": ProcessResult(exitCode: 1, stdout: errorJSON, stderr: "")
            ])
        )

        let status = await client.status()

        XCTAssertTrue(status.isInstalled)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.state, "Daemon unavailable")
        XCTAssertEqual(status.detail, "Unable to connect")
    }

    func testParsesConnectedStateAndCurrentServer() async {
        let stateJSON = """
        {"state":"CONNECTED","connectionState":"CONNECTED","connected":true}
        """
        let serverJSON = """
        {"country":"United States","city":"Seattle","server":"sea01"}
        """
        let client = SpeedifyClient(
            path: "/Applications/Speedify.app/Contents/Resources/speedify_cli",
            processRunner: StubProcessRunner(results: [
                "state": ProcessResult(exitCode: 0, stdout: stateJSON, stderr: ""),
                "show currentserver": ProcessResult(exitCode: 0, stdout: serverJSON, stderr: "")
            ])
        )

        let status = await client.status()

        XCTAssertTrue(status.isAvailable)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.state, "CONNECTED")
        XCTAssertEqual(status.server, "United States, Seattle")
    }
}
