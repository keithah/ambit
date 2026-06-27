import Foundation

public struct GraphAxis: Equatable, Sendable {
    public var min: Double
    public var max: Double?
    public var unitLabel: String?
    public var isFixed: Bool
    public var isEmpty: Bool

    public init(
        min: Double = 0,
        max: Double? = nil,
        unitLabel: String? = nil,
        isFixed: Bool = false,
        isEmpty: Bool = true
    ) {
        self.min = min
        self.max = max
        self.unitLabel = unitLabel
        self.isFixed = isFixed
        self.isEmpty = isEmpty
    }
}

public enum GraphAxisResolver {
    private static let mantissas: [Double] = [1, 1.5, 2, 2.5, 3, 5, 7.5, 10]

    public static func axis(
        descriptor: EntityDescriptor,
        samples: [Sample],
        currentState: EntityState?
    ) -> GraphAxis {
        if descriptor.deviceClass == .percent || descriptor.deviceClass == .battery {
            return GraphAxis(min: 0, max: 100, unitLabel: descriptor.unit, isFixed: true, isEmpty: false)
        }

        if let range = descriptor.range,
           descriptor.graphStyle == .progress || descriptor.deviceClass == .temperature || descriptor.deviceClass == .fan {
            return GraphAxis(min: range.min, max: range.max, unitLabel: descriptor.unit, isFixed: true, isEmpty: false)
        }

        var values = samples.compactMap { sample -> Double? in
            guard sample.ok else { return nil }
            return sample.value
        }
        if let currentValue = currentState?.numericValue {
            values.append(currentValue)
        }
        guard !values.isEmpty else {
            return GraphAxis(min: 0, max: nil, unitLabel: descriptor.unit, isFixed: false, isEmpty: true)
        }

        return GraphAxis(min: 0, max: niceMax(values), unitLabel: descriptor.unit, isFixed: false, isEmpty: false)
    }

    public static func niceMax(_ values: [Double]) -> Double? {
        guard let maxValue = values.max(), maxValue > 0 else { return nil }
        let exponent = (log10(maxValue)).rounded(.down)
        let base = pow(10, exponent)
        for mantissa in mantissas where mantissa * base >= maxValue {
            return mantissa * base
        }
        return 10 * base
    }
}

private extension EntityState {
    var numericValue: Double? {
        guard case .number(let value)? = self.value else { return nil }
        return value
    }
}
