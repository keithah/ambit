import AmbitCore
import Foundation
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case satisfied
        case requiresConnection
        case unsatisfied
    }

    var connectivityStatus: NetworkConnectivityStatus

    static let connected = NetworkPathSnapshot(connectivityStatus: .connected)

    static func classify(status: Status, supportsIPv4: Bool, supportsIPv6: Bool) -> NetworkPathSnapshot {
        switch status {
        case .satisfied:
            return supportsIPv4 || supportsIPv6
                ? .connected
                : NetworkPathSnapshot(connectivityStatus: .noIPAddress)
        case .requiresConnection:
            return NetworkPathSnapshot(connectivityStatus: .noInternet)
        case .unsatisfied:
            return NetworkPathSnapshot(connectivityStatus: .notConnected)
        }
    }
}

@MainActor
protocol NetworkChangeSource: AnyObject, Sendable {
    var onChange: (@MainActor @Sendable (NetworkPathSnapshot) async -> Void)? { get set }
    func start()
    func cancel()
}

@MainActor
final class NWPathNetworkChangeSource: NetworkChangeSource {
    var onChange: (@MainActor @Sendable (NetworkPathSnapshot) async -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tv.kodi.ambit.network-path")
    private var hasSeenInitialPath = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                guard self.hasSeenInitialPath else {
                    self.hasSeenInitialPath = true
                    return
                }
                await self.onChange?(Self.snapshot(from: path))
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    nonisolated private static func snapshot(from path: NWPath) -> NetworkPathSnapshot {
        let status: NetworkPathSnapshot.Status
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .requiresConnection:
            status = .requiresConnection
        case .unsatisfied:
            status = .unsatisfied
        @unknown default:
            status = .unsatisfied
        }
        return NetworkPathSnapshot.classify(status: status, supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6)
    }
}
