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
            lines.append(contentsOf: snapshot.metrics.map { "\($0.label): \($0.value.reportValue)" })
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

private extension MetricValue {
    var reportValue: String {
        switch self {
        case .throughput(let bitsPerSecond):
            return String(format: "%.2f Mbps", Double(bitsPerSecond) / 1_000_000)
        case .latency(let ms):
            return "\(Self.format(ms)) ms"
        case .percent(let value), .level(let value):
            return "\(Self.format(value))%"
        case .bool(let value):
            return String(value)
        case .text(let value):
            return value
        }
    }

    static func format(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }
}
