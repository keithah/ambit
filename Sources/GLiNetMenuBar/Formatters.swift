import Foundation
import GLiNetCore

enum DisplayFormatters {
    static func latency(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    static func vpnState(_ vpn: VPNStatus) -> String {
        vpn.isConnected ? "Connected" : "Disconnected"
    }

    static func bytes(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    static func throughput(_ bytesPerSecond: Int?) -> String? {
        guard let bytesPerSecond else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}
