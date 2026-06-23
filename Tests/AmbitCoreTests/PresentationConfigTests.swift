import XCTest
@testable import AmbitCore

final class PresentationConfigTests: XCTestCase {
    func testEmptyConfigHasNoOverrides() {
        let c = PresentationConfig.empty
        XCTAssertTrue(c.entityOverrides.isEmpty)
        XCTAssertTrue(c.integrationOverrides.isEmpty)
    }

    func testConfigRoundTripsThroughCodable() throws {
        var c = PresentationConfig.empty
        c.entityOverrides["ping/probe.latency"] = EntityPresentationOverride(
            visibility: .always, graphStyle: .sparkline, graphRange: .m1, enabled: true
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }
}
