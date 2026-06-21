import Foundation

public struct ProviderDiagnostic: Equatable, Sendable {
    public var title: String
    public var message: String
    public var nextStep: String

    public init(title: String, message: String, nextStep: String) {
        self.title = title
        self.message = ProviderDisplayText.singleLine(message)
        self.nextStep = ProviderDisplayText.singleLine(nextStep)
    }

    public static func make(
        providerID: ProviderID,
        providerName: String,
        snapshot: ProviderSnapshot
    ) -> ProviderDiagnostic? {
        let error = ProviderDisplayText.singleLine(snapshot.error ?? "")
        guard !error.isEmpty else { return nil }

        if let retryAfterSeconds = snapshot.retryAfterSeconds, retryAfterSeconds > 0 {
            return ProviderDiagnostic(
                title: "\(providerName) is backing off",
                message: error,
                nextStep: "Retry after about \(formatDuration(retryAfterSeconds)), or check the router password if the pause repeats."
            )
        }

        switch providerID {
        case ProviderIDs.starlink:
            return ProviderDiagnostic(
                title: "Starlink endpoint unreachable",
                message: error,
                nextStep: "Confirm the dish is reachable at 192.168.100.1:9200 and that grpcurl is installed."
            )
        case ProviderIDs.ecoflow:
            return ProviderDiagnostic(
                title: "EcoFlow daemon unavailable",
                message: error,
                nextStep: "Enable EcoFlow in settings and confirm the daemon is reachable on http://router-ip:8787."
            )
        case ProviderIDs.speedify:
            return ProviderDiagnostic(
                title: "Speedify unavailable",
                message: error,
                nextStep: "Confirm the GL.iNet router Speedify page loads and the router endpoint is selected correctly."
            )
        case ProviderIDs.router, ProviderIDs.vpn:
            return ProviderDiagnostic(
                title: "\(providerName) unavailable",
                message: error,
                nextStep: "Check the selected router endpoint, credentials, and local network reachability."
            )
        default:
            return ProviderDiagnostic(
                title: "\(providerName) reported an error",
                message: error,
                nextStep: "Refresh after checking the provider connection, credentials, and endpoint settings."
            )
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            if remainder == 0 { return "\(minutes)m" }
            return "\(minutes)m \(remainder)s"
        }
        return "\(seconds)s"
    }
}
