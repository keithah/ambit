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
                if viewModel.installedProviders.isEmpty {
                    Text("No manifest providers installed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.installedProviders) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName)
                                        .font(.headline)
                                    Text(provider.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { provider.isEnabled },
                                    set: { viewModel.setInstalledProvider(provider.id, enabled: $0) }
                                ))
                                .labelsHidden()
                            }

                            Text(provider.packagePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            switch provider.lastValidation {
                            case .valid:
                                Label("Manifest valid", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            case .invalid(let message):
                                Label(ProviderDisplayText.singleLine(message), systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            let credentials = viewModel.credentialRequirements(for: provider)
                            if !credentials.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Credentials")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    ForEach(credentials, id: \.id) { credential in
                                        SecureField(
                                            credential.label,
                                            text: viewModel.credentialBinding(providerID: provider.id, credentialID: credential.id)
                                        )
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    Button("Save Credentials") {
                                        viewModel.saveInstalledProviderCredentials(provider)
                                    }
                                }
                                .padding(.top, 4)
                            }

                            Button("Remove") {
                                viewModel.removeInstalledProvider(provider.id)
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
}
