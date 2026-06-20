import AmbitCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: StatusViewModel

    var body: some View {
        Form {
            Section("Router") {
                TextField("Local host", text: $viewModel.settings.localHost)
                TextField("Remote host", text: $viewModel.settings.remoteHost)
                TextField("Username", text: $viewModel.settings.username)
                SecureField("Password", text: $viewModel.routerPassword)
                Picker("Endpoint", selection: $viewModel.settings.endpointMode) {
                    Text("Auto").tag(EndpointMode.auto)
                    Text("Force Local").tag(EndpointMode.forceLocal)
                    Text("Force Remote").tag(EndpointMode.forceRemote)
                }
                .pickerStyle(.segmented)
            }

            Section("Polling") {
                Stepper(value: $viewModel.settings.pollInterval, in: 2...120, step: 1) {
                    Text("Every \(Int(viewModel.settings.pollInterval)) seconds")
                }
            }

            Section("Optional Tools") {
                TextField("speedify_cli", text: $viewModel.settings.speedifyPath)
                TextField("grpcurl", text: $viewModel.settings.grpcurlPath)
            }

            Section("EcoFlow") {
                Toggle("Enable EcoFlow", isOn: $viewModel.settings.ecoflowEnabled)
                TextField("Daemon host", text: $viewModel.settings.ecoflowHost)
                Stepper(value: $viewModel.settings.ecoflowPort, in: 1...65535, step: 1) {
                    Text("Port \(viewModel.settings.ecoflowPort)")
                }
            }

            HStack {
                Spacer()
                Button("Save") {
                    viewModel.saveSettings()
                    Task { await viewModel.refresh() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
