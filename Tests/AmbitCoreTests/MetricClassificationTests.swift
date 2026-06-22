import XCTest
@testable import AmbitCore

final class MetricClassificationTests: XCTestCase {
    func testMetricMappingDecodesOptionalClassificationWhenPresent() throws {
        let json = Data("""
        {
          "id": "battery_percent",
          "label": "Battery",
          "value": { "type": "percent", "path": "battery.soc" },
          "deviceClass": "battery",
          "category": "primary",
          "capability": "battery"
        }
        """.utf8)

        let mapping = try JSONDecoder().decode(ProviderManifest.MetricMapping.self, from: json)

        XCTAssertEqual(mapping.deviceClass, .battery)
        XCTAssertEqual(mapping.category, .primary)
        XCTAssertEqual(mapping.capability, ProviderCapability(rawValue: "battery"))
    }

    func testMetricMappingClassificationIsNilWhenAbsent() throws {
        let json = Data("""
        { "id": "latency_ms", "label": "Latency", "value": { "type": "latency", "path": "ping.ms" } }
        """.utf8)

        let mapping = try JSONDecoder().decode(ProviderManifest.MetricMapping.self, from: json)

        XCTAssertNil(mapping.deviceClass)
        XCTAssertNil(mapping.category)
        XCTAssertNil(mapping.capability)
    }

    func testMetricCarriesOptionalClassificationDefaultingNil() {
        let bare = Metric(id: "x", label: "X", value: .level(1))
        XCTAssertNil(bare.deviceClass)
        XCTAssertNil(bare.category)
        XCTAssertNil(bare.capability)

        let classified = Metric(id: "y", label: "Y", value: .percent(50), deviceClass: .battery, category: .primary)
        XCTAssertEqual(classified.deviceClass, .battery)
        XCTAssertEqual(classified.category, .primary)
    }
}
