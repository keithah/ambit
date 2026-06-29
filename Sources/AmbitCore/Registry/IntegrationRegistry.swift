import Foundation

/// One configured install of an integration. Generalizes `InstalledProviderRecord` from a
/// per-ProviderID manifest record to a per-IntegrationInstance record that also covers the
/// built-ins and dynamic (pingscope) instances.
public struct IntegrationInstanceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: IntegrationInstanceID      // "glinet", "ping@<uuid>"
    public var integrationID: IntegrationID   // "glinet", "ping"
    public var displayName: String
    public var enabled: Bool
    public var origin: Origin
    public var config: JSONObject             // integration-specific (e.g. pingscope host config)

    public enum Origin: String, Codable, Sendable {
        case builtIn   // a built-in integration's default install
        case manifest  // installed from a provider manifest package
        case user      // user-created (e.g. a pingscope host)
    }

    public init(
        id: IntegrationInstanceID,
        integrationID: IntegrationID,
        displayName: String,
        enabled: Bool = true,
        origin: Origin = .user,
        config: JSONObject = [:]
    ) {
        self.id = id
        self.integrationID = integrationID
        self.displayName = displayName
        self.enabled = enabled
        self.origin = origin
        self.config = config
    }
}

/// Persists the set of configured integration instances and which integration *types* are
/// disabled. Enable/disable works at BOTH granularities: an instance is effectively active
/// only when its own `enabled` flag is set AND its integration type is not disabled.
/// Disabled instances are never assembled into providers, so never polled.
public protocol IntegrationRegistry: Sendable {
    func instances() throws -> [IntegrationInstanceRecord]
    func save(_ records: [IntegrationInstanceRecord]) throws
    func disabledIntegrationIDs() throws -> Set<IntegrationID>
    func setDisabledIntegrationIDs(_ ids: Set<IntegrationID>) throws
    /// The instance the menu glyph / "primary" UI tracks (e.g. pingscope primary host).
    func primaryInstanceID() throws -> IntegrationInstanceID?
    func setPrimaryInstanceID(_ id: IntegrationInstanceID?) throws
}

public extension IntegrationRegistry {
    func instance(_ id: IntegrationInstanceID) throws -> IntegrationInstanceRecord? {
        try instances().first { $0.id == id }
    }

    /// Records whose own flag is enabled and whose integration type is not disabled.
    func activeInstances() throws -> [IntegrationInstanceRecord] {
        let disabled = try disabledIntegrationIDs()
        return try instances().filter { $0.enabled && !disabled.contains($0.integrationID) }
    }

    func upsert(_ record: IntegrationInstanceRecord) throws {
        var records = try instances()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records)
    }

    func remove(_ id: IntegrationInstanceID) throws {
        try save(instances().filter { $0.id != id })
    }

    func replaceInstance(replacing oldID: IntegrationInstanceID?, with record: IntegrationInstanceRecord) throws {
        var records = try instances()
        if let oldID {
            records.removeAll { $0.id == oldID }
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records)
    }

    func setInstanceEnabled(_ enabled: Bool, instanceID: IntegrationInstanceID) throws {
        var records = try instances()
        guard let index = records.firstIndex(where: { $0.id == instanceID }) else { return }
        records[index].enabled = enabled
        try save(records)
    }

    func setIntegrationEnabled(_ enabled: Bool, integrationID: IntegrationID) throws {
        var disabled = try disabledIntegrationIDs()
        if enabled { disabled.remove(integrationID) } else { disabled.insert(integrationID) }
        try setDisabledIntegrationIDs(disabled)
    }
}

/// In-memory registry (tests, and the Engine's default when none is injected).
public final class InMemoryIntegrationRegistry: IntegrationRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [IntegrationInstanceRecord]
    private var disabled: Set<IntegrationID>
    private var primary: IntegrationInstanceID?

    public init(records: [IntegrationInstanceRecord] = [], disabledIntegrations: Set<IntegrationID> = [], primary: IntegrationInstanceID? = nil) {
        self.records = records
        self.disabled = disabledIntegrations
        self.primary = primary
    }

    public func instances() throws -> [IntegrationInstanceRecord] { lock.withLock { records } }
    public func save(_ records: [IntegrationInstanceRecord]) throws { lock.withLock { self.records = records } }
    public func disabledIntegrationIDs() throws -> Set<IntegrationID> { lock.withLock { disabled } }
    public func setDisabledIntegrationIDs(_ ids: Set<IntegrationID>) throws { lock.withLock { disabled = ids } }
    public func primaryInstanceID() throws -> IntegrationInstanceID? { lock.withLock { primary } }
    public func setPrimaryInstanceID(_ id: IntegrationInstanceID?) throws { lock.withLock { primary = id } }
}

/// UserDefaults-backed registry (mirrors UserDefaultsInstalledProviderStore).
public struct UserDefaultsIntegrationRegistry: IntegrationRegistry, @unchecked Sendable {
    private let defaults: UserDefaults
    private let instancesKey = "integrationInstances"
    private let disabledKey = "disabledIntegrationIDs"
    private let primaryKey = "primaryIntegrationInstanceID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func instances() throws -> [IntegrationInstanceRecord] {
        guard let data = defaults.data(forKey: instancesKey) else { return [] }
        return try JSONDecoder().decode([IntegrationInstanceRecord].self, from: data)
    }

    public func save(_ records: [IntegrationInstanceRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: instancesKey)
    }

    public func disabledIntegrationIDs() throws -> Set<IntegrationID> {
        let raw = defaults.stringArray(forKey: disabledKey) ?? []
        return Set(raw.map(IntegrationID.init(rawValue:)))
    }

    public func setDisabledIntegrationIDs(_ ids: Set<IntegrationID>) throws {
        defaults.set(ids.map(\.rawValue).sorted(), forKey: disabledKey)
    }

    public func primaryInstanceID() throws -> IntegrationInstanceID? {
        (defaults.string(forKey: primaryKey)).map(IntegrationInstanceID.init(rawValue:))
    }

    public func setPrimaryInstanceID(_ id: IntegrationInstanceID?) throws {
        defaults.set(id?.rawValue, forKey: primaryKey)
    }
}
