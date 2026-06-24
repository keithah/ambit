import XCTest
@testable import AmbitCore

final class EntityEnricherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let instanceID = ProviderInstanceID(rawValue: "ping@1.1.1.1/probe")

    // interval 2 → staleness window 10s. fresh = within, stale = past.
    private var fresh: Date { now.addingTimeInterval(-5) }
    private var old: Date { now.addingTimeInterval(-15) }

    private func descriptor(displayThreshold: DisplayThreshold? = nil) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "ping@1.1.1.1/probe.latency_ms"),
            instanceID: instanceID,
            name: "Latency",
            kind: .sensor,
            deviceClass: .latency,
            stateClass: .measurement,
            displayThreshold: displayThreshold
        )
    }

    private func state(value: EntityValue? = .number(20), availability: Availability = .online) -> EntityState {
        EntityState(id: descriptor().id, value: value, availability: availability, lastUpdated: fresh)
    }

    private func enrich(
        value: EntityValue? = .number(20),
        availability: Availability = .online,
        lastSampleAt: Date? = nil,
        displayThreshold: DisplayThreshold? = nil,
        health: HealthStatus? = nil,
        alertActive: Bool = false
    ) -> EntityState {
        EntityEnricher.enrich(
            EntityEnricher.Inputs(
                descriptor: descriptor(displayThreshold: displayThreshold),
                state: state(value: value, availability: availability),
                interval: 2,
                lastSampleAt: lastSampleAt ?? fresh,
                displayThreshold: displayThreshold,
                health: health,
                alertActive: alertActive
            ),
            now: now
        )
    }

    func testOnlineFreshNoThresholdIsNormal() {
        let result = enrich()
        XCTAssertEqual(result.availability, .online)
        XCTAssertEqual(result.severity, .normal)
    }

    func testOnlineButStaleDowngradesToStaleElevated() {
        let result = enrich(lastSampleAt: old)
        XCTAssertEqual(result.availability, .stale)
        XCTAssertEqual(result.severity, .elevated)
    }

    func testStaleSuppressesDeeperFaultEvenWhenHealthDown() {
        // Old data + health .down must NOT escalate past .elevated (can't diagnose from data we didn't collect).
        let result = enrich(lastSampleAt: old, health: .down)
        XCTAssertEqual(result.availability, .stale)
        XCTAssertEqual(result.severity, .elevated)
    }

    func testUnavailableIsDownRegardlessOfHealth() {
        let result = enrich(availability: .unavailable, health: .healthy)
        XCTAssertEqual(result.availability, .unavailable)
        XCTAssertEqual(result.severity, .down)
    }

    func testDisplayThresholdCrossedIsElevated() {
        let threshold = DisplayThreshold(comparison: .greaterThanOrEqual, value: 100)
        let crossed = enrich(value: .number(142), displayThreshold: threshold)
        XCTAssertEqual(crossed.severity, .elevated)
        let belowThreshold = enrich(value: .number(50), displayThreshold: threshold)
        XCTAssertEqual(belowThreshold.severity, .normal)
    }

    func testHealthDegradedIsDegraded() {
        XCTAssertEqual(enrich(health: .degraded).severity, .degraded)
    }

    func testHealthDownIsDown() {
        XCTAssertEqual(enrich(health: .down).severity, .down)
    }

    func testAlertActiveIsAlerting() {
        XCTAssertEqual(enrich(alertActive: true).severity, .alerting)
    }

    func testAlertActiveAndHealthDownTakesTheHigher() {
        // Severity ordering: normal < elevated < degraded < alerting < down. max(.alerting, .down) = .down.
        XCTAssertEqual(enrich(health: .down, alertActive: true).severity, .down)
    }

    func testValueLastUpdatedErrorPassThrough() {
        var raw = state()
        raw.error = "boom"
        raw.lastUpdated = fresh
        let result = EntityEnricher.enrich(
            EntityEnricher.Inputs(descriptor: descriptor(), state: raw, interval: 2, lastSampleAt: fresh),
            now: now
        )
        XCTAssertEqual(result.value, .number(20))
        XCTAssertEqual(result.lastUpdated, fresh)
        XCTAssertEqual(result.error, "boom")
    }
}
