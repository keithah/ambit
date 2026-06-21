import Foundation

public struct ProviderMetricSection: Equatable, Sendable {
    public var title: String
    public var metrics: [Metric]

    public init(title: String, metrics: [Metric]) {
        self.title = title
        self.metrics = metrics
    }

    public static func sections(from metrics: [Metric]) -> [ProviderMetricSection] {
        let orderedCategories: [Category] = [.network, .power, .state, .other]
        let grouped = Dictionary(grouping: metrics, by: Category.category(for:))
        return orderedCategories.compactMap { category in
            guard let metrics = grouped[category], !metrics.isEmpty else { return nil }
            return ProviderMetricSection(title: category.title, metrics: metrics)
        }
    }

    private enum Category: CaseIterable, Hashable {
        case network
        case power
        case state
        case other

        var title: String {
            switch self {
            case .network:
                return "Network"
            case .power:
                return "Power"
            case .state:
                return "State"
            case .other:
                return "Other"
            }
        }

        static func category(for metric: Metric) -> Category {
            switch metric.value {
            case .latency, .throughput:
                return .network
            case .percent:
                return metric.id.localizedCaseInsensitiveContains("battery") || metric.id.localizedCaseInsensitiveContains("power") ? .power : .network
            case .bool, .text:
                return .state
            case .level:
                return metric.id.localizedCaseInsensitiveContains("battery") || metric.id.localizedCaseInsensitiveContains("power") ? .power : .other
            }
        }
    }
}
