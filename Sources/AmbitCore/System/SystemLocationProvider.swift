import Foundation

#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif

public struct PlaceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PlaceDeclaration: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: PlaceID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var schemaVersion: Int

    public init(
        id: PlaceID,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.schemaVersion = schemaVersion
    }
}

public struct LocationCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct SystemLocationSnapshot: Equatable, Sendable {
    public var permission: SystemSignalPermission
    public var coordinate: LocationCoordinate?

    public init(permission: SystemSignalPermission, coordinate: LocationCoordinate? = nil) {
        self.permission = permission
        self.coordinate = coordinate
    }
}

public protocol SystemLocationReading: Sendable {
    func snapshot() async -> SystemLocationSnapshot
}

public final class DarwinSystemLocationReader: SystemLocationReading, @unchecked Sendable {
    #if canImport(CoreLocation)
    @MainActor private var source: DarwinLocationSource?
    #endif

    public init() {}

    public func snapshot() async -> SystemLocationSnapshot {
        #if canImport(CoreLocation)
        return await locationSource().snapshot()
        #else
        return SystemLocationSnapshot(permission: .unavailable)
        #endif
    }

    #if canImport(CoreLocation)
    @MainActor
    private func locationSource() -> DarwinLocationSource {
        if let source { return source }
        let source = DarwinLocationSource()
        self.source = source
        return source
    }
    #endif
}

#if canImport(CoreLocation)
@MainActor
private final class DarwinLocationSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func snapshot() async -> SystemLocationSnapshot {
        let status = await authorizationStatus()
        switch SystemSignalPermission.from(status) {
        case .authorized:
            let location = await requestCurrentLocation()
            return SystemLocationSnapshot(
                permission: .authorized,
                coordinate: location.map {
                    LocationCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }
            )
        case .notDetermined, .denied, .restricted, .unavailable:
            return SystemLocationSnapshot(permission: SystemSignalPermission.from(status))
        }
    }

    private func authorizationStatus() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                resumeAuthorizationIfNeeded(manager.authorizationStatus)
            }
        }
    }

    private func requestCurrentLocation() async -> CLLocation? {
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                resumeLocationIfNeeded(nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            resumeAuthorizationIfNeeded(manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            resumeLocationIfNeeded(locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            resumeLocationIfNeeded(nil)
        }
    }

    private func resumeAuthorizationIfNeeded(_ status: CLAuthorizationStatus) {
        guard let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        continuation.resume(returning: status)
    }

    private func resumeLocationIfNeeded(_ location: CLLocation?) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: location)
    }
}
#endif

public protocol PlaceStore: Sendable {
    func load() -> [PlaceDeclaration]
    func create(_ place: PlaceDeclaration)
    func update(_ place: PlaceDeclaration)
    func delete(id: PlaceID)
}

public struct PlaceDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var places: [PlaceDeclaration]

    public init(schemaVersion: Int = PlaceDeclaration.currentSchemaVersion, places: [PlaceDeclaration]) {
        self.schemaVersion = schemaVersion
        self.places = places
    }
}

public struct UserDefaultsPlaceStore: PlaceStore, @unchecked Sendable {
    public static let defaultKey = "AmbitPlaces"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [PlaceDeclaration] {
        guard let data = defaults.data(forKey: key),
              let document = try? JSONDecoder().decode(PlaceDocument.self, from: data)
        else { return [] }
        return document.places
    }

    public func create(_ place: PlaceDeclaration) {
        var places = load().filter { $0.id != place.id }
        places.append(place)
        save(places)
    }

    public func update(_ place: PlaceDeclaration) {
        var places = load()
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            places.append(place)
        }
        save(places)
    }

    public func delete(id: PlaceID) {
        save(load().filter { $0.id != id })
    }

    private func save(_ places: [PlaceDeclaration]) {
        let document = PlaceDocument(places: places)
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct SystemLocationProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemLocation
    public let displayName = "Location"
    public let typeID: ProviderTypeID = "location"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemLocation
    public let pollInterval: TimeInterval

    private let reader: any SystemLocationReading
    private let placeStore: any PlaceStore

    public init(
        reader: any SystemLocationReading = DarwinSystemLocationReader(),
        placeStore: any PlaceStore = UserDefaultsPlaceStore(),
        pollInterval: TimeInterval = 30
    ) {
        self.reader = reader
        self.placeStore = placeStore
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        var descriptors = [
            EntityDescriptor(
                id: instanceID.entity("current_place"),
                instanceID: instanceID,
                name: "Current Place",
                kind: .text,
                category: .primary,
                capability: "system.location",
                access: .read,
                metricID: "current_place",
                defaultVisibility: .auto
            )
        ]
        descriptors.append(contentsOf: placeStore.load().map { place in
            EntityDescriptor(
                id: instanceID.entity("place.\(place.id.rawValue).active"),
                instanceID: instanceID,
                name: "\(place.name) Active",
                kind: .binarySensor,
                category: .primary,
                capability: "system.location",
                access: .read,
                metricID: "place.\(place.id.rawValue).active",
                defaultVisibility: .auto
            )
        })
        return descriptors
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let snapshot = await reader.snapshot()
        let places = placeStore.load()
        guard snapshot.permission.canRead, let coordinate = snapshot.coordinate else {
            return ProviderSnapshot(health: .ok)
        }
        let matches = places.map { place in
            (place, Self.distanceMeters(from: coordinate, to: place) <= place.radiusMeters)
        }
        let current = matches.first(where: { $0.1 })?.0.name
        var metrics: [Metric] = []
        if let current {
            metrics.append(Metric(id: "current_place", label: "Current Place", value: .text(current), capability: "system.location"))
        }
        metrics.append(contentsOf: matches.map { place, active in
            Metric(id: "place.\(place.id.rawValue).active", label: "\(place.name) Active", value: .bool(active), capability: "system.location")
        })
        return ProviderSnapshot(health: .ok, metrics: metrics)
    }

    private static func distanceMeters(from coordinate: LocationCoordinate, to place: PlaceDeclaration) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = coordinate.latitude * .pi / 180
        let lat2 = place.latitude * .pi / 180
        let deltaLat = (place.latitude - coordinate.latitude) * .pi / 180
        let deltaLon = (place.longitude - coordinate.longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
