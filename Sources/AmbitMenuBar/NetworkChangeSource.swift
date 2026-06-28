import Foundation
import Network

@MainActor
protocol NetworkChangeSource: AnyObject, Sendable {
    var onChange: (@MainActor @Sendable () async -> Void)? { get set }
    func start()
    func cancel()
}

@MainActor
final class NWPathNetworkChangeSource: NetworkChangeSource {
    var onChange: (@MainActor @Sendable () async -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tv.kodi.ambit.network-path")
    private var hasSeenInitialPath = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.hasSeenInitialPath else {
                    self.hasSeenInitialPath = true
                    return
                }
                await self.onChange?()
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
