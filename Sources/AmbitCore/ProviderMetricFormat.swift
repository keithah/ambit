import Foundation

public enum ProviderMetricFormat {
    public static func string(_ metric: Metric) -> String {
        if case .level(let value) = metric.value, metric.id.localizedCaseInsensitiveContains("percent") {
            return "\(number(value))%"
        }
        return string(metric.value)
    }

    public static func string(_ value: MetricValue) -> String {
        switch value {
        case .throughput(let bitsPerSecond):
            return String(format: "%.2f Mbps", Double(bitsPerSecond) / 1_000_000)
        case .latency(let ms):
            return "\(number(ms)) ms"
        case .percent(let value):
            return "\(number(value))%"
        case .level(let value):
            return number(value)
        case .bool(let value):
            return value ? "Yes" : "No"
        case .text(let value):
            return value
        case .table(let table):
            return table.rows.count == 1 ? "1 row" : "\(table.rows.count) rows"
        }
    }

    private static func number(_ value: Double) -> String {
        guard value != value.rounded() else { return String(Int(value)) }

        var formatted = String(format: "%.2f", value)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }
}
