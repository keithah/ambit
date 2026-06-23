import AmbitCore
import SwiftUI

struct PingHostRow: Identifiable, Equatable {
    var id: String { instanceID.rawValue }
    let instanceID: IntegrationInstanceID
    let config: PingScopeHostConfig
    let enabled: Bool
    let isPrimary: Bool
    var name: String { config.displayName }
    var detail: String { config.detailLine }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case hosts = "Hosts", display = "Display", notifications = "Notifications"
    case history = "History", diagnostics = "Diagnostics", advanced = "Advanced", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .hosts: return "rectangle.stack"
        case .display: return "display"
        case .notifications: return "bell"
        case .history: return "clock.arrow.circlepath"
        case .diagnostics: return "stethoscope"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

struct PingScopeSettings: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var tab: SettingsTab = .hosts

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 184)
            Divider()
            Group {
                switch tab {
                case .hosts: HostsPane()
                case .notifications: NotificationsPane()
                case .display: DisplayPane()
                case .history: HistoryPane()
                case .diagnostics: DiagnosticsPane()
                case .advanced: AdvancedPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 740, height: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PingScope").font(.system(size: 18, weight: .bold))
                Text("Settings").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(tab == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(tab == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

}

@ViewBuilder
private func paneHeader(_ title: String, _ icon: String, _ subtitle: String) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.secondary)
        VStack(alignment: .leading) {
            Text(title).font(.system(size: 20, weight: .bold))
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}

private struct DisplayPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Display", "display", "Default graph range and readouts.")
                Form {
                    Picker("Default range", selection: Binding(
                        get: { viewModel.pingScopeRange },
                        set: { viewModel.setPingScopeRange($0) }
                    )) {
                        ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .formStyle(.grouped)
                Text("The popover and overlay open at this range. Drag the overlay edges to resize it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct HistoryPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("History", "clock.arrow.circlepath", "Latency samples retained on disk.")
                Form {
                    LabeledContent("Retention", value: "7 days")
                    Button("Clear History", role: .destructive) { viewModel.clearHistory() }
                }
                .formStyle(.grouped)
                Text("Samples persist in a local SQLite store and are pruned past the retention window.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct DiagnosticsPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Diagnostics", "stethoscope", "Live network-perspective diagnosis.")
                if let d = viewModel.pingDiagnosis {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.title).font(.system(size: 15, weight: .semibold))
                        Text(d.detail).font(.callout).foregroundStyle(.secondary)
                        Text("Confidence: \(d.confidence.rawValue)\(d.faultTier.map { " · fault: \($0.displayName)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    if !d.tierEvidence.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("By tier").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(d.tierEvidence, id: \.tier) { e in
                                HStack {
                                    Text(e.tier.displayName)
                                    Spacer()
                                    Text(e.summary).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                } else {
                    Text("No diagnosis yet.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

private struct AdvancedPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Advanced", "slider.horizontal.3", "Reset and maintenance.")
                Form {
                    Button("Reset Hosts to Defaults", role: .destructive) { viewModel.resetPingScopeHostsToDefaults() }
                }
                .formStyle(.grouped)
                Text("Replaces all hosts with Cloudflare, Google, and the detected gateway.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 40)).foregroundStyle(.tint)
            Text("PingScope").font(.system(size: 22, weight: .bold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Multi-host latency monitoring, built on Ambit.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct NotificationsPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "bell").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Notifications").font(.system(size: 20, weight: .bold))
                        Text("How network-problem alerts are decided.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Form {
                    Picker("Diagnosis sensitivity", selection: Binding(
                        get: { viewModel.diagnosisSensitivity },
                        set: { viewModel.diagnosisSensitivity = $0 }
                    )) {
                        Text("Conservative").tag(DiagnosisSensitivity.conservative)
                        Text("Balanced").tag(DiagnosisSensitivity.balanced)
                        Text("Sensitive").tag(DiagnosisSensitivity.sensitive)
                    }
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                Text("Per-host latency thresholds, cooldown, and recovery are set per host under Hosts ▸ Edit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var description: String {
        switch viewModel.diagnosisSensitivity {
        case .conservative: return "Only alert on high-confidence network failures."
        case .balanced: return "Alert on confident failures; surface uncertain ones as a generic internet problem."
        case .sensitive: return "Surface uncertain failures with their specific cause (local / ISP / upstream)."
        }
    }
}

private struct HostsPane: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var editorShown = false
    @State private var editingRow: PingHostRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Hosts").font(.system(size: 20, weight: .bold))
                        Text("Manage monitored endpoints, methods, thresholds, and primary selection.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("\(viewModel.pingHostRows.count) configured").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button { editingRow = nil; editorShown = true } label: { Label("Add Host", systemImage: "plus") }
                }
                ForEach(viewModel.pingHostRows) { row in
                    card(row)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .sheet(isPresented: $editorShown) {
            HostEditor(existing: editingRow) { config in
                viewModel.addOrUpdatePingHost(config, replacing: editingRow?.instanceID)
            }
        }
    }

    private func card(_ row: PingHostRow) -> some View {
        HStack(spacing: 12) {
            Circle().fill(row.enabled ? Color.green : Color.secondary).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.name).font(.system(size: 14, weight: .semibold))
                    if row.isPrimary {
                        Text("PRIMARY").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(row.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { row.enabled }, set: { viewModel.setPingHostEnabled(row.instanceID, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button("Edit") { editingRow = row; editorShown = true }
            if !row.isPrimary {
                Button("Primary") { viewModel.setPrimaryPingHost(row.instanceID) }
                Button { viewModel.deletePingHost(row.instanceID) } label: { Image(systemName: "trash") }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct HostEditor: View {
    let existing: PingHostRow?
    let onSave: (PingScopeHostConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var address: String
    @State private var method: ProbeMethod
    @State private var port: String
    @State private var intervalMs: Double
    @State private var timeoutMs: Double
    @State private var degradedMs: Double
    @State private var downAfter: Int
    @State private var preset: AlertPreset

    init(existing: PingHostRow?, onSave: @escaping (PingScopeHostConfig) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let c = existing?.config
        _name = State(initialValue: c?.displayName ?? "")
        _address = State(initialValue: c?.address ?? "")
        _method = State(initialValue: c?.method ?? .tcp)
        _port = State(initialValue: c?.port.map(String.init) ?? "443")
        _intervalMs = State(initialValue: (c?.interval ?? 2) * 1000)
        _timeoutMs = State(initialValue: (c?.timeout ?? 2) * 1000)
        _degradedMs = State(initialValue: c?.thresholds.degradedAt ?? 100)
        _downAfter = State(initialValue: c?.thresholds.downAfterFailures ?? 3)
        _preset = State(initialValue: c?.policy.preset ?? .balanced)
    }

    private var draft: PingScopeHostConfig {
        PingScopeHostConfig(
            displayName: name, address: address, method: method,
            port: method.requiresPort ? UInt16(port) : nil,
            interval: intervalMs / 1000, timeout: timeoutMs / 1000,
            thresholds: HealthThresholds(degradedAt: degradedMs, downAfterFailures: downAfter),
            policy: .preset(preset)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add Host" : "Edit Host").font(.title3.weight(.semibold)).padding(16)
            Divider()
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $address)
                Picker("Method", selection: $method) {
                    ForEach(ProbeMethod.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                if method.requiresPort { TextField("Port", text: $port) }
                Stepper("Interval \(Int(intervalMs)) ms", value: $intervalMs, in: 250...60000, step: 250)
                Stepper("Timeout \(Int(timeoutMs)) ms", value: $timeoutMs, in: 250...60000, step: 250)
                Stepper("Degraded ≥ \(Int(degradedMs)) ms", value: $degradedMs, in: 1...2000, step: 5)
                Stepper("Down after \(downAfter) failures", value: $downAfter, in: 1...20)
                Picker("Alerts", selection: $preset) {
                    ForEach(AlertPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
    }
}
