import AmbitCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var isImportingProvider = false

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

            Section("Providers") {
                if viewModel.providerSetupSummaries.isEmpty {
                    Text("No manifest providers installed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.providerSetupSummaries) { summary in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.displayName)
                                        .font(.headline)
                                    Text(summary.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { summary.isEnabled },
                                    set: { viewModel.setInstalledProvider(summary.id, enabled: $0) }
                                ))
                                .labelsHidden()
                            }

                            Text(summary.statusText)
                                .font(.caption)
                                .foregroundStyle(statusColor(for: summary.status))

                            Text(summary.packagePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if !summary.credentials.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Credentials")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    ForEach(summary.credentials) { credential in
                                        HStack(spacing: 8) {
                                            Image(systemName: credential.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle")
                                                .foregroundStyle(credential.isConfigured ? .green : .orange)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(credential.label)
                                                    .font(.caption)
                                                Text(credential.isRequired ? "Required" : "Optional")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            SecureField(
                                                credential.label,
                                                text: viewModel.credentialBinding(providerID: summary.id, credentialID: credential.id)
                                            )
                                            .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                    Button("Save Credentials") {
                                        if let provider = viewModel.installedProviders.first(where: { $0.id == summary.id }) {
                                            viewModel.saveInstalledProviderCredentials(provider)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }

                            Button("Refresh Validation") {
                                viewModel.refreshInstalledProviderValidation(summary.id)
                            }

                            Button("Remove") {
                                viewModel.removeInstalledProvider(summary.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                if let error = viewModel.providerSetupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Install Manifest Folder...") {
                    isImportingProvider = true
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
        .fileImporter(
            isPresented: $isImportingProvider,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.installManifestProvider(from: url)
            }
        }
        .onAppear {
            viewModel.refreshInstalledProviders()
        }
    }

    private func statusColor(for status: ProviderSetupStatus) -> Color {
        switch status {
        case .ready:
            return .green
        case .needsCredentials, .invalid:
            return .orange
        case .disabled:
            return .secondary
        }
    }
}
