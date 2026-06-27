import XCTest
@testable import AmbitCore

final class GraphAxisResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    func testPercentAndBatteryUseFixedHundredAxis() {
        XCTAssertEqual(axis(for: .percent, values: [12, 61, 99]).max, 100)
        XCTAssertEqual(axis(for: .percent, values: [12]).min, 0)
        XCTAssertEqual(axis(for: .percent, values: [12]).isFixed, true)

        XCTAssertEqual(axis(for: .battery, values: [88]).max, 100)
        XCTAssertEqual(axis(for: .battery, values: [88]).isFixed, true)
    }

    func testProgressRangeUsesDescriptorRange() {
        let descriptor = descriptor(.count, graphStyle: .progress, range: ValueRange(min: 5, max: 25))

        let resolved = GraphAxisResolver.axis(descriptor: descriptor, samples: samples([7, 12]), currentState: nil)

        XCTAssertEqual(resolved.min, 5)
        XCTAssertEqual(resolved.max, 25)
        XCTAssertEqual(resolved.isFixed, true)
        XCTAssertEqual(resolved.isEmpty, false)
    }

    func testAutoScaledClassesUseSamplesAndCurrentValueWithZeroBaseline() {
        let classes: [DeviceClass] = [.latency, .throughput, .count, .duration, .dataSize]

        for deviceClass in classes {
            let descriptor = descriptor(deviceClass)
            let current = EntityState(id: descriptor.id, value: .number(120), availability: .online)

            let resolved = GraphAxisResolver.axis(descriptor: descriptor, samples: samples([42]), currentState: current)

            XCTAssertEqual(resolved.min, 0, "\(deviceClass)")
            XCTAssertEqual(resolved.max, 150, "\(deviceClass)")
            XCTAssertEqual(resolved.isFixed, false, "\(deviceClass)")
            XCTAssertEqual(resolved.isEmpty, false, "\(deviceClass)")
        }
    }

    func testTemperatureAndFanUseRangeWhenPresentOtherwiseAutoScale() {
        let rangedTemperature = descriptor(.temperature, range: ValueRange(min: -20, max: 120))
        let autoFan = descriptor(.fan)

        XCTAssertEqual(GraphAxisResolver.axis(descriptor: rangedTemperature, samples: samples([62]), currentState: nil).max, 120)
        XCTAssertEqual(GraphAxisResolver.axis(descriptor: rangedTemperature, samples: samples([62]), currentState: nil).isFixed, true)
        XCTAssertEqual(GraphAxisResolver.axis(descriptor: autoFan, samples: samples([600]), currentState: nil).max, 750)
        XCTAssertEqual(GraphAxisResolver.axis(descriptor: autoFan, samples: samples([600]), currentState: nil).isFixed, false)
    }

    func testEmptySamplesDoNotInventAMaxUnlessCurrentValueExists() {
        let descriptor = descriptor(.count)

        let empty = GraphAxisResolver.axis(descriptor: descriptor, samples: [], currentState: nil)
        XCTAssertEqual(empty.min, 0)
        XCTAssertNil(empty.max)
        XCTAssertEqual(empty.isEmpty, true)

        let current = EntityState(id: descriptor.id, value: .number(45), availability: .online)
        let currentOnly = GraphAxisResolver.axis(descriptor: descriptor, samples: [], currentState: current)
        XCTAssertEqual(currentOnly.max, 50)
        XCTAssertEqual(currentOnly.isEmpty, false)
    }

    func testFailedSamplesDoNotContributeToAutoAxisBounds() {
        let descriptor = descriptor(.latency)
        let samples = [
            Sample(timestamp: now, value: 25, ok: true),
            Sample(timestamp: now.addingTimeInterval(1), value: nil, ok: false),
            Sample(timestamp: now.addingTimeInterval(2), value: 10_000, ok: false)
        ]

        let resolved = GraphAxisResolver.axis(descriptor: descriptor, samples: samples, currentState: nil)

        XCTAssertEqual(resolved.max, 25)
        XCTAssertEqual(resolved.isEmpty, false)
    }

    private func axis(for deviceClass: DeviceClass, values: [Double]) -> GraphAxis {
        GraphAxisResolver.axis(descriptor: descriptor(deviceClass), samples: samples(values), currentState: nil)
    }

    private func descriptor(_ deviceClass: DeviceClass, graphStyle: GraphStyle? = nil, range: ValueRange? = nil) -> EntityDescriptor {
        EntityDescriptor(
            id: "test.provider.metric",
            instanceID: "test.provider",
            name: "Metric",
            kind: .sensor,
            deviceClass: deviceClass,
            range: range,
            graphStyle: graphStyle
        )
    }

    private func samples(_ values: [Double]) -> [Sample] {
        values.enumerated().map { offset, value in
            Sample(timestamp: now.addingTimeInterval(Double(offset)), value: value)
        }
    }
}
