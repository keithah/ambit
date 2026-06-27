import XCTest
@testable import AmbitUI
import AmbitCore

@MainActor
final class GraphAxisDensityTests: XCTestCase {
    func testPrimaryGraphCardsShowLabeledAxes() {
        let spec = CardSpec(
            id: "card.primary",
            kind: .historyGraph,
            entities: ["system@local/overview.cpu_usage_percent"],
            role: .primary
        )
        let view = CardView(spec: spec, data: SurfaceData())

        XCTAssertTrue(view.shouldShowGraphAxes)
    }

    func testSecondaryGraphCardsStayCompact() {
        let spec = CardSpec(
            id: "card.secondary",
            kind: .dualLineGraph,
            entities: ["system@local/network.in", "system@local/network.out"],
            role: .secondary
        )
        let view = CardView(spec: spec, data: SurfaceData())

        XCTAssertFalse(view.shouldShowGraphAxes)
    }

    func testNonGraphPrimaryCardsDoNotShowGraphAxes() {
        let spec = CardSpec(
            id: "card.gauge",
            kind: .gauge,
            entities: ["system@local/overview.cpu_usage_percent"],
            role: .primary
        )
        let view = CardView(spec: spec, data: SurfaceData())

        XCTAssertFalse(view.shouldShowGraphAxes)
    }
}
