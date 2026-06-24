import Foundation

public struct PingSnapshot: Equatable, Sendable {
    public var host: String
    public var transmitted: Int?
    public var received: Int?
    public var lossPercent: Double?
    public var averageLatencyMs: Double?
    public var rawOutput: String

    public init(
        host: String,
        transmitted: Int? = nil,
        received: Int? = nil,
        lossPercent: Double? = nil,
        averageLatencyMs: Double? = nil,
        rawOutput: String = ""
    ) {
        self.host = host
        self.transmitted = transmitted
        self.received = received
        self.lossPercent = lossPercent
        self.averageLatencyMs = averageLatencyMs
        self.rawOutput = rawOutput
    }
}

public struct Iperf3Snapshot: Equatable, Sendable {
    public var host: String
    public var downloadBps: Int?
    public var uploadBps: Int?
    public var rawOutput: String
    public var ranAt: Date?

    public init(host: String, downloadBps: Int? = nil, uploadBps: Int? = nil, rawOutput: String = "", ranAt: Date? = nil) {
        self.host = host
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.rawOutput = rawOutput
        self.ranAt = ranAt
    }
}

public struct ActiveMeasurementSummary: Equatable, Identifiable, Sendable {
    public var providerID: ProviderID
    public var title: String
    public var subtitle: String
    public var health: Health
    public var primaryMetric: Metric?
    public var secondaryMetrics: [Metric]
    public var errorMessage: String?
    public var diagnostic: ProviderDiagnostic?

    public var id: ProviderID { providerID }

    public init(
        providerID: ProviderID,
        title: String,
        subtitle: String,
        health: Health,
        primaryMetric: Metric?,
        secondaryMetrics: [Metric],
        errorMessage: String? = nil,
        diagnostic: ProviderDiagnostic? = nil
    ) {
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.health = health
        self.primaryMetric = primaryMetric
        self.secondaryMetrics = secondaryMetrics
        self.errorMessage = errorMessage
        self.diagnostic = diagnostic
    }

    public static func summaries(from snapshot: StatusSnapshot) -> [ActiveMeasurementSummary] {
        [
            iperf3Summary(from: snapshot.providers[ProviderInstanceIDs.iperf3])
        ].compactMap { $0 }
    }

    private static func iperf3Summary(from state: SourceState<ProviderSnapshot>?) -> ActiveMeasurementSummary? {
        guard let state, let provider = state.value, case .iperf3(let detail) = provider.detail else { return nil }
        return ActiveMeasurementSummary(
            providerID: ProviderIDs.iperf3,
            title: "iperf3",
            subtitle: detail.host.isEmpty ? "No run yet" : detail.host,
            health: provider.health,
            primaryMetric: provider.metric("download_bps"),
            secondaryMetrics: ["upload_bps"].compactMap(provider.metric),
            errorMessage: state.errorMessage ?? provider.error,
            diagnostic: ProviderDiagnostic.make(providerID: ProviderIDs.iperf3, providerName: "iperf3", snapshot: provider)
        )
    }
}

public actor Iperf3Provider: Provider {
    public let id: ProviderID = ProviderIDs.iperf3
    public let displayName = "iperf3"
    public let typeID: ProviderTypeID = ProviderIDs.iperf3
    public let integrationID = IntegrationIDs.iperf3
    public let integrationInstanceID = IntegrationInstanceIDs.iperf3
    public let instanceID = ProviderInstanceIDs.iperf3
    public let pollInterval: TimeInterval = 3_600
    public let commands = [
        CommandDescriptor(
            id: ProviderCommandIDs.iperf3Run,
            label: "Run iperf3",
            parameters: [CommandParameter(id: "host", label: "Host", kind: .text)]
        )
    ]

    private let defaultHost: String
    private let executable: String
    private let processRunner: ProcessRunner
    private var latest: Iperf3Snapshot?

    public init(defaultHost: String = "", executable: String = "/opt/homebrew/bin/iperf3", processRunner: ProcessRunner = SystemProcessRunner()) {
        self.defaultHost = defaultHost
        self.executable = executable
        self.processRunner = processRunner
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard let latest else {
            return ProviderSnapshot(health: .unknown, metrics: [], detail: .iperf3(Iperf3Snapshot(host: defaultHost)))
        }
        return ProviderSnapshot.iperf3(latest)
    }

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard commandID == ProviderCommandIDs.iperf3Run else {
            throw JSONRPCClientError.commandFailed("Unsupported iperf3 command \(commandID).")
        }
        let host = arguments.values["host"]?.stringValue ?? defaultHost
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCClientError.commandFailed("iperf3 host is required.")
        }
        let result = try await processRunner.run(executable: executable, arguments: ["-J", "-t", "5", "-c", host], timeout: 10)
        guard result.exitCode == 0 else {
            throw JSONRPCClientError.commandFailed(result.stderr.isEmpty ? "iperf3 failed." : result.stderr)
        }
        latest = Self.parse(host: host, output: result.stdout, ranAt: Date())
    }

    public static func parse(host: String, output: String, ranAt: Date? = nil) -> Iperf3Snapshot {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.objectValue
        else {
            return Iperf3Snapshot(host: host, rawOutput: output, ranAt: ranAt)
        }

        let end = root["end"]?.objectValue ?? [:]
        let sumReceived = end["sum_received"]?.objectValue
        let sumSent = end["sum_sent"]?.objectValue
        let sum = end["sum"]?.objectValue
        return Iperf3Snapshot(
            host: host,
            downloadBps: sumReceived?["bits_per_second"]?.intValue ?? sum?["bits_per_second"]?.intValue,
            uploadBps: sumSent?["bits_per_second"]?.intValue,
            rawOutput: output,
            ranAt: ranAt
        )
    }
}

public extension ProviderSnapshot {
    static func ping(_ snapshot: PingSnapshot) -> ProviderSnapshot {
        var metrics: [Metric] = []
        if let latency = snapshot.averageLatencyMs {
            metrics.append(Metric(id: "latency_ms", label: "Latency", value: .latency(ms: latency)))
        }
        if let loss = snapshot.lossPercent {
            metrics.append(Metric(id: "loss_percent", label: "Packet Loss", value: .percent(loss)))
        }
        if let received = snapshot.received {
            metrics.append(Metric(id: "received_packets", label: "Received", value: .level(Double(received))))
        }
        let health: Health
        if let loss = snapshot.lossPercent {
            health = loss >= 100 ? .down : (loss > 0 ? .degraded : .ok)
        } else {
            health = .unknown
        }
        return ProviderSnapshot(health: health, metrics: metrics, detail: .ping(snapshot))
    }

    static func iperf3(_ snapshot: Iperf3Snapshot) -> ProviderSnapshot {
        var metrics: [Metric] = []
        if let downloadBps = snapshot.downloadBps {
            metrics.append(Metric(id: "download_bps", label: "Download", value: .throughput(bitsPerSecond: downloadBps)))
        }
        if let uploadBps = snapshot.uploadBps {
            metrics.append(Metric(id: "upload_bps", label: "Upload", value: .throughput(bitsPerSecond: uploadBps)))
        }
        let health: Health = metrics.isEmpty ? .unknown : .ok
        return ProviderSnapshot(health: health, metrics: metrics, detail: .iperf3(snapshot))
    }
}

private func firstMatch(_ string: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
    else { return [] }
    return (0..<match.numberOfRanges).compactMap { index in
        guard let range = Range(match.range(at: index), in: string) else { return nil }
        return String(string[range])
    }
}

private extension Array {
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
