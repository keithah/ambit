import Foundation

public struct AlertFiringState: Equatable, Sendable {
    private var lastSent: [String: Date] = [:]

    public init() {}

    public mutating func fire(_ key: String, cooldown: TimeInterval, now: Date) -> Bool {
        if let last = lastSent[key], now.timeIntervalSince(last) < cooldown { return false }
        lastSent[key] = now
        return true
    }
}
