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
        snapshot.providers.compactMap { instanceID, state -> ProviderOverviewSummary? in
            let providerID = instanceID.rawValue
            guard !excludedProviderIDs.contains(providerID) else { return nil }
            guard state.value != nil || state.errorMessage != nil else { return nil }
            let providerSnapshot = state.value
            let health = providerSnapshot?.health ?? .down
            let errorMessage = (state.errorMessage ?? providerSnapshot?.error).map { ProviderDisplayText.singleLine($0) }
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

    // The dedicated built-ins are addressed by their scoped instance ids, matching the
    // re-keyed snapshot. Generic/manifest providers (instance id == bare provider id) are
    // never in this set, so they still surface here.
    public static let dedicatedOverviewProviderIDs: Set<ProviderID> = [
        ProviderInstanceIDs.router.rawValue,
        ProviderInstanceIDs.vpn.rawValue,
        ProviderInstanceIDs.reachability.rawValue,
        ProviderInstanceIDs.speedify.rawValue,
        ProviderInstanceIDs.starlink.rawValue,
        ProviderInstanceIDs.ecoflow.rawValue,
        ProviderInstanceIDs.ping.rawValue,
        ProviderInstanceIDs.iperf3.rawValue
    ]

    private static func detail(metrics: [Metric], errorMessage: String?, health: Health) -> String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        let metricSummary = metrics.prefix(3).map { "\($0.label) \(ProviderMetricFormat.string($0))" }
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

}
