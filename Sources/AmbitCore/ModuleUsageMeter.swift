import Foundation

public enum ModuleUsageOperation: String, Equatable, Sendable {
    case poll
    case command
}

public struct ModuleUsageSnapshot: Equatable, Sendable {
    public var providerID: ProviderID
    public var pollCount: Int
    public var commandCount: Int
    public var failureCount: Int
    public var totalDuration: TimeInterval
    public var lastOperation: ModuleUsageOperation?
    public var lastError: String?
    public var lastUpdated: Date?

    public init(
        providerID: ProviderID,
        pollCount: Int = 0,
        commandCount: Int = 0,
        failureCount: Int = 0,
        totalDuration: TimeInterval = 0,
        lastOperation: ModuleUsageOperation? = nil,
        lastError: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.providerID = providerID
        self.pollCount = pollCount
        self.commandCount = commandCount
        self.failureCount = failureCount
        self.totalDuration = totalDuration
        self.lastOperation = lastOperation
        self.lastError = lastError
        self.lastUpdated = lastUpdated
    }
}

public actor ModuleUsageMeter {
    private var snapshots: [ProviderID: ModuleUsageSnapshot] = [:]

    public init() {}

    public func record(
        providerID: ProviderID,
        operation: ModuleUsageOperation,
        duration: TimeInterval,
        error: String? = nil,
        at date: Date = Date()
    ) {
        var snapshot = snapshots[providerID] ?? ModuleUsageSnapshot(providerID: providerID)
        switch operation {
        case .poll:
            snapshot.pollCount += 1
        case .command:
            snapshot.commandCount += 1
        }
        if error != nil {
            snapshot.failureCount += 1
        }
        snapshot.totalDuration += max(0, duration)
        snapshot.lastOperation = operation
        snapshot.lastError = error
        snapshot.lastUpdated = date
        snapshots[providerID] = snapshot
    }

    public func snapshot(providerID: ProviderID) -> ModuleUsageSnapshot? {
        snapshots[providerID]
    }

    public func allSnapshots() -> [ProviderID: ModuleUsageSnapshot] {
        snapshots
    }
}
