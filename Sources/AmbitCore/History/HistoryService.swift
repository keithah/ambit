import Foundation

/// The single shared, EntityID-keyed history engine. The Engine feeds it automatically from
/// every integration's stateClass-bearing entities; consumers (pingscope graph/stats, future
/// sparklines) read from it. Retention-managed: prunes on a throttled cadence as samples
/// arrive. Backed by a swappable HistoryStore (in-memory or SQLite).
public actor HistoryService {
    public static let defaultRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private let store: any HistoryStore
    private let retention: TimeInterval
    private let pruneInterval: TimeInterval
    private var lastPrune: Date?

    public init(store: any HistoryStore = InMemoryHistoryStore(), retention: TimeInterval = HistoryService.defaultRetentionInterval, pruneInterval: TimeInterval = 60) {
        self.store = store
        self.retention = retention
        self.pruneInterval = pruneInterval
    }

    public func record(_ sample: Sample, for id: EntityID) async {
        await store.append(sample, for: id)
        await pruneIfNeeded(now: sample.timestamp)
    }

    public func samples(_ id: EntityID, since: Date, limit: Int = 10_000) async -> [Sample] {
        await store.samples(id, since: since, limit: limit)
    }

    public func stats(_ id: EntityID, since: Date) async -> SampleStats {
        SampleStats.from(await store.samples(id, since: since, limit: 10_000))
    }

    public func prune(now: Date) async {
        await store.prune(olderThan: now.addingTimeInterval(-retention))
        lastPrune = now
    }

    /// Remove all recorded samples.
    public func clear() async {
        await store.prune(olderThan: .distantFuture)
    }

    public var retentionInterval: TimeInterval { retention }

    private func pruneIfNeeded(now: Date) async {
        if let lastPrune, now.timeIntervalSince(lastPrune) < pruneInterval { return }
        await prune(now: now)
    }
}
