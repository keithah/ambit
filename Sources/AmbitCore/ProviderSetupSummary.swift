import Foundation

public enum ProviderSetupStatus: Equatable, Sendable {
    case ready
    case needsCredentials
    case invalid
    case disabled
}

public enum ProviderSetupAction: Equatable, Sendable {
    case refreshValidation
    case saveCredentials
}

public struct ProviderCredentialSetupSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: String
    public var isRequired: Bool
    public var isConfigured: Bool

    public init(
        id: String,
        label: String,
        kind: String,
        isRequired: Bool,
        isConfigured: Bool
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.isConfigured = isConfigured
    }
}

public struct ProviderSetupSummary: Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var displayName: String
    public var packagePath: String
    public var isEnabled: Bool
    public var status: ProviderSetupStatus
    public var statusText: String
    public var credentials: [ProviderCredentialSetupSummary]
    public var primaryAction: ProviderSetupAction

    public init(
        id: ProviderID,
        displayName: String,
        packagePath: String,
        isEnabled: Bool,
        status: ProviderSetupStatus,
        statusText: String,
        credentials: [ProviderCredentialSetupSummary],
        primaryAction: ProviderSetupAction
    ) {
        self.id = id
        self.displayName = displayName
        self.packagePath = packagePath
        self.isEnabled = isEnabled
        self.status = status
        self.statusText = statusText
        self.credentials = credentials
        self.primaryAction = primaryAction
    }

    public static func make(
        record: InstalledProviderRecord,
        credentialStore: any CredentialStore
    ) -> ProviderSetupSummary {
        let credentials = credentialSummaries(record: record, credentialStore: credentialStore)
        let status = status(record: record, credentials: credentials)
        return ProviderSetupSummary(
            id: record.id,
            displayName: record.displayName,
            packagePath: record.packagePath,
            isEnabled: record.isEnabled,
            status: status,
            statusText: statusText(status: status, validation: record.lastValidation),
            credentials: credentials,
            primaryAction: primaryAction(status: status)
        )
    }

    private static func credentialSummaries(
        record: InstalledProviderRecord,
        credentialStore: any CredentialStore
    ) -> [ProviderCredentialSetupSummary] {
        guard case .valid = record.lastValidation,
              let package = try? ProviderManifestPackage.load(from: URL(fileURLWithPath: record.packagePath))
        else { return [] }

        return package.manifest.credentials.map { credential in
            let key = CredentialKey(providerID: package.manifest.id, id: credential.id)
            let storedCredential = try? credentialStore.credential(key)
            return ProviderCredentialSetupSummary(
                id: credential.id,
                label: credential.label,
                kind: credential.kind.rawValue,
                isRequired: credential.required,
                isConfigured: storedCredential?.isEmpty == false
            )
        }
    }

    private static func status(
        record: InstalledProviderRecord,
        credentials: [ProviderCredentialSetupSummary]
    ) -> ProviderSetupStatus {
        guard record.isEnabled else { return .disabled }
        if case .invalid = record.lastValidation {
            return .invalid
        }
        if credentials.contains(where: { $0.isRequired && !$0.isConfigured }) {
            return .needsCredentials
        }
        return .ready
    }

    private static func statusText(
        status: ProviderSetupStatus,
        validation: InstalledProviderValidation
    ) -> String {
        switch status {
        case .ready:
            return "Ready"
        case .needsCredentials:
            return "Missing required credentials"
        case .invalid:
            if case .invalid(let message) = validation {
                return ProviderDisplayText.singleLine(message)
            }
            return "Invalid"
        case .disabled:
            return "Disabled"
        }
    }

    private static func primaryAction(status: ProviderSetupStatus) -> ProviderSetupAction {
        switch status {
        case .needsCredentials:
            return .saveCredentials
        case .ready, .invalid, .disabled:
            return .refreshValidation
        }
    }
}
