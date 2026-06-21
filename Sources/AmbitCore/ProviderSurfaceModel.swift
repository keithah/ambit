import Foundation

public enum ProviderSurfaceTone: Equatable, Sendable {
    case good
    case warn
    case bad
    case neutral
}

public struct ProviderSurfaceModel: Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var title: String
    public var health: Health
    public var tone: ProviderSurfaceTone
    public var icon: String?
    public var accent: String?
    public var primaryMetric: Metric?
    public var primaryValueText: String?
    public var shortMessage: String
    public var commandCount: Int
    public var activeAlertCount: Int
    public var diagnostic: ProviderDiagnostic?

    public init(
        id: ProviderID,
        title: String,
        health: Health,
        tone: ProviderSurfaceTone,
        icon: String? = nil,
        accent: String? = nil,
        primaryMetric: Metric? = nil,
        primaryValueText: String? = nil,
        shortMessage: String,
        commandCount: Int,
        activeAlertCount: Int,
        diagnostic: ProviderDiagnostic? = nil
    ) {
        self.id = id
        self.title = title
        self.health = health
        self.tone = tone
        self.icon = icon
        self.accent = accent
        self.primaryMetric = primaryMetric
        self.primaryValueText = primaryValueText
        self.shortMessage = shortMessage
        self.commandCount = commandCount
        self.activeAlertCount = activeAlertCount
        self.diagnostic = diagnostic
    }

    public static func make(
        providerID: ProviderID,
        providerName: String,
        state: SourceState<ProviderSnapshot>?,
        commands: [CommandDescriptor],
        layout: ProviderManifest.Layout? = nil,
        activeAlertCount: Int = 0
    ) -> ProviderSurfaceModel {
        let display = ProviderDisplayModel.make(
            providerID: providerID,
            providerName: providerName,
            state: state,
            commands: commands,
            layout: layout
        )

        return ProviderSurfaceModel(
            id: display.providerID,
            title: display.title,
            health: display.health,
            tone: tone(for: display.health),
            icon: display.icon,
            accent: display.accent,
            primaryMetric: display.primaryMetric,
            primaryValueText: display.primaryMetric.map(ProviderMetricFormat.string),
            shortMessage: display.primaryMessage,
            commandCount: display.commands.count,
            activeAlertCount: activeAlertCount,
            diagnostic: display.diagnostic
        )
    }

    private static func tone(for health: Health) -> ProviderSurfaceTone {
        switch health {
        case .ok:
            return .good
        case .degraded:
            return .warn
        case .down:
            return .bad
        case .unknown:
            return .neutral
        }
    }
}

public struct SurfaceSnapshot: Equatable, Sendable {
    public var providers: [ProviderSurfaceModel]
    public var lastUpdated: Date?

    public init(providers: [ProviderSurfaceModel], lastUpdated: Date?) {
        self.providers = providers
        self.lastUpdated = lastUpdated
    }

    public static func make(
        snapshot: StatusSnapshot,
        providerNames: [ProviderID: String],
        providerCommands: [ProviderID: [CommandDescriptor]] = [:],
        providerLayouts: [ProviderID: ProviderManifest.Layout] = [:],
        activeAlertCounts: [ProviderID: Int] = [:]
    ) -> SurfaceSnapshot {
        let providers = snapshot.providers.map { providerID, state in
            ProviderSurfaceModel.make(
                providerID: providerID,
                providerName: providerNames[providerID] ?? providerID,
                state: state,
                commands: providerCommands[providerID] ?? [],
                layout: providerLayouts[providerID],
                activeAlertCount: activeAlertCounts[providerID] ?? 0
            )
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return SurfaceSnapshot(providers: providers, lastUpdated: snapshot.lastUpdated)
    }
}

public struct NotificationSurfaceModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var title: String
    public var subtitle: String
    public var body: String
    public var severity: AlertSeverity
    public var triggeredAt: Date

    public init(
        id: String,
        providerID: ProviderID,
        title: String,
        subtitle: String,
        body: String,
        severity: AlertSeverity,
        triggeredAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.severity = severity
        self.triggeredAt = triggeredAt
    }

    public init(event: AlertEvent, providerName: String) {
        self.init(
            id: event.id,
            providerID: event.providerID,
            title: event.title,
            subtitle: providerName,
            body: event.message,
            severity: event.severity,
            triggeredAt: event.triggeredAt
        )
    }
}
