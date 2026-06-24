import XCTest
@testable import AmbitCore

final class SQLiteHistoryStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ o: TimeInterval) -> Date { t0.addingTimeInterval(o) }
    private let id = EntityID(rawValue: "ping@1.1.1.1:443/probe.latency_ms")

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ambit-history-\(UUID().uuidString).sqlite")
    }

    func testPersistsAndReadsByRangeAscending() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SQLiteHistoryStore(url: url)
        await store.append(Sample(timestamp: at(0), value: 10, ok: true), for: id)
        await store.append(Sample(timestamp: at(10), value: nil, ok: false, metadata: "timeout"), for: id)
        await store.append(Sample(timestamp: at(20), value: 30, ok: true), for: id)

        let all = await store.samples(id, since: at(0), limit: 100)
        XCTAssertEqual(all.map(\.value), [10, nil, 30])           // ascending
        XCTAssertEqual(all[1].ok, false)
        XCTAssertEqual(all[1].metadata, "timeout")                // rich detail round-trips

        let recent = await store.samples(id, since: at(5), limit: 100)
        XCTAssertEqual(recent.map(\.value), [nil, 30])            // range filter
    }

    func testMostRecentLimitReturnedAscending() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SQLiteHistoryStore(url: url)
        for i in 0..<5 { await store.append(Sample(timestamp: at(Double(i)), value: Double(i), ok: true), for: id) }
        let lastTwo = await store.samples(id, since: at(0), limit: 2)
        XCTAssertEqual(lastTwo.map(\.value), [3, 4])
    }

    func testPrunesOlderThanCutoff() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SQLiteHistoryStore(url: url)
        await store.append(Sample(timestamp: at(0), value: 1, ok: true), for: id)
        await store.append(Sample(timestamp: at(100), value: 2, ok: true), for: id)
        await store.prune(olderThan: at(50))
        let remaining = await store.samples(id, since: at(-10_000), limit: 100)
        XCTAssertEqual(remaining.map(\.value), [2])
    }

    func testDataSurvivesReopen() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = SQLiteHistoryStore(url: url)
            await store.append(Sample(timestamp: at(0), value: 42, ok: true), for: id)
        }
        let reopened = SQLiteHistoryStore(url: url)
        let samples = await reopened.samples(id, since: at(-10_000), limit: 100)
        XCTAssertEqual(samples.map(\.value), [42])
    }
}
