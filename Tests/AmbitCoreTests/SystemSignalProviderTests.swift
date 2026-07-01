import XCTest
@testable import AmbitCore

final class SystemSignalProviderTests: XCTestCase {
    func testDarwinSignalReadersRequestLocationAndCalendarAuthorization() throws {
        let calendarSource = try readRepoFile("Sources/AmbitCore/System/SystemCalendarProvider.swift")
        let locationSource = try readRepoFile("Sources/AmbitCore/System/SystemLocationProvider.swift")

        XCTAssertTrue(calendarSource.contains("requestFullAccessToEvents") || calendarSource.contains("requestAccess(to: .event"))
        XCTAssertTrue(locationSource.contains("requestWhenInUseAuthorization"))
        XCTAssertTrue(locationSource.contains("requestLocation"))
    }

    func testCalendarProviderEmitsBusyTitleAndNextEventFromFakeSource() async {
        let provider = SystemCalendarProvider(reader: FakeCalendarReader(snapshot: SystemCalendarSnapshot(
            permission: .authorized,
            isBusy: true,
            currentEventTitle: "Planning",
            nextEventStartsIn: 900
        )))

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.metricValue("busy"), .bool(true))
        XCTAssertEqual(snapshot.metricValue("current_event_title"), .text("Planning"))
        XCTAssertEqual(snapshot.metricValue("next_event_starts_in"), .level(900))
        XCTAssertEqual(states[ProviderInstanceIDs.systemCalendar.appending("busy")]?.value, .bool(true))
        XCTAssertEqual(states[ProviderInstanceIDs.systemCalendar.appending("current_event_title")]?.value, .text("Planning"))
    }

    func testCalendarPermissionDeniedIsUnavailableWithoutFailure() async {
        let provider = SystemCalendarProvider(reader: FakeCalendarReader(snapshot: SystemCalendarSnapshot(permission: .denied)))

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertNil(snapshot.error)
        XCTAssertNil(snapshot.metricValue("busy"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemCalendar.appending("busy")]?.availability, .unavailable)
        XCTAssertNil(states[ProviderInstanceIDs.systemCalendar.appending("busy")]?.error)
    }

    func testPlacesStorePersistsCreateUpdateDeleteAndLoadsEmptyOnCorruptData() {
        let suite = "SystemSignalProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPlaceStore(defaults: defaults)
        let home = PlaceDeclaration(id: "home", name: "Home", latitude: 37, longitude: -122, radiusMeters: 100)
        let work = PlaceDeclaration(id: "work", name: "Work", latitude: 38, longitude: -123, radiusMeters: 150)

        store.create(home)
        store.create(work)
        var updated = work
        updated.name = "Office"
        store.update(updated)
        store.delete(id: home.id)

        XCTAssertEqual(UserDefaultsPlaceStore(defaults: defaults).load(), [updated])

        defaults.set(Data("not-json".utf8), forKey: UserDefaultsPlaceStore.defaultKey)
        XCTAssertEqual(UserDefaultsPlaceStore(defaults: defaults).load(), [])
    }

    func testLocationProviderEmitsCurrentPlaceAndMembershipEntities() async {
        let places = [
            PlaceDeclaration(id: "home", name: "Home", latitude: 37.332, longitude: -122.031, radiusMeters: 500),
            PlaceDeclaration(id: "work", name: "Work", latitude: 40.0, longitude: -73.0, radiusMeters: 100)
        ]
        let provider = SystemLocationProvider(
            reader: FakeLocationReader(snapshot: SystemLocationSnapshot(
                permission: .authorized,
                coordinate: LocationCoordinate(latitude: 37.333, longitude: -122.030)
            )),
            placeStore: InMemoryPlaceStore(places: places)
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.metricValue("current_place"), .text("Home"))
        XCTAssertEqual(snapshot.metricValue("place.home.active"), .bool(true))
        XCTAssertEqual(snapshot.metricValue("place.work.active"), .bool(false))
        XCTAssertEqual(states[ProviderInstanceIDs.systemLocation.appending("place.home.active")]?.value, .bool(true))
    }

    func testLocationPermissionNotDeterminedIsUnavailableWithoutFailure() async {
        let provider = SystemLocationProvider(
            reader: FakeLocationReader(snapshot: SystemLocationSnapshot(permission: .notDetermined)),
            placeStore: InMemoryPlaceStore(places: [
                PlaceDeclaration(id: "home", name: "Home", latitude: 37, longitude: -122, radiusMeters: 100)
            ])
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertNil(snapshot.error)
        XCTAssertNil(snapshot.metricValue("current_place"))
        XCTAssertEqual(states[ProviderInstanceIDs.systemLocation.appending("current_place")]?.availability, .unavailable)
        XCTAssertNil(states[ProviderInstanceIDs.systemLocation.appending("current_place")]?.error)
    }

    func testFocusProviderDefaultsUnavailableButFakeSourceCanEmitEntities() async {
        let unavailable = SystemFocusProvider(reader: NoOpSystemFocusReader())
        let unavailableSnapshot = await unavailable.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let unavailableStates = EntityProjection.states(snapshot: unavailableSnapshot, descriptors: unavailable.entityDescriptors())

        XCTAssertEqual(unavailableSnapshot.health, .ok)
        XCTAssertNil(unavailableSnapshot.metricValue("active"))
        XCTAssertEqual(unavailableStates[ProviderInstanceIDs.systemFocus.appending("active")]?.availability, .unavailable)

        let provider = SystemFocusProvider(reader: FakeFocusReader(snapshot: SystemFocusSnapshot(
            availability: .available,
            isActive: true,
            mode: "Work"
        )))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metricValue("active"), .bool(true))
        XCTAssertEqual(snapshot.metricValue("mode"), .text("Work"))
    }

    func testNewSignalsWorkAsContextAndUserRuleOperandsWithoutEngineChanges() async throws {
        let ssidID = ProviderInstanceIDs.systemNetwork.appending("ssid")
        let busyID = ProviderInstanceIDs.systemCalendar.appending("busy")
        let homeID = ProviderInstanceIDs.systemLocation.appending("place.home.active")
        let focusID = ProviderInstanceIDs.systemFocus.appending("active")
        let input = ConditionEvaluator.Input(states: [
            ssidID: EntityState(id: ssidID, value: .text("Office WiFi"), availability: .online),
            busyID: EntityState(id: busyID, value: .bool(true), availability: .online),
            homeID: EntityState(id: homeID, value: .bool(true), availability: .online),
            focusID: EntityState(id: focusID, value: .bool(true), availability: .online)
        ])

        var contextMachine = ContextStateMachine(dwell: 0)
        let context = ContextDeclaration(
            id: "ctx.office",
            displayName: "Office",
            condition: .all([
                .comparison(Comparison(lhs: .address(ssidID), comparison: .equal, rhs: .literal(.string("Office WiFi")))),
                .comparison(Comparison(lhs: .address(busyID), comparison: .equal, rhs: .literal(.bool(true)))),
                .comparison(Comparison(lhs: .address(homeID), comparison: .equal, rhs: .literal(.bool(true)))),
                .comparison(Comparison(lhs: .address(focusID), comparison: .equal, rhs: .literal(.bool(true))))
            ]),
            priority: 0
        )

        let evaluated = contextMachine.evaluate(contexts: [context], input: input, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(evaluated.activeIDs, [context.id])

        let rule = UserRule(
            id: "rule.office",
            displayName: "Office rule",
            condition: .comparison(Comparison(lhs: .address(ssidID), comparison: .equal, rhs: .literal(.string("Office WiFi")))),
            reactions: [.mutateSurface(SurfaceMutation(
                target: SurfacePropertyAddress(surfaceID: "surface", itemID: "item", property: .badge),
                set: .string("Office")
            ))],
            enabled: true
        )
        var runner = UserRuleRunner()
        let results = try await runner.evaluate(
            rules: [rule],
            input: input,
            now: Date(timeIntervalSince1970: 0),
            executor: ReactionExecutor()
        )

        XCTAssertEqual(results.count, 1)
    }

    func testNewSignalDescriptorsAppearInGenericSignalPicker() {
        let descriptors =
            SystemNetworkProvider(
                reader: FakeSystemMetricsReader(snapshot: Self.metricsSnapshot()),
                networkInfoReader: FakeSystemNetworkInfoReader(snapshot: SystemNetworkInfoSnapshot(permission: .unavailable))
            ).entityDescriptors()
            + SystemCalendarProvider(reader: FakeCalendarReader(snapshot: SystemCalendarSnapshot(permission: .unavailable))).entityDescriptors()
            + SystemLocationProvider(
                reader: FakeLocationReader(snapshot: SystemLocationSnapshot(permission: .unavailable)),
                placeStore: InMemoryPlaceStore(places: [
                    PlaceDeclaration(id: "home", name: "Home", latitude: 37, longitude: -122, radiusMeters: 100)
                ])
            ).entityDescriptors()
            + SystemFocusProvider(reader: NoOpSystemFocusReader()).entityDescriptors()

        let labels = SignalPickerModel.items(from: descriptors).map(\.title)

        XCTAssertTrue(labels.contains("Wi-Fi SSID"))
        XCTAssertTrue(labels.contains("Calendar Busy"))
        XCTAssertTrue(labels.contains("Home Active"))
        XCTAssertTrue(labels.contains("Focus Active"))
    }

    func testSystemIntegrationWiresSignalProviders() {
        let integration = SystemIntegration(
            reader: FakeSystemMetricsReader(snapshot: Self.metricsSnapshot()),
            processRunner: FakeSignalProcessRunner(),
            sensorReader: NoOpSystemSensorReader(),
            networkInfoReader: FakeSystemNetworkInfoReader(snapshot: SystemNetworkInfoSnapshot(permission: .unavailable)),
            calendarReader: FakeCalendarReader(snapshot: SystemCalendarSnapshot(permission: .unavailable)),
            locationReader: FakeLocationReader(snapshot: SystemLocationSnapshot(permission: .unavailable)),
            placeStore: InMemoryPlaceStore(places: []),
            focusReader: NoOpSystemFocusReader()
        )

        let providers = integration.makeProviders(instance: IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.systemLocal,
            integrationID: IntegrationIDs.system,
            displayName: "System",
            enabled: true,
            origin: .builtIn
        ))

        XCTAssertTrue(providers.map(\.id).contains(ProviderIDs.systemCalendar))
        XCTAssertTrue(providers.map(\.id).contains(ProviderIDs.systemLocation))
        XCTAssertTrue(providers.map(\.id).contains(ProviderIDs.systemFocus))
    }

    private static func metricsSnapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 0, systemPercent: 0, idlePercent: 100, coreCount: 1),
            memory: MemoryMetrics(usedBytes: 0, wiredBytes: 0, compressedBytes: 0, totalBytes: 1)
        )
    }

    private func readRepoFile(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private struct FakeCalendarReader: SystemCalendarReading {
    var snapshot: SystemCalendarSnapshot
    func snapshot() async -> SystemCalendarSnapshot { snapshot }
}

private struct FakeLocationReader: SystemLocationReading {
    var snapshot: SystemLocationSnapshot
    func snapshot() async -> SystemLocationSnapshot { snapshot }
}

private struct FakeFocusReader: SystemFocusReading {
    var snapshot: SystemFocusSnapshot
    func snapshot() async -> SystemFocusSnapshot { snapshot }
}

private struct InMemoryPlaceStore: PlaceStore {
    var places: [PlaceDeclaration]
    func load() -> [PlaceDeclaration] { places }
    func create(_ place: PlaceDeclaration) {}
    func update(_ place: PlaceDeclaration) {}
    func delete(id: PlaceID) {}
}

private struct FakeSystemMetricsReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot
    func snapshot() async throws -> SystemMetricsSnapshot { snapshot }
}

private struct FakeSignalProcessRunner: ProcessRunner {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
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
