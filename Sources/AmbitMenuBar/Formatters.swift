import Foundation
import AmbitCore

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

    static func metricValue(_ value: MetricValue) -> String {
        switch value {
        case .throughput(let bitsPerSecond):
            return throughput(bitsPerSecond) ?? "Unknown"
        case .latency(let ms):
            return "\(Int(ms.rounded())) ms"
        case .percent(let value):
            return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
        case .level(let value):
            return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
        case .bool(let value):
            return value ? "Yes" : "No"
        case .text(let value):
            return value
        }
    }

    static func health(_ health: Health) -> String {
        switch health {
        case .ok:
            return "OK"
        case .degraded:
            return "Degraded"
        case .down:
            return "Down"
        case .unknown:
            return "Unknown"
        }
    }
}
