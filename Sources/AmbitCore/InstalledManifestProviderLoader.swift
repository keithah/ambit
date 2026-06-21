import Foundation

public struct InstalledManifestProviderLoadResult: Sendable {
    public var records: [InstalledProviderRecord]
    public var providers: [any Provider]
    public var alertRules: [AlertRule]

    public init(records: [InstalledProviderRecord], providers: [any Provider], alertRules: [AlertRule] = []) {
        self.records = records
        self.providers = providers
        self.alertRules = alertRules
    }
}

public struct InstalledManifestProviderLoader: Sendable {
    private let store: any InstalledProviderStore
    private let credentialStore: any CredentialStore
    private let httpClient: any ManifestHTTPClient

    public init(
        store: any InstalledProviderStore,
        credentialStore: any CredentialStore,
        httpClient: any ManifestHTTPClient = URLSessionManifestHTTPClient()
    ) {
        self.store = store
        self.credentialStore = credentialStore
        self.httpClient = httpClient
    }

    public func load() throws -> InstalledManifestProviderLoadResult {
        var updatedRecords: [InstalledProviderRecord] = []
        var providers: [any Provider] = []
        var alertRules: [AlertRule] = []

        for record in try store.load() {
            guard record.isEnabled else {
                updatedRecords.append(record)
                continue
            }

            do {
                let package = try ProviderManifestPackage.load(
                    from: URL(fileURLWithPath: record.packagePath, isDirectory: true)
                )
                var updated = record
                updated.id = package.manifest.id
                updated.displayName = package.manifest.displayName
                updated.lastValidation = .valid
                updatedRecords.append(updated)
                alertRules.append(contentsOf: ManifestAlertCompiler.rules(from: package.manifest))
                providers.append(
                    ManifestProvider(
                        manifest: package.manifest,
                        httpClient: httpClient,
                        credentialStore: credentialStore
                    )
                )
            } catch {
                var updated = record
                updated.lastValidation = .invalid(error.localizedDescription)
                updatedRecords.append(updated)
            }
        }

        try store.save(updatedRecords)
        return InstalledManifestProviderLoadResult(records: updatedRecords, providers: providers, alertRules: alertRules)
    }
}
