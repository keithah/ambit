public enum ManifestAlertCompiler {
    public static func rules(from manifest: ProviderManifest) -> [AlertRule] {
        manifest.alerts.map { alert in
            let ruleID = "\(manifest.id).\(alert.id)"
            switch alert.kind {
            case .threshold(let comparison, let value):
                return .threshold(ThresholdAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    comparison: comparison,
                    threshold: value,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            case .stateTransition(let value):
                return .stateTransition(StateTransitionAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    expectedValue: value,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            case .sustained(let comparison, let value, let duration):
                return .sustained(SustainedAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    comparison: comparison,
                    threshold: value,
                    duration: duration,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            }
        }
    }
}
