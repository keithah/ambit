import XCTest
@testable import AmbitUI
import AmbitCore

final class SurfaceDataTests: XCTestCase {
    func testReadoutResolvesDescriptorAndState() {
        let descriptor = EntityDescriptor(id: "i/p.lat", instanceID: "i/p", name: "Latency", kind: .sensor, deviceClass: .latency)
        let data = SurfaceData(
            descriptors: ["i/p.lat": descriptor],
            states: ["i/p.lat": EntityState(id: "i/p.lat", value: .number(12), availability: .online)],
            series: [:]
        )
        XCTAssertEqual(data.readout("i/p.lat").text, "12ms")
    }

    func testReadoutForUnknownEntityIsDash() {
        let data = SurfaceData(descriptors: [:], states: [:], series: [:])
        XCTAssertEqual(data.readout("missing").text, "—")
    }

    func testGraphLinesBindSamplesForEveryEntityWithDeterministicColors() {
        let now = Date(timeIntervalSince1970: 0)
        let a = EntityID(rawValue: "i/p.a")
        let b = EntityID(rawValue: "i/p.b")
        let data = SurfaceData(
            descriptors: [
                a: EntityDescriptor(id: a, instanceID: "i/p", name: "A", kind: .sensor, deviceClass: .percent),
                b: EntityDescriptor(id: b, instanceID: "i/p", name: "B", kind: .sensor, deviceClass: .percent)
            ],
            states: [:],
            series: [
                a: [Sample(timestamp: now, value: 1), Sample(timestamp: now.addingTimeInterval(1), value: 2)],
                b: [Sample(timestamp: now, value: 3), Sample(timestamp: now.addingTimeInterval(1), value: 4)]
            ]
        )

        let lines = data.graphLines([a, b])

        XCTAssertEqual(lines.map(\.id), ["A", "B"])
        XCTAssertEqual(lines.map { $0.samples.map(\.value) }, [[1, 2], [3, 4]])
        XCTAssertEqual(lines[0].color, Theme.lineColor(0))
        XCTAssertEqual(lines[1].color, Theme.lineColor(1))
    }

    func testMultiSeriesSummaryBindsToPrimaryEntityNotCombinedSamples() {
        let a = EntityID(rawValue: "i/p.a")
        let b = EntityID(rawValue: "i/p.b")
        let data = SurfaceData(
            descriptors: [:],
            states: [:],
            series: [:],
            primaryEntityID: b
        )

        XCTAssertEqual(data.summaryEntityID(for: [a, b]), b)
        XCTAssertEqual(data.summaryEntityID(for: [a]), a)
        XCTAssertNil(data.summaryEntityID(for: []))
    }
}
