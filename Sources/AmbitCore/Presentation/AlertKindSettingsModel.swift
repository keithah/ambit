import Foundation

public struct AlertKindSettingsRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var integrationInstanceID: IntegrationInstanceID
    public var integrationName: String
    public var kindID: AlertKindID
    public var title: String
    public var detail: String
    public var enabled: Bool

    public init(
        id: String,
        integrationInstanceID: IntegrationInstanceID,
        integrationName: String,
        kindID: AlertKindID,
        title: String,
        detail: String,
        enabled: Bool
    ) {
        self.id = id
        self.integrationInstanceID = integrationInstanceID
        self.integrationName = integrationName
        self.kindID = kindID
        self.title = title
        self.detail = detail
        self.enabled = enabled
    }
}

public enum AlertKindSettingsModel {
    public static func rows(
        records: [IntegrationInstanceRecord],
        declarationsByInstance: [IntegrationInstanceID: [AlertKindDeclaration]],
        config: PresentationConfig
    ) -> [AlertKindSettingsRow] {
        records.flatMap { record in
            (declarationsByInstance[record.id] ?? []).map { declaration in
                AlertKindSettingsRow(
                    id: "\(record.id.rawValue):\(declaration.id.rawValue)",
                    integrationInstanceID: record.id,
                    integrationName: record.displayName,
                    kindID: declaration.id,
                    title: declaration.titleTemplate,
                    detail: declaration.messageTemplate,
                    enabled: config.alertKindOverrides[declaration.id]?.enabled ?? declaration.defaultEnabled
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.integrationName != rhs.integrationName {
                return lhs.integrationName.localizedStandardCompare(rhs.integrationName) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
