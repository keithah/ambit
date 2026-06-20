import Foundation
import XCTest
@testable import AmbitCore

final class ModuleUsageMeterTests: XCTestCase {
    func testRecordsPollsCommandsFailuresAndDuration() async throws {
        let meter = ModuleUsageMeter()

        await meter.record(providerID: "demo", operation: .poll, duration: 0.25, at: Date(timeIntervalSince1970: 1))
        await meter.record(providerID: "demo", operation: .command, duration: 0.5, error: "failed", at: Date(timeIntervalSince1970: 2))

        let maybeSnapshot = await meter.snapshot(providerID: "demo")
        let snapshot = try XCTUnwrap(maybeSnapshot)
        XCTAssertEqual(snapshot.pollCount, 1)
        XCTAssertEqual(snapshot.commandCount, 1)
        XCTAssertEqual(snapshot.failureCount, 1)
        XCTAssertEqual(snapshot.totalDuration, 0.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.lastOperation, .command)
        XCTAssertEqual(snapshot.lastError, "failed")
        XCTAssertEqual(snapshot.lastUpdated, Date(timeIntervalSince1970: 2))
    }

    func testFormatsUsageReportInStableProviderOrder() {
        let snapshots = [
            ModuleUsageSnapshot(
                providerID: "vpn",
                pollCount: 1,
                commandCount: 2,
                failureCount: 1,
                totalDuration: 0.045,
                lastOperation: .command,
                lastError: "not connected",
                lastUpdated: Date(timeIntervalSince1970: 2)
            ),
            ModuleUsageSnapshot(
                providerID: "router",
                pollCount: 3,
                commandCount: 0,
                failureCount: 0,
                totalDuration: 0.1234,
                lastOperation: .poll,
                lastUpdated: Date(timeIntervalSince1970: 1)
            )
        ]

        let report = ModuleUsageReportFormatter.format(snapshots)

        XCTAssertEqual(
            report,
            """
            Module usage:
              router: polls 3, commands 0, failures 0, total 0.123s, last poll
              vpn: polls 1, commands 2, failures 1, total 0.045s, last command, last error: not connected
            """
        )
    }

    func testFormatsKnownProvidersBeforeActiveMeasurementsAndUnknownProviders() {
        let snapshots = [
            ModuleUsageSnapshot(providerID: "custom", pollCount: 1),
            ModuleUsageSnapshot(providerID: ProviderIDs.ping, pollCount: 1),
            ModuleUsageSnapshot(providerID: ProviderIDs.iperf3, commandCount: 1),
            ModuleUsageSnapshot(providerID: ProviderIDs.speedify, pollCount: 1),
            ModuleUsageSnapshot(providerID: ProviderIDs.router, pollCount: 1)
        ]

        let report = ModuleUsageReportFormatter.format(snapshots)

        XCTAssertEqual(
            report,
            """
            Module usage:
              router: polls 1, commands 0, failures 0, total 0.000s
              speedify: polls 1, commands 0, failures 0, total 0.000s
              ping: polls 1, commands 0, failures 0, total 0.000s
              iperf3: polls 0, commands 1, failures 0, total 0.000s
              custom: polls 1, commands 0, failures 0, total 0.000s
            """
        )
    }

    func testFormatsMultilineErrorsAsSingleLineEntries() {
        let snapshots = [
            ModuleUsageSnapshot(
                providerID: "starlink",
                pollCount: 1,
                failureCount: 1,
                totalDuration: 5,
                lastOperation: .poll,
                lastError: "Failed to dial target host\n\ncontext deadline exceeded"
            )
        ]

        let report = ModuleUsageReportFormatter.format(snapshots)

        XCTAssertEqual(
            report,
            """
            Module usage:
              starlink: polls 1, commands 0, failures 1, total 5.000s, last poll, last error: Failed to dial target host context deadline exceeded
            """
        )
    }
}
