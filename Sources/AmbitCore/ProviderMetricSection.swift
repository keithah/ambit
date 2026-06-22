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

        // Grouping reads the metric's declared classification (entity-model.md §6); the
        // old metric.id.contains("battery"/"power") substring heuristic is gone. When a
        // metric carries no deviceClass, fall back to its value shape.
        static func category(for metric: Metric) -> Category {
            if let deviceClass = metric.deviceClass {
                switch deviceClass {
                case .throughput, .latency, .connectivity:
                    return .network
                case .battery, .power:
                    return .power
                case .percent, .count, .duration:
                    return inferred(from: metric.value)
                }
            }
            return inferred(from: metric.value)
        }

        private static func inferred(from value: MetricValue) -> Category {
            switch value {
            case .latency, .throughput, .percent:
                return .network
            case .bool, .text:
                return .state
            case .level:
                return .other
            }
        }
    }
}
