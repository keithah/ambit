import AppKit
import AmbitCore
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var route: MenuRoute = .overview
    @State private var speedifyPanel: SpeedifyPanel = .graph
    @State private var speedifyMetric: SpeedifyGraphMetric = .networks

    var body: some View {
        Group {
            switch route {
            case .overview:
                OverviewMenuView(route: $route)
                    .environmentObject(viewModel)
            case .speedify:
                SpeedifyDetailView(route: $route, panel: $speedifyPanel, metric: $speedifyMetric)
                    .environmentObject(viewModel)
            case .starlink:
                StarlinkDetailView(route: $route)
                    .environmentObject(viewModel)
            case .ecoflow:
                EcoFlowDetailView(route: $route)
                    .environmentObject(viewModel)
            case .commands:
                CommandPaletteView(route: $route)
                    .environmentObject(viewModel)
            case .measurements:
                ActiveMeasurementsView(route: $route)
                    .environmentObject(viewModel)
            }
        }
        .frame(width: 460)
        .onChange(of: route) { newRoute in
            viewModel.setSpeedifyFocused(newRoute == .speedify)
        }
        .onDisappear {
            viewModel.setSpeedifyFocused(false)
        }
    }
}

private enum MenuRoute {
    case overview
    case speedify
    case starlink
    case ecoflow
    case commands
    case measurements
}

private enum SpeedifyPanel: String, CaseIterable {
    case graph = "Graph"
    case data = "Data"
    case controls = "Controls"
}

private enum SpeedifyGraphMetric: String, CaseIterable {
    case networks = "Networks"
    case traffic = "Traffic"
    case latency = "Latency"
    case loss = "Loss"
    case local = "Local"
}

private enum StatusTone {
    case good
    case warn
    case bad
    case neutral

    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .yellow
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}

private struct OverviewMenuView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute

    private var vpnOverview: AggregateVPNStatus {
        AggregateVPNStatus(routerVPN: viewModel.snapshot.providerVPNStatus, speedify: viewModel.snapshot.providerSpeedifyStatus)
    }

    private var interfaces: [InternetInterfaceStatus] {
        InternetInterfaceStatus.overview(router: viewModel.snapshot.providerRouterStatus, speedify: viewModel.snapshot.providerSpeedifyStatus)
    }

    private var topologyInterfaces: [InternetInterfaceStatus] {
        InternetInterfaceStatus.topology(
            router: viewModel.snapshot.providerRouterStatus,
            speedify: viewModel.snapshot.providerSpeedifyStatus,
            starlink: viewModel.snapshot.providerStarlinkStatus
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(title: "Ambit", subtitle: endpointText, showsBack: false) {
                Task { await viewModel.refresh() }
            }

            TopologyMapView(interfaces: topologyInterfaces, serviceSummary: serviceSummary)

            HStack(spacing: 8) {
                SummaryTile(title: "SIM", value: simText, subtitle: simDetail, tone: simTone)
                SummaryTile(title: "WAN", value: primaryInterface?.label ?? "Unknown", subtitle: primaryInterface?.detail ?? "Primary internet", tone: primaryInterface?.isConnected == true ? .good : .warn)
                SummaryTile(title: "VPN", value: vpnOverview.activeSummary, subtitle: viewModel.snapshot.providerSpeedifyStatus?.bondingMode?.label ?? "Services", tone: vpnOverview.connectedServices.isEmpty ? .warn : .good)
            }

            VStack(spacing: 8) {
                Button {
                    route = .commands
                } label: {
                    OverviewRow(
                        title: "Command Palette",
                        detail: commandPaletteDetail,
                        badge: "\(viewModel.commandPalette.count)",
                        tone: viewModel.commandPalette.isEmpty ? .neutral : .good,
                        systemImage: "command"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    route = .measurements
                } label: {
                    OverviewRow(
                        title: "Active Measurements",
                        detail: activeMeasurementDetail,
                        badge: "\(activeMeasurementSummaries.count)",
                        tone: activeMeasurementSummaries.contains { $0.health == .down || $0.health == .degraded } ? .warn : .good,
                        systemImage: "waveform.path.ecg"
                    )
                }
                .buttonStyle(.plain)

                if shouldShowSpeedify {
                    Button {
                        route = .speedify
                    } label: {
                        OverviewRow(
                            title: "Speedify VPN",
                            detail: speedifyDetail,
                            badge: viewModel.snapshot.providerSpeedifyStatus?.state ?? "Open",
                            tone: viewModel.snapshot.providerSpeedifyStatus?.isConnected == true ? .good : .warn,
                            systemImage: "lock.shield"
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    route = .starlink
                } label: {
                    OverviewRow(
                        title: "Starlink",
                        detail: starlinkDetail,
                        badge: starlinkBadge,
                        tone: starlinkTone,
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(.plain)

                if viewModel.settings.ecoflowEnabled {
                    Button {
                        route = .ecoflow
                    } label: {
                        OverviewRow(
                            title: "EcoFlow",
                            detail: ecoFlowDetail,
                            badge: ecoFlowBadge,
                            tone: ecoFlowTone,
                            systemImage: "battery.100percent"
                        )
                    }
                    .buttonStyle(.plain)
                }

                OverviewRow(
                    title: "Tethered Device",
                    detail: tethering?.detail ?? "No tethered device connected",
                    badge: tethering?.isConnected == true ? "Connected" : "Idle",
                    tone: tethering?.isConnected == true ? .good : .neutral,
                    systemImage: "cable.connector"
                )

                OverviewRow(
                    title: "Data usage",
                    detail: dataUsageDetail,
                    badge: "Open",
                    tone: .neutral,
                    systemImage: "chart.bar"
                )
            }

            InternetStatusLine(status: viewModel.snapshot.providerReachabilityStatus)
            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
        }
        .padding(14)
    }

    private var endpointText: String {
        guard let endpoint = viewModel.selectedEndpoint else { return "Endpoint unresolved" }
        return "\(endpoint.mode == .local ? "Local" : "Remote"): \(endpoint.host)"
    }

    private var primaryInterface: InternetInterfaceStatus? {
        interfaces.first(where: \.isPrimary) ?? interfaces.first(where: \.isConnected)
    }

    private var sim: InternetInterfaceStatus? {
        interfaces.first { $0.kind == .cellular }
    }

    private var starlink: InternetInterfaceStatus? {
        interfaces.first { $0.kind == .starlink }
    }

    private var tethering: InternetInterfaceStatus? {
        interfaces.first { $0.kind == .tethering }
    }

    private var simText: String {
        sim?.isConnected == true ? "Working" : "Idle"
    }

    private var simDetail: String {
        sim?.detail ?? "No SIM data"
    }

    private var simTone: StatusTone {
        sim?.isConnected == true ? .good : .warn
    }

    private var serviceSummary: String {
        if viewModel.snapshot.providerSpeedifyStatus?.isConnected == true {
            return "Speedify active"
        }
        if viewModel.snapshot.providerVPNStatus?.isConnected == true {
            return vpnOverview.activeSummary
        }
        return "Router online"
    }

    private var speedifyDetail: String {
        guard let speedify = viewModel.snapshot.providerSpeedifyStatus else { return "No Speedify data yet" }
        let server = speedify.server ?? "No server"
        let mode = speedify.bondingMode?.label ?? "Mode unknown"
        return "\(server) · \(mode)"
    }

    private var shouldShowSpeedify: Bool {
        guard let speedify = viewModel.snapshot.providerSpeedifyStatus else { return false }
        return speedify.isAvailable && (speedify.isConnected || !speedify.networks.isEmpty)
    }

    private var starlinkDetail: String {
        if let status = viewModel.snapshot.providerStarlinkStatus, status.isReachable {
            let latency = status.popPingLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "latency unknown"
            let drop = status.recentDropRate.map { "\(Int(($0 * 100).rounded()))% drop" } ?? "drop unknown"
            let down = DisplayFormatters.throughput(status.downlinkThroughputBps) ?? DisplayFormatters.throughput(status.recentDownlinkThroughputBps) ?? "down unknown"
            let obstruction = status.obstructionPercent.map { String(format: "%.1f%% obstructed", $0) } ?? "obstruction unknown"
            return "\(latency) · \(drop) · \(down) · \(obstruction)"
        }
        guard let starlink else { return viewModel.snapshot.providerErrorMessage(ProviderIDs.starlink) ?? "Not visible to Speedify" }
        let role = starlink.isPrimary ? "Primary" : (starlink.qualityLabel ?? "Secondary")
        if let traffic = trafficText(for: starlink) {
            return "\(starlink.detail ?? "Eth0") · \(role) · \(traffic)"
        }
        return "\(starlink.detail ?? "Eth0") · \(role)"
    }

    private var commandPaletteDetail: String {
        if viewModel.commandPalette.isEmpty {
            return "No provider commands registered"
        }
        let providers = Array(Set(viewModel.commandPalette.map(\.providerName))).sorted()
        return providers.prefix(3).joined(separator: " · ")
    }

    private var activeMeasurementSummaries: [ActiveMeasurementSummary] {
        ActiveMeasurementSummary.summaries(from: viewModel.snapshot)
    }

    private var activeMeasurementDetail: String {
        if activeMeasurementSummaries.isEmpty {
            return "Waiting for ping and throughput samples"
        }
        return activeMeasurementSummaries.map { summary in
            if let metric = summary.primaryMetric {
                return "\(summary.title) \(DisplayFormatters.metricValue(metric.value))"
            }
            return "\(summary.title) \(DisplayFormatters.health(summary.health))"
        }
        .joined(separator: " · ")
    }

    private var starlinkBadge: String {
        if let status = viewModel.snapshot.providerStarlinkStatus, status.isReachable {
            return status.state
        }
        return starlink?.qualityLabel ?? "Unavailable"
    }

    private var starlinkTone: StatusTone {
        if let status = viewModel.snapshot.providerStarlinkStatus, status.isReachable {
            let drop = status.recentDropRate ?? 0
            let obstruction = status.obstructionPercent ?? 0
            return drop > 0.25 || obstruction > 5 ? .warn : .good
        }
        return starlink?.isConnected == true ? .warn : .neutral
    }

    private var dataUsageDetail: String {
        let parts = interfaces.compactMap { interface -> String? in
            guard let data = DisplayFormatters.bytes(interface.dataUsedBytes) else { return nil }
            return "\(interface.label) \(data)"
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        let speedify = viewModel.snapshot.providerSpeedifyStatus
        let down = DisplayFormatters.bytes(speedify?.sessionDownloadBytes)
        let up = DisplayFormatters.bytes(speedify?.sessionUploadBytes)
        if let down, let up {
            return "Speedify \(down) down · \(up) up"
        }
        return "Not reported by router yet"
    }

    private var ecoFlowDetail: String {
        guard let ecoflow = viewModel.snapshot.providerEcoFlowSnapshot else {
            return viewModel.snapshot.providerErrorMessage(ProviderIDs.ecoflow) ?? "No EcoFlow data yet"
        }
        let battery = ecoflow.status.battery.percent.map { "\($0)%" } ?? "battery unknown"
        let state = ecoflow.status.battery.state.rawValue
        let input = ecoflow.status.power.inputWatts.map { "\($0)W in" } ?? "input unknown"
        let output = ecoflow.status.power.outputWatts.map { "\($0)W out" } ?? "output unknown"
        return "\(battery) · \(state) · \(input) · \(output)"
    }

    private var ecoFlowBadge: String {
        guard let ecoflow = viewModel.snapshot.providerEcoFlowSnapshot else { return "Unavailable" }
        return ecoflow.status.battery.percent.map { "\($0)%" } ?? ecoflow.status.battery.state.rawValue.capitalized
    }

    private var ecoFlowTone: StatusTone {
        guard let ecoflow = viewModel.snapshot.providerEcoFlowSnapshot else { return .neutral }
        guard let percent = ecoflow.status.battery.percent else { return .neutral }
        return percent <= 20 ? .warn : .good
    }

    private func trafficText(for interface: InternetInterfaceStatus) -> String? {
        let down = DisplayFormatters.throughput(interface.downloadBps)
        let up = DisplayFormatters.throughput(interface.uploadBps)
        switch (down, up) {
        case (.some(let down), .some(let up)): return "\(down) down / \(up) up"
        case (.some(let down), .none): return "\(down) down"
        case (.none, .some(let up)): return "\(up) up"
        case (.none, .none): return nil
        }
    }
}

private struct SpeedifyDetailView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute
    @Binding var panel: SpeedifyPanel
    @Binding var metric: SpeedifyGraphMetric

    var body: some View {
        VStack(spacing: 0) {
            SpeedifyHeader(route: $route, speedify: speedify)
            SpeedifyModeBanner(speedify: speedify)
            SpeedifyMetricTabs(metric: $metric)

            if panel == .graph {
                SpeedifyGraphView(speedify: speedify, metric: metric)
                SpeedifyNetworkListView(networks: speedify?.networks ?? []) { priority, id in
                    Task { await viewModel.setSpeedifyNetworkPriority(priority, networkID: id) }
                }
            } else if panel == .data {
                SpeedifyDataView(speedify: speedify, starlink: viewModel.snapshot.providerStarlinkStatus, starlinkError: viewModel.snapshot.providerErrorMessage(ProviderIDs.starlink))
            } else {
                SpeedifyControlsView(speedify: speedify)
                    .environmentObject(viewModel)
            }

            SpeedifyBottomBars(selected: $panel)
            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
                .padding([.horizontal, .bottom], 14)
                .padding(.top, 10)
                .background(Color.black)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            viewModel.setSpeedifyFocused(true)
        }
        .onDisappear {
            viewModel.setSpeedifyFocused(false)
        }
        .task {
            await viewModel.refreshSpeedifyNow()
        }
    }

    private var speedify: SpeedifyStatus? {
        viewModel.snapshot.providerSpeedifyStatus
    }
}

private struct StarlinkDetailView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(title: "Starlink", subtitle: subtitle, showsBack: true) {
                route = .overview
            }

            if let status = viewModel.snapshot.providerStarlinkStatus, status.isReachable {
                StarlinkHeroView(status: status)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StarlinkStatCard(title: "Latency", value: status.popPingLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "Not reported", tone: latencyTone(status.popPingLatencyMs))
                    StarlinkStatCard(title: "Drop Rate", value: status.recentDropRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not reported", tone: dropTone(status.recentDropRate))
                    StarlinkStatCard(title: "Down", value: DisplayFormatters.throughput(status.downlinkThroughputBps) ?? "Not reported", tone: .neutral)
                    StarlinkStatCard(title: "Up", value: DisplayFormatters.throughput(status.uplinkThroughputBps) ?? "Not reported", tone: .neutral)
                    StarlinkStatCard(title: "Obstruction", value: status.obstructionPercent.map { String(format: "%.1f%%", $0) } ?? "Not reported", tone: obstructionTone(status.obstructionPercent))
                    StarlinkStatCard(title: "GPS", value: status.gpsSats.map { "\($0) sats" } ?? "Not reported", tone: status.gpsValid == false ? .warn : .good)
                    StarlinkStatCard(title: "Ethernet", value: status.ethSpeedMbps.map { "\($0) Mbps" } ?? "Not reported", tone: .good)
                    StarlinkStatCard(title: "Outages", value: status.outageCount.map(String.init) ?? "Not reported", tone: (status.outageCount ?? 0) > 0 ? .warn : .good)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Device")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    StatusLine("Hardware", status.hardwareVersion ?? "Not reported")
                    StatusLine("Software", status.softwareVersion ?? "Not reported")
                    StatusLine("Uptime", status.uptimeSeconds.map(formatDuration) ?? "Not reported")
                    StatusLine("Update", status.softwareUpdateState ?? "Not reported")
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Starlink gRPC unavailable")
                        .font(.headline)
                    Text(viewModel.snapshot.providerErrorMessage(ProviderIDs.starlink) ?? "No Starlink status has been reported yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Expected endpoint: 192.168.100.1:9200")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
        }
        .padding(14)
    }

    private var subtitle: String {
        guard let status = viewModel.snapshot.providerStarlinkStatus, status.isReachable else {
            return viewModel.snapshot.providerErrorMessage(ProviderIDs.starlink) ?? "Unavailable"
        }
        let latency = status.popPingLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "latency unknown"
        let obstruction = status.obstructionPercent.map { String(format: "%.1f%% obstructed", $0) } ?? "obstruction unknown"
        return "\(status.state) · \(latency) · \(obstruction)"
    }

    private func latencyTone(_ latency: Double?) -> StatusTone {
        guard let latency else { return .neutral }
        return latency > 80 ? .warn : .good
    }

    private func dropTone(_ drop: Double?) -> StatusTone {
        guard let drop else { return .neutral }
        return drop > 0.25 ? .warn : .good
    }

    private func obstructionTone(_ obstruction: Double?) -> StatusTone {
        guard let obstruction else { return .neutral }
        return obstruction > 5 ? .warn : .good
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct StarlinkHeroView: View {
    let status: StarlinkStatus

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.30), Color.blue.opacity(0.46)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(status.state)
                        .font(.headline.weight(.bold))
                    Text(status.disablementCode ?? "OKAY")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.16), in: Capsule())
                        .foregroundStyle(.green)
                }
                Text("Dish gRPC · 192.168.100.1:9200")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let azimuth = status.popPingLatencyMs {
                        Label("\(Int(azimuth.rounded())) ms", systemImage: "timer")
                    }
                    if let eth = status.ethSpeedMbps {
                        Label("\(eth) Mbps", systemImage: "cable.connector")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.10, green: 0.18, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .foregroundStyle(.white)
    }
}

private struct StarlinkStatCard: View {
    let title: String
    let value: String
    let tone: StatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct EcoFlowDetailView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute
    @State private var lastControlResponse: EcoFlowControlResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(title: "EcoFlow", subtitle: subtitle, showsBack: true) {
                route = .overview
            }

            if let ecoflow = viewModel.snapshot.providerEcoFlowSnapshot {
                EcoFlowHeroView(snapshot: ecoflow)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StarlinkStatCard(title: "Input", value: watts(ecoflow.status.power.inputWatts), tone: .neutral)
                    StarlinkStatCard(title: "Output", value: watts(ecoflow.status.power.outputWatts), tone: .neutral)
                    StarlinkStatCard(title: "Net", value: watts(ecoflow.status.power.netWatts), tone: netTone(ecoflow.status.power.netWatts))
                    StarlinkStatCard(title: "Battery", value: ecoflow.status.battery.percent.map { "\($0)%" } ?? "Unknown", tone: batteryTone(ecoflow.status.battery.percent))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Outputs")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    EcoFlowOutputRow(target: .ac, output: ecoflowOutput(.ac, snapshot: ecoflow)) { state in
                        await setOutput(.ac, state: state)
                    }
                    EcoFlowOutputRow(target: .dc, output: ecoflowOutput(.dc, snapshot: ecoflow)) { state in
                        await setOutput(.dc, state: state)
                    }
                    EcoFlowOutputRow(target: .usb, output: ecoflowOutput(.usb, snapshot: ecoflow)) { state in
                        await setOutput(.usb, state: state)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let lastControlResponse {
                    EcoFlowControlResultView(response: lastControlResponse)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Device")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    StatusLine("Name", ecoflow.device?.device.name ?? "River 3 Plus")
                    StatusLine("Source", ecoflow.device?.device.ip ?? "EcoFlow daemon")
                    StatusLine("Updated", ecoflow.status.updatedAt)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EcoFlow daemon unavailable")
                        .font(.headline)
                    Text(viewModel.snapshot.providerErrorMessage(ProviderIDs.ecoflow) ?? "Enable EcoFlow and point it at the router daemon on port 8787.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Expected API: http://router-ip:8787/v1/status")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
        }
        .padding(14)
    }

    private var subtitle: String {
        guard viewModel.settings.ecoflowEnabled else { return "Disabled" }
        guard let ecoflow = viewModel.snapshot.providerEcoFlowSnapshot else {
            return viewModel.snapshot.providerErrorMessage(ProviderIDs.ecoflow) ?? "Unavailable"
        }
        let battery = ecoflow.status.battery.percent.map { "\($0)%" } ?? "battery unknown"
        return "\(battery) · \(ecoflow.status.battery.state.rawValue)"
    }

    private func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async {
        lastControlResponse = await viewModel.setEcoFlowOutput(target, state: state)
    }

    private func ecoflowOutput(_ target: EcoFlowOutputTarget, snapshot: EcoFlowSnapshot) -> EcoFlowOutputStatusWithControllability {
        if let output = snapshot.outputs?.outputs[target] {
            return output
        }
        let status = snapshot.status.outputs[target]
        return EcoFlowOutputStatusWithControllability(state: status.state, watts: status.watts, controllable: .unknown)
    }

    private func watts(_ value: Int?) -> String {
        value.map { "\($0) W" } ?? "Unknown"
    }

    private func batteryTone(_ percent: Int?) -> StatusTone {
        guard let percent else { return .neutral }
        return percent <= 20 ? .warn : .good
    }

    private func netTone(_ value: Int?) -> StatusTone {
        guard let value else { return .neutral }
        return value < 0 ? .warn : .good
    }
}

private struct EcoFlowHeroView: View {
    let snapshot: EcoFlowSnapshot

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.green.opacity(0.35), Color.cyan.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: batterySymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.device?.device.name ?? "EcoFlow River 3 Plus")
                    .font(.headline.weight(.bold))
                Text(snapshot.status.battery.state.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(snapshot.status.battery.percent.map { "\($0)%" } ?? "Unknown", systemImage: "battery.100percent")
                    Label("\(snapshot.status.power.outputWatts ?? 0) W", systemImage: "bolt")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.10), Color(red: 0.08, green: 0.20, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .foregroundStyle(.white)
    }

    private var batterySymbol: String {
        guard let percent = snapshot.status.battery.percent else { return "battery.0percent" }
        switch percent {
        case 80...100: return "battery.100percent"
        case 50..<80: return "battery.75percent"
        case 25..<50: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}

private struct EcoFlowOutputRow: View {
    let target: EcoFlowOutputTarget
    let output: EcoFlowOutputStatusWithControllability
    let setOutput: (EcoFlowOutputState) async -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.bold))
                Text("\(output.state.rawValue.capitalized) · \(output.watts.map { "\($0) W" } ?? "watts unknown") · \(output.controllable.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Set") {
                Button("On") {
                    Task { await setOutput(.on) }
                }
                Button("Off") {
                    Task { await setOutput(.off) }
                }
            }
            .disabled(output.controllable != .supported)
            .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private var label: String {
        switch target {
        case .ac: return "AC"
        case .dc: return "DC"
        case .usb: return "USB"
        }
    }

    private var icon: String {
        switch target {
        case .ac: return "powerplug"
        case .dc: return "car"
        case .usb: return "cable.connector"
        }
    }

    private var tone: StatusTone {
        output.state == .on ? .good : .neutral
    }
}

private struct EcoFlowControlResultView: View {
    let response: EcoFlowControlResponse

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(response.target.rawValue.uppercased()) \(response.requestedState.rawValue): \(response.result.rawValue)")
                    .font(.caption.weight(.bold))
                Text(response.message ?? message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tone: StatusTone {
        switch response.result {
        case .applied: return .good
        case .unknown: return .warn
        case .failed, .rejected, .unsupported: return .bad
        }
    }

    private var message: String {
        response.result == .unknown ? "Command sent, waiting for confirmation." : "Observed state: \(response.observedState.rawValue)"
    }
}

private struct ActiveMeasurementsView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute

    private var summaries: [ActiveMeasurementSummary] {
        ActiveMeasurementSummary.summaries(from: viewModel.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(title: "Measurements", subtitle: subtitle, showsBack: true) {
                route = .overview
            }

            if summaries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No active measurements yet")
                        .font(.headline)
                    Text("Ping and iperf3 providers will appear here after the engine publishes their first snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ForEach(summaries) { summary in
                    ActiveMeasurementCard(summary: summary)
                }
            }

            Button {
                route = .commands
            } label: {
                HStack {
                    Image(systemName: "command")
                    Text("Run measurement command")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
        }
        .padding(14)
        .task {
            await viewModel.refresh()
        }
    }

    private var subtitle: String {
        if summaries.isEmpty { return "Waiting for provider snapshots" }
        let badCount = summaries.filter { $0.health == .down || $0.health == .degraded }.count
        if badCount > 0 { return "\(badCount) needs attention" }
        return "\(summaries.count) providers reporting"
    }
}

private struct ActiveMeasurementCard: View {
    let summary: ActiveMeasurementSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tone.color.opacity(0.18))
                    Image(systemName: icon)
                        .foregroundStyle(tone.color)
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.headline.weight(.bold))
                    Text(summary.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(DisplayFormatters.health(summary.health))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tone.color.opacity(0.16), in: Capsule())
                    .foregroundStyle(tone.color)
            }

            if let primaryMetric = summary.primaryMetric {
                HStack(alignment: .firstTextBaseline) {
                    Text(primaryMetric.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(DisplayFormatters.metricValue(primaryMetric.value))
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if !summary.secondaryMetrics.isEmpty {
                HStack(spacing: 8) {
                    ForEach(summary.secondaryMetrics) { metric in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(DisplayFormatters.metricValue(metric.value))
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            if let errorMessage = summary.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tone: StatusTone {
        switch summary.health {
        case .ok:
            return .good
        case .degraded:
            return .warn
        case .down:
            return .bad
        case .unknown:
            return .neutral
        }
    }

    private var icon: String {
        switch summary.providerID {
        case ProviderIDs.ping:
            return "timer"
        case ProviderIDs.iperf3:
            return "speedometer"
        default:
            return "waveform.path.ecg"
        }
    }
}

private struct CommandPaletteView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @Binding var route: MenuRoute
    @State private var selectedItemID: CommandPaletteItem.ID?
    @State private var parameterValues: [String: String] = [:]

    private var selectedItem: CommandPaletteItem? {
        guard let selectedItemID else { return viewModel.commandPalette.first }
        return viewModel.commandPalette.first { $0.id == selectedItemID } ?? viewModel.commandPalette.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(title: "Commands", subtitle: subtitle, showsBack: true) {
                route = .overview
            }

            if viewModel.commandPalette.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No commands registered")
                        .font(.headline)
                    Text("Providers with actions will appear here after the engine refreshes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 6) {
                        ForEach(viewModel.commandPalette) { item in
                            CommandPaletteRow(
                                item: item,
                                isSelected: item.id == selectedItem?.id,
                                isExecuting: item.id == viewModel.executingCommandID
                            ) {
                                selectedItemID = item.id
                                seedParameterValues(for: item)
                            }
                        }
                    }
                    .frame(width: 190)

                    if let selectedItem {
                        CommandParameterPanel(
                            item: selectedItem,
                            values: $parameterValues,
                            isExecuting: selectedItem.id == viewModel.executingCommandID,
                            canRun: canRun(selectedItem)
                        ) {
                            await viewModel.executeCommand(selectedItem, arguments: arguments(for: selectedItem))
                        }
                    }
                }
            }

            if let message = viewModel.commandMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            FooterView(lastUpdated: viewModel.snapshot.lastUpdated)
        }
        .padding(14)
        .onAppear {
            viewModel.refreshCommandPalette()
            if selectedItemID == nil, let first = viewModel.commandPalette.first {
                selectedItemID = first.id
                seedParameterValues(for: first)
            }
        }
        .onChange(of: viewModel.commandPalette) { items in
            guard !items.isEmpty else {
                selectedItemID = nil
                parameterValues = [:]
                return
            }
            if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = items[0].id
                seedParameterValues(for: items[0])
            }
        }
    }

    private var subtitle: String {
        if viewModel.commandPalette.isEmpty { return "No provider actions" }
        let providerCount = Set(viewModel.commandPalette.map(\.providerID)).count
        return "\(viewModel.commandPalette.count) actions · \(providerCount) providers"
    }

    private func seedParameterValues(for item: CommandPaletteItem) {
        var values = parameterValues
        for parameter in item.command.parameters where values[parameter.id] == nil {
            values[parameter.id] = defaultValue(for: parameter)
        }
        parameterValues = values.filter { key, _ in
            item.command.parameters.contains { $0.id == key }
        }
    }

    private func defaultValue(for parameter: CommandParameter) -> String {
        switch parameter.kind {
        case .text, .number:
            return ""
        case .bool:
            return "false"
        case .option(let options):
            return options.first ?? ""
        }
    }

    private func canRun(_ item: CommandPaletteItem) -> Bool {
        item.command.parameters.allSatisfy { parameter in
            switch parameter.kind {
            case .bool, .option:
                return true
            case .text:
                return parameterValues[parameter.id]?.isEmpty == false
            case .number:
                guard let value = parameterValues[parameter.id], !value.isEmpty else { return false }
                return Double(value) != nil
            }
        }
    }

    private func arguments(for item: CommandPaletteItem) -> CommandArguments {
        var values: [String: JSONValue] = [:]
        for parameter in item.command.parameters {
            let rawValue = parameterValues[parameter.id] ?? defaultValue(for: parameter)
            switch parameter.kind {
            case .text, .option:
                values[parameter.id] = .string(rawValue)
            case .bool:
                values[parameter.id] = .bool(rawValue == "true")
            case .number:
                values[parameter.id] = .number(Double(rawValue) ?? 0)
            }
        }
        return CommandArguments(values: values)
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let isExecuting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .white : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.command.label)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(item.providerName)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch item.providerID {
        case ProviderIDs.speedify, ProviderIDs.vpn:
            return "lock.shield"
        case ProviderIDs.ecoflow:
            return "bolt"
        case ProviderIDs.iperf3:
            return "speedometer"
        default:
            return "play"
        }
    }
}

private struct CommandParameterPanel: View {
    let item: CommandPaletteItem
    @Binding var values: [String: String]
    let isExecuting: Bool
    let canRun: Bool
    let run: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.command.label)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(item.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.command.parameters.isEmpty {
                Text("No parameters required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(item.command.parameters) { parameter in
                    CommandParameterField(parameter: parameter, value: binding(for: parameter))
                }
            }

            Button {
                Task { await run() }
            } label: {
                HStack {
                    if isExecuting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isExecuting ? "Running" : "Run")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canRun || isExecuting)
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func binding(for parameter: CommandParameter) -> Binding<String> {
        Binding(
            get: { values[parameter.id] ?? defaultValue(for: parameter) },
            set: { values[parameter.id] = $0 }
        )
    }

    private func defaultValue(for parameter: CommandParameter) -> String {
        switch parameter.kind {
        case .text, .number:
            return ""
        case .bool:
            return "false"
        case .option(let options):
            return options.first ?? ""
        }
    }
}

private struct CommandParameterField: View {
    let parameter: CommandParameter
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(parameter.label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            switch parameter.kind {
            case .text:
                TextField(parameter.label, text: $value)
                    .textFieldStyle(.roundedBorder)
            case .number:
                TextField(parameter.label, text: $value)
                    .textFieldStyle(.roundedBorder)
            case .bool:
                Toggle(isOn: boolBinding) {
                    Text(value == "true" ? "On" : "Off")
                        .font(.caption)
                }
            case .option(let options):
                Picker(parameter.label, selection: $value) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { value == "true" },
            set: { value = $0 ? "true" : "false" }
        )
    }
}

private struct StatusLine: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }
}

private struct HeaderView: View {
    let title: String
    let subtitle: String
    let showsBack: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsBack {
                Button(action: action) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !showsBack {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }
}

private struct TopologyMapView: View {
    let interfaces: [InternetInterfaceStatus]
    let serviceSummary: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TopologyLink(title: "Cellular", active: isActive(.cellular))
                    TopologyLink(title: "Starlink", active: isActive(.starlink))
                    TopologyLink(title: "Tether", active: isActive(.tethering))
                    TopologyLink(title: "Ethernet", active: isActive(.ethernet))
                }
                .frame(width: 92, alignment: .leading)

                VStack(spacing: 4) {
                    Image(systemName: "wifi.router")
                        .font(.system(size: 30, weight: .semibold))
                    Text("GL-X3000")
                        .font(.caption.weight(.bold))
                    Text(serviceSummary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.cyan.opacity(0.48), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Label("Wi-Fi 3", systemImage: "wifi")
                    Label("LAN 0", systemImage: "network")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.13, green: 0.09, blue: 0.38), Color(red: 0.12, green: 0.36, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func isActive(_ kind: InternetInterfaceKind) -> Bool {
        interfaces.contains { $0.kind == kind && $0.isConnected }
    }
}

private struct TopologyLink: View {
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(active ? Color.cyan : Color.white.opacity(0.28))
                .frame(width: 7, height: 7)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(active ? .bold : .medium))
        .foregroundStyle(active ? Color.cyan : Color.white.opacity(0.58))
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let subtitle: String
    let tone: StatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct OverviewRow: View {
    let title: String
    let detail: String
    let badge: String
    let tone: StatusTone
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(badge)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tone.color.opacity(0.16), in: Capsule())
                .foregroundStyle(tone.color)
        }
        .padding(10)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct InternetStatusLine: View {
    let status: ReachabilityStatus?

    var body: some View {
        HStack {
            Text("Internet")
                .font(.caption.weight(.bold))
            Spacer()
            switch status?.state {
            case .online(let latency):
                Text("Online · \(DisplayFormatters.latency(latency))")
                    .foregroundStyle(.green)
            case .offline:
                Text("Offline")
                    .foregroundStyle(.red)
            case .unknown, nil:
                Text("No probe result")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private struct SpeedifyHeader: View {
    @Binding var route: MenuRoute
    let speedify: SpeedifyStatus?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                route = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speedify VPN")
                    .font(.headline.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Image(systemName: speedify?.isConnected == true ? "lock.fill" : "lock.open")
                .foregroundStyle(speedify?.isConnected == true ? .green : .orange)
                .font(.title3)
        }
        .padding(14)
        .background(Color(red: 0.08, green: 0.09, blue: 0.13))
    }

    private var subtitle: String {
        guard let speedify else { return "No Speedify data yet" }
        return "\(speedify.state) · \(speedify.server ?? "No server")"
    }
}

private struct SpeedifyModeBanner: View {
    let speedify: SpeedifyStatus?

    var body: some View {
        HStack {
            Spacer()
            Text("\(speedify?.bondingMode?.label ?? "Unknown") Mode")
                .font(.caption.weight(.bold))
            Text("·")
                .foregroundStyle(.white.opacity(0.5))
            Text(speedify?.isConnected == true ? "Secure" : "Disconnected")
                .font(.caption.weight(.bold))
            Spacer()
        }
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [Color(red: 0.38, green: 0.24, blue: 0.88), Color(red: 0.25, green: 0.60, blue: 0.84)], startPoint: .leading, endPoint: .trailing))
    }
}

private struct SpeedifyMetricTabs: View {
    @Binding var metric: SpeedifyGraphMetric

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SpeedifyGraphMetric.allCases, id: \.self) { item in
                Button {
                    metric = item
                } label: {
                    Text(item.rawValue.uppercased())
                        .font(.caption2.weight(.black))
                        .foregroundStyle(metric == item ? .white : .white.opacity(0.46))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(metric == item ? Color.cyan : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black)
    }
}

private struct SpeedifyGraphView: View {
    let speedify: SpeedifyStatus?
    let metric: SpeedifyGraphMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let latest = speedify?.graphSamples.last {
                    Text(DisplayFormatters.throughput(latest.totalBps) ?? "")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sampleColor(sample))
                        .frame(width: 8, height: barHeight(sample))
                }
                if samples.isEmpty {
                    Text("Waiting for Speedify graph samples")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 76)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .bottomLeading)
        }
        .padding(14)
        .background(Color(red: 0.02, green: 0.02, blue: 0.03))
    }

    private var samples: [SpeedifyGraphSample] {
        let real = speedify?.graphSamples ?? []
        guard !real.isEmpty else { return [] }
        if real.count >= 18 { return Array(real.suffix(18)) }
        return Array(repeating: real[0], count: 18)
    }

    private func barHeight(_ sample: SpeedifyGraphSample) -> CGFloat {
        let maxValue = max(samples.map(\.totalBps).max() ?? 1, 1)
        return CGFloat(max(8, min(76, sample.totalBps * 76 / maxValue)))
    }

    private func sampleColor(_ sample: SpeedifyGraphSample) -> Color {
        sample.downloadBps ?? 0 > sample.uploadBps ?? 0 ? Color.cyan : Color.purple
    }
}

private struct SpeedifyNetworkListView: View {
    let networks: [SpeedifyNetwork]
    let setPriority: (SpeedifyNetworkPriority, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if networks.isEmpty {
                Text("No Speedify interfaces reported")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else {
                ForEach(networks) { network in
                    SpeedifyInterfaceRow(network: network) { priority in
                        setPriority(priority, network.id)
                    }
                }
            }
        }
    }
}

private struct SpeedifyInterfaceRow: View {
    let network: SpeedifyNetwork
    let setPriority: (SpeedifyNetworkPriority) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(iconText)
                    .font(.caption.weight(.black))
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(network.statusMessage ?? network.priority.label)
                        .foregroundStyle(network.statusMessage == nil ? .white.opacity(0.55) : .orange)
                    if let traffic {
                        Text("· \(traffic)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Menu(network.priority.label) {
                ForEach(SpeedifyNetworkPriority.allCases.filter { $0 != .unknown }, id: \.self) { priority in
                    Button(priority.label) {
                        setPriority(priority)
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var iconText: String {
        if network.type?.localizedCaseInsensitiveContains("cell") == true { return "5G" }
        if network.displayName.localizedCaseInsensitiveContains("starlink") { return "✕" }
        return "↔"
    }

    private var traffic: String? {
        let down = DisplayFormatters.throughput(network.receiveBps)
        let up = DisplayFormatters.throughput(network.sendBps)
        switch (down, up) {
        case (.some(let down), .some(let up)): return "↓ \(down) ↑ \(up)"
        case (.some(let down), .none): return "↓ \(down)"
        case (.none, .some(let up)): return "↑ \(up)"
        case (.none, .none): return nil
        }
    }
}

private struct SpeedifyBottomBars: View {
    @Binding var selected: SpeedifyPanel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SpeedifyPanel.allCases, id: \.self) { panel in
                Button {
                    selected = panel
                } label: {
                    VStack(spacing: 2) {
                        Text(panel.rawValue)
                            .font(.caption.weight(.bold))
                        Text(subtitle(panel))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selected == panel ? Color.white.opacity(0.18) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.black)
    }

    private func subtitle(_ panel: SpeedifyPanel) -> String {
        switch panel {
        case .graph: return "latency/loss"
        case .data: return "usage"
        case .controls: return "mode/server"
        }
    }
}

private struct SpeedifyDataView: View {
    let speedify: SpeedifyStatus?
    let starlink: StarlinkStatus?
    let starlinkError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data")
                .font(.subheadline.weight(.bold))
            HStack(spacing: 8) {
                DataCard(title: "Session Down", value: DisplayFormatters.bytes(speedify?.sessionDownloadBytes) ?? "Not reported")
                DataCard(title: "Session Up", value: DisplayFormatters.bytes(speedify?.sessionUploadBytes) ?? "Not reported")
            }
            ForEach(speedify?.networks ?? []) { network in
                HStack {
                    Text(network.displayName)
                    Spacer()
                    Text([DisplayFormatters.throughput(network.receiveBps), DisplayFormatters.throughput(network.sendBps)].compactMap { $0 }.joined(separator: " / "))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .font(.caption)
            }

            Divider()
                .overlay(Color.white.opacity(0.18))

            Text("Starlink")
                .font(.subheadline.weight(.bold))
            if let starlink, starlink.isReachable {
                HStack(spacing: 8) {
                    DataCard(title: "Latency", value: starlink.popPingLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "Not reported")
                    DataCard(title: "Drop", value: starlink.recentDropRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not reported")
                }
                HStack(spacing: 8) {
                    DataCard(title: "Down", value: DisplayFormatters.throughput(starlink.downlinkThroughputBps) ?? "Not reported")
                    DataCard(title: "Up", value: DisplayFormatters.throughput(starlink.uplinkThroughputBps) ?? "Not reported")
                }
                HStack(spacing: 8) {
                    DataCard(title: "Obstruction", value: starlink.obstructionPercent.map { String(format: "%.1f%%", $0) } ?? "Not reported")
                    DataCard(title: "GPS", value: starlink.gpsSats.map { "\($0) sats" } ?? "Not reported")
                }
                HStack(spacing: 8) {
                    DataCard(title: "Ethernet", value: starlink.ethSpeedMbps.map { "\($0) Mbps" } ?? "Not reported")
                    DataCard(title: "Outages", value: starlink.outageCount.map(String.init) ?? "Not reported")
                }
                if let hardware = starlink.hardwareVersion {
                    Text("\(hardware) · \(starlink.softwareVersion ?? "software unknown")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            } else {
                Text(starlinkError ?? "Starlink gRPC unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }
}

private struct DataCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.caption.weight(.bold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SpeedifyControlsView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let speedify: SpeedifyStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(speedify?.isConnected == true ? "Disconnect" : "Connect") {
                    Task { await viewModel.toggleSpeedify() }
                }
                .disabled(speedify?.isAvailable != true)

                Menu("Bonding") {
                    ForEach(SpeedifyBondingMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                        Button(mode.label) {
                            Task { await viewModel.setSpeedifyBondingMode(mode) }
                        }
                    }
                }
                .disabled(speedify?.isAvailable != true)

                Menu("Server") {
                    Button("Auto / Best") {
                        Task {
                            if speedify?.isConnected == true {
                                await viewModel.toggleSpeedify()
                            }
                            await viewModel.toggleSpeedify()
                        }
                    }
                }
                .disabled(speedify?.isAvailable != true)
            }

            Text("Interface priority")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))

            ForEach(speedify?.networks ?? []) { network in
                SpeedifyInterfaceRow(network: network) { priority in
                    Task { await viewModel.setSpeedifyNetworkPriority(priority, networkID: network.id) }
                }
            }
        }
        .padding(14)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }
}

private struct FooterView: View {
    let lastUpdated: Date?

    var body: some View {
        HStack {
            Text(lastUpdatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings...") {
                NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var lastUpdatedText: String {
        guard let lastUpdated else { return "Not updated" }
        return "Updated \(lastUpdated.formatted(date: .omitted, time: .standard))"
    }
}
