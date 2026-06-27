import XCTest
@testable import AmbitCore

final class GraphAxisTicksTests: XCTestCase {
    func testPercentTicksUseUnitAwareLabels() {
        let descriptor = descriptor(.percent, unit: "%")
        let ticks = GraphAxisTicks.ticks(
            axis: GraphAxis(min: 0, max: 100, unitLabel: "%", isFixed: true, isEmpty: false),
            descriptor: descriptor
        )

        XCTAssertEqual(ticks.map(\.value), [100, 50, 0])
        XCTAssertEqual(ticks.map(\.label), ["100%", "50%", "0%"])
    }

    func testLatencyTicksUseMilliseconds() {
        let descriptor = descriptor(.latency, unit: "ms")
        let ticks = GraphAxisTicks.ticks(
            axis: GraphAxis(min: 0, max: 150, unitLabel: "ms", isFixed: false, isEmpty: false),
            descriptor: descriptor
        )

        XCTAssertEqual(ticks.map(\.value), [150, 75, 0])
        XCTAssertEqual(ticks.map(\.label), ["150ms", "75ms", "0ms"])
    }

    func testCountTicksAreNotFormattedAsPercent() {
        let descriptor = descriptor(.count, unit: nil)
        let ticks = GraphAxisTicks.ticks(
            axis: GraphAxis(min: 0, max: 3, unitLabel: nil, isFixed: false, isEmpty: false),
            descriptor: descriptor
        )

        XCTAssertEqual(ticks.map(\.label), ["3", "2", "0"])
        XCTAssertFalse(ticks.map(\.label).contains { $0.contains("%") })
    }

    func testEmptyAxisWithoutMaximumProducesNoInventedTicks() {
        let ticks = GraphAxisTicks.ticks(
            axis: GraphAxis(min: 0, max: nil, unitLabel: nil, isFixed: false, isEmpty: true),
            descriptor: descriptor(.count, unit: nil)
        )

        XCTAssertTrue(ticks.isEmpty)
    }

    private func descriptor(_ deviceClass: DeviceClass, unit: String?) -> EntityDescriptor {
        EntityDescriptor(
            id: "test.provider.metric",
            instanceID: "test.provider",
            name: "Metric",
            kind: .sensor,
            deviceClass: deviceClass,
            unit: unit
        )
    }
}
