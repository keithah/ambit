import XCTest
@testable import AmbitUI
import AmbitCore

final class HistoryGraphLoaderTests: XCTestCase {
    func testLoadsSamplesWithinTheRangeWindow() async {
        let history = HistoryService()
        let id: EntityID = "i/p.lat"
        let now = Date(timeIntervalSince1970: 10_000)
        await history.record(Sample(timestamp: now.addingTimeInterval(-30), value: 10), for: id)   // inside 1m
        await history.record(Sample(timestamp: now.addingTimeInterval(-120), value: 99), for: id)  // outside 1m

        let recent = await HistoryGraphLoader.samples(for: id, range: .m1, from: history, now: now)
        XCTAssertEqual(recent.map(\.value), [10])
    }
}
