import Foundation

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case unavailable
    case unknown(String)
}

public struct NotificationIntent: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var severity: Severity
    public var entityIDs: Set<EntityID>
    public var phase: AlertEventPhase
    public var triggeredAt: Date

    public init(
        id: String,
        title: String,
        body: String,
        severity: Severity,
        entityIDs: Set<EntityID>,
        phase: AlertEventPhase,
        triggeredAt: Date
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.entityIDs = entityIDs
        self.phase = phase
        self.triggeredAt = triggeredAt
    }
}

public extension NotificationIntent {
    static func testNotification(now: Date = Date()) -> NotificationIntent {
        NotificationIntent(
            id: "notification.test.\(Int(now.timeIntervalSince1970))",
            title: "Ambit test notification",
            body: "Notifications are enabled for Ambit.",
            severity: .info,
            entityIDs: [],
            phase: .active,
            triggeredAt: now
        )
    }
}

public protocol NotificationDelivering: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async -> NotificationAuthorizationStatus
    func deliver(_ intent: NotificationIntent) async throws
}

public enum NotificationSkipReason: Equatable, Sendable {
    case permissionDenied
    case permissionUnavailable
    case unresolvedTarget
}

public enum NotificationDeliveryResult: Equatable, Sendable {
    case delivered(String)
    case skipped(String, reason: NotificationSkipReason)
    case failed(String, message: String)
}

public actor AlertNotificationService {
    public init() {}

    public func requestAuthorization(using notifier: any NotificationDelivering) async -> NotificationAuthorizationStatus {
        await notifier.requestAuthorization()
    }

    public func deliver(
        _ events: [ResolvedAlertEvent],
        using notifier: any NotificationDelivering
    ) async -> [NotificationDeliveryResult] {
        guard !events.isEmpty else { return [] }
        let status = await authorizationStatus(using: notifier)
        guard status == .authorized || status == .provisional else {
            let reason: NotificationSkipReason = status == .denied ? .permissionDenied : .permissionUnavailable
            return events.map { .skipped($0.event.id, reason: reason) }
        }

        var results: [NotificationDeliveryResult] = []
        for event in events {
            guard !event.entityIDs.isEmpty else {
                results.append(.skipped(event.event.id, reason: .unresolvedTarget))
                continue
            }
            let intent = NotificationIntent(
                id: event.event.id,
                title: event.event.title,
                body: event.event.message,
                severity: event.event.severity,
                entityIDs: event.entityIDs,
                phase: event.event.phase,
                triggeredAt: event.event.triggeredAt
            )
            do {
                try await notifier.deliver(intent)
                results.append(.delivered(intent.id))
            } catch {
                results.append(.failed(intent.id, message: String(describing: error)))
            }
        }
        return results
    }

    private func authorizationStatus(using notifier: any NotificationDelivering) async -> NotificationAuthorizationStatus {
        let current = await notifier.authorizationStatus()
        if current == .notDetermined {
            return await notifier.requestAuthorization()
        }
        return current
    }
}
