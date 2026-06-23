import Foundation
import AmbitCore

// Bridges the shared HistoryService to a graph card: given an entity + range, return the
// sample window the View plots. Keeps HistoryService access in one tested place.
public enum HistoryGraphLoader {
    public static func samples(for id: EntityID, range: GraphRange, from history: HistoryService, now: Date = Date()) async -> [Sample] {
        await history.samples(id, since: now.addingTimeInterval(-range.seconds))
    }
}
