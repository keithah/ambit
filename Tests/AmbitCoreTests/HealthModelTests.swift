import XCTest
@testable import AmbitCore

// Ports the intent of pingscope's health tests (consecutive-failures→down, threshold→
// degraded, success reset, recovery transitions) against the generic evaluator.
final class HealthModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testRequiresConsecutiveFailuresBeforeDown() {
        var state = HealthState()
        let thresholds = HealthThresholds(degradedAt: 100, downAfterFailures: 3)

        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .degraded); XCTAssertEqual(state.consecutiveFailures, 1)
        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .degraded); XCTAssertEqual(state.consecutiveFailures, 2)
        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0.addingTimeInterval(1))
        XCTAssertEqual(state.status, .down); XCTAssertEqual(state.consecutiveFailures, 3)
        XCTAssertEqual(state.lastFailureTransition, t0.addingTimeInterval(1))
    }

    func testDefaultThresholdMarks107MillisecondsDegradedAndBelowHealthy() {
        var state = HealthState()
        let thresholds = HealthThresholds()  // degradedAt 100
        state.ingest(value: 107, ok: true, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .degraded)
        state.ingest(value: 42, ok: true, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .healthy)
    }

    func testSuccessResetsConsecutiveFailures() {
        var state = HealthState()
        let thresholds = HealthThresholds(degradedAt: 100, downAfterFailures: 3)
        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0)
        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0)
        state.ingest(value: 10, ok: true, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testRecoveryTransitionRecordedOnlyWhenLeavingDown() {
        var state = HealthState()
        let thresholds = HealthThresholds(degradedAt: 100, downAfterFailures: 1) // down on first failure
        state.ingest(value: nil, ok: false, thresholds: thresholds, at: t0)
        XCTAssertEqual(state.status, .down)
        XCTAssertNil(state.lastRecoveryTransition)

        let recoverAt = t0.addingTimeInterval(5)
        state.ingest(value: 10, ok: true, thresholds: thresholds, at: recoverAt)
        XCTAssertEqual(state.status, .healthy)
        XCTAssertEqual(state.lastRecoveryTransition, recoverAt)

        // A healthy→healthy sample does not move the recovery transition.
        state.ingest(value: 12, ok: true, thresholds: thresholds, at: t0.addingTimeInterval(9))
        XCTAssertEqual(state.lastRecoveryTransition, recoverAt)
    }

    func testDownThresholdClampedToAtLeastOne() {
        XCTAssertEqual(HealthThresholds(downAfterFailures: 0).downAfterFailures, 1)
    }

    func testLegacyHealthProjection() {
        XCTAssertEqual(HealthStatus.noData.legacyHealth, .unknown)
        XCTAssertEqual(HealthStatus.healthy.legacyHealth, .ok)
        XCTAssertEqual(HealthStatus.degraded.legacyHealth, .degraded)
        XCTAssertEqual(HealthStatus.down.legacyHealth, .down)
    }
}
