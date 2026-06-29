import Foundation

public struct DiagnosticsFailureRow: Identifiable, Equatable, Sendable {
    public var id: String { "\(entityID.rawValue)-\(timestamp.timeIntervalSince1970)" }
    public var entityID: EntityID
    public var entityName: String
    public var timestamp: Date
    public var reason: String

    public init(entityID: EntityID, entityName: String, timestamp: Date, reason: String) {
        self.entityID = entityID
        self.entityName = entityName
        self.timestamp = timestamp
        self.reason = reason
    }
}

public enum DiagnosticsFailureQuery {
    public static func rows(
        descriptors: [EntityDescriptor],
        samplesByEntity: [EntityID: [Sample]],
        limit: Int = 8
    ) -> [DiagnosticsFailureRow] {
        let descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        return samplesByEntity.flatMap { entityID, samples -> [DiagnosticsFailureRow] in
            guard let descriptor = descriptorsByID[entityID] else { return [] }
            return samples.compactMap { sample in
                guard sample.ok == false || sample.value == nil else { return nil }
                return DiagnosticsFailureRow(
                    entityID: entityID,
                    entityName: descriptor.name,
                    timestamp: sample.timestamp,
                    reason: sample.metadata?.isEmpty == false ? sample.metadata! : "Failed"
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.entityName.localizedStandardCompare(rhs.entityName) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

public struct AppBuildInfo: Equatable, Sendable {
    public var name: String
    public var version: String
    public var build: String
    public var flavor: String

    public init(name: String, version: String, build: String, flavor: String) {
        self.name = name
        self.version = version
        self.build = build
        self.flavor = flavor
    }

    public static func current(bundle: Bundle = .main) -> AppBuildInfo {
        AppBuildInfo(
            name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ambit",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            flavor: bundle.bundleIdentifier?.contains(".dev") == true ? "Developer" : "Release"
        )
    }
}

public enum SoftwareUpdateStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case idle
    case checking
    case updateAvailable(String)
    case upToDate
    case failed(String)
}

public enum SoftwareUpdateConfigurationStatus: Equatable, Sendable {
    case unavailable(String)
    case configured
}

public enum SoftwareUpdateCheckResult: Equatable, Sendable {
    case unavailable(String)
    case checked(SoftwareUpdateStatus)
}

public protocol SoftwareUpdateService: Sendable {
    var feedURLStatus: SoftwareUpdateConfigurationStatus { get }
    var publicKeyStatus: SoftwareUpdateConfigurationStatus { get }
    func status() async -> SoftwareUpdateStatus
    func checkNow() async -> SoftwareUpdateCheckResult
}

public struct UnavailableSoftwareUpdateService: SoftwareUpdateService {
    private let reason: String

    public init(reason: String = "Software updates are not configured.") {
        self.reason = reason
    }

    public var feedURLStatus: SoftwareUpdateConfigurationStatus {
        .unavailable(reason)
    }

    public var publicKeyStatus: SoftwareUpdateConfigurationStatus {
        .unavailable(reason)
    }

    public func status() async -> SoftwareUpdateStatus {
        .unavailable(reason: reason)
    }

    public func checkNow() async -> SoftwareUpdateCheckResult {
        .unavailable(reason)
    }
}

public struct StaticSoftwareUpdateService: SoftwareUpdateService {
    private let storedStatus: SoftwareUpdateStatus
    public let feedURLStatus: SoftwareUpdateConfigurationStatus
    public let publicKeyStatus: SoftwareUpdateConfigurationStatus

    public init(
        status: SoftwareUpdateStatus,
        feedURLStatus: SoftwareUpdateConfigurationStatus,
        publicKeyStatus: SoftwareUpdateConfigurationStatus
    ) {
        self.storedStatus = status
        self.feedURLStatus = feedURLStatus
        self.publicKeyStatus = publicKeyStatus
    }

    public func status() async -> SoftwareUpdateStatus {
        storedStatus
    }

    public func checkNow() async -> SoftwareUpdateCheckResult {
        .checked(storedStatus)
    }
}
