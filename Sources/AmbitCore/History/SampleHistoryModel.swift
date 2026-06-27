import Foundation

public struct SampleHistoryRow: Equatable, Sendable {
    public var timestamp: Date
    public var result: String
    public var isFailure: Bool
    public var status: String

    public init(timestamp: Date, result: String, isFailure: Bool, status: String) {
        self.timestamp = timestamp
        self.result = result
        self.isFailure = isFailure
        self.status = status
    }
}

public enum SampleHistoryModel {
    public static func rows(
        samples: [Sample],
        descriptor: EntityDescriptor,
        limit: Int
    ) -> [SampleHistoryRow] {
        samples
            .reversed()
            .prefix(max(0, limit))
            .map { sample in
                let failed = !sample.ok || sample.value == nil
                let result: String
                if failed {
                    result = sample.metadata?.isEmpty == false ? sample.metadata! : "Failed"
                } else if let value = sample.value {
                    result = EntityReadout.format(value, deviceClass: descriptor.deviceClass, unit: descriptor.unit)
                } else {
                    result = "Failed"
                }
                return SampleHistoryRow(
                    timestamp: sample.timestamp,
                    result: result,
                    isFailure: failed,
                    status: failed ? "Failed" : "OK"
                )
            }
    }

    public static func emptyMessage(rangeLabel: String?) -> String {
        if let rangeLabel, !rangeLabel.isEmpty {
            return "No samples in the last \(rangeLabel)."
        }
        return "No samples yet."
    }
}
