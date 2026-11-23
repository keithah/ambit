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
    /// True while VPN reads fail and `vpn` is what the router said earlier.
    var vpnIsOld = false
}

struct PingReading: Equatable {
    var condition = DeviceCondition.loading
    /// The last half hour, oldest first. A sample without a latency got no reply.
    var samples: [ProbeSample] = []
}

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = DiagnosisSnapshot()
    private(set) var devices: [SavedDevice] = []
    private(set) var dishes: [UUID: StarlinkReading] = [:]
    private(set) var routers: [UUID: RouterReading] = [:]
    private(set) var pings: [UUID: PingReading] = [:]
    /// Goes up each time the popover closes, so the popover opens on its first page again.
    private(set) var popoverClosures = 0
    /// Devices with a command under way. Their command buttons are disabled meanwhile.
    private(set) var busy: Set<UUID> = []
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
    /// Nil when the history file cannot be used: graphs then show this run only.
    @ObservationIgnored private let history = try? HistoryStore.standard()
    @ObservationIgnored private let pingProbe = ICMPProbe()
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
        Task { [weak self, monitor, history] in
            let earlier = try? await history?.samples(
                device: HistoryStore.connection, series: Self.latencySeries, since: Date().addingTimeInterval(-Self.graphSpan)
            )
            await monitor.seed(history: earlier ?? [])
            await monitor.start()
            for await next in await monitor.snapshots() {
                self?.apply(next)
            }
        }
    }

    private func apply(_ next: DiagnosisSnapshot) {
        // Each probe cycle adds one sample; a snapshot without a new cycle adds none.
        if next.updated != nil, next.updated != snapshot.updated, let sample = next.internetHistory.last {
            record(sample, device: HistoryStore.connection)
        }
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
    private static let pingInterval: Duration = .seconds(5)
    static let latencySeries = "latency"
    /// How far back the short graph goes.
    static let graphSpan: TimeInterval = 1_800
    private static let samplesKept = 360

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
        case .ping:
            guard ProbeTarget.isValidHost(host) else { return "That is not an address Ambit can ping." }
            device = SavedDevice(kind: kind, name: host, host: host)
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
        // The password goes first. Once the device is off the list nothing remembers its ID, so a
        // password left behind could never be removed. If the list then cannot be saved, the device
        // stays and asks for its password again.
        do { try passwords.remove(for: id) } catch { return "Couldn't remove the password from your Keychain." }
        guard save(devices.filter { $0.id != id }) else { return "Couldn't save the device list." }
        polls.removeValue(forKey: id)?.cancel()
        trackers[id] = nil
        latestPoll[id] = nil
        dishClients[id] = nil
        routerClients[id] = nil
        dishes[id] = nil
        routers[id] = nil
        pings[id] = nil
        if let history {
            Task { try? await history.remove(device: id.uuidString) }
        }
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
        guard busy.insert(id).inserted else { return nil }
        defer { busy.remove(id) }
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
        guard busy.insert(id).inserted else { return nil }
        defer { busy.remove(id) }
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
        case .ping:
            pings[id] = PingReading()
            let host = device.host
            polls[id] = Task { [weak self, history] in
                let earlier = try? await history?.samples(
                    device: id.uuidString, series: Self.latencySeries, since: Date().addingTimeInterval(-Self.graphSpan)
                )
                if let earlier, let self, self.pings[id]?.samples.isEmpty == true {
                    self.pings[id]?.samples = Array(earlier.suffix(Self.samplesKept))
                }
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollPing(id, host: host)
                    try? await Task.sleep(for: Self.pingInterval)
                }
            }
        }
    }

    /// Half-hour buckets are too coarse and one-minute ones too many for a graph this wide.
    private static let dayBucket = 300

    /// The last 24 hours of a graph, one point for each five minutes that has samples.
    /// `device` is nil for the connection itself.
    func dayHistory(device: UUID?) async -> [ProbeSample] {
        let buckets = try? await history?.buckets(
            device: device?.uuidString ?? HistoryStore.connection, series: Self.latencySeries,
            since: Date().addingTimeInterval(-86_400), seconds: Self.dayBucket
        )
        return (buckets ?? []).map(\.sample)
    }

    private func record(_ sample: ProbeSample, device: String) {
        guard let history else { return }
        Task { try? await history.record(device: device, series: Self.latencySeries, sample: sample) }
    }

    private func pollPing(_ id: UUID, host: String) async {
        let sample = await pingProbe.measure(ProbeTarget(host: host, timeout: 2))
        // The target may have been removed while the ping was out.
        guard pings[id] != nil, !Task.isCancelled else { return }
        if sample.succeeded { trackers[id]?.succeeded() } else { trackers[id]?.failed(.noReply) }
        pings[id]?.condition = trackers[id]?.condition ?? .unreachable
        pings[id]?.samples.append(sample)
        if let count = pings[id]?.samples.count, count > Self.samplesKept {
            pings[id]?.samples.removeFirst(count - Self.samplesKept)
        }
        record(sample, device: id.uuidString)
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
                : RouterReading(condition: .online, status: status, vpn: last.vpn, vpnKnown: last.vpnKnown, vpnIsOld: last.vpnKnown)
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
