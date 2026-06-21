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

        if let diagnostic = ProviderDiagnostic.make(providerID: providerID, providerName: providerName, snapshot: snapshot) {
            lines.append("Diagnosis: \(diagnostic.title)")
            lines.append("Next: \(diagnostic.nextStep)")
        }

        if snapshot.metrics.isEmpty {
            lines.append("Metrics: none")
        } else {
            lines.append(contentsOf: snapshot.metrics.map { "\($0.label): \(ProviderMetricFormat.string($0))" })
        }

        if !commands.isEmpty {
            lines.append("Commands: \(commands.map(commandSummary).joined(separator: ", "))")
        }

        return lines
    }

    private static func commandSummary(_ command: CommandDescriptor) -> String {
        var qualifiers: [String] = [command.id]
        if !command.parameters.isEmpty {
            qualifiers.append("\(command.parameters.count) params")
        }
        if command.requiresConfirmation {
            qualifiers.append("confirmation")
        }
        return "\(command.label) (\(qualifiers.joined(separator: ", ")))"
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
