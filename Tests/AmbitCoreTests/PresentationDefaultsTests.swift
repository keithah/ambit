import XCTest
@testable import AmbitCore

final class PresentationDefaultsTests: XCTestCase {
    func testGraphRangeSeconds() {
        XCTAssertEqual(GraphRange.m1.seconds, 60)
        XCTAssertEqual(GraphRange.m5.seconds, 300)
        XCTAssertEqual(GraphRange.m10.seconds, 600)
        XCTAssertEqual(GraphRange.h1.seconds, 3600)
        XCTAssertEqual(GraphRange.allCases.count, 4)
    }

    func testDisplayThresholdRoundTrips() throws {
        let t = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(DisplayThreshold.self, from: data), t)
    }

    func testDescriptorPresentationDefaultsHaveSensibleFallbacks() {
        let d = EntityDescriptor(
            id: "glinet/router.latency",
            instanceID: "glinet/router",
            name: "Latency",
            kind: .sensor
        )
        XCTAssertEqual(d.defaultVisibility, .auto)
        XCTAssertFalse(d.isPrimary)
        XCTAssertNil(d.graphStyle)
        XCTAssertNil(d.defaultGraphRange)
        XCTAssertNil(d.priority)
    }

    func testDescriptorCarriesPresentationDefaults() {
        let d = EntityDescriptor(
            id: "ping/probe.latency", instanceID: "ping/probe", name: "Latency", kind: .sensor,
            stateClass: .measurement,
            graphStyle: .sparkline, defaultGraphRange: .m5, isPrimary: true, priority: 3
        )
        XCTAssertEqual(d.graphStyle, .sparkline)
        XCTAssertEqual(d.defaultGraphRange, .m5)
        XCTAssertTrue(d.isPrimary)
        XCTAssertEqual(d.priority, 3)
    }
}
