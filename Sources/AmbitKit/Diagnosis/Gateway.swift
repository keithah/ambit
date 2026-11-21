import Foundation

public protocol GatewayFinding: Sendable {
    /// The default gateway's address, or nil when the Mac has no default route.
    func defaultGateway() async -> String?
}

/// Reads the default route with `/sbin/route -n get default`.
public struct RouteGatewayFinder: GatewayFinding {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner = SystemProcessRunner()) {
        self.runner = runner
    }

    public func defaultGateway() async -> String? {
        guard let result = try? await runner.run(
            executable: "/sbin/route", arguments: ["-n", "get", "default"], timeout: 2
        ), result.exitCode == 0 else { return nil }
        return Self.parseGateway(result.stdout)
    }

    static func parseGateway(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gateway:") else { continue }
            let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            return ProbeTarget.isValidHost(value) ? value : nil
        }
        return nil
    }
}
