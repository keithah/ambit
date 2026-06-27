import XCTest
@testable import AmbitCore

final class PresentationConfigTests: XCTestCase {
    func testEmptyConfigHasNoOverrides() {
        let c = PresentationConfig.empty
        XCTAssertTrue(c.entityOverrides.isEmpty)
        XCTAssertTrue(c.integrationOverrides.isEmpty)
        XCTAssertTrue(c.slotOverrides.isEmpty)
    }

    func testConfigRoundTripsThroughCodable() throws {
        var c = PresentationConfig.empty
        c.entityOverrides["ping/probe.latency"] = EntityPresentationOverride(
            visibility: .always, graphStyle: .sparkline, graphRange: .m1, enabled: true
        )
        c.slotOverrides[SlotID(rawValue: "slot.system")] = SlotPresentationOverride(
            shownItems: [SurfaceItemID(rawValue: "entity:system@local/overview.cpu_usage_percent")],
            hiddenItems: [SurfaceItemID(rawValue: "group:system.memory:dataSize:B:segments")]
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }

    func testSlotPresentationOverrideDecodesWithDefaults() throws {
        let json = #"{"slots":[]}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: json)

        XCTAssertTrue(decoded.slotOverrides.isEmpty)
    }
}
