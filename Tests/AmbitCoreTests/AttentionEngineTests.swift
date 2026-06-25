import XCTest
@testable import AmbitCore

final class AttentionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let bar = SurfaceID(rawValue: "bar")

    private func candidate(
        _ key: String,
        availability: Availability = .online,
        severity: Severity = .normal,
        value: EntityValue? = nil,
        visibility: GlanceVisibility = .auto,
        priority: Int? = nil,
        isPrimary: Bool = false,
        displayThreshold: DisplayThreshold? = nil
    ) -> AttentionCandidate {
        let id = EntityID(rawValue: "inst.\(key)")
        let descriptor = EntityDescriptor(
            id: id, instanceID: ProviderInstanceID(rawValue: "inst"), name: key, kind: .sensor,
            defaultVisibility: visibility, displayThreshold: displayThreshold, isPrimary: isPrimary, priority: priority
        )
        let state = EntityState(id: id, value: value, availability: availability, severity: severity)
        return AttentionCandidate(descriptor: descriptor, state: state)
    }

    private func selection(
        _ candidates: [AttentionCandidate],
        lanes: Int = 1,
        alerting: Set<EntityID> = [],
        config: PresentationConfig = .empty,
        now: Date? = nil
    ) -> AttentionSelection {
        var engine = AttentionEngine()
        return selection(candidates, engine: &engine, lanes: lanes, alerting: alerting, config: config, now: now ?? self.now)
    }

    private func selection(
        _ candidates: [AttentionCandidate],
        engine: inout AttentionEngine,
        lanes: Int = 1,
        alerting: Set<EntityID> = [],
        config: PresentationConfig = .empty,
        now: Date
    ) -> AttentionSelection {
        return engine.evaluate(
            candidates: candidates,
            surfaces: [bar: SurfaceCapacity(lanes: lanes)],
            alertingIDs: alerting,
            config: config,
            now: now
        )[bar]!
    }

    private func laneIDs(_ s: AttentionSelection) -> [String] { s.lanes.map { $0.id.rawValue } }
    private func id(_ key: String) -> EntityID { EntityID(rawValue: "inst.\(key)") }

    // MARK: Visibility routing

    func testNeverIsNeverALane() {
        // A .never entity, even at .down severity, must not occupy a lane (an auto entity fills it).
        let s = selection([
            candidate("never", severity: .down, visibility: .never),
            candidate("auto", severity: .degraded, visibility: .auto)
        ], lanes: 2)
        XCTAssertEqual(laneIDs(s), ["inst.auto"])
    }

    func testAlwaysSurfacesEvenWhenNormal() {
        let s = selection([candidate("always", severity: .normal, visibility: .always)])
        XCTAssertEqual(laneIDs(s), ["inst.always"])
        XCTAssertEqual(s.lanes.first?.tier, .surfaced)
    }

    func testAutoNormalIsNotSurfacedButAutoElevatedIs() {
        let calm = selection([candidate("a", severity: .normal, visibility: .auto), candidate("b", severity: .normal, visibility: .auto, isPrimary: true)], lanes: 2)
        // Nothing surfaced → resting fallback shows exactly the isPrimary one.
        XCTAssertEqual(laneIDs(calm), ["inst.b"])
        XCTAssertEqual(calm.lanes.first?.tier, .detail)

        let hot = selection([candidate("a", severity: .elevated, visibility: .auto)])
        XCTAssertEqual(laneIDs(hot), ["inst.a"])
        XCTAssertEqual(hot.lanes.first?.tier, .surfaced)
    }

    // MARK: Tier — display vs alert separation

    func testDisplayThresholdCrossesToSurfacedAndAlertingToAlerted() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100)
        let over = candidate("lat", value: .number(150), displayThreshold: threshold)

        let surfaced = selection([over])
        XCTAssertEqual(surfaced.lanes.first?.tier, .surfaced)
        XCTAssertTrue(surfaced.lanes.first?.reason.summary.contains("display threshold crossed") ?? false)

        let alerted = selection([over], alerting: [id("lat")])
        XCTAssertEqual(alerted.lanes.first?.tier, .alerted)
        XCTAssertEqual(alerted.alerted.map { $0.id.rawValue }, ["inst.lat"])
    }

    // MARK: Lane-fill order

    func testAlertedPreemptsPinnedAtCapacityOne() {
        var config = PresentationConfig.empty
        config.entityOverrides[id("pin")] = EntityPresentationOverride(pinned: true)
        let s = selection([
            candidate("pin", severity: .normal),               // pinned-normal (reserved)
            candidate("alarm", severity: .normal)              // alerted via alertingIDs
        ], lanes: 1, alerting: [id("alarm")], config: config)
        XCTAssertEqual(laneIDs(s), ["inst.alarm"])
        XCTAssertEqual(s.overflowCount, 1)
    }

    func testReservedOutranksHigherScoredSurfacedWhenNoAlerted() {
        // B is .down (score ~4000); A is reserved-normal (score ~0). With no alerted, reserved fills first.
        let s = selection([
            candidate("a", severity: .normal, visibility: .always),  // reserved
            candidate("b", severity: .down, visibility: .auto)       // surfaced, higher score
        ], lanes: 1)
        XCTAssertEqual(laneIDs(s), ["inst.a"])
        XCTAssertEqual(s.overflowCount, 1)
    }

    // MARK: Ranking

    func testRankingByScoreThenStableEntityIDTieBreak() {
        let s = selection([
            candidate("low", severity: .elevated, visibility: .auto),
            candidate("high", severity: .down, visibility: .auto),
            candidate("mid", severity: .degraded, visibility: .auto)
        ], lanes: 3)
        XCTAssertEqual(laneIDs(s), ["inst.high", "inst.mid", "inst.low"])
    }

    func testPriorityBreaksSeverityTieAndIDBreaksPriorityTie() {
        let s = selection([
            candidate("z", severity: .degraded, visibility: .auto, priority: 5),
            candidate("a", severity: .degraded, visibility: .auto, priority: 5),  // same score → id tie-break
            candidate("p", severity: .degraded, visibility: .auto, priority: 9)   // higher priority first
        ], lanes: 3)
        XCTAssertEqual(laneIDs(s), ["inst.p", "inst.a", "inst.z"])
    }

    // MARK: Overflow

    func testOverflowCountAtCapacityOneAndN() {
        let three = [
            candidate("a", severity: .down, visibility: .auto),
            candidate("b", severity: .degraded, visibility: .auto),
            candidate("c", severity: .elevated, visibility: .auto)
        ]
        XCTAssertEqual(selection(three, lanes: 1).overflowCount, 2)
        XCTAssertEqual(selection(three, lanes: 5).overflowCount, 0)
        XCTAssertEqual(selection(three, lanes: 5).lanes.count, 3)
    }

    // MARK: Resting fallback

    func testRestingFallbackPicksHighestPriorityPrimary() {
        let s = selection([
            candidate("sec", severity: .normal, visibility: .auto, priority: 1),
            candidate("pri", severity: .normal, visibility: .auto, priority: 2, isPrimary: true),
            candidate("hidden", severity: .normal, visibility: .never)
        ], lanes: 1)
        XCTAssertEqual(laneIDs(s), ["inst.pri"])
        XCTAssertEqual(s.lanes.first?.tier, .detail)
        XCTAssertEqual(s.overflowCount, 0)
    }

    func testReasonStringsPopulated() {
        let s = selection([candidate("a", severity: .down, visibility: .auto)])
        let reason = s.lanes.first?.reason
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.summary.isEmpty)
        XCTAssertEqual(reason?.severity, .down)
        XCTAssertEqual(reason?.tier, .surfaced)
    }

    // MARK: Debounce and transition boost

    func testAutoDebounceSurfacesAndUnsurfacesAfterConsecutiveSamples() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        var engine = AttentionEngine()
        let high = [candidate("a", value: .number(150), displayThreshold: threshold)]
        let low = [candidate("a", value: .number(50), displayThreshold: threshold)]

        XCTAssertEqual(selection(high, engine: &engine, now: now).lanes.first?.tier, .detail)
        XCTAssertEqual(selection(high, engine: &engine, now: now.addingTimeInterval(1)).lanes.first?.tier, .detail)

        let surfaced = selection(high, engine: &engine, now: now.addingTimeInterval(2))
        XCTAssertEqual(laneIDs(surfaced), ["inst.a"])
        XCTAssertEqual(surfaced.lanes.first?.tier, .surfaced)

        XCTAssertEqual(selection(low, engine: &engine, now: now.addingTimeInterval(3)).lanes.first?.tier, .surfaced)
        XCTAssertEqual(selection(low, engine: &engine, now: now.addingTimeInterval(4)).lanes.first?.tier, .surfaced)

        let unsurfaced = selection(low, engine: &engine, now: now.addingTimeInterval(5))
        XCTAssertEqual(unsurfaced.lanes.first?.tier, .detail)
    }

    func testDefaultConsecutiveOneSurfacesImmediately() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100)
        let s = selection([candidate("a", value: .number(150), displayThreshold: threshold)])
        XCTAssertEqual(laneIDs(s), ["inst.a"])
        XCTAssertEqual(s.lanes.first?.tier, .surfaced)
    }

    func testAlwaysAndAlertedIgnoreDebounce() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        var engine = AttentionEngine()

        let always = selection(
            [candidate("always", value: .number(50), visibility: .always, displayThreshold: threshold)],
            engine: &engine,
            now: now
        )
        XCTAssertEqual(laneIDs(always), ["inst.always"])
        XCTAssertEqual(always.lanes.first?.tier, .surfaced)

        let alerted = selection(
            [candidate("alert", value: .number(50), displayThreshold: threshold)],
            engine: &engine,
            alerting: [id("alert")],
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(laneIDs(alerted), ["inst.alert"])
        XCTAssertEqual(alerted.lanes.first?.tier, .alerted)
    }

    func testTransitionBoostOutranksChronicWithinSeverityTierThenExpires() {
        var engine = AttentionEngine()
        _ = selection([
            candidate("chronic", severity: .degraded, visibility: .auto),
            candidate("riser", severity: .elevated, visibility: .auto)
        ], engine: &engine, lanes: 2, now: now)

        let boosted = selection([
            candidate("chronic", severity: .degraded, visibility: .auto),
            candidate("riser", severity: .degraded, visibility: .auto)
        ], engine: &engine, lanes: 2, now: now.addingTimeInterval(1))
        XCTAssertEqual(laneIDs(boosted), ["inst.riser", "inst.chronic"])
        XCTAssertEqual(boosted.lanes.first?.reason.transitionBoosted, true)

        let expired = selection([
            candidate("chronic", severity: .degraded, visibility: .auto),
            candidate("riser", severity: .degraded, visibility: .auto)
        ], engine: &engine, lanes: 2, now: now.addingTimeInterval(21))
        XCTAssertEqual(laneIDs(expired), ["inst.chronic", "inst.riser"])
        XCTAssertEqual(expired.lanes.first?.reason.transitionBoosted, false)
    }

    func testTransitionBoostCannotCrossSeverityTier() {
        var engine = AttentionEngine()
        _ = selection([
            candidate("chronic", severity: .degraded, visibility: .auto),
            candidate("riser", severity: .normal, visibility: .auto)
        ], engine: &engine, lanes: 2, now: now)

        let s = selection([
            candidate("chronic", severity: .degraded, visibility: .auto),
            candidate("riser", severity: .elevated, visibility: .auto)
        ], engine: &engine, lanes: 2, now: now.addingTimeInterval(1))
        XCTAssertEqual(laneIDs(s), ["inst.chronic", "inst.riser"])
        XCTAssertEqual(s.lanes.last?.reason.transitionBoosted, true)
    }

    func testPrunedStateMeansReturningEntityStartsFresh() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        var engine = AttentionEngine()
        let highA = [candidate("a", value: .number(150), displayThreshold: threshold)]

        XCTAssertEqual(selection(highA, engine: &engine, now: now).lanes.first?.tier, .detail)
        XCTAssertEqual(selection([candidate("b", severity: .normal, isPrimary: true)], engine: &engine, now: now.addingTimeInterval(1)).lanes.first?.id, id("b"))

        let returned = selection(highA, engine: &engine, now: now.addingTimeInterval(2))
        XCTAssertEqual(returned.lanes.first?.tier, .detail)
    }

    func testReasonStringsIncludeSustainedCountAndTransitionBoostFlag() {
        let threshold = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 4)
        var engine = AttentionEngine()
        let high = [candidate("a", value: .number(150), displayThreshold: threshold)]

        _ = selection([candidate("a", value: .number(50), displayThreshold: threshold)], engine: &engine, now: now)
        _ = selection(high, engine: &engine, now: now.addingTimeInterval(1))
        _ = selection(high, engine: &engine, now: now.addingTimeInterval(2))
        _ = selection(high, engine: &engine, now: now.addingTimeInterval(3))
        let s = selection(high, engine: &engine, now: now.addingTimeInterval(4))

        let reason = s.lanes.first?.reason
        XCTAssertTrue(reason?.summary.contains("sustained 4/4") ?? false)
        XCTAssertTrue(reason?.summary.contains("transitionBoosted true") ?? false)
        XCTAssertEqual(reason?.transitionBoosted, true)
    }
}
