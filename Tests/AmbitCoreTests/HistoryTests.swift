import XCTest
@testable import AmbitCore

final class HistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
    private func ok(_ v: Double, _ offset: TimeInterval) -> Sample { Sample(timestamp: at(offset), value: v, ok: true) }
    private func fail(_ offset: TimeInterval) -> Sample { Sample(timestamp: at(offset), value: nil, ok: false) }

    func testSampleSeriesBoundsToCapacityAndComputesStats() {
        var series = SampleSeries(capacity: 4)
        [ok(10, 0), ok(20, 1), ok(40, 2), fail(3), ok(50, 4)].forEach { series.append($0) }

        XCTAssertEqual(series.samples.count, 4)                       // oldest (10) dropped
        XCTAssertEqual(series.samples.map(\.value), [20, 40, nil, 50])
        let stats = series.stats()
        XCTAssertEqual(stats.transmitted, 4)
        XCTAssertEqual(stats.received, 3)
        XCTAssertEqual(stats.lossPercent, 25, accuracy: 0.001)
        XCTAssertEqual(stats.min, 20)
        XCTAssertEqual(stats.max, 50)
        XCTAssertEqual(stats.avg ?? 0, 36.667, accuracy: 0.01)
    }

    func testSampleStatsAllFailuresIsFullLossNoValues() {
        let stats = SampleStats.from([fail(0), fail(1)])
        XCTAssertEqual(stats.transmitted, 2)
        XCTAssertEqual(stats.received, 0)
        XCTAssertEqual(stats.lossPercent, 100)
        XCTAssertNil(stats.avg)
    }

    func testHistoryServiceRecordsReadsByRangeAndComputesStats() async {
        let service = HistoryService(store: InMemoryHistoryStore(), retention: 86_400, pruneInterval: 60)
        let id = EntityID(rawValue: "pingscope@1.1.1.1:443/probe.latency_ms")
        await service.record(ok(10, 0), for: id)
        await service.record(ok(30, 10), for: id)
        await service.record(ok(50, 20), for: id)

        let recent = await service.samples(id, since: at(5))
        XCTAssertEqual(recent.map(\.value), [30, 50])
        let stats = await service.stats(id, since: at(0))
        XCTAssertEqual(stats.received, 3)
        XCTAssertEqual(stats.avg, 30)
    }

    func testHistoryServicePrunesByRetention() async {
        // retention 60s, prune every record (interval 0): a sample at +120 prunes the +0 one.
        let service = HistoryService(store: InMemoryHistoryStore(), retention: 60, pruneInterval: 0)
        let id = EntityID(rawValue: "e1")
        await service.record(ok(10, 0), for: id)
        await service.record(ok(20, 120), for: id)

        let remaining = await service.samples(id, since: at(-10_000))
        XCTAssertEqual(remaining.map(\.value), [20])
    }
}
