import AmbitKit
import AppKit
import Observation
import SwiftUI
import UserNotifications

struct StarlinkReading: Equatable {
    var condition = DeviceCondition.loading
    var status: StarlinkStatus?
}

struct RouterReading: Equatable {
    var condition = DeviceCondition.loading
    var status: GLiNetStatus?
    var vpn: GLiNetVPN?
    /// False until a VPN read has succeeded, so "no VPN" is not shown for a failed read.
    var vpnKnown = false
}

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = DiagnosisSnapshot()
    private(set) var devices: [SavedDevice] = []
    private(set) var dishes: [UUID: StarlinkReading] = [:]
    private(set) var routers: [UUID: RouterReading] = [:]
    /// Goes up each time the popover closes, so the popover opens on its first page again.
    private(set) var popoverClosures = 0
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let monitor = DiagnosisMonitor()
    @ObservationIgnored private var alerts = ConnectionAlerts()
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    @ObservationIgnored private let deviceFile = try? DeviceListFile.standard()
    /// False when the saved list could not be read: saving then would replace it.
    @ObservationIgnored private var canSaveDevices = false
    /// The number of the latest poll started for each device. An older poll's result is dropped.
    @ObservationIgnored private var latestPoll: [UUID: Int] = [:]
    @ObservationIgnored private let passwords = PasswordStore()
    @ObservationIgnored private var polls: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var trackers: [UUID: DeviceHealthTracker] = [:]
    @ObservationIgnored private var dishClients: [UUID: StarlinkClient] = [:]
    @ObservationIgnored private var routerClients: [UUID: GLiNetClient] = [:]

    /// Short readout for the menu bar: latency when online, otherwise the failing hop.
    var menuBarText: String {
        switch snapshot.verdict {
        case .checking: "…"
        case .online, .internetSlow, .wifiSlow:
            snapshot.internet.lastMs.map { "\(Int($0.rounded())) ms" } ?? "…"
        case .noNetwork: "No network"
        case .routerUnreachable: "Router"
        case .internetDown, .connectionDown: "Offline"
        case .dnsFailing: "DNS"
        }
    }

    func start() {
        // Without an activity assertion App Nap throttles the timer of a UI-less app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Monitoring the connection"
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [monitor] _ in
            Task { await monitor.runCycle() }
        }
        if let deviceFile, let saved = try? deviceFile.load() {
            devices = saved
            canSaveDevices = true
        }
        devices.forEach(startPolling)
        Task { [weak self, monitor] in
            await monitor.start()
            for await next in await monitor.snapshots() {
                self?.apply(next)
            }
        }
    }

    private func apply(_ next: DiagnosisSnapshot) {
        snapshot = next
        onChange?()
        if let message = alerts.evaluate(verdict: next.verdict) {
            Notifier.deliver(message)
        }
    }
}

// MARK: Devices

extension AppModel {
    private static let dishInterval: Duration = .seconds(5)
    private static let routerInterval: Duration = .seconds(10)

    /// Adds a device and starts reading it. Returns a sentence for the user if it could not.
    func add(kind: DeviceKind, host rawHost: String, password: String?) -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !devices.contains(where: { $0.kind == kind && $0.host == host }) else { return "That device is already added." }
        let device: SavedDevice
        switch kind {
        case .starlink:
            guard (try? StarlinkClient(host: host)) != nil else { return "That is not an address Ambit can use." }
            device = SavedDevice(kind: kind, name: "Starlink", host: host)
        case .glinet:
            guard (try? GLiNetClient(host: host, password: { nil })) != nil else { return "That is not an address Ambit can use." }
            device = SavedDevice(kind: kind, name: "Router", host: host)
        }
        if let password, !password.isEmpty {
            do { try passwords.set(password, for: device.id) } catch { return "Couldn't save the password in your Keychain." }
        }
        guard save(devices + [device]) else {
            try? passwords.remove(for: device.id)
            return "Couldn't save the device list."
        }
        startPolling(device)
        return nil
    }

    func popoverDidClose() {
        popoverClosures += 1
    }

    /// Returns a sentence for the user if the device could not be removed.
    func remove(_ id: UUID) -> String? {
        guard save(devices.filter { $0.id != id }) else { return "Couldn't save the device list." }
        polls.removeValue(forKey: id)?.cancel()
        trackers[id] = nil
        latestPoll[id] = nil
        dishClients[id] = nil
        routerClients[id] = nil
        dishes[id] = nil
        routers[id] = nil
        // If this fails the password stays in the Keychain under an ID nothing uses any more.
        try? passwords.remove(for: id)
        return nil
    }

    func setPassword(_ password: String, for id: UUID) async -> String? {
        do { try passwords.set(password, for: id) } catch { return "Couldn't save the password in your Keychain." }
        await pollRouter(id)
        return nil
    }

    /// Devices on the network that are not added yet.
    func discover() async -> [FoundDevice] {
        // The diagnosis may not have found the router yet when the page opens.
        var gateway = snapshot.gateway
        if gateway == nil { gateway = try? await RouteGatewayFinder().defaultGateway() }
        return await Discovery.find(gateway: gateway).filter { found in
            !devices.contains { $0.kind == found.kind && $0.host == found.host }
        }
    }

    func rebootDish(_ id: UUID) async -> String? {
        await dishCommand(id) { try await $0.reboot() }
    }

    func setDishStowed(_ stowed: Bool, _ id: UUID) async -> String? {
        await dishCommand(id) { try await $0.setStowed(stowed) }
    }

    func setVPN(on: Bool, _ id: UUID) async -> String? {
        guard let client = routerClients[id] else { return "This device is no longer in Ambit." }
        do {
            try await client.setVPN(on: on)
        } catch {
            return "The router did not switch the VPN. Check that you're on its network."
        }
        await pollRouter(id)
        return nil
    }

    private func dishCommand(_ id: UUID, _ command: (StarlinkClient) async throws -> Void) async -> String? {
        guard let client = dishClients[id] else { return "This device is no longer in Ambit." }
        do {
            try await command(client)
        } catch {
            return "The dish did not accept that. Check that you're on its network."
        }
        await pollDish(id)
        return nil
    }

    private func save(_ next: [SavedDevice]) -> Bool {
        guard canSaveDevices, let deviceFile, (try? deviceFile.save(next)) != nil else { return false }
        devices = next
        return true
    }

    private func startPolling(_ device: SavedDevice) {
        let id = device.id
        trackers[id] = DeviceHealthTracker()
        switch device.kind {
        case .starlink:
            dishes[id] = StarlinkReading()
            guard let client = try? StarlinkClient(host: device.host) else {
                dishes[id]?.condition = .unreachable
                return
            }
            dishClients[id] = client
            polls[id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollDish(id)
                    try? await Task.sleep(for: Self.dishInterval)
                }
            }
        case .glinet:
            routers[id] = RouterReading()
            let passwords = passwords
            guard let client = try? GLiNetClient(host: device.host, password: { passwords.password(for: id) }) else {
                routers[id]?.condition = .unreachable
                return
            }
            routerClients[id] = client
            polls[id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollRouter(id)
                    try? await Task.sleep(for: Self.routerInterval)
                }
            }
        }
    }

    private func startPoll(_ id: UUID) -> Int {
        let poll = (latestPoll[id] ?? 0) + 1
        latestPoll[id] = poll
        return poll
    }

    private func pollDish(_ id: UUID) async {
        guard let client = dishClients[id] else { return }
        let poll = startPoll(id)
        do {
            let status = try await client.status()
            guard dishes[id] != nil, latestPoll[id] == poll else { return }
            trackers[id]?.succeeded()
            dishes[id] = StarlinkReading(condition: .online, status: status)
        } catch is CancellationError {
            return
        } catch {
            guard dishes[id] != nil, latestPoll[id] == poll else { return }
            trackers[id]?.failed(DeviceFailure(starlink: error))
            dishes[id]?.condition = trackers[id]?.condition ?? .unreachable
        }
    }

    private func pollRouter(_ id: UUID) async {
        guard let client = routerClients[id] else { return }
        let poll = startPoll(id)
        do {
            let status = try await client.status()
            var vpn: GLiNetVPN?
            var vpnRead = true
            do { vpn = try await client.vpn() } catch { vpnRead = false }
            guard let last = routers[id], latestPoll[id] == poll else { return }
            trackers[id]?.succeeded()
            // A failed VPN read keeps the last known state instead of hiding the switch.
            routers[id] = vpnRead
                ? RouterReading(condition: .online, status: status, vpn: vpn, vpnKnown: true)
                : RouterReading(condition: .online, status: status, vpn: last.vpn, vpnKnown: last.vpnKnown)
        } catch is CancellationError {
            return
        } catch {
            guard routers[id] != nil, latestPoll[id] == poll else { return }
            trackers[id]?.failed(DeviceFailure(glinet: error))
            routers[id]?.condition = trackers[id]?.condition ?? .unreachable
        }
    }
}

enum Notifier {
    static func deliver(_ message: AlertMessage) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

extension Health {
    var color: Color {
        switch self {
        case .unknown: .secondary
        case .online: .green
        case .degraded: .orange
        case .offline: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .unknown: .secondaryLabelColor
        case .online: .systemGreen
        case .degraded: .systemOrange
        case .offline: .systemRed
        }
    }
}
