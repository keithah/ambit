import Foundation

public protocol GatewayFinding: Sendable {
    /// The default gateway's address, or nil when the Mac has no default route.
    /// Throws when the lookup itself failed, which says nothing about the route.
    func defaultGateway() async throws -> String?
}

/// Reads the default route with `/sbin/route -n get default`.
public struct RouteGatewayFinder: GatewayFinding {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner = SystemProcessRunner()) {
        self.runner = runner
    }

    public func defaultGateway() async throws -> String? {
        let result = try await runner.run(
            executable: "/sbin/route", arguments: ["-n", "get", "default"], timeout: 2
        )
        // `route` exits non-zero when there is no default route ("not in table").
        guard result.exitCode == 0 else { return nil }
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
