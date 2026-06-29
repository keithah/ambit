import AmbitCore
import Foundation

struct IntegrationConfigMigrator {
    var settings: AppSettings

    func migrate(_ registry: any IntegrationRegistry) {
        migrateRetiredPingscopeRecords(registry)
        seedIntegrationRegistryIfNeeded(registry)
        dedupePingHostsByAddress(registry)
    }

    /// First-run seed: built-ins are listed so they remain toggleable, while ping hosts provide
    /// the default visible monitoring set. The detected gateway is added asynchronously after
    /// launch because it depends on current network state.
    private func seedIntegrationRegistryIfNeeded(_ registry: any IntegrationRegistry) {
        guard ((try? registry.instances()) ?? []).isEmpty else { return }
        let builtIns = BuiltInIntegrationSeed.records(ecoflowEnabled: settings.ecoflowEnabled, includeActiveMeasurement: true)
        try? registry.save(builtIns + Self.defaultPingHosts.map { IntegrationInstanceRecord.ping($0) })
        try? registry.setDisabledIntegrationIDs(BuiltInIntegrationSeed.integrationIDs)
    }

    /// One-shot migration for retired pingscope/basic-ping records. Scoped to explicit retired
    /// ids so manifest integrations that are merely unavailable this launch are not removed.
    private func migrateRetiredPingscopeRecords(_ registry: any IntegrationRegistry) {
        let isRetiredPingArtifact: (IntegrationInstanceRecord) -> Bool = {
            $0.integrationID == "pingscope" || $0.id == IntegrationInstanceIDs.ping
        }
        if let all = try? registry.instances(), all.contains(where: isRetiredPingArtifact) {
            var kept = all.filter { !isRetiredPingArtifact($0) }
            if !kept.contains(where: { $0.integrationID == IntegrationIDs.ping }) {
                kept += Self.defaultPingHosts.map { IntegrationInstanceRecord.ping($0) }
            }
            try? registry.save(kept)
        }
        if let disabled = try? registry.disabledIntegrationIDs(), disabled.contains(IntegrationIDs.ping) {
            try? registry.setDisabledIntegrationIDs(disabled.subtracting([IntegrationIDs.ping]))
        }
    }

    /// Remove duplicate ping hosts by address, preserving the configured primary when present.
    private func dedupePingHostsByAddress(_ registry: any IntegrationRegistry) {
        guard let all = try? registry.instances() else { return }
        let hosts = all.filter { $0.integrationID == IntegrationIDs.ping }
        let primary = (try? registry.primaryInstanceID()) ?? nil
        let ordered = hosts.filter { $0.id == primary } + hosts.filter { $0.id != primary }
        var seen = Set<String>()
        var removeIDs = Set<IntegrationInstanceID>()
        for record in ordered {
            guard let address = PingHostConfig(configObject: record.config)?.address else { continue }
            if seen.contains(address) {
                removeIDs.insert(record.id)
            } else {
                seen.insert(address)
            }
        }
        guard !removeIDs.isEmpty else { return }
        try? registry.save(all.filter { !removeIDs.contains($0.id) })
    }

    private static let defaultPingHosts = [
        PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
        PingHostConfig(displayName: "Google DNS", address: "8.8.8.8", method: .tcp, port: 443)
    ]
}
