import Foundation

public struct ProviderOverviewSummary: Equatable, Identifiable, Sendable {
    public var providerID: ProviderID
    public var title: String
    public var detail: String
    public var badge: String
    public var health: Health
    public var errorMessage: String?

    public var id: ProviderID { providerID }

    public init(
        providerID: ProviderID,
        title: String,
        detail: String,
        badge: String,
        health: Health,
        errorMessage: String? = nil
    ) {
        self.providerID = providerID
        self.title = title
        self.detail = detail
        self.badge = badge
        self.health = health
        self.errorMessage = errorMessage
    }

    public static func genericSummaries(
        from snapshot: StatusSnapshot,
        providerNames: [ProviderID: String] = [:],
        excluding excludedProviderIDs: Set<ProviderID> = dedicatedOverviewProviderIDs
    ) -> [ProviderOverviewSummary] {
        snapshot.providers.compactMap { providerID, state -> ProviderOverviewSummary? in
            guard !excludedProviderIDs.contains(providerID) else { return nil }
            guard state.value != nil || state.errorMessage != nil else { return nil }
            let providerSnapshot = state.value
            let health = providerSnapshot?.health ?? .down
            let errorMessage = state.errorMessage ?? providerSnapshot?.error
            return ProviderOverviewSummary(
                providerID: providerID,
                title: providerNames[providerID] ?? providerID,
                detail: detail(metrics: providerSnapshot?.metrics ?? [], errorMessage: errorMessage, health: health),
                badge: badge(for: health),
                health: health,
                errorMessage: errorMessage
            )
        }
        .sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    public static let dedicatedOverviewProviderIDs: Set<ProviderID> = [
        ProviderIDs.router,
        ProviderIDs.vpn,
        ProviderIDs.reachability,
        ProviderIDs.speedify,
        ProviderIDs.starlink,
        ProviderIDs.ecoflow,
        ProviderIDs.ping,
        ProviderIDs.iperf3
    ]

    private static func detail(metrics: [Metric], errorMessage: String?, health: Health) -> String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        let metricSummary = metrics.prefix(3).map { "\($0.label) \(format($0.value))" }
        if !metricSummary.isEmpty {
            return metricSummary.joined(separator: " · ")
        }
        return "Health \(badge(for: health))"
    }

    private static func badge(for health: Health) -> String {
        switch health {
        case .ok:
            return "OK"
        case .degraded:
            return "Degraded"
        case .down:
            return "Down"
        case .unknown:
            return "Unknown"
        }
    }

    private static func format(_ value: MetricValue) -> String {
        switch value {
        case .throughput(let bitsPerSecond):
            return String(format: "%.2f Mbps", Double(bitsPerSecond) / 1_000_000)
        case .latency(let ms):
            return "\(format(ms)) ms"
        case .percent(let value):
            return "\(format(value))%"
        case .level(let value):
            return format(value)
        case .bool(let value):
            return value ? "yes" : "no"
        case .text(let value):
            return value
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
