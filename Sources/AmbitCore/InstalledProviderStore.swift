import Foundation

public enum InstalledProviderValidation: Codable, Equatable, Sendable {
    case valid
    case invalid(String)

    private enum CodingKeys: String, CodingKey {
        case status
        case message
    }

    private enum Status: String, Codable {
        case valid
        case invalid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .valid:
            self = .valid
        case .invalid:
            self = .invalid(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .valid:
            try container.encode(Status.valid, forKey: .status)
        case .invalid(let message):
            try container.encode(Status.invalid, forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }
}

public struct InstalledProviderRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var displayName: String
    public var packagePath: String
    public var isEnabled: Bool
    public var lastValidation: InstalledProviderValidation

    public init(
        id: ProviderID,
        displayName: String,
        packagePath: String,
        isEnabled: Bool = true,
        lastValidation: InstalledProviderValidation = .valid
    ) {
        self.id = id
        self.displayName = displayName
        self.packagePath = packagePath
        self.isEnabled = isEnabled
        self.lastValidation = lastValidation
    }
}

public protocol InstalledProviderStore: Sendable {
    func load() throws -> [InstalledProviderRecord]
    func save(_ records: [InstalledProviderRecord]) throws
}

public extension InstalledProviderStore {
    @discardableResult
    func installManifestPackage(at directory: URL) throws -> InstalledProviderRecord {
        let package = try ProviderManifestPackage.load(from: directory)
        let record = InstalledProviderRecord(
            id: package.manifest.id,
            displayName: package.manifest.displayName,
            packagePath: directory.path,
            isEnabled: true,
            lastValidation: .valid
        )
        var records = try load().filter { $0.id != record.id }
        records.append(record)
        try save(records.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        })
        return record
    }

    func remove(providerID: ProviderID) throws {
        try save(try load().filter { $0.id != providerID })
    }

    func setEnabled(_ enabled: Bool, providerID: ProviderID) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == providerID }) else { return }
        records[index].isEnabled = enabled
        try save(records)
    }
}

public struct UserDefaultsInstalledProviderStore: InstalledProviderStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "installedProviders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> [InstalledProviderRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([InstalledProviderRecord].self, from: data)
    }

    public func save(_ records: [InstalledProviderRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }
}
