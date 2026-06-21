import Foundation

public enum ProviderDisplayAction: Equatable, Sendable {
    case none
    case configureCredentials
}

public struct ProviderCommandDisplayModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct ProviderDisplayModel: Equatable, Sendable {
    public var providerID: ProviderID
    public var title: String
    public var health: Health
    public var isLoading: Bool
    public var primaryMessage: String
    public var primaryMetric: Metric?
    public var icon: String?
    public var accent: String?
    public var metrics: [Metric]
    public var metricSections: [ProviderMetricSection]
    public var commands: [ProviderCommandDisplayModel]
    public var diagnostic: ProviderDiagnostic?
    public var action: ProviderDisplayAction

    public init(
        providerID: ProviderID,
        title: String,
        health: Health,
        isLoading: Bool,
        primaryMessage: String,
        primaryMetric: Metric?,
        icon: String?,
        accent: String?,
        metrics: [Metric],
        metricSections: [ProviderMetricSection],
        commands: [ProviderCommandDisplayModel],
        diagnostic: ProviderDiagnostic?,
        action: ProviderDisplayAction
    ) {
        self.providerID = providerID
        self.title = title
        self.health = health
        self.isLoading = isLoading
        self.primaryMessage = primaryMessage
        self.primaryMetric = primaryMetric
        self.icon = icon
        self.accent = accent
        self.metrics = metrics
        self.metricSections = metricSections
        self.commands = commands
        self.diagnostic = diagnostic
        self.action = action
    }

    public static func make(
        providerID: ProviderID,
        providerName: String,
        state: SourceState<ProviderSnapshot>?,
        commands: [CommandDescriptor],
        layout: ProviderManifest.Layout? = nil
    ) -> ProviderDisplayModel {
        let snapshot = state?.value
        let error = (state?.errorMessage ?? snapshot?.error).map { ProviderDisplayText.singleLine($0) }
        let health = snapshot?.health ?? (error == nil ? .unknown : .down)
        let metrics = snapshot?.metrics ?? []
        let primaryMetric = layout?.primaryMetric.flatMap { id in
            metrics.first { $0.id == id }
        } ?? metrics.first
        let primaryMessage = error ?? primaryMessage(metrics: metrics, health: health)
        let action: ProviderDisplayAction = primaryMessage.contains("Manifest credential") ? .configureCredentials : .none

        return ProviderDisplayModel(
            providerID: providerID,
            title: providerName,
            health: health,
            isLoading: state?.isLoading == true,
            primaryMessage: primaryMessage,
            primaryMetric: primaryMetric,
            icon: layout?.icon,
            accent: layout?.accent,
            metrics: metrics,
            metricSections: ProviderMetricSection.sections(from: metrics),
            commands: commands.map(commandDisplayModel),
            diagnostic: snapshot.flatMap { ProviderDiagnostic.make(providerID: providerID, providerName: providerName, snapshot: $0) },
            action: action
        )
    }

    private static func primaryMessage(metrics: [Metric], health: Health) -> String {
        let metricSummary = metrics.prefix(2).map { "\($0.label) \(ProviderMetricFormat.string($0))" }
        if !metricSummary.isEmpty {
            return metricSummary.joined(separator: " · ")
        }
        return health == .unknown ? "Waiting for provider snapshot" : "No metrics reported yet"
    }

    private static func commandDisplayModel(_ command: CommandDescriptor) -> ProviderCommandDisplayModel {
        var details: [String] = []
        if !command.parameters.isEmpty {
            details.append(command.parameters.count == 1 ? "1 param" : "\(command.parameters.count) params")
        }
        if command.requiresConfirmation {
            details.append("confirmation")
        }
        return ProviderCommandDisplayModel(
            id: command.id,
            label: command.label,
            detail: details.joined(separator: " · ")
        )
    }
}
