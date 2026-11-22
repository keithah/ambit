import Foundation

public enum DeviceKind: String, Codable, Sendable {
    case starlink, glinet
}

/// One device the user added. The password, if any, is in the Keychain under `id`.
public struct SavedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: DeviceKind
    public var name: String
    public var host: String

    public init(id: UUID = UUID(), kind: DeviceKind, name: String, host: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
    }
}

/// The list of devices, kept as one JSON file.
public struct DeviceListFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Ambit/devices.json`
    public static func standard() throws -> DeviceListFile {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DeviceListFile(url: folder.appendingPathComponent("Ambit", isDirectory: true).appendingPathComponent("devices.json"))
    }

    /// A missing file is an empty list. A file that cannot be read is set aside, not overwritten.
    public func load() -> [SavedDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let devices = try? JSONDecoder().decode([SavedDevice].self, from: data) { return devices }
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    public func save(_ devices: [SavedDevice]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: url, options: .atomic)
    }
}
