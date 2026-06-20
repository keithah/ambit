import Foundation

public enum ModuleUsageReportFormatter {
    public static func format(_ snapshots: [ModuleUsageSnapshot]) -> String {
        var lines = ["Module usage:"]
        for snapshot in snapshots.sorted(by: isOrderedBefore) {
            lines.append("  \(snapshot.providerID): \(format(snapshot))")
        }
        return lines.joined(separator: "\n")
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

    private static func format(_ snapshot: ModuleUsageSnapshot) -> String {
        var parts = [
            "polls \(snapshot.pollCount)",
            "commands \(snapshot.commandCount)",
            "failures \(snapshot.failureCount)",
            "total \(String(format: "%.3f", snapshot.totalDuration))s"
        ]
        if let lastOperation = snapshot.lastOperation {
            parts.append("last \(lastOperation.rawValue)")
        }
        if let lastError = snapshot.lastError {
            parts.append("last error: \(ProviderDisplayText.singleLine(lastError))")
        }
        return parts.joined(separator: ", ")
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
