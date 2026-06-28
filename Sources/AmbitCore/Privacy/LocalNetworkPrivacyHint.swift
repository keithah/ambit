import Foundation

public enum LocalNetworkPrivacyHint {
    public static func requiresLocalNetworkPermission(host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return false }
        if normalized == "localhost" || normalized == "::1" { return true }
        if normalized.hasPrefix("127.") { return true }
        if normalized.hasPrefix("169.254.") { return true }
        if normalized.hasPrefix("10.") { return true }
        if normalized.hasPrefix("192.168.") { return true }
        if let octets = ipv4Octets(normalized), octets[0] == 172, (16...31).contains(octets[1]) {
            return true
        }
        return false
    }

    public static func guidance(for displayName: String, host: String) -> String {
        "\(displayName) uses local address \(host). If macOS prompts for Local Network access, allow Ambit so this host can be reached."
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let pieces = value.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        let octets = pieces.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
