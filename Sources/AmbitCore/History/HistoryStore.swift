import Foundation

/// Persistence behind the shared history engine — swappable and behavior-tested (retention /
/// range / persistence), not pinned to a backend. Keyed by EntityID + timestamp.
public protocol HistoryStore: Sendable {
    func append(_ sample: Sample, for id: EntityID) async
    func samples(_ id: EntityID, since: Date, limit: Int) async -> [Sample]
    func prune(olderThan cutoff: Date) async
}

/// In-memory store (tests, and the Engine's default when no persistent store is configured).
public actor InMemoryHistoryStore: HistoryStore {
    private var series: [EntityID: [Sample]] = [:]

    public init() {}

    public func append(_ sample: Sample, for id: EntityID) {
        series[id, default: []].append(sample)
    }

    public func samples(_ id: EntityID, since: Date, limit: Int) -> [Sample] {
        let kept = (series[id] ?? []).filter { $0.timestamp >= since }
        return kept.suffix(limit)
    }

    public func prune(olderThan cutoff: Date) {
        for (id, samples) in series {
            series[id] = samples.filter { $0.timestamp >= cutoff }
        }
    }
}
