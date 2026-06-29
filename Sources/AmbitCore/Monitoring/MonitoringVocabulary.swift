import Foundation

public struct MonitoringPerspectiveID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AlertKindID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MonitoringRole: String, Codable, Sendable, CaseIterable {
    case localLink
    case localGateway
    case accessNetwork
    case upstreamInternet
    case remoteService
    case endpoint

    public var displayName: String {
        switch self {
        case .localLink: return "Local link"
        case .localGateway: return "Local network"
        case .accessNetwork: return "ISP path"
        case .upstreamInternet: return "Upstream"
        case .remoteService: return "Remote service"
        case .endpoint: return "Endpoint"
        }
    }
}

public enum DiagnosisSensitivity: String, CaseIterable, Codable, Sendable {
    case conservative
    case balanced
    case sensitive
}

public enum NetworkConnectivityStatus: String, CaseIterable, Codable, Sendable {
    case connected
    case noInternet
    case noIPAddress
    case notConnected
}

public enum DiagnosticSummaryRole: String, Codable, Sendable {
    case owner
    case member
}

public struct MonitoringMetadata: Equatable, Codable, Sendable {
    public var role: MonitoringRole?
    public var perspectiveID: MonitoringPerspectiveID?
    public var alertKindIDs: [AlertKindID]
    public var diagnosticSummary: DiagnosticSummaryRole?
    public var address: MonitoredAddress?
    public var roleAssignment: MonitoringRoleAssignment?

    public init(
        role: MonitoringRole? = nil,
        perspectiveID: MonitoringPerspectiveID? = nil,
        alertKindIDs: [AlertKindID] = [],
        diagnosticSummary: DiagnosticSummaryRole? = nil,
        address: MonitoredAddress? = nil,
        roleAssignment: MonitoringRoleAssignment? = nil
    ) {
        self.role = role
        self.perspectiveID = perspectiveID
        self.alertKindIDs = alertKindIDs
        self.diagnosticSummary = diagnosticSummary
        self.address = address
        self.roleAssignment = roleAssignment
    }
}

public enum AddressScope: String, Codable, Sendable {
    case loopback
    case linkLocal
    case privateNetwork
    case publicInternet
    case hostname
    case unknown
}

public struct MonitoredAddress: Equatable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var scope: AddressScope {
        AddressClassifier.scope(for: rawValue)
    }
}

public enum RoleAssignmentSource: String, Codable, Sendable {
    case explicit
    case addressClassifier
    case provider
}

public struct MonitoringRoleAssignment: Equatable, Codable, Sendable {
    public var explicitRole: MonitoringRole?
    public var derivedRole: MonitoringRole?
    public var source: RoleAssignmentSource

    public init(
        explicitRole: MonitoringRole? = nil,
        derivedRole: MonitoringRole? = nil,
        source: RoleAssignmentSource
    ) {
        self.explicitRole = explicitRole
        self.derivedRole = derivedRole
        self.source = source
    }
}

public enum AddressClassifier {
    public static func scope(for address: String) -> AddressScope {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "localhost" || trimmed == "::1" { return .loopback }
        guard let octets = ipv4Octets(trimmed) else {
            return looksLikeHostname(trimmed) ? .hostname : .unknown
        }
        switch (octets[0], octets[1]) {
        case (127, _):
            return .loopback
        case (169, 254):
            return .linkLocal
        case (10, _), (172, 16...31), (192, 168):
            return .privateNetwork
        default:
            return .publicInternet
        }
    }

    public static func derivedRole(for address: String) -> MonitoringRole {
        switch scope(for: address) {
        case .loopback, .linkLocal, .privateNetwork:
            return .localGateway
        case .publicInternet:
            return .upstreamInternet
        case .hostname, .unknown:
            return .remoteService
        }
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func looksLikeHostname(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.contains { $0.isLetter }
    }
}

public struct MonitoringPerspectiveMember: Equatable, Sendable {
    public var entityID: EntityID
    public var instanceID: IntegrationInstanceID
    public var displayName: String
    public var role: MonitoringRole
    public var status: HealthStatus
    public var isStale: Bool
    public var consecutiveFailures: Int

    public init(
        entityID: EntityID,
        instanceID: IntegrationInstanceID,
        displayName: String,
        role: MonitoringRole,
        status: HealthStatus,
        isStale: Bool,
        consecutiveFailures: Int
    ) {
        self.entityID = entityID
        self.instanceID = instanceID
        self.displayName = displayName
        self.role = role
        self.status = status
        self.isStale = isStale
        self.consecutiveFailures = consecutiveFailures
    }
}

public struct MonitoringPerspective: Equatable, Sendable {
    public var id: MonitoringPerspectiveID
    public var title: String
    public var members: [MonitoringPerspectiveMember]
    public var linkStatus: NetworkConnectivityStatus?
    public var sensitivity: DiagnosisSensitivity

    public init(
        id: MonitoringPerspectiveID,
        title: String,
        members: [MonitoringPerspectiveMember],
        linkStatus: NetworkConnectivityStatus? = nil,
        sensitivity: DiagnosisSensitivity
    ) {
        self.id = id
        self.title = title
        self.members = members
        self.linkStatus = linkStatus
        self.sensitivity = sensitivity
    }
}

public enum DiagnosisConfidence: String, Codable, Sendable {
    case high
    case tentative
}

public struct MonitoringVerdict: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case noData
        case monitoringStalled
        case allReachable
        case localNetworkDown
        case accessNetworkDown
        case upstreamDown
        case remoteServiceDown
        case partialDegradation
    }

    public var kind: Kind
    public var affectedRole: MonitoringRole?

    public init(kind: Kind, affectedRole: MonitoringRole? = nil) {
        self.kind = kind
        self.affectedRole = affectedRole
    }
}

public struct MonitoringEvidence: Equatable, Codable, Sendable {
    public var role: MonitoringRole
    public var total: Int
    public var healthy: Int
    public var degraded: Int
    public var down: Int
    public var status: HealthStatus
    public var summary: String

    public init(
        role: MonitoringRole,
        total: Int,
        healthy: Int,
        degraded: Int,
        down: Int,
        status: HealthStatus,
        summary: String
    ) {
        self.role = role
        self.total = total
        self.healthy = healthy
        self.degraded = degraded
        self.down = down
        self.status = status
        self.summary = summary
    }
}

public struct MonitoringDiagnosis: Equatable, Sendable {
    public var perspectiveID: MonitoringPerspectiveID
    public var verdict: MonitoringVerdict
    public var severity: Severity
    public var confidence: DiagnosisConfidence
    public var affectedEntityIDs: [EntityID]
    public var title: String
    public var detail: String
    public var evidence: [MonitoringEvidence]

    public init(
        perspectiveID: MonitoringPerspectiveID,
        verdict: MonitoringVerdict,
        severity: Severity,
        confidence: DiagnosisConfidence,
        affectedEntityIDs: [EntityID],
        title: String,
        detail: String,
        evidence: [MonitoringEvidence] = []
    ) {
        self.perspectiveID = perspectiveID
        self.verdict = verdict
        self.severity = severity
        self.confidence = confidence
        self.affectedEntityIDs = affectedEntityIDs
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

public typealias AlertTargetTemplate = AlertTarget

public struct AlertRecoveryDeclaration: Equatable, Codable, Sendable {
    public var titleTemplate: String
    public var messageTemplate: String

    public init(titleTemplate: String, messageTemplate: String) {
        self.titleTemplate = titleTemplate
        self.messageTemplate = messageTemplate
    }
}

public enum AlertTriggerDeclaration: Equatable, Codable, Sendable {
    case healthTransition(to: HealthStatus)
    case diagnosisVerdict(MonitoringVerdict.Kind)
    case connectivityTransition(to: NetworkConnectivityStatus)
    case allMembersFailing(minimumCount: Int, ratio: Double)
    case metricThreshold(EntityAlertPolicy)
}

public struct AlertKindDeclaration: Equatable, Codable, Sendable {
    public var id: AlertKindID
    public var titleTemplate: String
    public var messageTemplate: String
    public var severity: Severity
    public var defaultEnabled: Bool
    public var target: AlertTargetTemplate
    public var trigger: AlertTriggerDeclaration
    public var recovery: AlertRecoveryDeclaration?
    public var cooldown: TimeInterval

    public init(
        id: AlertKindID,
        titleTemplate: String,
        messageTemplate: String,
        severity: Severity,
        defaultEnabled: Bool,
        target: AlertTargetTemplate,
        trigger: AlertTriggerDeclaration,
        recovery: AlertRecoveryDeclaration? = nil,
        cooldown: TimeInterval
    ) {
        self.id = id
        self.titleTemplate = titleTemplate
        self.messageTemplate = messageTemplate
        self.severity = severity
        self.defaultEnabled = defaultEnabled
        self.target = target
        self.trigger = trigger
        self.recovery = recovery
        self.cooldown = cooldown
    }
}

public struct NetworkAwarenessConfig: Equatable, Codable, Sendable {
    public var connectivityAlertsEnabled: Bool
    public var networkChangeAlertsEnabled: Bool
    public var pathRecoveredAlertsEnabled: Bool
    public var cooldown: TimeInterval

    public init(
        connectivityAlertsEnabled: Bool = true,
        networkChangeAlertsEnabled: Bool = true,
        pathRecoveredAlertsEnabled: Bool = true,
        cooldown: TimeInterval = 300
    ) {
        self.connectivityAlertsEnabled = connectivityAlertsEnabled
        self.networkChangeAlertsEnabled = networkChangeAlertsEnabled
        self.pathRecoveredAlertsEnabled = pathRecoveredAlertsEnabled
        self.cooldown = cooldown
    }
}

public struct AlertTemplateContext: Equatable, Sendable {
    public var hostName: String?
    public var entityName: String?
    public var affectedCount: Int?
    public var totalCount: Int?
    public var moreCount: Int?
    public var roleName: String?
    public var gatewayOld: String?
    public var gatewayNew: String?
    public var statusOld: String?
    public var statusNew: String?

    public init(
        hostName: String? = nil,
        entityName: String? = nil,
        affectedCount: Int? = nil,
        totalCount: Int? = nil,
        moreCount: Int? = nil,
        roleName: String? = nil,
        gatewayOld: String? = nil,
        gatewayNew: String? = nil,
        statusOld: String? = nil,
        statusNew: String? = nil
    ) {
        self.hostName = hostName
        self.entityName = entityName
        self.affectedCount = affectedCount
        self.totalCount = totalCount
        self.moreCount = moreCount
        self.roleName = roleName
        self.gatewayOld = gatewayOld
        self.gatewayNew = gatewayNew
        self.statusOld = statusOld
        self.statusNew = statusNew
    }
}

public enum AlertTemplateRenderer {
    public static func render(_ template: String, context: AlertTemplateContext) -> String {
        var output = template
        for (token, value) in tokens(context) {
            output = output.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return output
    }

    private static func tokens(_ context: AlertTemplateContext) -> [(String, String)] {
        [
            ("hostName", context.hostName),
            ("entityName", context.entityName),
            ("affectedCount", context.affectedCount.map(String.init)),
            ("totalCount", context.totalCount.map(String.init)),
            ("moreCount", context.moreCount.map(String.init)),
            ("roleName", context.roleName),
            ("tierName", context.roleName),
            ("gatewayOld", context.gatewayOld),
            ("gatewayNew", context.gatewayNew),
            ("statusOld", context.statusOld),
            ("statusNew", context.statusNew)
        ].compactMap { key, value in value.map { (key, $0) } }
    }
}
