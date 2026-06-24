import XCTest
@testable import AmbitCore

final class SlotTests: XCTestCase {
    private func roundTrip(_ slot: Slot) throws -> Slot {
        let data = try JSONEncoder().encode(slot)
        return try JSONDecoder().decode(Slot.self, from: data)
    }

    func testSlotSelectionRoundTripsEveryCase() throws {
        let selections: [SlotSelection] = [
            .integration("ping@1.1.1.1"),
            .integrations(["ping@1.1.1.1", "ping@8.8.8.8"]),
            .integrationType("ping"),
            .capability("uplink"),
            .entities(["ping@1.1.1.1/probe.latency_ms"])
        ]
        for (i, selection) in selections.enumerated() {
            let slot = Slot(id: SlotID(rawValue: "s\(i)"), title: "T\(i)", selection: selection, barReadout: .dynamic)
            XCTAssertEqual(try roundTrip(slot), slot, "selection \(selection)")
        }
    }

    func testBarReadoutModeRoundTrips() throws {
        let dynamic = Slot(id: "d", selection: .integrationType("ping"), barReadout: .dynamic)
        let fixed = Slot(id: "f", selection: .integrationType("ping"), barReadout: .fixed("ping@1.1.1.1/probe.latency_ms"))
        XCTAssertEqual(try roundTrip(dynamic), dynamic)
        XCTAssertEqual(try roundTrip(fixed), fixed)
    }

    func testPresentationConfigWithSlotsRoundTrips() throws {
        var config = PresentationConfig.empty
        config.slots = [Slot(id: "ping", title: "Ping", selection: .integrationType("ping"), barReadout: .dynamic)]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(PresentationConfig.self, from: data), config)
    }

    func testConfigDecodeIsForwardCompatibleWhenKeysMissing() throws {
        // A payload from before slots existed (any subset of keys) must still decode — every
        // field is optional-with-default. An empty object exercises all defaults at once.
        let legacy = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: legacy)
        XCTAssertEqual(decoded, .empty)
        XCTAssertEqual(decoded.slots, [])
    }

    func testStoreSavesAndLoads() {
        let suite = "p3-slot-store-test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPresentationConfigStore(defaults: defaults)

        XCTAssertEqual(store.load(), .empty, "no data → empty")

        var config = PresentationConfig.empty
        config.slots = [Slot(id: "ping", title: "Ping", selection: .integrationType("ping"))]
        store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    func testStoreLoadsEmptyOnCorruptData() {
        let suite = "p3-slot-store-corrupt"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "presentationConfig")
        XCTAssertEqual(UserDefaultsPresentationConfigStore(defaults: defaults).load(), .empty)
    }
}
