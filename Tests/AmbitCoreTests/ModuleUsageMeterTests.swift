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
}
