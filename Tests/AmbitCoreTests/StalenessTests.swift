import XCTest
@testable import AmbitCore

final class StalenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testWindowIsIntervalTimesFactorFlooredAtTenSeconds() {
        XCTAssertEqual(Staleness.window(interval: 2), 10)            // 2×3=6 → floored to 10
        XCTAssertEqual(Staleness.window(interval: 5, factor: 3), 15) // 5×3=15 > floor
        XCTAssertEqual(Staleness.window(interval: 5, factor: 3, floor: 20), 20)
    }

    func testIsStale() {
        // interval 2 → window 10.
        XCTAssertFalse(Staleness.isStale(lastUpdate: now.addingTimeInterval(-5), interval: 2, now: now))  // within window
        XCTAssertTrue(Staleness.isStale(lastUpdate: now.addingTimeInterval(-15), interval: 2, now: now))  // past window
        XCTAssertTrue(Staleness.isStale(lastUpdate: nil, interval: 2, now: now))                          // never updated
        XCTAssertFalse(Staleness.isStale(lastUpdate: now.addingTimeInterval(5), interval: 2, now: now))   // future (clock skew)
    }

    func testIsStaleBoundaryIsNotStaleAtExactlyWindow() {
        XCTAssertFalse(Staleness.isStale(lastUpdate: now.addingTimeInterval(-10), interval: 2, now: now))
    }

    func testAvailabilityDowngradesOnlineToStale() {
        XCTAssertEqual(Staleness.availability(.online, lastUpdate: now.addingTimeInterval(-5), interval: 2, now: now), .online)
        XCTAssertEqual(Staleness.availability(.online, lastUpdate: now.addingTimeInterval(-15), interval: 2, now: now), .stale)
    }

    func testAvailabilityPassesThroughNonOnline() {
        XCTAssertEqual(Staleness.availability(.unavailable, lastUpdate: now.addingTimeInterval(-15), interval: 2, now: now), .unavailable)
        XCTAssertEqual(Staleness.availability(.stale, lastUpdate: now, interval: 2, now: now), .stale)  // idempotent
    }
}
