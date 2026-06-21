# Provider Setup, Generic UI, and Manifest Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build surface-agnostic installed manifest provider setup, improve reusable generic provider display, and expand declarative manifest runtime transforms/layout/alerts.

**Architecture:** Core owns installed provider records, credential requirements, provider loading, generic display models, manifest transforms, layout hints, and manifest alert compilation. AmbitMenuBar renders those shared models in Settings and generic provider detail, but does not own platform state. Engine gets installed manifest providers through a store/factory path while preserving the existing explicit-provider injection used by tests.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Codable`, existing `CredentialStore`, `ProviderManifest`, `ManifestProvider`, `Engine`, `AlertEngine`, XCTest.

---

## File Structure

- Create `Sources/AmbitCore/InstalledProviderStore.swift`: installed manifest provider record model, validation result model, store protocol, UserDefaults-backed store.
- Create `Sources/AmbitCore/InstalledManifestProviderLoader.swift`: loads installed records, validates packages, builds `ManifestProvider` instances with the shared credential store.
- Modify `Sources/AmbitCore/Engine.swift`: accept an installed provider store, merge loaded installed manifest providers with built-ins and explicit providers, expose installed provider records for UI.
- Create `Sources/AmbitCore/ProviderDisplayModel.swift`: reusable provider display model for generic surfaces, including missing credential and command summaries.
- Modify `Sources/AmbitCore/ProviderManifest.swift`: add transform, layout, and default alert schema.
- Modify `Sources/AmbitCore/ManifestProvider.swift`: apply transforms, expose layout hints through snapshots/display model inputs, and validate credential references.
- Create `Sources/AmbitCore/ManifestAlertCompiler.swift`: compile manifest alert declarations into existing `AlertRule` values.
- Modify `Sources/AmbitMenuBar/StatusViewModel.swift`: expose installed provider records, install/remove/enable/save-credential operations, and refresh provider registry.
- Modify `Sources/AmbitMenuBar/SettingsView.swift`: add provider manager UI for local folder install, credentials, validation, enable/disable, remove.
- Modify `Sources/AmbitMenuBar/MenuContent.swift`: use `ProviderDisplayModel` for generic provider detail and surface missing credential prompts.
- Add tests in `Tests/AmbitCoreTests/InstalledProviderStoreTests.swift`, `InstalledManifestProviderLoaderTests.swift`, `ProviderDisplayModelTests.swift`, `ProviderManifestTransformTests.swift`, `ManifestAlertCompilerTests.swift`.
- Extend `Tests/AmbitCoreTests/EngineTests.swift`, `ProviderManifestTests.swift`, `ManifestProviderTests.swift`.
- Add examples under `Examples/provider-manifests/secure-post-demo` and `Examples/provider-manifests/transform-layout-alert-demo`.

---

### Task 1: Installed Provider Store

**Files:**
- Create: `Sources/AmbitCore/InstalledProviderStore.swift`
- Test: `Tests/AmbitCoreTests/InstalledProviderStoreTests.swift`

- [ ] **Step 1: Write the failing persistence tests**

```swift
import XCTest
@testable import AmbitCore

final class InstalledProviderStoreTests: XCTestCase {
    func testUserDefaultsStorePersistsInstalledManifestProviders() throws {
        let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsInstalledProviderStore(defaults: defaults)
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: "/tmp/demo",
            isEnabled: true,
            lastValidation: .valid
        )

        try store.save([record])

        XCTAssertEqual(try store.load(), [record])
    }

    func testStoreUpdatesEnabledStateWithoutDroppingValidation() throws {
        let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsInstalledProviderStore(defaults: defaults)
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: "/tmp/demo",
            isEnabled: true,
            lastValidation: .invalid("Missing manifest file")
        )
        try store.save([record])

        try store.setEnabled(false, providerID: "demo.secure")

        XCTAssertEqual(try store.load(), [
            InstalledProviderRecord(
                id: "demo.secure",
                displayName: "Secure Demo",
                packagePath: "/tmp/demo",
                isEnabled: false,
                lastValidation: .invalid("Missing manifest file")
            )
        ])
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run: `swift test --filter InstalledProviderStoreTests`

Expected: compile failure for missing `InstalledProviderRecord`, `InstalledProviderValidation`, and `UserDefaultsInstalledProviderStore`.

- [ ] **Step 3: Implement the minimal store**

Add `Sources/AmbitCore/InstalledProviderStore.swift`:

```swift
import Foundation

public enum InstalledProviderValidation: Codable, Equatable, Sendable {
    case valid
    case invalid(String)

    private enum CodingKeys: String, CodingKey {
        case status
        case message
    }

    private enum Status: String, Codable {
        case valid
        case invalid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .valid:
            self = .valid
        case .invalid:
            self = .invalid(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .valid:
            try container.encode(Status.valid, forKey: .status)
        case .invalid(let message):
            try container.encode(Status.invalid, forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }
}

public struct InstalledProviderRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var displayName: String
    public var packagePath: String
    public var isEnabled: Bool
    public var lastValidation: InstalledProviderValidation

    public init(
        id: ProviderID,
        displayName: String,
        packagePath: String,
        isEnabled: Bool = true,
        lastValidation: InstalledProviderValidation = .valid
    ) {
        self.id = id
        self.displayName = displayName
        self.packagePath = packagePath
        self.isEnabled = isEnabled
        self.lastValidation = lastValidation
    }
}

public protocol InstalledProviderStore: Sendable {
    func load() throws -> [InstalledProviderRecord]
    func save(_ records: [InstalledProviderRecord]) throws
}

public extension InstalledProviderStore {
    func setEnabled(_ enabled: Bool, providerID: ProviderID) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == providerID }) else { return }
        records[index].isEnabled = enabled
        try save(records)
    }
}

public struct UserDefaultsInstalledProviderStore: InstalledProviderStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "installedProviders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> [InstalledProviderRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([InstalledProviderRecord].self, from: data)
    }

    public func save(_ records: [InstalledProviderRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Verify store tests pass**

Run: `swift test --filter InstalledProviderStoreTests`

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitCore/InstalledProviderStore.swift Tests/AmbitCoreTests/InstalledProviderStoreTests.swift
git commit -m "Add installed provider store"
```

---

### Task 2: Installed Manifest Provider Loader

**Files:**
- Create: `Sources/AmbitCore/InstalledManifestProviderLoader.swift`
- Test: `Tests/AmbitCoreTests/InstalledManifestProviderLoaderTests.swift`

- [ ] **Step 1: Write loader tests**

```swift
import XCTest
@testable import AmbitCore

final class InstalledManifestProviderLoaderTests: XCTestCase {
    func testLoadsEnabledValidManifestProviders() throws {
        let directory = try Self.writeManifest(id: "demo.secure", displayName: "Secure Demo")
        let store = InMemoryInstalledProviderStore(records: [
            InstalledProviderRecord(id: "demo.secure", displayName: "Secure Demo", packagePath: directory.path, isEnabled: true)
        ])
        let loader = InstalledManifestProviderLoader(store: store, credentialStore: StaticCredentialStore(credentials: [:]))

        let result = try loader.load()

        XCTAssertEqual(result.records.map(\.id), ["demo.secure"])
        XCTAssertEqual(result.providers.map(\.id), ["demo.secure"])
        XCTAssertEqual(result.records.first?.lastValidation, .valid)
    }

    func testKeepsInvalidRecordsButDoesNotCreateProvider() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = InMemoryInstalledProviderStore(records: [
            InstalledProviderRecord(id: "demo.missing", displayName: "Missing Demo", packagePath: directory.path, isEnabled: true)
        ])
        let loader = InstalledManifestProviderLoader(store: store, credentialStore: StaticCredentialStore(credentials: [:]))

        let result = try loader.load()

        XCTAssertEqual(result.providers.count, 0)
        XCTAssertEqual(result.records.first?.id, "demo.missing")
        if case .invalid(let message) = result.records.first?.lastValidation {
            XCTAssertTrue(message.contains("Manifest file is missing"))
        } else {
            XCTFail("Expected invalid validation result")
        }
    }

    private static func writeManifest(id: String, displayName: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "pollInterval": 30,
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [
            { "id": "ok", "label": "OK", "value": { "type": "bool", "path": "ok" } }
          ],
          "commands": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

private final class InMemoryInstalledProviderStore: InstalledProviderStore, @unchecked Sendable {
    var records: [InstalledProviderRecord]

    init(records: [InstalledProviderRecord]) {
        self.records = records
    }

    func load() throws -> [InstalledProviderRecord] {
        records
    }

    func save(_ records: [InstalledProviderRecord]) throws {
        self.records = records
    }
}
```

- [ ] **Step 2: Run loader tests red**

Run: `swift test --filter InstalledManifestProviderLoaderTests`

Expected: compile failure for missing `InstalledManifestProviderLoader`.

- [ ] **Step 3: Implement loader**

Create `Sources/AmbitCore/InstalledManifestProviderLoader.swift`:

```swift
import Foundation

public struct InstalledManifestProviderLoadResult: Sendable {
    public var records: [InstalledProviderRecord]
    public var providers: [any Provider]

    public init(records: [InstalledProviderRecord], providers: [any Provider]) {
        self.records = records
        self.providers = providers
    }
}

public struct InstalledManifestProviderLoader: Sendable {
    private let store: any InstalledProviderStore
    private let credentialStore: any CredentialStore

    public init(store: any InstalledProviderStore, credentialStore: any CredentialStore) {
        self.store = store
        self.credentialStore = credentialStore
    }

    public func load() throws -> InstalledManifestProviderLoadResult {
        var updatedRecords: [InstalledProviderRecord] = []
        var providers: [any Provider] = []

        for record in try store.load() {
            guard record.isEnabled else {
                updatedRecords.append(record)
                continue
            }
            do {
                let package = try ProviderManifestPackage.load(from: URL(fileURLWithPath: record.packagePath, isDirectory: true))
                var updated = record
                updated.id = package.manifest.id
                updated.displayName = package.manifest.displayName
                updated.lastValidation = .valid
                updatedRecords.append(updated)
                providers.append(ManifestProvider(manifest: package.manifest, credentialStore: credentialStore))
            } catch {
                var updated = record
                updated.lastValidation = .invalid(error.localizedDescription)
                updatedRecords.append(updated)
            }
        }

        try store.save(updatedRecords)
        return InstalledManifestProviderLoadResult(records: updatedRecords, providers: providers)
    }
}
```

- [ ] **Step 4: Verify loader tests pass**

Run: `swift test --filter InstalledManifestProviderLoaderTests`

Expected: all loader tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitCore/InstalledManifestProviderLoader.swift Tests/AmbitCoreTests/InstalledManifestProviderLoaderTests.swift
git commit -m "Load installed manifest providers"
```

---

### Task 3: Engine Loads Installed Manifest Providers

**Files:**
- Modify: `Sources/AmbitCore/Engine.swift`
- Test: `Tests/AmbitCoreTests/EngineTests.swift`

- [ ] **Step 1: Add Engine tests for installed providers**

Append tests to `EngineTests`:

```swift
func testRefreshLoadsInstalledManifestProviders() async throws {
    let directory = try Self.writeManifest(id: "demo.installed", displayName: "Installed Demo")
    let installedStore = InMemoryInstalledProviderStore(records: [
        InstalledProviderRecord(id: "demo.installed", displayName: "Installed Demo", packagePath: directory.path, isEnabled: true)
    ])
    let httpClient = StubManifestHTTPClient(responses: [.success(#"{ "ok": true }"#)])
    let engine = Engine(
        settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
        credentialStore: InMemoryCredentialStore(password: "secret"),
        settings: AppSettings(localHost: "router.local"),
        routerPassword: "secret",
        registerBuiltInProviders: false,
        installedProviderStore: installedStore,
        manifestHTTPClient: httpClient
    )

    await engine.refresh()

    let snapshot = await engine.currentSnapshot()
    XCTAssertEqual(snapshot.providers["demo.installed"]?.value?.metric("ok")?.value, .bool(true))
    XCTAssertEqual(await engine.providerDisplayNames()["demo.installed"], "Installed Demo")
}

private static func writeManifest(id: String, displayName: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ambit-engine-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "id": "\(id)",
      "displayName": "\(displayName)",
      "pollInterval": 1,
      "endpoint": { "method": "GET", "url": "https://example.test/status" },
      "metrics": [
        { "id": "ok", "label": "OK", "value": { "type": "bool", "path": "ok" } }
      ],
      "commands": []
    }
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}
```

Also add a small `StubManifestHTTPClient` in `EngineTests` if no equivalent is visible in that file:

```swift
private final class StubManifestHTTPClient: ManifestHTTPClient, @unchecked Sendable {
    enum Response {
        case success(String)
    }

    var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: ManifestHTTPRequest) async throws -> Data {
        switch responses.removeFirst() {
        case .success(let json):
            return Data(json.utf8)
        }
    }
}
```

- [ ] **Step 2: Run Engine test red**

Run: `swift test --filter EngineTests/testRefreshLoadsInstalledManifestProviders`

Expected: compile failure for missing `installedProviderStore` and `manifestHTTPClient` Engine initializer parameters.

- [ ] **Step 3: Extend Engine initializer and provider rebuild**

Modify `Engine`:

```swift
private let installedProviderStore: (any InstalledProviderStore)?
private let manifestHTTPClient: any ManifestHTTPClient
private var installedProviderRecords: [InstalledProviderRecord] = []
```

Add initializer parameters:

```swift
installedProviderStore: (any InstalledProviderStore)? = nil,
manifestHTTPClient: any ManifestHTTPClient = URLSessionManifestHTTPClient(),
```

Set them before building providers:

```swift
self.installedProviderStore = installedProviderStore
self.manifestHTTPClient = manifestHTTPClient
```

Add helper:

```swift
private func loadInstalledManifestProviders() -> [any Provider] {
    guard let installedProviderStore else { return [] }
    do {
        let result = try InstalledManifestProviderLoader(
            store: installedProviderStore,
            credentialStore: credentialStore,
            httpClient: manifestHTTPClient
        ).load()
        installedProviderRecords = result.records
        return result.providers
    } catch {
        return []
    }
}
```

If the loader from Task 2 does not yet accept `httpClient`, update it to:

```swift
private let httpClient: any ManifestHTTPClient

public init(
    store: any InstalledProviderStore,
    credentialStore: any CredentialStore,
    httpClient: any ManifestHTTPClient = URLSessionManifestHTTPClient()
) {
    self.store = store
    self.credentialStore = credentialStore
    self.httpClient = httpClient
}
```

and instantiate manifest providers as:

```swift
ManifestProvider(manifest: package.manifest, httpClient: httpClient, credentialStore: credentialStore)
```

When building `self.providers`, merge built-ins + installed + explicit. Preserve explicit override behavior:

```swift
let installed = loadInstalledManifestProviders()
self.providers = Self.mergedProviders(
    builtIns: builtInProviderFactory?.providers(settings: loadedSettings) ?? [] + installed,
    explicit: providers
)
```

If Swift precedence makes that expression unclear, use:

```swift
let baseProviders = (builtInProviderFactory?.providers(settings: loadedSettings) ?? []) + installed
self.providers = Self.mergedProviders(builtIns: baseProviders, explicit: providers)
```

Update `rebuildBuiltInProvidersIfNeeded()` to include installed providers:

```swift
let baseProviders = builtInProviderFactory.providers(settings: settings) + loadInstalledManifestProviders()
providers = Self.mergedProviders(builtIns: baseProviders, explicit: explicitProviders)
```

Add public accessors:

```swift
public func installedProviders() -> [InstalledProviderRecord] {
    installedProviderRecords
}

public func reloadInstalledProviders() {
    rebuildBuiltInProvidersIfNeeded()
}
```

- [ ] **Step 4: Verify Engine test passes**

Run: `swift test --filter EngineTests/testRefreshLoadsInstalledManifestProviders`

Expected: test passes.

- [ ] **Step 5: Run related tests**

Run: `swift test --filter 'EngineTests|InstalledManifestProviderLoaderTests'`

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/Engine.swift Sources/AmbitCore/InstalledManifestProviderLoader.swift Tests/AmbitCoreTests/EngineTests.swift Tests/AmbitCoreTests/InstalledManifestProviderLoaderTests.swift
git commit -m "Load installed providers in engine"
```

---

### Task 4: Manifest Provider Setup View Model Support

**Files:**
- Modify: `Sources/AmbitMenuBar/StatusViewModel.swift`
- Test: add Core tests only if logic is moved into Core; otherwise compile-check via `swift test`

- [ ] **Step 1: Add Core install helper tests**

Add to `InstalledProviderStoreTests`:

```swift
func testInstalledProviderStoreInstallsManifestPackageRecord() throws {
    let directory = try Self.writeManifest(id: "demo.install", displayName: "Install Demo")
    let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
    let store = UserDefaultsInstalledProviderStore(defaults: defaults)

    let record = try store.installManifestPackage(at: directory)

    XCTAssertEqual(record.id, "demo.install")
    XCTAssertEqual(record.displayName, "Install Demo")
    XCTAssertEqual(record.packagePath, directory.path)
    XCTAssertEqual(record.isEnabled, true)
    XCTAssertEqual(record.lastValidation, .valid)
    XCTAssertEqual(try store.load(), [record])
}
```

Include helper in the same test file:

```swift
private static func writeManifest(id: String, displayName: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ambit-install-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "id": "\(id)",
      "displayName": "\(displayName)",
      "pollInterval": 30,
      "endpoint": { "method": "GET", "url": "https://example.test/status" },
      "metrics": [],
      "commands": []
    }
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}
```

- [ ] **Step 2: Run store test red**

Run: `swift test --filter InstalledProviderStoreTests/testInstalledProviderStoreInstallsManifestPackageRecord`

Expected: compile failure for missing `installManifestPackage(at:)`.

- [ ] **Step 3: Implement install/remove helpers**

Add extension to `InstalledProviderStore.swift`:

```swift
public extension InstalledProviderStore {
    @discardableResult
    func installManifestPackage(at directory: URL) throws -> InstalledProviderRecord {
        let package = try ProviderManifestPackage.load(from: directory)
        let record = InstalledProviderRecord(
            id: package.manifest.id,
            displayName: package.manifest.displayName,
            packagePath: directory.path,
            isEnabled: true,
            lastValidation: .valid
        )
        var records = try load().filter { $0.id != record.id }
        records.append(record)
        try save(records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        return record
    }

    func remove(providerID: ProviderID) throws {
        try save(try load().filter { $0.id != providerID })
    }
}
```

- [ ] **Step 4: Extend StatusViewModel**

Add stored property:

```swift
private let installedProviderStore: any InstalledProviderStore
```

Add published state:

```swift
@Published var installedProviders: [InstalledProviderRecord] = []
@Published var providerSetupError: String?
```

Update initializer with default:

```swift
installedProviderStore: any InstalledProviderStore = UserDefaultsInstalledProviderStore()
```

Pass it into `Engine(...)` as `installedProviderStore: installedProviderStore`.

Add methods:

```swift
func refreshInstalledProviders() {
    installedProviders = (try? installedProviderStore.load()) ?? []
}

func installManifestProvider(from directory: URL) {
    do {
        _ = try installedProviderStore.installManifestPackage(at: directory)
        providerSetupError = nil
        refreshInstalledProviders()
        Task {
            await engine.reloadInstalledProviders()
            await refresh()
        }
    } catch {
        providerSetupError = error.localizedDescription
    }
}

func setInstalledProvider(_ providerID: ProviderID, enabled: Bool) {
    do {
        try installedProviderStore.setEnabled(enabled, providerID: providerID)
        providerSetupError = nil
        refreshInstalledProviders()
        Task {
            await engine.reloadInstalledProviders()
            await refresh()
        }
    } catch {
        providerSetupError = error.localizedDescription
    }
}

func removeInstalledProvider(_ providerID: ProviderID) {
    do {
        try installedProviderStore.remove(providerID: providerID)
        providerSetupError = nil
        refreshInstalledProviders()
        Task {
            await engine.reloadInstalledProviders()
            await refresh()
        }
    } catch {
        providerSetupError = error.localizedDescription
    }
}
```

Call `refreshInstalledProviders()` in `start()` before/after command palette refresh.

- [ ] **Step 5: Verify compile and tests**

Run: `swift test --filter 'InstalledProviderStoreTests|EngineTests'`

Expected: selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/InstalledProviderStore.swift Sources/AmbitMenuBar/StatusViewModel.swift Tests/AmbitCoreTests/InstalledProviderStoreTests.swift
git commit -m "Add provider install view model support"
```

---

### Task 5: Provider Manager Settings UI

**Files:**
- Modify: `Sources/AmbitMenuBar/SettingsView.swift`

- [ ] **Step 1: Add provider manager UI**

Replace the existing `SettingsView` body with a `TabView` or grouped sections. Keep Router/Polling/Tools/EcoFlow intact and add Providers. Use `fileImporter` for local folders.

Add state:

```swift
@State private var isImportingProvider = false
```

Add section:

```swift
Section("Providers") {
    if viewModel.installedProviders.isEmpty {
        Text("No manifest providers installed")
            .foregroundStyle(.secondary)
    } else {
        ForEach(viewModel.installedProviders) { provider in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading) {
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
.fileImporter(
    isPresented: $isImportingProvider,
    allowedContentTypes: [.folder],
    allowsMultipleSelection: false
) { result in
    if case .success(let urls) = result, let url = urls.first {
        viewModel.installManifestProvider(from: url)
    }
}
```

If `.folder` requires importing `UniformTypeIdentifiers`, add:

```swift
import UniformTypeIdentifiers
```

- [ ] **Step 2: Compile Settings UI**

Run: `swift build`

Expected: build succeeds. If `.folder` is unavailable, use `UTType.folder`.

- [ ] **Step 3: Run full tests**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitMenuBar/SettingsView.swift
git commit -m "Add manifest provider manager UI"
```

---

### Task 6: Generic Provider Display Model

**Files:**
- Create: `Sources/AmbitCore/ProviderDisplayModel.swift`
- Modify: `Sources/AmbitMenuBar/MenuContent.swift`
- Test: `Tests/AmbitCoreTests/ProviderDisplayModelTests.swift`

- [ ] **Step 1: Write display model tests**

```swift
import XCTest
@testable import AmbitCore

final class ProviderDisplayModelTests: XCTestCase {
    func testBuildsMissingCredentialDisplayModel() {
        let model = ProviderDisplayModel.make(
            providerID: "demo.secure",
            providerName: "Secure Demo",
            state: SourceState(value: ProviderSnapshot(health: .down, error: "Manifest credential api_token is not configured.")),
            commands: []
        )

        XCTAssertEqual(model.title, "Secure Demo")
        XCTAssertEqual(model.health, .down)
        XCTAssertEqual(model.primaryMessage, "Manifest credential api_token is not configured.")
        XCTAssertEqual(model.action, .configureCredentials)
    }

    func testCommandSummariesIncludeParametersAndConfirmation() {
        let model = ProviderDisplayModel.make(
            providerID: "demo.secure",
            providerName: "Secure Demo",
            state: SourceState(value: ProviderSnapshot(health: .ok)),
            commands: [
                CommandDescriptor(
                    id: "demo.run",
                    label: "Run",
                    parameters: [CommandParameter(id: "host", label: "Host", kind: .text)],
                    requiresConfirmation: true
                )
            ]
        )

        XCTAssertEqual(model.commands, [
            ProviderCommandDisplayModel(id: "demo.run", label: "Run", detail: "1 param · confirmation")
        ])
    }
}
```

- [ ] **Step 2: Run display tests red**

Run: `swift test --filter ProviderDisplayModelTests`

Expected: compile failure for missing display model types.

- [ ] **Step 3: Implement display model**

Create `Sources/AmbitCore/ProviderDisplayModel.swift`:

```swift
import Foundation

public enum ProviderDisplayAction: Equatable, Sendable {
    case none
    case configureCredentials
}

public struct ProviderCommandDisplayModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String
}

public struct ProviderDisplayModel: Equatable, Sendable {
    public var providerID: ProviderID
    public var title: String
    public var health: Health
    public var isLoading: Bool
    public var primaryMessage: String
    public var metrics: [Metric]
    public var metricSections: [ProviderMetricSection]
    public var commands: [ProviderCommandDisplayModel]
    public var diagnostic: ProviderDiagnostic?
    public var action: ProviderDisplayAction

    public static func make(
        providerID: ProviderID,
        providerName: String,
        state: SourceState<ProviderSnapshot>?,
        commands: [CommandDescriptor]
    ) -> ProviderDisplayModel {
        let snapshot = state?.value
        let error = (state?.errorMessage ?? snapshot?.error).map(ProviderDisplayText.singleLine)
        let health = snapshot?.health ?? (error == nil ? .unknown : .down)
        let metrics = snapshot?.metrics ?? []
        let action: ProviderDisplayAction = error?.contains("Manifest credential") == true ? .configureCredentials : .none
        let primaryMessage = error ?? {
            if metrics.isEmpty { return "No metrics reported yet" }
            return metrics.prefix(2).map { "\($0.label) \(ProviderMetricFormat.string($0))" }.joined(separator: " · ")
        }()

        return ProviderDisplayModel(
            providerID: providerID,
            title: providerName,
            health: health,
            isLoading: state?.isLoading == true,
            primaryMessage: primaryMessage,
            metrics: metrics,
            metricSections: ProviderMetricSection.sections(from: metrics),
            commands: commands.map(commandDisplayModel),
            diagnostic: snapshot.flatMap { ProviderDiagnostic.make(providerID: providerID, providerName: providerName, snapshot: $0) },
            action: action
        )
    }

    private static func commandDisplayModel(_ command: CommandDescriptor) -> ProviderCommandDisplayModel {
        var details: [String] = []
        if !command.parameters.isEmpty {
            details.append(command.parameters.count == 1 ? "1 param" : "\(command.parameters.count) params")
        }
        if command.requiresConfirmation {
            details.append("confirmation")
        }
        return ProviderCommandDisplayModel(id: command.id, label: command.label, detail: details.joined(separator: " · "))
    }
}
```

- [ ] **Step 4: Update generic provider detail to use display model**

In `GenericProviderDetailView`, add:

```swift
private var displayModel: ProviderDisplayModel {
    ProviderDisplayModel.make(
        providerID: providerID,
        providerName: providerName,
        state: state,
        commands: providerCommands.map(\.command)
    )
}
```

Replace direct uses:

- `snapshot?.health ?? .unknown` with `displayModel.health`.
- `metrics` with `displayModel.metrics`.
- `metricSections` with `displayModel.metricSections`.
- error text with `displayModel.primaryMessage` when non-empty.
- command detail text with matching `displayModel.commands`.

Add prompt in generic detail:

```swift
if displayModel.action == .configureCredentials {
    Button {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } label: {
        Label("Configure credentials", systemImage: "key")
    }
    .buttonStyle(.borderedProminent)
}
```

- [ ] **Step 5: Verify display tests and build**

Run: `swift test --filter ProviderDisplayModelTests && swift build`

Expected: tests and build pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/ProviderDisplayModel.swift Sources/AmbitMenuBar/MenuContent.swift Tests/AmbitCoreTests/ProviderDisplayModelTests.swift
git commit -m "Add generic provider display model"
```

---

### Task 7: Manifest Transforms

**Files:**
- Modify: `Sources/AmbitCore/ProviderManifest.swift`
- Modify: `Sources/AmbitCore/ManifestProvider.swift`
- Test: `Tests/AmbitCoreTests/ProviderManifestTransformTests.swift`

- [ ] **Step 1: Write transform tests**

```swift
import XCTest
@testable import AmbitCore

final class ProviderManifestTransformTests: XCTestCase {
    func testAppliesNumericTransformsWhenMappingMetrics() async {
        let client = StubManifestHTTPClient(responses: [.success(#"{ "battery": 0.42, "state": "online" }"#)])
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.transform",
            displayName: "Transform Demo",
            pollInterval: 30,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(
                    id: "battery_percent",
                    label: "Battery",
                    value: .init(type: .percent, path: "battery", transforms: [.multiply(100), .round])
                )
            ]
        )
        let provider = ManifestProvider(manifest: manifest, httpClient: client)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metric("battery_percent")?.value, .percent(42))
    }
}
```

- [ ] **Step 2: Run transform tests red**

Run: `swift test --filter ProviderManifestTransformTests`

Expected: compile failure for missing `transforms` and transform enum.

- [ ] **Step 3: Add transform schema**

In `ProviderManifest.ValueMapping`, add:

```swift
public var transforms: [Transform]

public init(type: ValueType, path: String, transforms: [Transform] = []) {
    self.type = type
    self.path = path
    self.transforms = transforms
}
```

Add custom decode defaulting transforms to `[]`.

Add enum:

```swift
enum Transform: Codable, Equatable, Sendable {
    case multiply(Double)
    case divide(Double)
    case round
    case clamp(min: Double?, max: Double?)
    case defaultValue(JSONValue)
}
```

Implement tagged decoding with JSON shape:

```json
{ "type": "multiply", "value": 100 }
{ "type": "round" }
{ "type": "clamp", "min": 0, "max": 100 }
```

- [ ] **Step 4: Apply transforms in ManifestProvider**

Before converting to `MetricValue`, apply:

```swift
let transformed = mapping.value.transforms.reduce(source) { current, transform in
    transform.apply(to: current)
}
```

Implement `apply(to:)` for numeric operations and default value. Numeric transforms leave non-numeric values unchanged except `defaultValue`, which replaces `null` or missing values when used by the mapping path fallback.

- [ ] **Step 5: Verify transform tests**

Run: `swift test --filter ProviderManifestTransformTests`

Expected: tests pass.

- [ ] **Step 6: Run manifest regression tests**

Run: `swift test --filter 'ProviderManifestTests|ManifestProviderTests|ProviderManifestTransformTests'`

Expected: selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/AmbitCore/ProviderManifest.swift Sources/AmbitCore/ManifestProvider.swift Tests/AmbitCoreTests/ProviderManifestTransformTests.swift
git commit -m "Add manifest value transforms"
```

---

### Task 8: Manifest Layout Hints

**Files:**
- Modify: `Sources/AmbitCore/ProviderManifest.swift`
- Modify: `Sources/AmbitCore/ProviderDisplayModel.swift`
- Test: `Tests/AmbitCoreTests/ProviderManifestTests.swift`, `Tests/AmbitCoreTests/ProviderDisplayModelTests.swift`

- [ ] **Step 1: Add layout decode and display tests**

Add to `ProviderManifestTests`:

```swift
func testDecodesManifestLayoutHints() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "demo.layout",
      "displayName": "Layout Demo",
      "pollInterval": 30,
      "layout": {
        "icon": "bolt",
        "accent": "green",
        "primaryMetric": "battery_percent"
      },
      "endpoint": { "method": "GET", "url": "https://example.test/status" },
      "metrics": [
        { "id": "battery_percent", "label": "Battery", "value": { "type": "percent", "path": "battery" } }
      ],
      "commands": []
    }
    """

    let manifest = try ProviderManifest.decode(Data(json.utf8))

    XCTAssertEqual(manifest.layout, ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent"))
}
```

Add to `ProviderDisplayModelTests`:

```swift
func testDisplayModelUsesLayoutPrimaryMetric() {
    let model = ProviderDisplayModel.make(
        providerID: "demo.layout",
        providerName: "Layout Demo",
        state: SourceState(value: ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "latency", label: "Latency", value: .latency(ms: 20)),
            Metric(id: "battery_percent", label: "Battery", value: .percent(81))
        ])),
        commands: [],
        layout: ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent")
    )

    XCTAssertEqual(model.primaryMetric?.id, "battery_percent")
    XCTAssertEqual(model.icon, "bolt")
    XCTAssertEqual(model.accent, "green")
}
```

- [ ] **Step 2: Run tests red**

Run: `swift test --filter 'ProviderManifestTests/testDecodesManifestLayoutHints|ProviderDisplayModelTests/testDisplayModelUsesLayoutPrimaryMetric'`

Expected: compile failure for missing layout types and display fields.

- [ ] **Step 3: Implement layout schema**

Add to `ProviderManifest`:

```swift
public var layout: Layout?
```

Add initializer parameter and decoder default.

Add nested type:

```swift
struct Layout: Codable, Equatable, Sendable {
    public var icon: String?
    public var accent: String?
    public var primaryMetric: String?

    public init(icon: String? = nil, accent: String? = nil, primaryMetric: String? = nil) {
        self.icon = icon
        self.accent = accent
        self.primaryMetric = primaryMetric
    }
}
```

Validate `primaryMetric` if present:

```swift
if let primaryMetric = layout?.primaryMetric, !metrics.map(\.id).contains(primaryMetric) {
    throw ValidationError.invalidLayoutMetricID(primaryMetric)
}
```

- [ ] **Step 4: Extend display model**

Add fields:

```swift
public var primaryMetric: Metric?
public var icon: String?
public var accent: String?
```

Change make signature:

```swift
layout: ProviderManifest.Layout? = nil
```

Choose primary metric:

```swift
let primaryMetric = layout?.primaryMetric.flatMap { id in metrics.first { $0.id == id } } ?? metrics.first
```

- [ ] **Step 5: Verify layout tests**

Run: `swift test --filter 'ProviderManifestTests|ProviderDisplayModelTests'`

Expected: selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/ProviderManifest.swift Sources/AmbitCore/ProviderDisplayModel.swift Tests/AmbitCoreTests/ProviderManifestTests.swift Tests/AmbitCoreTests/ProviderDisplayModelTests.swift
git commit -m "Add manifest layout hints"
```

---

### Task 9: Manifest Alert Declarations

**Files:**
- Modify: `Sources/AmbitCore/ProviderManifest.swift`
- Create: `Sources/AmbitCore/ManifestAlertCompiler.swift`
- Test: `Tests/AmbitCoreTests/ManifestAlertCompilerTests.swift`

- [ ] **Step 1: Write alert compiler tests**

```swift
import XCTest
@testable import AmbitCore

final class ManifestAlertCompilerTests: XCTestCase {
    func testCompilesThresholdAlertDeclarations() throws {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo.alerts",
            displayName: "Alerts Demo",
            pollInterval: 30,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(id: "battery_percent", label: "Battery", value: .init(type: .percent, path: "battery"))
            ],
            alerts: [
                ProviderManifest.Alert(
                    id: "battery.low",
                    metricID: "battery_percent",
                    kind: .threshold(comparison: .lessThan, value: 20),
                    title: "Battery low",
                    message: "Battery is below 20%.",
                    severity: .warning
                )
            ]
        )

        XCTAssertEqual(ManifestAlertCompiler.rules(from: manifest), [
            .threshold(ThresholdAlertRule(
                id: "demo.alerts.battery.low",
                providerID: "demo.alerts",
                metricID: "battery_percent",
                comparison: .lessThan,
                threshold: 20,
                title: "Battery low",
                message: "Battery is below 20%.",
                severity: .warning
            ))
        ])
    }
}
```

- [ ] **Step 2: Run alert tests red**

Run: `swift test --filter ManifestAlertCompilerTests`

Expected: compile failure for missing manifest alert schema and compiler.

- [ ] **Step 3: Add alert schema**

Add to `ProviderManifest`:

```swift
public var alerts: [Alert]
```

Add initializer parameter and decoder default.

Add nested:

```swift
struct Alert: Codable, Equatable, Sendable {
    public var id: String
    public var metricID: String
    public var kind: Kind
    public var title: String
    public var message: String
    public var severity: AlertSeverity

    public enum Kind: Codable, Equatable, Sendable {
        case threshold(comparison: AlertComparison, value: Double)
        case stateTransition(value: MetricValue)
        case sustained(comparison: AlertComparison, value: Double, duration: TimeInterval)
    }
}
```

If `AlertComparison` and `MetricValue` do not decode yet, add `Codable` conformance in a focused way or add manifest-specific enums and map them in the compiler.

Validate alert metric ids:

```swift
for alert in alerts where !metrics.map(\.id).contains(alert.metricID) {
    throw ValidationError.invalidAlertMetricID(alert.id, alert.metricID)
}
```

- [ ] **Step 4: Implement compiler**

Create `Sources/AmbitCore/ManifestAlertCompiler.swift`:

```swift
public enum ManifestAlertCompiler {
    public static func rules(from manifest: ProviderManifest) -> [AlertRule] {
        manifest.alerts.map { alert in
            let ruleID = "\(manifest.id).\(alert.id)"
            switch alert.kind {
            case .threshold(let comparison, let value):
                return .threshold(ThresholdAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    comparison: comparison,
                    threshold: value,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            case .stateTransition(let value):
                return .stateTransition(StateTransitionAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    expectedValue: value,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            case .sustained(let comparison, let value, let duration):
                return .sustained(SustainedAlertRule(
                    id: ruleID,
                    providerID: manifest.id,
                    metricID: alert.metricID,
                    comparison: comparison,
                    threshold: value,
                    duration: duration,
                    title: alert.title,
                    message: alert.message,
                    severity: alert.severity
                ))
            }
        }
    }
}
```

- [ ] **Step 5: Verify alert compiler tests**

Run: `swift test --filter ManifestAlertCompilerTests`

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/ProviderManifest.swift Sources/AmbitCore/ManifestAlertCompiler.swift Tests/AmbitCoreTests/ManifestAlertCompilerTests.swift
git commit -m "Compile manifest alert declarations"
```

---

### Task 10: Examples And Documentation

**Files:**
- Create: `Examples/provider-manifests/secure-post-demo/manifest.json`
- Create: `Examples/provider-manifests/transform-layout-alert-demo/manifest.json`
- Modify: `MIGRATION_PLAN.md`
- Modify or create: `docs/provider-manifests.md`

- [ ] **Step 1: Add secure POST example manifest**

Create `Examples/provider-manifests/secure-post-demo/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "demo.secure-post",
  "displayName": "Secure POST Demo",
  "pollInterval": 30,
  "credentials": [
    {
      "id": "api_token",
      "label": "API Token",
      "kind": "bearerToken",
      "required": true
    }
  ],
  "endpoint": {
    "method": "POST",
    "url": "https://example.test/status",
    "headers": {
      "Authorization": "Bearer {credential.api_token}",
      "Content-Type": "application/json"
    },
    "body": "{\"query\":\"status\"}"
  },
  "metrics": [
    {
      "id": "ok",
      "label": "OK",
      "value": { "type": "bool", "path": "ok" }
    }
  ],
  "commands": []
}
```

- [ ] **Step 2: Add transform/layout/alert example manifest**

Create `Examples/provider-manifests/transform-layout-alert-demo/manifest.json` with current schema from Tasks 7-9:

```json
{
  "schemaVersion": 1,
  "id": "demo.power",
  "displayName": "Power Demo",
  "pollInterval": 30,
  "layout": {
    "icon": "bolt",
    "accent": "green",
    "primaryMetric": "battery_percent"
  },
  "endpoint": {
    "method": "GET",
    "url": "https://example.test/power"
  },
  "metrics": [
    {
      "id": "battery_percent",
      "label": "Battery",
      "value": {
        "type": "percent",
        "path": "battery_ratio",
        "transforms": [
          { "type": "multiply", "value": 100 },
          { "type": "round" }
        ]
      }
    }
  ],
  "alerts": [
    {
      "id": "battery.low",
      "metricID": "battery_percent",
      "kind": { "type": "threshold", "comparison": "lessThan", "value": 20 },
      "title": "Power Demo battery low",
      "message": "Power Demo battery is below 20%.",
      "severity": "warning"
    }
  ],
  "commands": []
}
```

- [ ] **Step 3: Add manifest docs**

Create `docs/provider-manifests.md` explaining:

```markdown
# Provider Manifests

Provider manifests are declarative HTTP integrations. They declare an endpoint, credentials, metric mappings, optional layout hints, optional default alerts, and optional commands.

Use `ambit-check --validate-manifest <folder>` to validate a package.

Use `ambit-check --run-manifest <folder> --manifest-credential api_token=value` to run a credentialed package from the CLI.
```

Include compact JSON snippets for credentials, transforms, layout, and alerts using the examples above.

- [ ] **Step 4: Update migration status**

Update `MIGRATION_PLAN.md` status to mention installed provider setup, display model, transforms, layout hints, and alert declarations once implemented.

- [ ] **Step 5: Verify examples and tests**

Run:

```bash
swift run ambit-check --validate-manifest Examples/provider-manifests/secure-post-demo
swift run ambit-check --validate-manifest Examples/provider-manifests/transform-layout-alert-demo
swift test
git diff --check
```

Expected: both manifests validate, all tests pass, whitespace check passes.

- [ ] **Step 6: Commit**

```bash
git add Examples/provider-manifests docs/provider-manifests.md MIGRATION_PLAN.md
git commit -m "Document expanded provider manifests"
```

---

## Final Verification

- [ ] Run full tests:

```bash
swift test
```

Expected: all tests pass.

- [ ] Run build:

```bash
swift build
```

Expected: build succeeds.

- [ ] Run CLI checks:

```bash
swift run ambit-check --validate-manifest Examples/provider-manifests/ping-demo
swift run ambit-check --validate-manifest Examples/provider-manifests/secure-post-demo
swift run ambit-check --validate-manifest Examples/provider-manifests/transform-layout-alert-demo
```

Expected: all manifests valid.

- [ ] Relaunch dev app:

```bash
old_pid=$(pgrep -f '/private/tmp/AmbitMenuBar.app/Contents/MacOS/AmbitMenuBar' || true)
if [ -n "$old_pid" ]; then kill $old_pid; fi
rm -rf /private/tmp/AmbitMenuBar.app
mkdir -p /private/tmp/AmbitMenuBar.app/Contents/MacOS /private/tmp/AmbitMenuBar.app/Contents/Resources
cp .build/debug/AmbitMenuBar /private/tmp/AmbitMenuBar.app/Contents/MacOS/AmbitMenuBar
if [ -d .build/debug/AmbitMenuBar_AmbitMenuBar.resources ]; then cp -R .build/debug/AmbitMenuBar_AmbitMenuBar.resources /private/tmp/AmbitMenuBar.app/Contents/Resources/; fi
open /private/tmp/AmbitMenuBar.app
sleep 2
pgrep -fl '/private/tmp/AmbitMenuBar.app/Contents/MacOS/AmbitMenuBar'
```

Expected: app process is running.

---

## Self-Review Notes

- Spec coverage: setup store and UI covered by Tasks 1-5; generic display model covered by Task 6; runtime transforms/layout/alerts covered by Tasks 7-9; examples/docs covered by Task 10.
- Scope control: package registry, cloud sync, JS runtime, widgets/island implementation, and built-in integration hardening remain out of scope.
- Type consistency: plan consistently uses `InstalledProviderRecord`, `InstalledProviderValidation`, `InstalledProviderStore`, `InstalledManifestProviderLoader`, `ProviderDisplayModel`, and `ManifestAlertCompiler`.
