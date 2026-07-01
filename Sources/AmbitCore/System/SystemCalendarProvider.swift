import Foundation

#if canImport(EventKit)
@preconcurrency import EventKit
#endif

public struct SystemCalendarSnapshot: Equatable, Sendable {
    public var permission: SystemSignalPermission
    public var isBusy: Bool?
    public var currentEventTitle: String?
    public var nextEventStartsIn: TimeInterval?

    public init(
        permission: SystemSignalPermission,
        isBusy: Bool? = nil,
        currentEventTitle: String? = nil,
        nextEventStartsIn: TimeInterval? = nil
    ) {
        self.permission = permission
        self.isBusy = isBusy
        self.currentEventTitle = currentEventTitle
        self.nextEventStartsIn = nextEventStartsIn
    }
}

public protocol SystemCalendarReading: Sendable {
    func snapshot() async -> SystemCalendarSnapshot
}

public struct DarwinSystemCalendarReader: SystemCalendarReading {
    public init() {}

    public func snapshot() async -> SystemCalendarSnapshot {
        #if canImport(EventKit)
        let store = EKEventStore()
        let status = await Self.authorizedStatus(store: store)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            break
        case .notDetermined:
            return SystemCalendarSnapshot(permission: .notDetermined)
        case .denied:
            return SystemCalendarSnapshot(permission: .denied)
        case .restricted:
            return SystemCalendarSnapshot(permission: .restricted)
        @unknown default:
            return SystemCalendarSnapshot(permission: .unavailable)
        }

        let now = Date()
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 60 * 60), end: horizon, calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        let current = events
            .filter { $0.startDate <= now && $0.endDate > now }
            .sorted { $0.endDate < $1.endDate }
            .first
        let next = events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
        return SystemCalendarSnapshot(
            permission: .authorized,
            isBusy: current != nil,
            currentEventTitle: current?.title,
            nextEventStartsIn: next.map { max(0, $0.startDate.timeIntervalSince(now)) }
        )
        #else
        return SystemCalendarSnapshot(permission: .unavailable)
        #endif
    }

    #if canImport(EventKit)
    private static func authorizedStatus(store: EKEventStore) async -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .notDetermined else { return status }
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        return granted ? EKEventStore.authorizationStatus(for: .event) : .denied
    }
    #endif
}

public struct SystemCalendarProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemCalendar
    public let displayName = "Calendar"
    public let typeID: ProviderTypeID = "calendar"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemCalendar
    public let pollInterval: TimeInterval

    private let reader: any SystemCalendarReading

    public init(reader: any SystemCalendarReading = DarwinSystemCalendarReader(), pollInterval: TimeInterval = 60) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        [
            EntityDescriptor(
                id: instanceID.entity("busy"),
                instanceID: instanceID,
                name: "Calendar Busy",
                kind: .binarySensor,
                category: .primary,
                capability: "system.calendar",
                access: .read,
                metricID: "busy",
                defaultVisibility: .auto
            ),
            EntityDescriptor(
                id: instanceID.entity("current_event_title"),
                instanceID: instanceID,
                name: "Current Event",
                kind: .text,
                category: .primary,
                capability: "system.calendar",
                access: .read,
                metricID: "current_event_title",
                defaultVisibility: .auto
            ),
            EntityDescriptor(
                id: instanceID.entity("next_event_starts_in"),
                instanceID: instanceID,
                name: "Next Event Starts In",
                kind: .sensor,
                deviceClass: .duration,
                category: .primary,
                capability: "system.calendar",
                access: .read,
                unit: "s",
                stateClass: .measurement,
                metricID: "next_event_starts_in",
                defaultVisibility: .auto
            )
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let snapshot = await reader.snapshot()
        guard snapshot.permission.canRead else {
            return ProviderSnapshot(health: .ok)
        }
        var metrics: [Metric] = []
        if let isBusy = snapshot.isBusy {
            metrics.append(Metric(id: "busy", label: "Calendar Busy", value: .bool(isBusy), capability: "system.calendar"))
        }
        if let title = snapshot.currentEventTitle, !title.isEmpty {
            metrics.append(Metric(id: "current_event_title", label: "Current Event", value: .text(title), capability: "system.calendar"))
        }
        if let nextEventStartsIn = snapshot.nextEventStartsIn {
            metrics.append(Metric(
                id: "next_event_starts_in",
                label: "Next Event Starts In",
                value: .level(nextEventStartsIn),
                deviceClass: .duration,
                capability: "system.calendar"
            ))
        }
        return ProviderSnapshot(health: .ok, metrics: metrics)
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
