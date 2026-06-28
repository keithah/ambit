import AmbitCore
import Foundation
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    var connectivityStatus: NetworkConnectivityStatus

    static let connected = NetworkPathSnapshot(connectivityStatus: .connected)
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
        switch path.status {
        case .satisfied:
            return .connected
        case .requiresConnection:
            return NetworkPathSnapshot(connectivityStatus: .noInternet)
        case .unsatisfied:
            return NetworkPathSnapshot(connectivityStatus: .notConnected)
        @unknown default:
            return NetworkPathSnapshot(connectivityStatus: .notConnected)
        }
    }
}
