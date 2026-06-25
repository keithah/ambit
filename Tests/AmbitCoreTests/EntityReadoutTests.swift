import XCTest
@testable import AmbitCore

final class EntityReadoutTests: XCTestCase {
    private func descriptor(_ deviceClass: DeviceClass?, kind: EntityKind = .sensor, unit: String? = nil, range: ValueRange? = nil) -> EntityDescriptor {
        EntityDescriptor(id: "i/p.e", instanceID: "i/p", name: "E", kind: kind, deviceClass: deviceClass, unit: unit, range: range)
    }

    func testLatencyFormatsAsMilliseconds() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(42.4), availability: .online))
        XCTAssertEqual(r.text, "42ms")
        XCTAssertEqual(r.tone, .good)
        XCTAssertNil(r.fraction)
    }

    func testPercentProducesFraction() {
        let r = EntityReadout.make(descriptor: descriptor(.percent), state: EntityState(id: "i/p.e", value: .number(64), availability: .online))
        XCTAssertEqual(r.text, "64%")
        XCTAssertEqual(r.fraction!, 0.64, accuracy: 0.0001)
    }

    func testBatteryUsesRangeWhenPresent() {
        let r = EntityReadout.make(descriptor: descriptor(.battery, range: ValueRange(min: 0, max: 100)), state: EntityState(id: "i/p.e", value: .number(20), availability: .online))
        XCTAssertEqual(r.fraction!, 0.20, accuracy: 0.0001)
    }

    func testBoolBinarySensorTextAndTone() {
        let r = EntityReadout.make(descriptor: descriptor(.connectivity, kind: .binarySensor), state: EntityState(id: "i/p.e", value: .bool(true), availability: .online))
        XCTAssertEqual(r.text, "Yes")
        XCTAssertEqual(r.tone, .good)
    }

    func testUnavailableIsBadAndLabeledDown() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: nil, availability: .unavailable))
        XCTAssertEqual(r.text, "Down")
        XCTAssertEqual(r.tone, .bad)
    }

    func testStaleIsWarn() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(10), availability: .stale))
        XCTAssertEqual(r.tone, .warn)
    }

    func testNilStateIsNeutralDash() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: nil)
        XCTAssertEqual(r.text, "—")
        XCTAssertEqual(r.tone, .neutral)
    }

    func testPublicFormatterIsUnitGeneric() {
        XCTAssertEqual(EntityReadout.format(150, deviceClass: .latency, unit: "ms"), "150ms")
        XCTAssertEqual(EntityReadout.format(15_000_000, deviceClass: .throughput, unit: "bps"), "15.0 Mbps")
    }

    func testSeverityOverridesAvailabilityTone() {
        let d = descriptor(nil, kind: .text)
        let r = EntityReadout.make(descriptor: d, state: EntityState(id: "i/p.e", value: .text("ISP path down"), availability: .online, severity: .down))
        XCTAssertEqual(r.tone, .bad)
        XCTAssertEqual(r.text, "ISP path down")
    }

    func testElevatedSeverityIsWarn() {
        let d = descriptor(nil, kind: .text)
        let r = EntityReadout.make(descriptor: d, state: EntityState(id: "i/p.e", value: .text("x"), availability: .online, severity: .degraded))
        XCTAssertEqual(r.tone, .warn)
    }

    func testNormalSeverityFallsBackToAvailability() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(10), availability: .online, severity: .normal))
        XCTAssertEqual(r.tone, .good)
    }

    func testTableReadoutSummarizesRows() {
        let table = TableValue(
            columns: [TableColumn(id: "mount", title: "Mount", alignment: .leading, valueStyle: .text)],
            rows: [
                TableRow(id: "/", cells: ["mount": .text("/")]),
                TableRow(id: "/Volumes/Data", cells: ["mount": .text("/Volumes/Data")])
            ]
        )
        let r = EntityReadout.make(
            descriptor: descriptor(nil, kind: .table),
            state: EntityState(id: "i/p.e", value: .table(table), availability: .online)
        )

        XCTAssertEqual(r.text, "2 rows")
        XCTAssertEqual(r.tone, .good)
        XCTAssertNil(r.fraction)
    }
}
