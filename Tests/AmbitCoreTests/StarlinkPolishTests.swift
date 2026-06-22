import XCTest
@testable import AmbitCore

final class StarlinkPolishTests: XCTestCase {
    func testDescriptorsCoverEveryEmittedMetric() {
        let descriptors = StarlinkProvider().entityDescriptors()
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

        XCTAssertEqual(byID["starlink/starlink.drop_percent"]?.deviceClass, .percent)
        XCTAssertEqual(byID["starlink/starlink.drop_percent"]?.category, .diagnostic)
        XCTAssertEqual(byID["starlink/starlink.drop_percent"]?.metricID, "drop_percent")
        XCTAssertEqual(byID["starlink/starlink.state"]?.kind, .text)
        XCTAssertEqual(byID["starlink/starlink.state"]?.category, .diagnostic)

        // Every metric a healthy Starlink poll emits should now have a backing descriptor.
        let status = StarlinkStatus(
            isReachable: true, state: "Online",
            downlinkThroughputBps: 120_000_000, uplinkThroughputBps: 20_000_000,
            popPingLatencyMs: 34, obstructionPercent: 1.2, recentDropRate: 0.01, outageCount: 2
        )
        let emitted = Set(ProviderSnapshot.starlink(status).metrics.map(\.id))
        let backed = Set(descriptors.compactMap(\.metricID))
        XCTAssertTrue(emitted.isSubset(of: backed), "uncovered metrics: \(emitted.subtracting(backed))")
    }
}
