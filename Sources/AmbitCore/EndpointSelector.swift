import Foundation

public protocol EndpointProber: Sendable {
    func challenge(host: String, username: String) async -> Bool
}

public protocol RouterAddressDiscovery: Sendable {
    func defaultGatewayHost() async -> String?
}

public struct SystemRouterAddressDiscovery: RouterAddressDiscovery {
    public init() {}

    public func defaultGatewayHost() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Self.parseDefaultGateway(from: output)
    }

    static func parseDefaultGateway(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gateway:") else { continue }
            return trimmed
                .dropFirst("gateway:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

public struct RouterEndpointProber: EndpointProber {
    private let transport: RouterTransport

    public init(transport: RouterTransport = URLSessionRouterTransport()) {
        self.transport = transport
    }

    public func challenge(host: String, username: String) async -> Bool {
        guard let url = URL.routerRPC(host: host) else { return false }
        do {
            let request = JSONRPCRequest.challenge(id: 0, username: username)
            let data = try await transport.send(request, to: url)
            _ = try JSONDecoder().decode(JSONRPCResponse<JSONObject>.self, from: data).value()
            return true
        } catch {
            return false
        }
    }
}

public struct EndpointSelector: Sendable {
    private let prober: EndpointProber
    private let addressDiscovery: RouterAddressDiscovery
    private let fallbackLocalHosts = ["192.168.8.1"]

    public init(
        prober: EndpointProber = RouterEndpointProber(),
        addressDiscovery: RouterAddressDiscovery = SystemRouterAddressDiscovery()
    ) {
        self.prober = prober
        self.addressDiscovery = addressDiscovery
    }

    public func select(settings: AppSettings) async throws -> EndpointSelection {
        switch settings.endpointMode {
        case .forceLocal:
            return EndpointSelection(mode: .local, host: try await forcedLocalHost(from: settings))
        case .forceRemote:
            return EndpointSelection(mode: .remote, host: settings.remoteHost)
        case .auto:
            return try await race(settings: settings)
        }
    }

    private func race(settings: AppSettings) async throws -> EndpointSelection {
        let locals = await localCandidates(from: settings)
        let candidates: [(EndpointSelectionMode, String)] = locals.map { (.local, $0) } + [
            (.remote, settings.remoteHost)
        ].filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return try await withThrowingTaskGroup(of: EndpointSelection?.self) { group in
            for (mode, host) in candidates {
                group.addTask {
                    await prober.challenge(host: host, username: settings.username) ? EndpointSelection(mode: mode, host: host) : nil
                }
            }
            for try await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            throw JSONRPCClientError.commandFailed("Neither local nor remote router endpoint answered challenge.")
        }
    }

    private func forcedLocalHost(from settings: AppSettings) async throws -> String {
        let candidates = await localCandidates(from: settings)
        for host in candidates {
            if await prober.challenge(host: host, username: settings.username) {
                return host
            }
        }
        if let first = candidates.first {
            return first
        }
        throw JSONRPCClientError.commandFailed("Could not discover the local router gateway.")
    }

    private func localCandidates(from settings: AppSettings) async -> [String] {
        let configured = settings.localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, configured.localizedCaseInsensitiveCompare("auto") != .orderedSame {
            return [configured]
        }
        var candidates: [String] = []
        if let discovered = await addressDiscovery.defaultGatewayHost(), !discovered.isEmpty {
            candidates.append(discovered)
        }
        candidates.append(contentsOf: fallbackLocalHosts)
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }
}

public extension URL {
    static func routerRPC(host: String) -> URL? {
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            return URL(string: host.hasSuffix("/rpc") ? host : "\(host)/rpc")
        }
        return URL(string: "http://\(host)/rpc")
    }
}
