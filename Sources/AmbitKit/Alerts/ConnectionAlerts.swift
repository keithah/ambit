import Foundation

public struct AlertMessage: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Turns verdict changes into at most one "offline" and one "back online" alert per outage.
/// Offline must be sustained for `offlineAfter` seconds before anything is sent.
public struct ConnectionAlerts: Sendable {
    public var offlineAfter: TimeInterval
    /// A longer silence between evaluations (sleep, a stopped monitor) breaks continuity: the
    /// outage clock restarts instead of counting time nobody was watching.
    public var maxGap: TimeInterval
    private var lastEvaluation: Date?
    private var offlineSince: Date?
    private var announcedVerdict: Verdict?

    public init(offlineAfter: TimeInterval = 30, maxGap: TimeInterval = 20) {
        self.offlineAfter = offlineAfter
        self.maxGap = maxGap
    }

    public mutating func evaluate(verdict: Verdict, now: Date = Date()) -> AlertMessage? {
        if let last = lastEvaluation, now.timeIntervalSince(last) > maxGap, announcedVerdict == nil {
            offlineSince = nil
        }
        lastEvaluation = now
        switch verdict.health {
        case .offline:
            let since = offlineSince ?? now
            offlineSince = since
            guard announcedVerdict == nil, now.timeIntervalSince(since) >= offlineAfter else { return nil }
            announcedVerdict = verdict
            return AlertMessage(title: verdict.title, body: verdict.detail)
        case .online, .degraded:
            let outageStart = offlineSince
            offlineSince = nil
            guard announcedVerdict != nil else { return nil }
            announcedVerdict = nil
            let seconds = Int(now.timeIntervalSince(outageStart ?? now).rounded())
            return AlertMessage(title: "Back online", body: "The outage lasted \(Self.duration(seconds)).")
        case .unknown:
            return nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }
}
