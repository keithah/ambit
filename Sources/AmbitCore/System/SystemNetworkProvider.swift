import Foundation

public actor SystemNetworkProvider: Provider {
    public nonisolated let id: ProviderID = ProviderIDs.systemNetwork
    public nonisolated let displayName = "System Network"
    public nonisolated let typeID: ProviderTypeID = "network"
    public nonisolated let integrationID = IntegrationIDs.system
    public nonisolated let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public nonisolated let instanceID = ProviderInstanceIDs.systemNetwork
    public nonisolated let pollInterval: TimeInterval

    private let reader: any SystemMetricsReading
    private let clock: @Sendable () -> Date
    private var previous: PreviousCounters?

    public init(
        reader: any SystemMetricsReading = DarwinSystemMetricsReader(),
        pollInterval: TimeInterval = 2,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.pollInterval = pollInterval
        self.clock = clock
    }

    public nonisolated func entityDescriptors() -> [EntityDescriptor] {
        [
            EntityDescriptor(
                id: instanceID.entity("throughput_in"),
                instanceID: instanceID,
                name: "Network In",
                kind: .sensor,
                deviceClass: .throughput,
                category: .primary,
                capability: "system.network",
                access: .read,
                unit: "bps",
                stateClass: .measurement,
                metricID: "throughput_in",
                defaultVisibility: .auto,
                graphStyle: .sparkline,
                isPrimary: true
            ),
            EntityDescriptor(
                id: instanceID.entity("throughput_out"),
                instanceID: instanceID,
                name: "Network Out",
                kind: .sensor,
                deviceClass: .throughput,
                category: .primary,
                capability: "system.network",
                access: .read,
                unit: "bps",
                stateClass: .measurement,
                metricID: "throughput_out",
                defaultVisibility: .auto,
                graphStyle: .sparkline
            ),
            EntityDescriptor(
                id: instanceID.entity("interfaces"),
                instanceID: instanceID,
                name: "Interfaces",
                kind: .table,
                category: .primary,
                capability: "system.network",
                access: .read,
                metricID: "interfaces",
                defaultVisibility: .auto
            )
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let now = clock()
            let snapshot = try await reader.snapshot()
            let current = countersByInterface(snapshot.networkCounters)
            let rates = previous.flatMap { ratesByInterface(previous: $0, current: current, now: now) } ?? [:]
            previous = PreviousCounters(timestamp: now, counters: current)

            var metrics = [
                Metric(id: "interfaces", label: "Interfaces", value: .table(Self.table(from: snapshot.networkCounters, rates: rates)))
            ]
            if let aggregateIn = aggregateRate(rates: rates, counters: snapshot.networkCounters, keyPath: \.inBitsPerSecond) {
                metrics.append(Metric(id: "throughput_in", label: "Network In", value: .throughput(bitsPerSecond: aggregateIn)))
            }
            if let aggregateOut = aggregateRate(rates: rates, counters: snapshot.networkCounters, keyPath: \.outBitsPerSecond) {
                metrics.append(Metric(id: "throughput_out", label: "Network Out", value: .throughput(bitsPerSecond: aggregateOut)))
            }
            return ProviderSnapshot(health: .ok, metrics: metrics)
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    private func countersByInterface(_ counters: [NetworkCounterMetrics]) -> [String: NetworkCounterMetrics] {
        Dictionary(uniqueKeysWithValues: counters.map { ($0.interfaceName, $0) })
    }

    private func ratesByInterface(
        previous: PreviousCounters,
        current: [String: NetworkCounterMetrics],
        now: Date
    ) -> [String: InterfaceRate] {
        let elapsed = now.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return [:] }

        var rates: [String: InterfaceRate] = [:]
        for (name, currentCounter) in current {
            guard let previousCounter = previous.counters[name],
                  currentCounter.bytesIn >= previousCounter.bytesIn,
                  currentCounter.bytesOut >= previousCounter.bytesOut
            else { continue }

            let inBits = Double(currentCounter.bytesIn - previousCounter.bytesIn) * 8 / elapsed
            let outBits = Double(currentCounter.bytesOut - previousCounter.bytesOut) * 8 / elapsed
            rates[name] = InterfaceRate(inBitsPerSecond: Int(inBits.rounded()), outBitsPerSecond: Int(outBits.rounded()))
        }
        return rates
    }

    private func aggregateRate(
        rates: [String: InterfaceRate],
        counters: [NetworkCounterMetrics],
        keyPath: KeyPath<InterfaceRate, Int>
    ) -> Int? {
        let names = Set(counters.filter { !$0.isLoopback }.map(\.interfaceName))
        let values = rates
            .filter { names.contains($0.key) }
            .map { $0.value[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func table(from counters: [NetworkCounterMetrics], rates: [String: InterfaceRate]) -> TableValue {
        TableValue(
            columns: [
                TableColumn(id: "interface", title: "Interface"),
                TableColumn(id: "in_bps", title: "In bps", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "out_bps", title: "Out bps", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "loopback", title: "Loopback", alignment: .center, valueStyle: .badge)
            ],
            rows: counters.map { counter in
                let rate = rates[counter.interfaceName]
                return TableRow(id: counter.interfaceName, cells: [
                    "interface": .text(counter.interfaceName),
                    "in_bps": rate.map { .number(Double($0.inBitsPerSecond), unit: "bps") } ?? .text("-"),
                    "out_bps": rate.map { .number(Double($0.outBitsPerSecond), unit: "bps") } ?? .text("-"),
                    "loopback": counter.isLoopback ? .badge("Yes", .elevated) : .badge("No", .normal)
                ])
            }
        )
    }
}

private struct PreviousCounters: Sendable {
    var timestamp: Date
    var counters: [String: NetworkCounterMetrics]
}

private struct InterfaceRate: Sendable {
    var inBitsPerSecond: Int
    var outBitsPerSecond: Int
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
