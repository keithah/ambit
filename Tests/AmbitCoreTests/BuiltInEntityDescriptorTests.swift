import XCTest
@testable import AmbitCore

final class BuiltInEntityDescriptorTests: XCTestCase {
    private func byKey(_ descriptors: [EntityDescriptor]) -> [String: EntityDescriptor] {
        Dictionary(uniqueKeysWithValues: descriptors.map { (String($0.id.rawValue.split(separator: ".").last ?? ""), $0) })
    }

    func testEcoFlowExposesThreeOutputTogglesAndBatterySensor() {
        let descriptors = EcoFlowProvider().entityDescriptors()
        let byKey = byKey(descriptors)

        // Battery sensor.
        XCTAssertEqual(byKey["battery_percent"]?.kind, .sensor)
        XCTAssertEqual(byKey["battery_percent"]?.deviceClass, .battery)
        XCTAssertEqual(byKey["battery_percent"]?.capability, ProviderCapability(rawValue: "battery"))

        // Three output toggles, one setOutput command each, fanned out by fixed `target`.
        for (key, target) in [("ac_output", "ac"), ("dc_output", "dc"), ("usb_output", "usb")] {
            let toggle = byKey[key]
            XCTAssertEqual(toggle?.kind, .toggle)
            XCTAssertEqual(toggle?.capability, ProviderCapability(rawValue: "powerOutput"))
            XCTAssertEqual(toggle?.command?.commandID, ProviderCommandIDs.ecoFlowSetOutput)
            XCTAssertEqual(toggle?.command?.argumentKey, "state")
            XCTAssertEqual(toggle?.command?.fixedArguments["target"], .string(target))
            XCTAssertEqual(toggle?.metricID, key)
        }

        let toggleCount = descriptors.filter { $0.kind == .toggle }.count
        XCTAssertEqual(toggleCount, 3)
    }

    func testSpeedifyExposesBondingSelectAndThroughputSensors() {
        let byKey = byKey(SpeedifyProvider().entityDescriptors())

        let bonding = byKey["bonding_mode"]
        XCTAssertEqual(bonding?.kind, .select)
        XCTAssertEqual(bonding?.options?.map(\.value), ["SP", "RD", "STR"])
        XCTAssertEqual(bonding?.command?.commandID, ProviderCommandIDs.speedifySetBondingMode)
        XCTAssertEqual(bonding?.command?.argumentKey, "mode")

        XCTAssertEqual(byKey["connected"]?.kind, .toggle)
        XCTAssertEqual(byKey["download_bps"]?.deviceClass, .throughput)
        XCTAssertEqual(byKey["upload_bps"]?.deviceClass, .throughput)
        // Multi-param command renders as a button (opens detail), not an auto form.
        XCTAssertEqual(byKey["set_network_priority"]?.kind, .button)
    }

    func testStarlinkExposesObstructionPercentSensor() {
        let byKey = byKey(StarlinkProvider().entityDescriptors())

        XCTAssertEqual(byKey["obstruction_percent"]?.kind, .sensor)
        XCTAssertEqual(byKey["obstruction_percent"]?.deviceClass, .percent)
        XCTAssertEqual(byKey["obstruction_percent"]?.metricID, "obstruction_percent")
        XCTAssertEqual(byKey["online"]?.kind, .binarySensor)
        XCTAssertEqual(byKey["online"]?.deviceClass, .connectivity)
    }

    func testGLiNetRouterExposesConfigDescriptorsFromCredentials() {
        let byKey = byKey(GLiNetRouterProvider().entityDescriptors())

        XCTAssertEqual(byKey["host"]?.category, .config)
        XCTAssertEqual(byKey["password"]?.category, .config)
        XCTAssertEqual(byKey["password"]?.access, .write)
        XCTAssertEqual(byKey["wan_up"]?.deviceClass, .connectivity)
    }

    func testGLiNetVPNToggleTargetsTheVPNCommand() {
        let byKey = byKey(GLiNetVPNProvider().entityDescriptors())
        XCTAssertEqual(byKey["vpn_connected"]?.kind, .toggle)
        XCTAssertEqual(byKey["vpn_connected"]?.command?.commandID, ProviderCommandIDs.vpnToggle)
        XCTAssertEqual(byKey["vpn_connected"]?.metricID, "connected")
    }

    func testIperf3ProviderDeclaresDescriptors() {
        let iperf3 = byKey(Iperf3Provider().entityDescriptors())
        XCTAssertEqual(iperf3["run"]?.kind, .button)
        XCTAssertEqual(iperf3["download_bps"]?.deviceClass, .throughput)
    }

    func testOnlineStatesReflectSnapshotMetricsAndToggleState() {
        let provider = EcoFlowProvider()
        let descriptors = provider.entityDescriptors()
        let snapshot = ProviderSnapshot.ecoFlow(EcoFlowSnapshot(
            status: EcoFlowDeviceStatus(
                battery: EcoFlowBatteryStatus(percent: 82, state: .discharging),
                power: EcoFlowPowerStatus(inputWatts: 5, outputWatts: 12, netWatts: 7),
                outputs: EcoFlowOutputMap(
                    ac: EcoFlowOutputStatus(state: .on, watts: 12),
                    dc: EcoFlowOutputStatus(state: .off, watts: 0),
                    usb: EcoFlowOutputStatus(state: .off, watts: 0)
                ),
                updatedAt: "2026-06-22T00:00:00Z"
            ),
            stats: EcoFlowDeviceStats(
                batteryPercent: 82, inputWatts: 5, outputWatts: 12, netWatts: 7,
                estimatedMinutesRemaining: 240, estimatedMinutesToFull: nil,
                isEstimateDerived: false, updatedAt: "2026-06-22T00:00:00Z"
            )
        ))

        let states = EntityProjection.states(snapshot: snapshot, descriptors: descriptors)
        let instance = provider.instanceID

        XCTAssertEqual(states[instance.appending("battery_percent")]?.value, .number(82))
        XCTAssertEqual(states[instance.appending("ac_output")]?.value, .bool(true))
        XCTAssertEqual(states[instance.appending("dc_output")]?.value, .bool(false))
        XCTAssertTrue(states.values.allSatisfy { $0.availability == .online })
    }

    func testOverridesDispatchThroughExistentialProvider() {
        // Held as `any Provider`, entityDescriptors() must reach the built-in override
        // (the EcoFlow toggles), not the default commands+health projection.
        let provider: any Provider = EcoFlowProvider()
        let descriptors = provider.entityDescriptors()
        XCTAssertEqual(descriptors.filter { $0.kind == .toggle }.count, 3)
        XCTAssertTrue(descriptors.contains { $0.metricID == "battery_percent" })
    }

    func testOfflineDescriptorsPersistAndStatesAreUnavailable() {
        let provider = StarlinkProvider()
        let descriptors = provider.entityDescriptors()

        let states = EntityProjection.states(snapshot: nil, descriptors: descriptors)

        XCTAssertEqual(states.count, descriptors.count)
        XCTAssertFalse(descriptors.isEmpty)
        XCTAssertTrue(states.values.allSatisfy { $0.availability == .unavailable })
        XCTAssertTrue(states.values.allSatisfy { $0.value == nil })
    }
}

private extension ProviderInstanceID {
    func appending(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
