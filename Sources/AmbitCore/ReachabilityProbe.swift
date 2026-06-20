import Foundation
import Network

public protocol ReachabilityProbeProtocol: Sendable {
    func probe() async -> ReachabilityStatus
}

public struct ReachabilityProbe: ReachabilityProbeProtocol {
    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL = URL(string: "https://www.gstatic.com/generate_204")!, timeout: TimeInterval = 3) {
        self.url = url
        self.timeout = timeout
    }

    public func probe() async -> ReachabilityStatus {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(started)
            if let http = response as? HTTPURLResponse, http.statusCode == 204 || (200..<400).contains(http.statusCode) {
                return ReachabilityStatus(hasNetworkPath: true, state: .online(latency: latency))
            }
        } catch {
            return ReachabilityStatus(hasNetworkPath: false, state: .offline)
        }
        return ReachabilityStatus(hasNetworkPath: true, state: .offline)
    }
}
