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
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value).trimmedTrailingZeros()
    }
}

private extension String {
    func trimmedTrailingZeros() -> String {
        guard contains(".") else { return self }
        return trimmingCharacters(in: CharacterSet(charactersIn: "0")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
