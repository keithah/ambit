# Provider Polish And Surface Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish manifest provider setup and generic provider runtime UX while adding reusable Core surface models for future widgets, island-style glances, notifications, and app-window surfaces.

**Architecture:** Core owns setup summaries, credential completeness, surface summaries, and enriched manifest reports. AmbitMenuBar renders those Core models in Settings and generic provider detail without owning platform state. No OS-specific widget/island/window target is added in this milestone.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Codable`, existing `CredentialStore`, `ProviderManifest`, `Engine`, `ProviderDisplayModel`, XCTest.

---

## File Structure

- Create `Sources/AmbitCore/ProviderSetupSummary.swift`: UI-safe installed-provider setup summary, credential completeness, package validation summary, and factory helpers.
- Create `Tests/AmbitCoreTests/ProviderSetupSummaryTests.swift`: setup summary tests for valid, invalid, missing credential, saved credential, and disabled provider states.
- Modify `Sources/AmbitMenuBar/StatusViewModel.swift`: expose setup summaries and delegate credential/package actions through existing stores.
- Modify `Sources/AmbitMenuBar/SettingsView.swift`: render setup summaries rather than raw records.
- Create `Sources/AmbitCore/ProviderSurfaceModel.swift`: compact provider and notification surface models.
- Create `Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift`: surface model tests for health, primary metric, commands, alerts, diagnostics, sorting, and notification event mapping.
- Modify `Sources/AmbitMenuBar/MenuContent.swift`: use surface model fields where useful for generic provider rows/detail without changing dedicated provider detail views.
- Modify `Sources/AmbitCore/ProviderManifestReport.swift`: include layout, transforms, alerts, credential required/optional status, and richer command metadata in CLI validation reports.
- Modify `Tests/AmbitCoreTests/ProviderManifestReportTests.swift`: assert richer report lines.
- Modify `docs/provider-manifests.md`: document setup states and surface/layout expectations.

---

### Task 1: Core Provider Setup Summary

**Files:**
- Create: `Sources/AmbitCore/ProviderSetupSummary.swift`
- Test: `Tests/AmbitCoreTests/ProviderSetupSummaryTests.swift`

- [ ] **Step 1: Write failing setup summary tests**

Create `Tests/AmbitCoreTests/ProviderSetupSummaryTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class ProviderSetupSummaryTests: XCTestCase {
    func testBuildsValidSetupSummaryWithMissingRequiredCredential() throws {
        let directory = try Self.writeManifest(
            id: "demo.secure",
            displayName: "Secure Demo",
            credentialsJSON: #"""
            [
              { "id": "api_token", "label": "API Token", "kind": "bearerToken", "required": true },
              { "id": "region", "label": "Region", "kind": "header", "required": false }
            ]
            """#
        )
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: directory.path,
            isEnabled: true,
            lastValidation: .valid
        )
        let credentialStore = StaticCredentialStore(credentials: [:])

        let summary = ProviderSetupSummary.make(record: record, credentialStore: credentialStore)

        XCTAssertEqual(summary.id, "demo.secure")
        XCTAssertEqual(summary.displayName, "Secure Demo")
        XCTAssertEqual(summary.status, .needsCredentials)
        XCTAssertEqual(summary.statusText, "Missing required credentials")
        XCTAssertEqual(summary.credentials, [
            ProviderCredentialSetupSummary(id: "api_token", label: "API Token", kind: "bearerToken", isRequired: true, isConfigured: false),
            ProviderCredentialSetupSummary(id: "region", label: "Region", kind: "header", isRequired: false, isConfigured: false)
        ])
        XCTAssertEqual(summary.primaryAction, .saveCredentials)
    }

    func testBuildsReadySummaryWhenRequiredCredentialsAreConfigured() throws {
        let directory = try Self.writeManifest(
            id: "demo.secure",
            displayName: "Secure Demo",
            credentialsJSON: #"""
            [
              { "id": "api_token", "label": "API Token", "kind": "bearerToken", "required": true }
            ]
            """#
        )
        let record = InstalledProviderRecord(id: "demo.secure", displayName: "Secure Demo", packagePath: directory.path, isEnabled: true)
        let credentialStore = StaticCredentialStore.manifestCredentials(providerID: "demo.secure", values: ["api_token": "secret"])

        let summary = ProviderSetupSummary.make(record: record, credentialStore: credentialStore)

        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.statusText, "Ready")
        XCTAssertEqual(summary.credentials.first?.isConfigured, true)
        XCTAssertEqual(summary.primaryAction, .refreshValidation)
    }

    func testInvalidManifestRecordStaysManageable() {
        let record = InstalledProviderRecord(
            id: "demo.bad",
            displayName: "Broken Demo",
            packagePath: "/tmp/missing",
            isEnabled: true,
            lastValidation: .invalid("Manifest file is missing at /tmp/missing/manifest.json.")
        )

        let summary = ProviderSetupSummary.make(record: record, credentialStore: StaticCredentialStore(credentials: [:]))

        XCTAssertEqual(summary.status, .invalid)
        XCTAssertEqual(summary.statusText, "Manifest file is missing at /tmp/missing/manifest.json.")
        XCTAssertEqual(summary.credentials, [])
        XCTAssertEqual(summary.primaryAction, .refreshValidation)
    }

    func testDisabledProviderSummaryIsDisabledEvenWhenValid() throws {
        let directory = try Self.writeManifest(id: "demo.off", displayName: "Off Demo")
        let record = InstalledProviderRecord(id: "demo.off", displayName: "Off Demo", packagePath: directory.path, isEnabled: false)

        let summary = ProviderSetupSummary.make(record: record, credentialStore: StaticCredentialStore(credentials: [:]))

        XCTAssertEqual(summary.status, .disabled)
        XCTAssertEqual(summary.statusText, "Disabled")
    }

    private static func writeManifest(
        id: String,
        displayName: String,
        credentialsJSON: String = "[]"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-setup-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "pollInterval": 30,
          "credentials": \(credentialsJSON),
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [],
          "commands": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
```

- [ ] **Step 2: Run setup summary tests red**

Run:

```bash
swift test --filter ProviderSetupSummaryTests
```

Expected: compile failure for missing `ProviderSetupSummary`, `ProviderCredentialSetupSummary`, `ProviderSetupStatus`, and `ProviderSetupAction`.

- [ ] **Step 3: Implement setup summary model**

Create `Sources/AmbitCore/ProviderSetupSummary.swift`:

```swift
import Foundation

public enum ProviderSetupStatus: Equatable, Sendable {
    case ready
    case needsCredentials
    case invalid
    case disabled
}

public enum ProviderSetupAction: Equatable, Sendable {
    case refreshValidation
    case saveCredentials
}

public struct ProviderCredentialSetupSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: String
    public var isRequired: Bool
    public var isConfigured: Bool

    public init(id: String, label: String, kind: String, isRequired: Bool, isConfigured: Bool) {
        self.id = id
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.isConfigured = isConfigured
    }
}

public struct ProviderSetupSummary: Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var displayName: String
    public var packagePath: String
    public var isEnabled: Bool
    public var status: ProviderSetupStatus
    public var statusText: String
    public var credentials: [ProviderCredentialSetupSummary]
    public var primaryAction: ProviderSetupAction

    public init(
        id: ProviderID,
        displayName: String,
        packagePath: String,
        isEnabled: Bool,
        status: ProviderSetupStatus,
        statusText: String,
        credentials: [ProviderCredentialSetupSummary],
        primaryAction: ProviderSetupAction
    ) {
        self.id = id
        self.displayName = displayName
        self.packagePath = packagePath
        self.isEnabled = isEnabled
        self.status = status
        self.statusText = statusText
        self.credentials = credentials
        self.primaryAction = primaryAction
    }

    public static func make(record: InstalledProviderRecord, credentialStore: any CredentialStore) -> ProviderSetupSummary {
        let credentials = credentialSummaries(record: record, credentialStore: credentialStore)
        let hasMissingRequiredCredential = credentials.contains { $0.isRequired && !$0.isConfigured }

        let status: ProviderSetupStatus
        let statusText: String
        let primaryAction: ProviderSetupAction
        if !record.isEnabled {
            status = .disabled
            statusText = "Disabled"
            primaryAction = .refreshValidation
        } else if case .invalid(let message) = record.lastValidation {
            status = .invalid
            statusText = ProviderDisplayText.singleLine(message)
            primaryAction = .refreshValidation
        } else if hasMissingRequiredCredential {
            status = .needsCredentials
            statusText = "Missing required credentials"
            primaryAction = .saveCredentials
        } else {
            status = .ready
            statusText = "Ready"
            primaryAction = .refreshValidation
        }

        return ProviderSetupSummary(
            id: record.id,
            displayName: record.displayName,
            packagePath: record.packagePath,
            isEnabled: record.isEnabled,
            status: status,
            statusText: statusText,
            credentials: credentials,
            primaryAction: primaryAction
        )
    }

    private static func credentialSummaries(
        record: InstalledProviderRecord,
        credentialStore: any CredentialStore
    ) -> [ProviderCredentialSetupSummary] {
        guard case .valid = record.lastValidation,
              let package = try? ProviderManifestPackage.load(from: URL(fileURLWithPath: record.packagePath, isDirectory: true))
        else { return [] }

        return package.manifest.credentials.map { credential in
            let stored = (try? credentialStore.credential(CredentialKey(providerID: package.manifest.id, id: credential.id))) ?? nil
            return ProviderCredentialSetupSummary(
                id: credential.id,
                label: credential.label,
                kind: credential.kind.rawValue,
                isRequired: credential.required,
                isConfigured: stored?.isEmpty == false
            )
        }
    }
}
```

- [ ] **Step 4: Verify setup summary tests pass**

Run:

```bash
swift test --filter ProviderSetupSummaryTests
```

Expected: all `ProviderSetupSummaryTests` pass.

- [ ] **Step 5: Commit setup summary**

```bash
git add Sources/AmbitCore/ProviderSetupSummary.swift Tests/AmbitCoreTests/ProviderSetupSummaryTests.swift
git commit -m "Add provider setup summaries"
```

---

### Task 2: Settings Uses Setup Summaries

**Files:**
- Modify: `Sources/AmbitMenuBar/StatusViewModel.swift`
- Modify: `Sources/AmbitMenuBar/SettingsView.swift`

- [ ] **Step 1: Extend view model with setup summaries**

In `Sources/AmbitMenuBar/StatusViewModel.swift`, add:

```swift
@Published var providerSetupSummaries: [ProviderSetupSummary] = []
```

Update `refreshInstalledProviders()`:

```swift
func refreshInstalledProviders() {
    installedProviders = (try? installedProviderStore.load()) ?? []
    providerSetupSummaries = installedProviders.map { record in
        ProviderSetupSummary.make(record: record, credentialStore: credentialStore)
    }
    loadProviderCredentialValues()
}
```

Add validation refresh:

```swift
func refreshInstalledProviderValidation(_ providerID: ProviderID) {
    do {
        guard let record = installedProviders.first(where: { $0.id == providerID }) else { return }
        let package = try ProviderManifestPackage.load(from: URL(fileURLWithPath: record.packagePath, isDirectory: true))
        var records = try installedProviderStore.load()
        guard let index = records.firstIndex(where: { $0.id == providerID }) else { return }
        records[index].id = package.manifest.id
        records[index].displayName = package.manifest.displayName
        records[index].lastValidation = .valid
        try installedProviderStore.save(records)
        providerSetupError = nil
        reloadInstalledProviders()
    } catch {
        providerSetupError = error.localizedDescription
    }
}
```

- [ ] **Step 2: Update Settings provider section**

In `Sources/AmbitMenuBar/SettingsView.swift`, change provider `ForEach` from `viewModel.installedProviders` to `viewModel.providerSetupSummaries`.

For each summary row, display:

```swift
Text(summary.displayName)
Text(summary.id)
Text(summary.statusText)
Text(summary.packagePath)
```

Use `summary.credentials` for saved/missing labels:

```swift
ForEach(summary.credentials) { credential in
    HStack {
        Image(systemName: credential.isConfigured ? "checkmark.circle" : "exclamationmark.circle")
        Text(credential.label)
        Text(credential.isRequired ? "Required" : "Optional")
    }
    SecureField(
        credential.label,
        text: viewModel.credentialBinding(providerID: summary.id, credentialID: credential.id)
    )
}
```

Keep existing actions but map by summary id:

```swift
Button("Refresh Validation") {
    viewModel.refreshInstalledProviderValidation(summary.id)
}
Button("Save Credentials") {
    if let provider = viewModel.installedProviders.first(where: { $0.id == summary.id }) {
        viewModel.saveInstalledProviderCredentials(provider)
    }
}
Button("Remove") {
    viewModel.removeInstalledProvider(summary.id)
}
```

- [ ] **Step 3: Compile SwiftUI changes**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Run setup-related tests**

Run:

```bash
swift test --filter 'ProviderSetupSummaryTests|InstalledProviderStoreTests|InstalledManifestProviderLoaderTests'
```

Expected: selected tests pass.

- [ ] **Step 5: Commit Settings setup summary UI**

```bash
git add Sources/AmbitMenuBar/StatusViewModel.swift Sources/AmbitMenuBar/SettingsView.swift
git commit -m "Use setup summaries in provider settings"
```

---

### Task 3: Core Surface Models

**Files:**
- Create: `Sources/AmbitCore/ProviderSurfaceModel.swift`
- Test: `Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift`

- [ ] **Step 1: Write failing surface model tests**

Create `Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class ProviderSurfaceModelTests: XCTestCase {
    func testBuildsCompactProviderSurfaceModel() {
        let state = SourceState(value: ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "battery_percent", label: "Battery", value: .percent(81)),
            Metric(id: "latency", label: "Latency", value: .latency(ms: 22))
        ]))
        let model = ProviderSurfaceModel.make(
            providerID: "demo.power",
            providerName: "Power Demo",
            state: state,
            commands: [CommandDescriptor(id: "demo.reboot", label: "Reboot", requiresConfirmation: true)],
            layout: ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent"),
            activeAlertCount: 1
        )

        XCTAssertEqual(model.id, "demo.power")
        XCTAssertEqual(model.title, "Power Demo")
        XCTAssertEqual(model.health, .ok)
        XCTAssertEqual(model.tone, .good)
        XCTAssertEqual(model.icon, "bolt")
        XCTAssertEqual(model.accent, "green")
        XCTAssertEqual(model.primaryMetric?.id, "battery_percent")
        XCTAssertEqual(model.primaryValueText, "81%")
        XCTAssertEqual(model.shortMessage, "Battery 81% · Latency 22 ms")
        XCTAssertEqual(model.commandCount, 1)
        XCTAssertEqual(model.activeAlertCount, 1)
    }

    func testSurfaceSnapshotSortsProvidersByTitle() {
        let snapshot = StatusSnapshot(providers: [
            "z": SourceState(value: ProviderSnapshot(health: .ok)),
            "a": SourceState(value: ProviderSnapshot(health: .down, error: "offline"))
        ])

        let surface = SurfaceSnapshot.make(
            snapshot: snapshot,
            providerNames: ["z": "Zulu", "a": "Alpha"],
            providerCommands: [:],
            providerLayouts: [:],
            activeAlertCounts: [:]
        )

        XCTAssertEqual(surface.providers.map(\.title), ["Alpha", "Zulu"])
        XCTAssertEqual(surface.providers.first?.tone, .bad)
    }

    func testNotificationSurfaceModelUsesAlertEvent() {
        let event = AlertEvent(
            id: "event-1",
            ruleID: "rule-1",
            providerID: "demo.power",
            title: "Battery low",
            message: "Battery below 20%.",
            severity: .warning,
            triggeredAt: Date(timeIntervalSince1970: 10)
        )

        let model = NotificationSurfaceModel(event: event, providerName: "Power Demo")

        XCTAssertEqual(model.id, "event-1")
        XCTAssertEqual(model.providerID, "demo.power")
        XCTAssertEqual(model.title, "Battery low")
        XCTAssertEqual(model.subtitle, "Power Demo")
        XCTAssertEqual(model.body, "Battery below 20%.")
        XCTAssertEqual(model.severity, .warning)
    }
}
```

- [ ] **Step 2: Run surface tests red**

Run:

```bash
swift test --filter ProviderSurfaceModelTests
```

Expected: compile failure for missing `ProviderSurfaceModel`, `SurfaceSnapshot`, `NotificationSurfaceModel`, and `ProviderSurfaceTone`.

- [ ] **Step 3: Implement surface models**

Create `Sources/AmbitCore/ProviderSurfaceModel.swift`:

```swift
import Foundation

public enum ProviderSurfaceTone: Equatable, Sendable {
    case good
    case warn
    case bad
    case neutral
}

public struct ProviderSurfaceModel: Equatable, Identifiable, Sendable {
    public var id: ProviderID
    public var title: String
    public var health: Health
    public var tone: ProviderSurfaceTone
    public var icon: String?
    public var accent: String?
    public var primaryMetric: Metric?
    public var primaryValueText: String?
    public var shortMessage: String
    public var commandCount: Int
    public var activeAlertCount: Int
    public var diagnostic: ProviderDiagnostic?

    public static func make(
        providerID: ProviderID,
        providerName: String,
        state: SourceState<ProviderSnapshot>?,
        commands: [CommandDescriptor],
        layout: ProviderManifest.Layout?,
        activeAlertCount: Int
    ) -> ProviderSurfaceModel {
        let display = ProviderDisplayModel.make(
            providerID: providerID,
            providerName: providerName,
            state: state,
            commands: commands,
            layout: layout
        )
        return ProviderSurfaceModel(
            id: providerID,
            title: display.title,
            health: display.health,
            tone: tone(for: display.health),
            icon: display.icon,
            accent: display.accent,
            primaryMetric: display.primaryMetric,
            primaryValueText: display.primaryMetric.map(ProviderMetricFormat.string),
            shortMessage: display.primaryMessage,
            commandCount: commands.count,
            activeAlertCount: activeAlertCount,
            diagnostic: display.diagnostic
        )
    }

    private static func tone(for health: Health) -> ProviderSurfaceTone {
        switch health {
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
}

public struct SurfaceSnapshot: Equatable, Sendable {
    public var providers: [ProviderSurfaceModel]
    public var lastUpdated: Date?

    public static func make(
        snapshot: StatusSnapshot,
        providerNames: [ProviderID: String],
        providerCommands: [ProviderID: [CommandDescriptor]],
        providerLayouts: [ProviderID: ProviderManifest.Layout],
        activeAlertCounts: [ProviderID: Int]
    ) -> SurfaceSnapshot {
        let providers = snapshot.providers.map { providerID, state in
            ProviderSurfaceModel.make(
                providerID: providerID,
                providerName: providerNames[providerID] ?? providerID,
                state: state,
                commands: providerCommands[providerID] ?? [],
                layout: providerLayouts[providerID],
                activeAlertCount: activeAlertCounts[providerID] ?? 0
            )
        }
        .sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return SurfaceSnapshot(providers: providers, lastUpdated: snapshot.lastUpdated)
    }
}

public struct NotificationSurfaceModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var title: String
    public var subtitle: String
    public var body: String
    public var severity: AlertSeverity
    public var triggeredAt: Date

    public init(event: AlertEvent, providerName: String) {
        self.id = event.id
        self.providerID = event.providerID
        self.title = event.title
        self.subtitle = providerName
        self.body = event.message
        self.severity = event.severity
        self.triggeredAt = event.triggeredAt
    }
}
```

- [ ] **Step 4: Verify surface tests pass**

Run:

```bash
swift test --filter ProviderSurfaceModelTests
```

Expected: all `ProviderSurfaceModelTests` pass.

- [ ] **Step 5: Commit surface models**

```bash
git add Sources/AmbitCore/ProviderSurfaceModel.swift Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift
git commit -m "Add reusable provider surface models"
```

---

### Task 4: Generic Provider And CLI Metadata Polish

**Files:**
- Modify: `Sources/AmbitCore/ProviderManifestReport.swift`
- Modify: `Tests/AmbitCoreTests/ProviderManifestReportTests.swift`
- Modify: `Sources/AmbitMenuBar/MenuContent.swift`

- [ ] **Step 1: Extend manifest report tests**

Add to `Tests/AmbitCoreTests/ProviderManifestReportTests.swift`:

```swift
func testFormatsLayoutTransformsAlertsAndCommandMetadata() {
    let manifest = ProviderManifest(
        schemaVersion: 1,
        id: "demo.power",
        displayName: "Power Demo",
        pollInterval: 30,
        credentials: [
            ProviderManifest.Credential(id: "api_token", label: "API Token", kind: .bearerToken, required: true)
        ],
        layout: ProviderManifest.Layout(icon: "bolt", accent: "green", primaryMetric: "battery_percent"),
        endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/status"),
        metrics: [
            ProviderManifest.MetricMapping(
                id: "battery_percent",
                label: "Battery",
                value: .init(type: .percent, path: "battery", transforms: [.multiply(100), .round])
            )
        ],
        alerts: [
            ProviderManifest.Alert(
                id: "battery.low",
                metricID: "battery_percent",
                kind: .threshold(comparison: .lessThan, value: 20),
                title: "Battery low",
                message: "Battery below 20%.",
                severity: .warning
            )
        ],
        commands: [
            ProviderManifest.Command(
                id: "demo.reset",
                label: "Reset",
                parameters: [ProviderManifest.CommandParameter(id: "mode", label: "Mode", kind: .option(["soft", "hard"]))],
                requiresConfirmation: true,
                endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/reset")
            )
        ]
    )

    let lines = ProviderManifestReport.lines(manifest: manifest)

    XCTAssertTrue(lines.contains("Layout: icon bolt, accent green, primary battery_percent"))
    XCTAssertTrue(lines.contains("  battery_percent: Battery (percent at battery, transforms: multiply, round)"))
    XCTAssertTrue(lines.contains("Alerts: 1"))
    XCTAssertTrue(lines.contains("  battery.low: Battery low (battery_percent lessThan 20, warning)"))
    XCTAssertTrue(lines.contains("  demo.reset: Reset (1 param, confirmation, executable)"))
}
```

- [ ] **Step 2: Run manifest report test red**

Run:

```bash
swift test --filter ProviderManifestReportTests/testFormatsLayoutTransformsAlertsAndCommandMetadata
```

Expected: test fails because report lines do not include layout, transforms, alerts, and richer command metadata.

- [ ] **Step 3: Implement richer manifest reports**

Update `Sources/AmbitCore/ProviderManifestReport.swift` so `lines(manifest:)` includes:

```swift
if let layout = manifest.layout {
    let parts = [
        layout.icon.map { "icon \($0)" },
        layout.accent.map { "accent \($0)" },
        layout.primaryMetric.map { "primary \($0)" }
    ].compactMap { $0 }
    if !parts.isEmpty {
        lines.append("Layout: \(parts.joined(separator: ", "))")
    }
}
```

For metrics, append transform names:

```swift
let transforms = metric.value.transforms.map(\.reportName)
let transformText = transforms.isEmpty ? "" : ", transforms: \(transforms.joined(separator: ", "))"
lines.append("  \(metric.id): \(metric.label) (\(metric.value.type.rawValue) at \(metric.value.path)\(transformText))")
```

Add a private extension:

```swift
private extension ProviderManifest.Transform {
    var reportName: String {
        switch self {
        case .multiply:
            return "multiply"
        case .divide:
            return "divide"
        case .round:
            return "round"
        case .clamp:
            return "clamp"
        case .defaultValue:
            return "defaultValue"
        }
    }
}
```

Add alert lines:

```swift
lines.append("Alerts: \(manifest.alerts.count)")
for alert in manifest.alerts {
    lines.append("  \(alert.id): \(alert.title) (\(alert.metricID) \(alert.kind.reportText), \(alert.severity.rawValue))")
}
```

Add a private extension:

```swift
private extension ProviderManifest.Alert.Kind {
    var reportText: String {
        switch self {
        case .threshold(let comparison, let value):
            return "\(comparison.rawValue) \(ProviderManifestReport.number(value))"
        case .stateTransition(let value):
            return "stateTransition \(ProviderMetricFormat.string(value))"
        case .sustained(let comparison, let value, let duration):
            return "\(comparison.rawValue) \(ProviderManifestReport.number(value)) for \(Int(duration))s"
        }
    }
}
```

For commands, include parameters and confirmation:

```swift
let parameterText = command.parameters.count == 1 ? "1 param" : "\(command.parameters.count) params"
let confirmationText = command.requiresConfirmation ? ", confirmation" : ""
let executableText = command.endpoint == nil ? ", metadata" : ", executable"
lines.append("  \(command.id): \(command.label) (\(parameterText)\(confirmationText)\(executableText))")
```

Add this helper inside `ProviderManifestReport`:

```swift
static func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}
```

- [ ] **Step 4: Update view model and generic provider detail to show declared alert count**

In `Sources/AmbitMenuBar/StatusViewModel.swift`, add:

```swift
@Published var providerAlertRuleCounts: [ProviderID: Int] = [:]
```

Update `refreshCommandPalette()` so it also refreshes alert rule counts:

```swift
providerAlertRuleCounts = await engine.alertRules().reduce(into: [ProviderID: Int]()) { counts, rule in
    counts[rule.providerID, default: 0] += 1
}
```

Make `AlertRule.providerID` public in `Sources/AmbitCore/AlertEngine.swift`:

```swift
public var providerID: ProviderID {
    switch self {
    case .threshold(let rule):
        return rule.providerID
    case .stateTransition(let rule):
        return rule.providerID
    case .sustained(let rule):
        return rule.providerID
    }
}
```

In `Sources/AmbitMenuBar/MenuContent.swift`, add a small row in `GenericProviderDetailView` after the status card:

```swift
if let alertCount = viewModel.providerAlertRuleCounts[providerID], alertCount > 0 {
    HStack(spacing: 8) {
        Image(systemName: "bell.badge")
            .foregroundStyle(.orange)
            .frame(width: 16)
        Text(alertCount == 1 ? "1 declared alert" : "\(alertCount) declared alerts")
            .font(.caption.weight(.bold))
        Spacer()
    }
    .padding(10)
    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
}
```

Expected minimal UI change: no compile errors and no dedicated provider view changes.

- [ ] **Step 5: Verify report tests and build**

Run:

```bash
swift test --filter ProviderManifestReportTests
swift build
```

Expected: selected tests pass and build succeeds.

- [ ] **Step 6: Commit metadata polish**

```bash
git add Sources/AmbitCore/AlertEngine.swift Sources/AmbitCore/ProviderManifestReport.swift Sources/AmbitMenuBar/StatusViewModel.swift Sources/AmbitMenuBar/MenuContent.swift Tests/AmbitCoreTests/ProviderManifestReportTests.swift
git commit -m "Polish generic provider metadata reports"
```

---

### Task 5: Documentation And Final Verification

**Files:**
- Modify: `docs/provider-manifests.md`
- Modify: `MIGRATION_PLAN.md`

- [ ] **Step 1: Update provider manifest docs**

Add sections to `docs/provider-manifests.md`:

```markdown
## Setup States

Installed providers can be ready, disabled, invalid, or waiting for required credentials. Disabled and invalid providers remain visible in Settings, but only ready enabled providers load into runtime surfaces.

## Surfaces

Ambit builds compact provider surface models from the same provider snapshot data used by the menubar. Future widgets, island-style glances, notifications, and app windows should consume these Core models instead of reading menubar view state.
```

- [ ] **Step 2: Update migration status**

In `MIGRATION_PLAN.md`, extend the current status bullet list with:

```markdown
- Provider setup summaries now expose validation and credential completeness for Settings.
- Core surface models now provide compact provider and notification state for future non-menubar surfaces.
```

- [ ] **Step 3: Run full verification**

Run:

```bash
swift test
swift build
swift run ambit-check --validate-manifest Examples/provider-manifests/ping-demo
swift run ambit-check --validate-manifest Examples/provider-manifests/secure-post-demo
swift run ambit-check --validate-manifest Examples/provider-manifests/transform-layout-alert-demo
git diff --check
```

Expected:

- `swift test`: all tests pass.
- `swift build`: build succeeds.
- all three manifest packages validate.
- `git diff --check`: no output.

- [ ] **Step 4: Relaunch dev app**

Run:

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

- [ ] **Step 5: Commit docs and final status**

```bash
git add docs/provider-manifests.md MIGRATION_PLAN.md
git commit -m "Document provider polish surface foundation"
```

---

## Self-Review Notes

- Spec coverage: Task 1 covers setup summaries and credential completeness; Task 2 covers Settings rendering and lifecycle actions; Task 3 covers shared Core surface models; Task 4 covers generic runtime/CLI metadata polish; Task 5 covers docs and full verification.
- Scope control: OS widgets, Dynamic Island, app window target, cloud sync, registry distribution, and deep built-in integration hardening are out of scope.
- Type consistency: plan consistently uses `ProviderSetupSummary`, `ProviderCredentialSetupSummary`, `ProviderSurfaceModel`, `SurfaceSnapshot`, and `NotificationSurfaceModel`.
