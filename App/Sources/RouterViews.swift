import AmbitKit
import SwiftUI

struct RouterRow: View {
    let device: SavedDevice
    let reading: RouterReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.router")
                .frame(width: 22)
                .foregroundStyle(DeviceText.color(reading.condition))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if showsReadings, let vpn = reading.vpn {
                Text(vpn.isOn ? "VPN on" : "VPN off").font(.system(size: 13))
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var showsReadings: Bool {
        if case .stale = reading.condition { return true }
        return reading.condition == .online
    }

    private var summary: String {
        if let problem = DeviceText.problem(reading.condition, noun: "router") { return problem }
        var parts: [String] = []
        if let wan = reading.status?.wan { parts.append(wan.text) }
        if let count = reading.status?.clientCount { parts.append(count == 1 ? "1 client" : "\(count) clients") }
        return parts.isEmpty ? "Online" : parts.joined(separator: " · ")
    }
}

struct RouterDetail: View {
    let model: AppModel
    let device: SavedDevice
    let close: () -> Void
    @State private var failure: String?
    @State private var password = ""

    var body: some View {
        let reading = model.routers[device.id] ?? RouterReading()
        let status = reading.status
        VStack(alignment: .leading, spacing: 10) {
            if let problem = DeviceText.problem(reading.condition, noun: "router") {
                Text(problem).font(.system(size: 13)).foregroundStyle(DeviceText.color(reading.condition))
            }
            if needsPassword(reading.condition) {
                passwordEntry
            }
            DetailLine(label: "Internet through", value: status?.wan?.text ?? "–")
            DetailLine(label: "Clients", value: status?.clientCount.map(String.init) ?? "–")
            DetailLine(label: "Running for", value: DeviceText.uptime(status?.uptimeSeconds))
            DetailLine(label: "Address", value: status?.lanIP ?? device.host)
            Divider()
            if let vpn = reading.vpn {
                DetailLine(label: "VPN", value: vpnState(vpn))
                ConfirmedButton(
                    title: vpn.isOn ? "Turn VPN off" : "Turn VPN on",
                    question: vpn.isOn ? "Turn the VPN off? Traffic will go out unprotected." : "Turn the VPN on?"
                ) {
                    failure = await model.setVPN(on: !vpn.isOn, device.id)
                }
                // If the VPN changes state while the question is open, the question goes away.
                .id(vpn.isOn)
            } else {
                DetailLine(label: "VPN", value: reading.vpnKnown ? "Not set up on the router" : "–")
            }
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red)
            }
            if let url = URL(string: "http://\(device.host.contains(":") ? "[\(device.host)]" : device.host)/") {
                Link("Open the router's admin page", destination: url).font(.system(size: 13))
            }
            Divider()
            ConfirmedButton(title: "Remove device", question: "Remove \(device.name) from Ambit?") {
                failure = model.remove(device.id)
                if failure == nil { close() }
            }
        }
    }

    private var passwordEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("Admin password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(savePassword)
                Button("Save", action: savePassword).disabled(password.isEmpty)
            }
            Text("Stored in your Mac's Keychain.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Also during a lockout: the router then gets the corrected password when it accepts a try again.
    private func needsPassword(_ condition: DeviceCondition) -> Bool {
        switch condition {
        case .passwordNeeded, .wrongPassword, .lockedOut: true
        default: false
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        Task { failure = await model.setPassword(entered, for: device.id) }
    }

    private func vpnState(_ vpn: GLiNetVPN) -> String {
        let state = !vpn.isOn ? "Off" : vpn.isConnected ? "Connected" : "On, not connected"
        return vpn.profile.map { "\($0) · \(state)" } ?? state
    }
}
