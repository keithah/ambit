import Foundation

// Generic time-series primitives (shaped by pingscope, reusable by every integration). A
// Sample is the universal sparkline axis: a timestamp + an optional numeric value + a
// success flag, with optional opaque metadata for richer per-integration detail.

public struct Sample: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var value: Double?      // nil ⇒ no measurement (failure / unavailable)
    public var ok: Bool            // success flag (drives loss accounting)
    public var metadata: String?   // opaque per-integration detail (e.g. failure reason)

    public init(timestamp: Date, value: Double? = nil, ok: Bool = true, metadata: String? = nil) {
        self.timestamp = timestamp
        self.value = value
        self.ok = ok
        self.metadata = metadata
    }
}

public struct SampleStats: Equatable, Sendable {
    public var transmitted: Int
    public var received: Int
    public var lossPercent: Double
    public var min: Double?
    public var avg: Double?
    public var max: Double?

    public init(transmitted: Int = 0, received: Int = 0, lossPercent: Double = 0, min: Double? = nil, avg: Double? = nil, max: Double? = nil) {
        self.transmitted = transmitted
        self.received = received
        self.lossPercent = lossPercent
        self.min = min
        self.avg = avg
        self.max = max
    }

    public static func from(_ samples: [Sample]) -> SampleStats {
        let transmitted = samples.count
        let values = samples.filter { $0.ok && $0.value != nil }.map { $0.value! }
        let received = values.count
        let loss = transmitted == 0 ? 0 : Double(transmitted - received) / Double(transmitted) * 100
        guard received > 0 else {
            return SampleStats(transmitted: transmitted, received: 0, lossPercent: loss)
        }
        return SampleStats(
            transmitted: transmitted,
            received: received,
            lossPercent: loss,
            min: values.min(),
            avg: values.reduce(0, +) / Double(received),
            max: values.max()
        )
    }
}

/// A bounded, ordered in-memory window of recent samples (oldest dropped past capacity).
public struct SampleSeries: Equatable, Sendable {
    public private(set) var samples: [Sample]
    public let capacity: Int

    public init(capacity: Int = 300) {
        self.capacity = Swift.max(1, capacity)
        self.samples = []
    }

    public mutating func append(_ sample: Sample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func stats() -> SampleStats { SampleStats.from(samples) }
}
