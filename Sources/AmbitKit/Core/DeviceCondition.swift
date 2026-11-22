import Foundation

/// What a device row shows about the connection to its device.
public enum DeviceCondition: Sendable, Equatable {
    /// No answer yet since the device was added or the app started.
    case loading
    case online
    /// A recent poll failed. The last reading is still shown; this is not "down".
    case stale(lastSeen: Date)
    case unreachable
    case passwordNeeded
    case wrongPassword
    /// The device refuses logins until this time.
    case lockedOut(until: Date)
    /// The device answered, but not in a way the app understands.
    case unexpectedReply
}

/// Why one poll failed.
public enum DeviceFailure: Sendable, Equatable {
    case noReply
    case passwordNeeded
    case wrongPassword
    case lockedOut(seconds: Int?)
    case unexpectedReply

    public init(starlink error: any Error) {
        switch error {
        case StarlinkError.timedOut, is URLError: self = .noReply
        default: self = .unexpectedReply
        }
    }

    public init(glinet error: any Error) {
        switch error {
        case GLiNetError.timedOut, is URLError: self = .noReply
        case GLiNetError.noPassword: self = .passwordNeeded
        case GLiNetError.wrongPassword: self = .wrongPassword
        case GLiNetError.lockedOut(let seconds): self = .lockedOut(seconds: seconds)
        default: self = .unexpectedReply
        }
    }
}

/// Turns poll results into a condition. One missed poll makes a device stale, not unreachable.
public struct DeviceHealthTracker: Sendable {
    public static let failuresUntilUnreachable = 3
    /// Shown when the device reports a lockout without saying for how long.
    public static let defaultLockout: TimeInterval = 300

    public private(set) var condition: DeviceCondition = .loading
    private var missed = 0
    private var lastSeen: Date?

    public init() {}

    public mutating func succeeded(at date: Date = Date()) {
        missed = 0
        lastSeen = date
        condition = .online
    }

    public mutating func failed(_ failure: DeviceFailure, at date: Date = Date()) {
        switch failure {
        case .noReply:
            missed += 1
            if missed >= Self.failuresUntilUnreachable {
                condition = .unreachable
            } else if let lastSeen {
                condition = .stale(lastSeen: lastSeen)
            } else if condition != .loading {
                // A device that answered with an error and then went quiet is no longer in that state.
                condition = .unreachable
            }
        case .passwordNeeded:
            missed = 0
            condition = .passwordNeeded
        case .wrongPassword:
            missed = 0
            condition = .wrongPassword
        case .lockedOut(let seconds):
            missed = 0
            // Keep the first deadline: later polls report the time that is left, not a new lockout.
            if case .lockedOut(let until) = condition, until > date { return }
            let wait = seconds.flatMap { $0 > 0 ? TimeInterval($0) : nil } ?? Self.defaultLockout
            condition = .lockedOut(until: date.addingTimeInterval(wait))
        case .unexpectedReply:
            missed = 0
            condition = .unexpectedReply
        }
    }
}
