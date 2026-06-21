import Foundation

public enum ProviderManifestReport {
    public static func lines(manifest: ProviderManifest) -> [String] {
        var lines = [
            "Manifest valid: \(manifest.displayName) (\(manifest.id))"
        ]
        if let layoutLine = layoutLine(manifest.layout) {
            lines.append(layoutLine)
        }
        lines.append("Endpoint: \(manifest.endpoint.method.rawValue) \(manifest.endpoint.url)")
        lines.append("Credentials: \(manifest.credentials.count) declared")
        lines.append(contentsOf: manifest.credentials.map(credentialLine))
        lines.append("Metrics: \(manifest.metrics.count)")
        lines.append(contentsOf: manifest.metrics.map(metricLine))
        lines.append("Alerts: \(manifest.alerts.count)")
        lines.append(contentsOf: manifest.alerts.map(alertLine))
        lines.append("Commands: \(manifest.commands.count) declared, \(manifest.executableCommandDescriptors.count) executable")
        lines.append(contentsOf: manifest.commands.map(commandLine))
        return lines
    }

    static func number(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func layoutLine(_ layout: ProviderManifest.Layout?) -> String? {
        guard let layout else { return nil }
        var parts: [String] = []
        if let icon = layout.icon {
            parts.append("icon \(icon)")
        }
        if let accent = layout.accent {
            parts.append("accent \(accent)")
        }
        if let primaryMetric = layout.primaryMetric {
            parts.append("primary \(primaryMetric)")
        }
        guard !parts.isEmpty else { return nil }
        return "Layout: \(parts.joined(separator: ", "))"
    }

    private static func credentialLine(_ credential: ProviderManifest.Credential) -> String {
        let requirement = credential.required ? "required" : "optional"
        return "  \(credential.id): \(credential.label) (\(credential.kind.rawValue), \(requirement))"
    }

    private static func metricLine(_ metric: ProviderManifest.MetricMapping) -> String {
        var detail = "\(metric.value.type.rawValue) at \(metric.value.path)"
        if !metric.value.transforms.isEmpty {
            let transforms = metric.value.transforms.map(\.reportName).joined(separator: ", ")
            detail += ", transforms: \(transforms)"
        }
        return "  \(metric.id): \(metric.label) (\(detail))"
    }

    private static func alertLine(_ alert: ProviderManifest.Alert) -> String {
        "  \(alert.id): \(alert.title) (\(alert.metricID) \(alert.kind.reportText), \(alert.severity.rawValue))"
    }

    private static func commandLine(_ command: ProviderManifest.Command) -> String {
        let paramLabel = command.parameters.count == 1 ? "param" : "params"
        var details = ["\(command.parameters.count) \(paramLabel)"]
        if command.requiresConfirmation {
            details.append("confirmation")
        }
        details.append(command.endpoint == nil ? "metadata only" : "executable")
        return "  \(command.id): \(command.label) (\(details.joined(separator: ", ")))"
    }
}

private extension ProviderManifest.Transform {
    var reportName: String {
        switch self {
        case .multiply:
            return "multiply"
        case .divide:
            return "divide"
        case .round:
            return "round"
        case .clamp:
            return "clamp"
        case .defaultValue:
            return "defaultValue"
        }
    }
}

private extension ProviderManifest.Alert.Kind {
    var reportText: String {
        switch self {
        case .threshold(let comparison, let value):
            return "\(comparison.rawValue) \(ProviderManifestReport.number(value))"
        case .stateTransition(let value):
            return "stateTransition \(value)"
        case .sustained(let comparison, let value, let duration):
            return "\(comparison.rawValue) \(ProviderManifestReport.number(value)) for \(ProviderManifestReport.number(duration))s"
        }
    }
}
