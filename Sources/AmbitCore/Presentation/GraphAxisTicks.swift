import Foundation

public struct GraphAxisTick: Equatable, Sendable {
    public var value: Double
    public var label: String

    public init(value: Double, label: String) {
        self.value = value
        self.label = label
    }
}

public enum GraphAxisTicks {
    public static func ticks(axis: GraphAxis, descriptor: EntityDescriptor?) -> [GraphAxisTick] {
        guard let max = axis.max else { return [] }
        let values = [max, max / 2, 0]
        return values.map { value in
            GraphAxisTick(
                value: value,
                label: EntityReadout.format(value, deviceClass: descriptor?.deviceClass, unit: descriptor?.unit ?? axis.unitLabel)
            )
        }
    }
}
