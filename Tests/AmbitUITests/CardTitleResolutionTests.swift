import XCTest
@testable import AmbitUI
import AmbitCore

@MainActor
final class CardTitleResolutionTests: XCTestCase {
    func testGaugeCardUsesOmittedCardSpecTitleAsNoCaption() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let descriptor = EntityDescriptor(id: id, instanceID: "system@local/overview", name: "CPU", kind: .sensor, deviceClass: .percent)
        let data = SurfaceData(
            descriptors: [id: descriptor],
            states: [id: EntityState(id: id, value: .number(42), availability: .online)]
        )
        let spec = CardSpec(id: "card.cpu", kind: .gauge, title: nil, entities: [id])

        let view = CardView(spec: spec, data: data)

        XCTAssertNil(view.resolvedTitle)
        XCTAssertEqual(data.title(id), "CPU")
    }

    func testCardSpecTitleOverridesEntityNameForCaptionedCards() {
        let id = EntityID(rawValue: "system@local/overview.memory_pressure_percent")
        let descriptor = EntityDescriptor(id: id, instanceID: "system@local/overview", name: "Pressure Raw", kind: .sensor, deviceClass: .percent)
        let data = SurfaceData(descriptors: [id: descriptor])
        let spec = CardSpec(id: "card.pressure", kind: .gauge, title: "Memory Pressure", entities: [id])

        let view = CardView(spec: spec, data: data)

        XCTAssertEqual(view.resolvedTitle, "Memory Pressure")
        XCTAssertEqual(data.title(id), "Pressure Raw")
    }
}
