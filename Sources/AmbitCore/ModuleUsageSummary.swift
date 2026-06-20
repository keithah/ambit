import Foundation

public struct ModuleUsageSummary: Equatable, Identifiable, Sendable {
    public var providerID: ProviderID
    public var title: String
    public var detail: String
    public var duration: String
    public var lastActivity: String
    public var hasFailures: Bool
    public var lastError: String?

    public var id: ProviderID { providerID }

    public init(
        providerID: ProviderID,
        title: String,
        detail: String,
        duration: String,
        lastActivity: String,
        hasFailures: Bool,
        lastError: String? = nil
    ) {
        self.providerID = providerID
        self.title = title
        self.detail = detail
        self.duration = duration
        self.lastActivity = lastActivity
        self.hasFailures = hasFailures
        self.lastError = lastError
    }

    public static func summaries(
        from snapshots: [ModuleUsageSnapshot],
        providerNames: [ProviderID: String] = [:]
    ) -> [ModuleUsageSummary] {
        snapshots.sorted(by: isOrderedBefore).map { snapshot in
            ModuleUsageSummary(
                providerID: snapshot.providerID,
                title: providerNames[snapshot.providerID] ?? defaultTitle(for: snapshot.providerID),
                detail: [
                    plural(snapshot.pollCount, singular: "poll"),
                    plural(snapshot.commandCount, singular: "command"),
                    plural(snapshot.failureCount, singular: "failure")
                ].joined(separator: " · "),
                duration: String(format: "%.3fs", snapshot.totalDuration),
                lastActivity: snapshot.lastOperation.map { "Last \($0.rawValue)" } ?? "No activity",
                hasFailures: snapshot.failureCount > 0,
                lastError: snapshot.lastError.map { ProviderDisplayText.singleLine($0) }
            )
        }
    }

    private static func isOrderedBefore(_ lhs: ModuleUsageSnapshot, _ rhs: ModuleUsageSnapshot) -> Bool {
        let lhsRank = providerOrder[lhs.providerID]
        let rhsRank = providerOrder[rhs.providerID]
        switch (lhsRank, rhsRank) {
        case let (lhsRank?, rhsRank?):
            return lhsRank < rhsRank
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.providerID < rhs.providerID
        }
    }

    private static func plural(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private static func defaultTitle(for providerID: ProviderID) -> String {
        switch providerID {
        case ProviderIDs.router:
            return "Router"
        case ProviderIDs.vpn:
            return "VPN"
        case ProviderIDs.reachability:
            return "Internet"
        case ProviderIDs.speedify:
            return "Speedify"
        case ProviderIDs.starlink:
            return "Starlink"
        case ProviderIDs.ecoflow:
            return "EcoFlow"
        case ProviderIDs.ping:
            return "Ping"
        case ProviderIDs.iperf3:
            return "iperf3"
        default:
            return providerID
        }
    }

    private static let providerOrder: [ProviderID: Int] = [
        ProviderIDs.router: 0,
        ProviderIDs.vpn: 1,
        ProviderIDs.reachability: 2,
        ProviderIDs.speedify: 3,
        ProviderIDs.starlink: 4,
        ProviderIDs.ecoflow: 5,
        ProviderIDs.ping: 6,
        ProviderIDs.iperf3: 7
    ]
}
