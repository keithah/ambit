import XCTest
@testable import AmbitCore

final class PingPresenterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func sample(_ value: Double?, agoSeconds: TimeInterval, ok: Bool = true) -> Sample {
        Sample(timestamp: now.addingTimeInterval(-agoSeconds), value: value, ok: ok)
    }

    func testFormatRoundsAndHandlesMissing() {
        XCTAssertEqual(PingPresenter.format(ms: 14.6), "15ms")
        XCTAssertEqual(PingPresenter.format(ms: nil), "--ms")
    }

    func testReadoutHealthyWithinFreshness() {
        let r = PingPresenter.readout(latest: sample(6, agoSeconds: 20), health: .healthy, now: now, freshness: 60)
        XCTAssertEqual(r.text, "6ms")
        XCTAssertEqual(r.tone, .good)
        XCTAssertEqual(r.statusLabel, "Healthy")
    }

    func testReadoutAgesOutStaleLatest() {
        let r = PingPresenter.readout(latest: sample(6, agoSeconds: 90), health: .healthy, now: now, freshness: 60)
        XCTAssertEqual(r.text, "--ms")
        XCTAssertEqual(r.tone, .neutral)
        XCTAssertEqual(r.statusLabel, "No Recent Data")
    }

    func testReadoutNoDataWhenNoSample() {
        let r = PingPresenter.readout(latest: nil, health: .noData, now: now, freshness: 60)
        XCTAssertEqual(r.text, "--ms")
        XCTAssertEqual(r.statusLabel, "No Data")
    }

    func testGlyphStacksTextAndTone() {
        let g = PingPresenter.glyph(latest: sample(22, agoSeconds: 5), health: .healthy, now: now, freshness: 60)
        XCTAssertEqual(g.latencyText, "22ms")
        XCTAssertEqual(g.tone, .good)
        XCTAssertEqual(g.itemWidth, 34)
        XCTAssertEqual(g.dotDiameter, 8)
        XCTAssertEqual(g.fontSize, 9.5, accuracy: 0.001)
    }

    func testNiceMaxRoundsUpToReadableMaximum() {
        XCTAssertEqual(PingPresenter.niceMax([14, 78, 107]), 125)
        XCTAssertEqual(PingPresenter.ticks(max: 125), [125, 62.5, 0])
        XCTAssertEqual(PingPresenter.niceMax([3, 5, 8]), 25)   // floor for tiny series
    }

    func testWindowedFiltersToRangeAndSorts() {
        let samples = [sample(10, agoSeconds: 400), sample(20, agoSeconds: 50), sample(30, agoSeconds: 10)]
        let windowed = PingPresenter.windowed(samples, range: .fiveMinutes, now: now)
        XCTAssertEqual(windowed.map(\.value), [20, 30])   // 400s-ago dropped, sorted oldest→newest
    }

    func testToneFromHealthStatus() {
        XCTAssertEqual(LatencyTone(.healthy), .good)
        XCTAssertEqual(LatencyTone(.degraded), .warn)
        XCTAssertEqual(LatencyTone(.down), .bad)
        XCTAssertEqual(LatencyTone(.noData), .neutral)
    }
}
