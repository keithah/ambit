import Foundation

public enum ProviderManifestReport {
    public static func lines(manifest: ProviderManifest) -> [String] {
        var lines = [
            "Manifest valid: \(manifest.displayName) (\(manifest.id))",
            "Endpoint: \(manifest.endpoint.method.rawValue) \(manifest.endpoint.url)",
            "Credentials: \(manifest.credentials.count) declared"
        ]
        lines.append(contentsOf: manifest.credentials.map(credentialLine))
        lines.append("Metrics: \(manifest.metrics.count)")
        lines.append("Commands: \(manifest.commands.count) declared, \(manifest.executableCommandDescriptors.count) executable")
        return lines
    }

    private static func credentialLine(_ credential: ProviderManifest.Credential) -> String {
        let requirement = credential.required ? "required" : "optional"
        return "  \(credential.id): \(credential.label) (\(credential.kind.rawValue), \(requirement))"
    }
}
