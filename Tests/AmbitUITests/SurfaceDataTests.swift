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
}
