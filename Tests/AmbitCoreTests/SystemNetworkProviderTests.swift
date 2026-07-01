import XCTest
@testable import AmbitCore

final class SystemNetworkProviderTests: XCTestCase {
    func testSinglePollLeavesThroughputEntitiesUnavailableWithoutPriorSample() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [Self.snapshot(counters: [
                NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 2_000, isLoopback: false)
            ])]),
            clock: SequenceClock([Date(timeIntervalSince1970: 10)]).now
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertNil(snapshot.metricValue("throughput_in"))
        XCTAssertNil(snapshot.metricValue("throughput_out"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("throughput_in")]?.availability, .unavailable)
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("throughput_out")]?.availability, .unavailable)
        XCTAssertNil(states[ProviderInstanceIDs.systemNetwork.appending("throughput_in")]?.error)
        XCTAssertNil(states[ProviderInstanceIDs.systemNetwork.appending("throughput_out")]?.error)
    }

    func testTwoPollsComputeAggregateThroughputBpsFromNonLoopbackDeltas() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 2_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 10_000, bytesOut: 10_000, isLoopback: true)
                ]),
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 3_000, bytesOut: 3_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 20_000, bytesOut: 20_000, isLoopback: true)
                ])
            ]),
            clock: SequenceClock([
                Date(timeIntervalSince1970: 10),
                Date(timeIntervalSince1970: 12)
            ]).now
        )

        _ = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metricValue("throughput_in"), .throughput(bitsPerSecond: 8_000))
        XCTAssertEqual(snapshot.metricValue("throughput_out"), .throughput(bitsPerSecond: 4_000))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("throughput_in")]?.availability, .online)
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("throughput_out")]?.availability, .online)
    }

    func testCounterDecreaseSkipsThatInterfaceAndAggregatesRemainingInterfaces() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 5_000, bytesOut: 5_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "en1", bytesIn: 1_000, bytesOut: 1_000, isLoopback: false)
                ]),
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "en1", bytesIn: 2_000, bytesOut: 3_000, isLoopback: false)
                ])
            ]),
            clock: SequenceClock([
                Date(timeIntervalSince1970: 10),
                Date(timeIntervalSince1970: 11)
            ]).now
        )

        _ = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metricValue("throughput_in"), .throughput(bitsPerSecond: 8_000))
        XCTAssertEqual(snapshot.metricValue("throughput_out"), .throughput(bitsPerSecond: 16_000))
    }

    func testInterfaceTableIncludesLoopbackButAggregateExcludesIt() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: true)
                ]),
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 2_000, bytesOut: 3_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 101_000, bytesOut: 101_000, isLoopback: true)
                ])
            ]),
            clock: SequenceClock([
                Date(timeIntervalSince1970: 10),
                Date(timeIntervalSince1970: 11)
            ]).now
        )

        _ = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metricValue("throughput_in"), .throughput(bitsPerSecond: 8_000))
        XCTAssertEqual(snapshot.metricValue("throughput_out"), .throughput(bitsPerSecond: 16_000))
        guard case .table(let table) = snapshot.metricValue("interfaces") else {
            return XCTFail("Expected interfaces table")
        }
        XCTAssertEqual(table.columns.map(\.id), ["interface", "in_bps", "out_bps", "loopback"])
        XCTAssertEqual(table.rows.map(\.id), ["en0", "lo0"])
        XCTAssertEqual(table.rows[1].cells["loopback"], .badge("Yes", .elevated))
        XCTAssertEqual(table.rows[1].cells["in_bps"], .number(800_000, unit: "bps"))
    }

    func testInterfaceTableHidesZeroTrafficVirtualInterfacesButKeepsPhysicalActiveAndLoopback() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "utun4", bytesIn: 5_000, bytesOut: 5_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "utun5", bytesIn: 10_000, bytesOut: 10_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: true)
                ]),
                Self.snapshot(counters: [
                    NetworkCounterMetrics(interfaceName: "en0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "utun4", bytesIn: 5_000, bytesOut: 5_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "utun5", bytesIn: 11_000, bytesOut: 12_000, isLoopback: false),
                    NetworkCounterMetrics(interfaceName: "lo0", bytesIn: 1_000, bytesOut: 1_000, isLoopback: true)
                ])
            ]),
            clock: SequenceClock([
                Date(timeIntervalSince1970: 10),
                Date(timeIntervalSince1970: 11)
            ]).now
        )

        _ = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        guard case .table(let table) = snapshot.metricValue("interfaces") else {
            return XCTFail("Expected interfaces table")
        }
        XCTAssertEqual(table.rows.map(\.id), ["en0", "utun5", "lo0"])
    }

    func testWiFiSSIDAndBSSIDMetricsComeFromInjectedNetworkInfoSource() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [Self.snapshot(counters: [])]),
            networkInfoReader: FakeSystemNetworkInfoReader(snapshot: SystemNetworkInfoSnapshot(
                permission: .authorized,
                ssid: "Office WiFi",
                bssid: "aa:bb:cc:dd:ee:ff"
            ))
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.metricValue("ssid"), .text("Office WiFi"))
        XCTAssertEqual(snapshot.metricValue("bssid"), .text("aa:bb:cc:dd:ee:ff"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("ssid")]?.value, .text("Office WiFi"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("bssid")]?.value, .text("aa:bb:cc:dd:ee:ff"))
    }

    func testWiFiPermissionDeniedLeavesSSIDDescriptorsUnavailableWithoutFailure() async {
        let provider = SystemNetworkProvider(
            reader: SequenceNetworkReader(snapshots: [Self.snapshot(counters: [])]),
            networkInfoReader: FakeSystemNetworkInfoReader(snapshot: SystemNetworkInfoSnapshot(permission: .denied))
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertNil(snapshot.error)
        XCTAssertNil(snapshot.metricValue("ssid"))
        XCTAssertNil(snapshot.metricValue("bssid"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("ssid")]?.availability, .unavailable)
        XCTAssertEqual(states[ProviderInstanceIDs.systemNetwork.appending("bssid")]?.availability, .unavailable)
        XCTAssertNil(states[ProviderInstanceIDs.systemNetwork.appending("ssid")]?.error)
        XCTAssertNil(states[ProviderInstanceIDs.systemNetwork.appending("bssid")]?.error)
    }

    func testDarwinNetworkInfoReaderDoesNotReadWiFiIdentifiersBeforeLocationAuthorization() async {
        let reader = DarwinSystemNetworkInfoReader(
            locationPermission: { .notDetermined },
            wifiIdentifiers: {
                XCTFail("CoreWLAN should not be queried before Location is authorized")
                return (ssid: "Office WiFi", bssid: "aa:bb:cc:dd:ee:ff")
            }
        )

        let snapshot = await reader.snapshot()

        XCTAssertEqual(snapshot.permission, .notDetermined)
        XCTAssertNil(snapshot.ssid)
        XCTAssertNil(snapshot.bssid)
    }

    func testDarwinNetworkInfoReaderReadsWiFiIdentifiersAfterLocationAuthorization() async {
        let reader = DarwinSystemNetworkInfoReader(
            locationPermission: { .authorized },
            wifiIdentifiers: { (ssid: "Office WiFi", bssid: "aa:bb:cc:dd:ee:ff") }
        )

        let snapshot = await reader.snapshot()

        XCTAssertEqual(snapshot.permission, .authorized)
        XCTAssertEqual(snapshot.ssid, "Office WiFi")
        XCTAssertEqual(snapshot.bssid, "aa:bb:cc:dd:ee:ff")
    }

    func testSystemNetworkDescriptorsRouteToNetworkSection() {
        let provider = SystemNetworkProvider(reader: SequenceNetworkReader(snapshots: []))

        let plan = SurfaceComposer.detailPlan(descriptors: provider.entityDescriptors(), states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["Network"])
        XCTAssertEqual(plan.cards.flatMap(\.children).map(\.kind), [.historyGraph, .statTable, .statusRow, .statusRow])
    }

    func testPingNetworkRoutingUnchanged() {
        let descriptors = [
            EntityDescriptor(id: "ping/probe.latency", instanceID: "ping/probe", name: "Latency", kind: .sensor, deviceClass: .latency, capability: "network.latency", metricID: "latency")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["Network"])
    }

    fileprivate static func snapshot(counters: [NetworkCounterMetrics]) -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 0, systemPercent: 0, idlePercent: 100, coreCount: 1),
            memory: MemoryMetrics(usedBytes: 0, wiredBytes: 0, compressedBytes: 0, totalBytes: 1),
            networkCounters: counters
        )
    }
}

private actor SequenceNetworkReader: SystemMetricsReading {
    private var snapshots: [SystemMetricsSnapshot]

    init(snapshots: [SystemMetricsSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot() async throws -> SystemMetricsSnapshot {
        guard !snapshots.isEmpty else { return SystemNetworkProviderTests.snapshot(counters: []) }
        return snapshots.removeFirst()
    }
}

private final class SequenceClock: @unchecked Sendable {
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func now() -> Date {
        guard !dates.isEmpty else { return Date(timeIntervalSince1970: 0) }
        return dates.removeFirst()
    }
}

private struct FakeSystemNetworkInfoReader: SystemNetworkInfoReading {
    var snapshot: SystemNetworkInfoSnapshot
    func snapshot() async -> SystemNetworkInfoSnapshot { snapshot }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}

private extension ProviderInstanceID {
    func appending(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
