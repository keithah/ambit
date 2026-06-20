import Foundation

public enum ProviderSnapshotReport {
    public static func lines(
        providerID: ProviderID,
        providerName: String,
        snapshot: ProviderSnapshot,
        commands: [CommandDescriptor] = []
    ) -> [String] {
        var lines = [
            "Provider: \(providerName) (\(providerID))",
            "Health: \(snapshot.health.reportValue)"
        ]

        if let error = snapshot.error, !error.isEmpty {
            lines.append("Error: \(ProviderDisplayText.singleLine(error))")
        }

        if snapshot.metrics.isEmpty {
            lines.append("Metrics: none")
        } else {
            lines.append(contentsOf: snapshot.metrics.map { "\($0.label): \(ProviderMetricFormat.string($0))" })
        }

        if !commands.isEmpty {
            lines.append("Commands: \(commands.map(\.id).joined(separator: ", "))")
        }

        return lines
    }
}

private extension Health {
    var reportValue: String {
        switch self {
        case .ok:
            return "ok"
        case .degraded:
            return "degraded"
        case .down:
            return "down"
        case .unknown:
            return "unknown"
        }
    }
}
