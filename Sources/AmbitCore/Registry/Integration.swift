import Foundation

/// The installable, branded unit (`integration-model.md`). An integration stands up one or
/// more provider instances for a configured install. Phase-1-minimal: just enough to drive
/// registry-based, multi-instance provider assembly — no manifest-bundle schema, no
/// setup flow, no multi-engine coordination.
public protocol Integration: Sendable {
    var id: IntegrationID { get }
    var displayName: String { get }
    var configSchema: IntegrationConfigSchema? { get }

    /// True if the integration supports many configured installs (e.g. pingscope, one per
    /// host). Single-install integrations (the built-ins today) report false.
    var isMultiInstance: Bool { get }

    /// Build the provider instances for one enabled, configured install. Single-instance
    /// integrations ignore `instance.config`; multi-instance ones decode it.
    func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider]

    /// Alert rules this integration contributes for one configured instance (e.g. pingscope's
    /// per-host high-latency rule from its AlertPolicy). Default: none.
    func alertRules(instance: IntegrationInstanceRecord) -> [AlertRule]
}

public extension Integration {
    var isMultiInstance: Bool { false }
    var configSchema: IntegrationConfigSchema? { nil }
    func alertRules(instance: IntegrationInstanceRecord) -> [AlertRule] { [] }
}
