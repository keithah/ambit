import AmbitKit
import SwiftUI

struct AddDeviceView: View {
    let model: AppModel
    let close: () -> Void

    @State private var found: [FoundDevice]?
    @State private var passwords: [String: String] = [:]
    @State private var manualKind = DeviceKind.starlink
    @State private var manualHost = ""
    @State private var manualPassword = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let found {
                if found.isEmpty {
                    Text("No new devices found on this network.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(found) { device in
                    foundRow(device)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Add by address").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Kind", selection: $manualKind) {
                Text("Starlink").tag(DeviceKind.starlink)
                Text("GL.iNet router").tag(DeviceKind.glinet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(manualKind == .starlink ? "192.168.100.1" : "192.168.8.1", text: $manualHost)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Address")
            if manualKind == .glinet {
                passwordField($manualPassword)
            }
            HStack {
                if let failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button("Add") {
                    add(manualKind, manualHost, manualKind == .glinet ? manualPassword : nil)
                }
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { found = await model.discover() }
    }

    @ViewBuilder
    private func foundRow(_ device: FoundDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: device.kind == .starlink ? "antenna.radiowaves.left.and.right" : "wifi.router")
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.kind == .starlink ? "Starlink" : "GL.iNet router").font(.system(size: 13))
                    Text(device.host).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") {
                    add(device.kind, device.host, device.kind == .glinet ? passwords[device.id] : nil)
                }
                .disabled(device.kind == .glinet && (passwords[device.id] ?? "").isEmpty)
            }
            if device.kind == .glinet {
                passwordField(Binding(get: { passwords[device.id] ?? "" }, set: { passwords[device.id] = $0 }))
            }
        }
    }

    private func passwordField(_ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Admin password", text: text).textFieldStyle(.roundedBorder)
            Text("Stored in your Mac's Keychain.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func add(_ kind: DeviceKind, _ host: String, _ password: String?) {
        failure = model.add(kind: kind, host: host, password: password)
        if failure == nil { close() }
    }
}
