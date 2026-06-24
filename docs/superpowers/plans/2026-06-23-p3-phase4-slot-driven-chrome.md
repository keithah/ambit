# P3 Phase 4: Slot-Driven Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS menu-bar chrome slot-driven — one status item per slot, each backed by a generic `SlotSurface` value and rendered by a new `SlotPopover` — retiring the hardcoded single-Ping chrome while preserving exact visual parity with today (one "Ping" item, same popover layout, same bar glyph).

**Architecture:** `StatusViewModel` is refactored to replace its five ping-specific published properties (`surfaceData`, `surfacePlan`, `menuGlyph`, `pingHosts`, `pingSelection`) with two generic ones (`slotSurfaces: [SlotID: SlotSurface]`, `slotFocus: [SlotID: IntegrationInstanceID]`) and a `selectInstance` method. A new `SlotPopover` view (generic, ping-aware only for the diagnosis banner prepend) replaces `PingPopover`. `App.swift` creates one `StatusBarController` per slot, each observing its own glyph. `PingGlyphRenderer` is renamed `StatusGlyphRenderer`. `PingColors` and `PingHostDisplay` are deleted; their consumers switch to `Theme.lineColor` and `DisplayTone.color`.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (NSStatusItem, NSPopover), Combine, AmbitCore (SlotResolver, SurfaceComposer, DiagnosisEntity, PingPresenter), AmbitUI (Theme, InstanceSelectorCard, SurfaceView)

## Global Constraints

- `swift build` AND `swift test` must be green after every commit (350 tests expected to pass).
- AmbitCore stays UI-free — all new view types go in AmbitMenuBar or AmbitUI.
- No EngineID in any `id` string.
- Bar readout is STATIC in P3 (`.dynamic` falls back to the primary-entity ping glyph).
- No `Ping*`-named UI types after this phase (`PingGlyphRenderer` → `StatusGlyphRenderer`; `PingColors` → deleted, use `Theme`; `PingHostDisplay` → deleted).
- Never edit `~/src/pingscope` or `~/src/glinet-travel`.
- Single commit (or two at most): commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`, no backticks in `-m`.
- Do NOT weaken tests; only delete tests for genuinely-removed types.

---

## File Map

| File | Change |
|---|---|
| `Sources/AmbitMenuBar/SlotSurface.swift` | **CREATE** — `SlotSurface` struct |
| `Sources/AmbitMenuBar/SlotPopover.swift` | **CREATE** — `SlotPopover` view + `StatusGlyphRenderer` (moved from PingPopover) |
| `Sources/AmbitMenuBar/StatusViewModel.swift` | **MODIFY** — replace 5 ping-specific props with `slotSurfaces`/`slotFocus`/`selectInstance`; refactor `refreshPing` to call `buildSlotSurface` |
| `Sources/AmbitMenuBar/App.swift` | **MODIFY** — `MenuBarAppModel` holds `[StatusBarController]` (one per slot); `StatusBarController` parameterised with `slotID` |
| `Sources/AmbitMenuBar/PingOverlay.swift` | **MODIFY** — `OverlayView` reads `slotSurfaces[pingSlotID]` and calls `viewModel.selectInstance` |
| `Sources/AmbitMenuBar/PingPopover.swift` | **DELETE** — `PingPopover`, `PingHostDisplay`, `PingColors`, `PingGlyphRenderer` all removed |
| `Sources/AmbitMenuBar/PingSettings.swift` | **NO CHANGE** — only reads `pingHostRows`, `pingDiagnosis`, `pingRange`, `setPingRange`, `diagnosisSensitivity` — all kept |

---

## Task 1: Create `SlotSurface` struct

**Files:**
- Create: `Sources/AmbitMenuBar/SlotSurface.swift`

**Interfaces:**
- Produces: `struct SlotSurface { var plan: SurfacePlan; var data: SurfaceData; var glyph: MenuBarGlyph; var hostOptions: [InstanceSelectorCard.Option] }` — used by StatusViewModel, SlotPopover, StatusBarController.

No unit test (UI module); build is the gate.

- [ ] **Step 1: Create `SlotSurface.swift`**

```swift
import AmbitCore
import AmbitUI

/// Per-slot value computed by StatusViewModel and consumed by the chrome.
struct SlotSurface {
    var plan: SurfacePlan
    var data: SurfaceData
    var glyph: MenuBarGlyph
    /// Options for the InstanceSelectorCard. Only shown when count > 1.
    var hostOptions: [InstanceSelectorCard.Option]

    static let empty = SlotSurface(
        plan: SurfacePlan(),
        data: SurfaceData(),
        glyph: MenuBarGlyph(latencyText: "--ms", tone: .neutral),
        hostOptions: []
    )
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/keith/src/ambit && swift build 2>&1 | tail -20
```

Expected: no errors (new file only adds a type, nothing breaks).

---

## Task 2: Create `SlotPopover` + rename `PingGlyphRenderer` → `StatusGlyphRenderer`

**Files:**
- Create: `Sources/AmbitMenuBar/SlotPopover.swift`

**Interfaces:**
- Consumes: `SlotSurface` (Task 1), `StatusViewModel.slotFocus`, `StatusViewModel.pingRange`, `StatusViewModel.setPingRange`, `StatusViewModel.selectInstance`, `StatusViewModel.toggleOverlay`, `StatusViewModel.openSettings` (these exist on StatusViewModel now or will after Task 3 — write the view to call them; the build is the gate after Task 3).
- Produces: `struct SlotPopover: View` with `init(slotID: SlotID)`, `enum StatusGlyphRenderer` with `static func image(_ glyph: MenuBarGlyph) -> NSImage`.

The layout mirrors `PingPopover` exactly (420×640, dark background `Color(red: 0.055, green: 0.055, blue: 0.07)`, header/rangePicker/SurfaceView/Spacer). The new file replaces the Ping-specific one; `StatusGlyphRenderer` is generic (no Ping* name).

- [ ] **Step 1: Create `SlotPopover.swift`**

```swift
import AppKit
import AmbitCore
import AmbitUI
import SwiftUI

// MARK: - Generic menu-bar glyph renderer

/// Renders a stacked "dot over latency text" NSImage for any slot's bar readout.
/// Renamed from PingGlyphRenderer — this type does generic chrome, not Ping-specific UI.
enum StatusGlyphRenderer {
    static func image(_ glyph: MenuBarGlyph) -> NSImage {
        let width = glyph.itemWidth, height = 22.0
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let dot = NSBezierPath(ovalIn: NSRect(
            x: (width - glyph.dotDiameter) / 2,
            y: height - glyph.dotDiameter - 1,
            width: glyph.dotDiameter, height: glyph.dotDiameter))
        nsColor(glyph.tone).setFill()
        dot.fill()
        let text = NSAttributedString(string: glyph.latencyText, attributes: [
            .font: NSFont.systemFont(ofSize: glyph.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (width - size.width) / 2, y: 0))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func nsColor(_ tone: LatencyTone) -> NSColor {
        switch tone {
        case .neutral: return .secondaryLabelColor
        case .good: return .systemGreen
        case .warn: return .systemYellow
        case .bad: return .systemRed
        }
    }
}

// MARK: - Generic slot popover

/// One popover per slot. Reads SlotSurface from viewModel.slotSurfaces[slotID].
/// Layout is identical to the retired PingPopover (420×640, dark bg).
struct SlotPopover: View {
    let slotID: SlotID
    @EnvironmentObject private var viewModel: StatusViewModel

    private var surface: SlotSurface {
        viewModel.slotSurfaces[slotID] ?? .empty
    }
    private var focus: IntegrationInstanceID? {
        viewModel.slotFocus[slotID]
    }
    private var focusReadout: (text: String, tone: LatencyTone, statusLabel: String) {
        // Derive readout from the glyph (glyph already holds primary-entity data).
        // When focused on a specific host, the glyph is already recomputed for that host.
        let g = surface.glyph
        let label: String
        switch g.tone {
        case .neutral: label = "No Data"
        case .good: label = "Healthy"
        case .warn: label = "Degraded"
        case .bad: label = "Down"
        }
        return (g.latencyText, g.tone, label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rangePicker
            SurfaceView(plan: surface.plan, data: surface.data)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    private var header: some View {
        HStack(alignment: .top) {
            if surface.hostOptions.count > 1 {
                InstanceSelectorCard(
                    options: surface.hostOptions,
                    selectedID: focus?.rawValue,
                    onSelect: { rawID in
                        viewModel.selectInstance(slotID, rawID.map { IntegrationInstanceID(rawValue: $0) })
                    },
                    allLabel: "All Hosts"
                )
            } else {
                // Single host or no options: show the slot title as plain text.
                Text(viewModel.slots.first(where: { $0.id == slotID })?.title ?? "Ping")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focusReadout.text).font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(DisplayTone(latencyTone: focusReadout.tone).color)
                        .frame(width: 9, height: 9)
                    Text(focusReadout.statusLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(DisplayTone(latencyTone: focusReadout.tone).color)
                }
            }
            Button { viewModel.toggleOverlay?() } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 6).help("Toggle floating overlay")
            Button { viewModel.openSettings?() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 14, weight: .semibold))
            Picker("", selection: Binding(
                get: { viewModel.pingRange },
                set: { viewModel.setPingRange($0) }
            )) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
    }
}
```

Note: `DisplayTone(latencyTone:)` is a bridge needed in the next step. The tone dot in PingPopover used `PingColors.tone(latencyTone)`. We bridge this by adding an extension on `DisplayTone` in AmbitUI (or a local helper), mapping `LatencyTone` → `DisplayTone`. This is done as part of this task.

- [ ] **Step 2: Add `DisplayTone(latencyTone:)` extension in `Theme.swift`**

Open `/Users/keith/src/ambit/Sources/AmbitUI/Theme.swift` and append after the existing `DisplayTone.color` extension:

```swift
// Bridge: map LatencyTone (ping-domain) to DisplayTone (generic) for the popover's
// status dot, so SlotPopover stays free of PingColors.
public extension DisplayTone {
    init(latencyTone: LatencyTone) {
        switch latencyTone {
        case .neutral: self = .neutral
        case .good: self = .good
        case .warn: self = .warn
        case .bad: self = .bad
        }
    }
}
```

- [ ] **Step 3: Verify it compiles (build will still have errors from missing slotSurfaces/slotFocus until Task 3 — that's OK; at least no *new* errors from this file)**

The build will fail until Task 3 and 4 are done. Note any new errors and fix them before proceeding.

---

## Task 3: Refactor `StatusViewModel` — replace ping-specific props with slot host

**Files:**
- Modify: `Sources/AmbitMenuBar/StatusViewModel.swift`

**Interfaces:**
- Removes: `@Published var surfaceData`, `@Published var surfacePlan`, `@Published var menuGlyph`, `@Published var pingHosts`, `@Published var pingSelection`
- Adds: `@Published var slotSurfaces: [SlotID: SlotSurface] = [:]`, `@Published var slotFocus: [SlotID: IntegrationInstanceID] = [:]`, `func selectInstance(_ slot: SlotID, _ id: IntegrationInstanceID?)`
- Keeps: `pingHostRows`, `pingDiagnosis`, `pingRange`, `setPingRange`, `diagnosisSensitivity`, all ping host management methods, `slots`
- Modifies: `refreshPing()` — keeps the diagnosis/alerts computation; adds call to `buildSlotSurface(slot:diagnosis:activeRecords:allDescriptors:allStates:now:)` for each slot.

This is the core change. Follow it carefully.

- [ ] **Step 1: Remove dead published properties**

In `StatusViewModel.swift`, remove these four lines from the `@Published` section:
```swift
@Published var pingSelection: IntegrationInstanceID?   // nil = All Hosts
@Published var pingHosts: [PingHostDisplay] = []
@Published var menuGlyph = MenuBarGlyph(latencyText: "--ms", tone: .neutral)
@Published var surfaceData = SurfaceData()
@Published var surfacePlan = SurfacePlan()
```

Replace with:
```swift
/// Per-slot surface values (plan + data + glyph + hostOptions), keyed by SlotID.
@Published var slotSurfaces: [SlotID: SlotSurface] = [:]
/// Per-slot focused instance (nil = show all resolved instances for the slot).
@Published var slotFocus: [SlotID: IntegrationInstanceID] = [:]
```

- [ ] **Step 2: Add `selectInstance` method**

Add the following after the existing `selectPingHost` method (or replace it — keep `selectPingHost` as a deprecated shim only if PingSettings still calls it; inspect and confirm; it doesn't — it's only called from PingPopover which we delete):

```swift
/// Set or clear the per-slot focus. Clears focus when `id` is nil (show all).
func selectInstance(_ slot: SlotID, _ id: IntegrationInstanceID?) {
    slotFocus[slot] = id
    Task { await refreshPing() }
}
```

Also REMOVE `selectPingHost` entirely (it was only called from the old PingPopover):
```swift
// DELETE:
func selectPingHost(_ id: IntegrationInstanceID?) {
    pingSelection = id
    Task { await refreshPing() }
}
```

- [ ] **Step 3: Rewrite the surface-building part of `refreshPing()`**

The diagnosis/host loop stays exactly as-is (it populates `pingHosts = displays` — BUT we need to keep `displays` as a local var since we need it for `buildSlotSurface`). Actually, `pingHosts` is removed. The local `var displays: [PingHostDisplay]` is also removed. Here is the full new `refreshPing()` to replace the existing one:

```swift
/// Rebuild per-host rows + diagnosis/alerts (settings), then build per-slot surfaces.
func refreshPing() async {
    let now = Date()
    let freshness = max(pingRange.seconds, 30)
    let allRecords = ((try? integrationRegistry.instances()) ?? [])
        .filter { $0.integrationID == IntegrationIDs.ping }
    let disabledTypes = (try? integrationRegistry.disabledIntegrationIDs()) ?? []
    let primaryID = (try? integrationRegistry.primaryInstanceID()) ?? nil
    let activeRecords = disabledTypes.contains(IntegrationIDs.ping) ? [] : allRecords.filter(\.enabled)
    let fallbackPrimary = primaryID ?? activeRecords.first?.id

    // All hosts (enabled + disabled) for the Settings list.
    pingHostRows = allRecords.compactMap { record in
        guard let config = PingHostConfig(configObject: record.config) else { return nil }
        return PingHostRow(instanceID: record.id, config: config, enabled: record.enabled, isPrimary: record.id == fallbackPrimary)
    }

    // Active hosts: per-host readout for diagnosis + alert inputs.
    var diagnosisHosts: [DiagnosisHost] = []
    var alertHosts: [AlertHost] = []
    // Also collect per-host readouts keyed by instanceID (used by buildSlotSurface for the glyph).
    var hostReadouts: [IntegrationInstanceID: LatencyReadout] = [:]
    for record in activeRecords {
        guard let host = PingHostConfig(configObject: record.config) else { continue }
        let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
        let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
        let samples = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
        let health = HealthStatus(legacy: snapshot.providers[providerInstance]?.value?.health ?? .unknown)
        let readout = PingPresenter.readout(latest: samples.last, health: health, now: now, freshness: freshness)
        hostReadouts[record.id] = readout
        diagnosisHosts.append(DiagnosisHost(id: record.id.rawValue, tier: pingTierClassifier.tier(for: host), status: health))
        alertHosts.append(AlertHost(id: record.id.rawValue, name: record.displayName, status: health,
                                    notifyOnRecovery: host.policy.notifyOnRecovery, cooldown: host.policy.cooldown))
    }

    // Tier diagnosis + network/host alerts.
    let diagnosis = pingDiagnoser.diagnose(hosts: diagnosisHosts)
    pingDiagnosis = diagnosis
    let events = pingAlertMonitor.evaluate(hosts: alertHosts, diagnosis: diagnosis, now: now)
    await alertNotifier.deliver(events)

    // Build per-slot surfaces.
    let allDescriptors = await engine.entityDescriptors()
    let allStates = await engine.entityStates()
    var newSurfaces: [SlotID: SlotSurface] = [:]
    let allRegistryRecords = ((try? integrationRegistry.instances()) ?? [])

    for slot in slots {
        let surface = await buildSlotSurface(
            slot: slot,
            diagnosis: diagnosis,
            allRecords: activeRecords,
            allRegistryRecords: allRegistryRecords,
            fallbackPrimary: fallbackPrimary,
            hostReadouts: hostReadouts,
            allDescriptors: allDescriptors,
            allStates: allStates,
            now: now
        )
        newSurfaces[slot.id] = surface
    }
    slotSurfaces = newSurfaces
}

private func buildSlotSurface(
    slot: Slot,
    diagnosis: NetworkPerspectiveDiagnosis,
    allRecords: [IntegrationInstanceRecord],      // enabled ping records
    allRegistryRecords: [IntegrationInstanceRecord], // all records (for SlotResolver)
    fallbackPrimary: IntegrationInstanceID?,
    hostReadouts: [IntegrationInstanceID: LatencyReadout],
    allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
    allStates: [EntityID: EntityState],
    now: Date
) async -> SlotSurface {
    // Flatten descriptors for SlotResolver.
    let flatDescriptors = allDescriptors.values.flatMap { $0 }

    // Resolve the slot's selection to descriptors, then apply per-slot focus.
    let resolved = SlotResolver.resolve(slot.selection, descriptors: flatDescriptors, records: allRegistryRecords)

    // Distinct integration instances the slot resolved to (for hostOptions).
    let resolvedInstanceIDs = Set(resolved.map { $0.instanceID.integrationInstanceID })
    let resolvedRecords = allRecords.filter { resolvedInstanceIDs.contains($0.id) }
    let hostOptions = resolvedRecords.map { InstanceSelectorCard.Option(id: $0.id.rawValue, label: $0.displayName) }

    // Apply per-slot focus: filter to the focused instance if set.
    let focusedID = slotFocus[slot.id]
    let shownRecords = focusedID.map { id in resolvedRecords.filter { $0.id == id } } ?? resolvedRecords

    // Compute glyph from the primary (or focused) host's readout.
    let primaryRecord = shownRecords.first(where: { $0.id == fallbackPrimary }) ?? shownRecords.first
    let glyph: MenuBarGlyph
    if let primary = primaryRecord, let readout = hostReadouts[primary.id] {
        glyph = MenuBarGlyph(latencyText: readout.text, tone: readout.tone)
    } else {
        glyph = MenuBarGlyph(latencyText: "--ms", tone: .neutral)
    }

    // Build SurfaceData: latency descriptors for shown hosts (renamed to host displayName
    // for multi-host legend, matching today's behaviour).
    var descriptors: [EntityID: EntityDescriptor] = [:]
    var states: [EntityID: EntityState] = [:]
    var series: [EntityID: [Sample]] = [:]
    var latencyDescriptors: [EntityDescriptor] = []
    for record in shownRecords {
        let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
        let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
        guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
        latency.name = record.displayName
        latencyDescriptors.append(latency)
        descriptors[latencyID] = latency
        states[latencyID] = allStates[latencyID]
        series[latencyID] = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
    }

    // Build plan: for ping slot prepend diagnosis banner (P4: promote to attention-emitted entity).
    var planCards: [CardSpec] = []
    let isPingSlot: Bool
    if case .integrationType(let integID) = slot.selection, integID == IntegrationIDs.ping {
        isPingSlot = true
    } else {
        isPingSlot = false
    }
    if isPingSlot, let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis) {
        descriptors[diagnosisDescriptor.id] = diagnosisDescriptor
        states[diagnosisDescriptor.id] = diagnosisState
        planCards.append(CardSpec(
            id: "card.\(diagnosisDescriptor.id.rawValue)",
            kind: .statusBanner,
            title: diagnosisDescriptor.name,
            entities: [diagnosisDescriptor.id],
            role: .banner
        ))
    }
    planCards.append(contentsOf: SurfaceComposer.detailPlan(descriptors: latencyDescriptors, states: states).cards)

    return SlotSurface(
        plan: SurfacePlan(cards: planCards),
        data: SurfaceData(descriptors: descriptors, states: states, series: series),
        glyph: glyph,
        hostOptions: hostOptions
    )
}
```

- [ ] **Step 4: Verify the build (partial — PingPopover.swift still references the removed props)**

```bash
cd /Users/keith/src/ambit && swift build 2>&1 | grep -E "error:|warning:" | head -40
```

Expected: errors only in `PingPopover.swift` (dead file about to be deleted) and `App.swift` / `PingOverlay.swift` (those still reference old props or `PingGlyphRenderer`). No errors in `StatusViewModel.swift` itself.

---

## Task 4: Update `PingOverlay.swift` — repoint at slot surface

**Files:**
- Modify: `Sources/AmbitMenuBar/PingOverlay.swift`

**Interfaces:**
- Reads: `viewModel.slotSurfaces`, `viewModel.slots`, `viewModel.selectInstance`
- Removes: references to `viewModel.surfacePlan`, `viewModel.surfaceData`, `viewModel.pingHosts`, `viewModel.selectPingHost`

`OverlayView` currently uses `viewModel.surfacePlan.cards` and `viewModel.surfaceData`. Repoint it to the ping slot's surface. The ping slot is `slots.first` (guaranteed to exist by `loadOrSeedSlots`).

- [ ] **Step 1: Replace the `OverlayView` body with slot-aware version**

Replace the entire `OverlayView` struct (lines 7-37 in the current file) with:

```swift
/// The floating, always-on-top compact multi-host graph.
struct OverlayView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let openPopover: () -> Void
    let close: () -> Void

    /// The ping slot is always slots.first (seeded by loadOrSeedSlots).
    private var pingSlotID: SlotID { viewModel.slots.first?.id ?? SlotID(rawValue: "ping") }
    private var surface: SlotSurface { viewModel.slotSurfaces[pingSlotID] ?? .empty }

    var body: some View {
        let flattened: [CardSpec] = surface.plan.cards
            .flatMap { (card: CardSpec) -> [CardSpec] in card.kind == .section ? card.children : [card] }
        let graphCards = flattened
            .filter { $0.kind == .historyGraph || $0.kind == .dualLineGraph }
        VStack(spacing: 5) {
            SurfaceView(plan: SurfacePlan(cards: graphCards), data: surface.data)
        }
        .padding(8)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .contextMenu {
            Menu("Host") {
                Button("All Hosts") { viewModel.selectInstance(pingSlotID, nil) }
                ForEach(surface.hostOptions) { option in
                    Button(option.label) {
                        viewModel.selectInstance(pingSlotID, IntegrationInstanceID(rawValue: option.id))
                    }
                }
            }
            Button("Open Popover", action: openPopover)
            Button("Settings…") { viewModel.openSettings?() }
            Divider()
            Button("Close Overlay", action: close)
        }
    }
}
```

- [ ] **Step 2: Verify `PingOverlay.swift` compiles in isolation**

```bash
cd /Users/keith/src/ambit && swift build 2>&1 | grep "PingOverlay" | head -10
```

Expected: no errors from `PingOverlay.swift`.

---

## Task 5: Update `App.swift` — multi-slot chrome

**Files:**
- Modify: `Sources/AmbitMenuBar/App.swift`

**Interfaces:**
- Removes: single `StatusBarController` field; `PingGlyphRenderer` reference.
- Adds: `var statusBarControllers: [StatusBarController]` (one per slot); `StatusBarController(slotID:viewModel:)` init.
- Keeps: `OverlayController`, `SettingsWindowController`, overlay/settings wiring.

- [ ] **Step 1: Update `StatusBarController` to be slot-parameterised**

Replace the current `StatusBarController` class in `App.swift` with:

```swift
/// Owns one NSStatusItem + one NSPopover for a single slot.
@MainActor
private final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private let viewModel: StatusViewModel
    private let slotID: SlotID
    private var cancellables: Set<AnyCancellable> = []

    init(slotID: SlotID, viewModel: StatusViewModel) {
        self.slotID = slotID
        self.viewModel = viewModel
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: SlotPopover(slotID: slotID).environmentObject(viewModel)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        // Initial glyph from current slotSurfaces (may be .empty on first tick).
        updateGlyph(viewModel.slotSurfaces[slotID]?.glyph ?? MenuBarGlyph(latencyText: "--ms", tone: .neutral))
        viewModel.$slotSurfaces
            .receive(on: RunLoop.main)
            .sink { [weak self] surfaces in
                guard let self else { return }
                self.updateGlyph(surfaces[self.slotID]?.glyph ?? MenuBarGlyph(latencyText: "--ms", tone: .neutral))
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateGlyph(_ glyph: MenuBarGlyph) {
        let slot = viewModel.slots.first(where: { $0.id == slotID })
        let title = slot?.title ?? slotID.rawValue
        statusItem.button?.image = StatusGlyphRenderer.image(glyph)
        statusItem.button?.toolTip = "\(title) · \(glyph.latencyText)"
    }
}
```

- [ ] **Step 2: Update `MenuBarAppModel` to hold an array of controllers**

Replace `MenuBarAppModel` with:

```swift
@MainActor
private final class MenuBarAppModel: ObservableObject {
    let viewModel: StatusViewModel
    private var statusBarControllers: [StatusBarController] = []
    private let overlayController: OverlayController
    private let settingsController: SettingsWindowController

    init() {
        let viewModel = StatusViewModel()
        self.viewModel = viewModel

        // Create one StatusBarController per slot. Today there is exactly one (Ping).
        let controllers = viewModel.slots.map { slot in
            StatusBarController(slotID: slot.id, viewModel: viewModel)
        }
        self.statusBarControllers = controllers

        // Overlay and settings always target the first (ping) slot's popover.
        let firstController = controllers.first
        let overlayController = OverlayController(
            viewModel: viewModel,
            onOpenPopover: { [weak firstController] in firstController?.showPopover() }
        )
        self.overlayController = overlayController
        let settingsController = SettingsWindowController(viewModel: viewModel)
        self.settingsController = settingsController
        viewModel.toggleOverlay = { [weak overlayController] in overlayController?.toggle() }
        viewModel.showPopover = { [weak firstController] in firstController?.showPopover() }
        viewModel.openSettings = { [weak settingsController] in settingsController?.show() }
        viewModel.start()
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 3: Verify the build (App.swift and all updated files should now compile)**

```bash
cd /Users/keith/src/ambit && swift build 2>&1 | grep -E "error:" | head -20
```

Expected: errors only in `PingPopover.swift` (which we're about to delete).

---

## Task 6: Delete `PingPopover.swift` and verify full build

**Files:**
- Delete: `Sources/AmbitMenuBar/PingPopover.swift`

`PingPopover.swift` contains `PingPopover` (view, replaced by `SlotPopover`), `PingHostDisplay` (struct, no longer needed — we removed all consumers), `PingColors` (replaced by `Theme.lineColor` and `DisplayTone.color`), and `PingGlyphRenderer` (renamed to `StatusGlyphRenderer` in `SlotPopover.swift`).

Confirm before deleting:
- `PingHostDisplay` — search for any remaining uses (`grep -r "PingHostDisplay" Sources/`).
- `PingColors` — search for remaining uses (`grep -r "PingColors" Sources/`). The only valid remaining use is `PingColors.line(colorIndex)` in the old `PingHostDisplay.color` property — which disappears with the struct.
- `PingPopover` — search for any remaining uses (`grep -r "PingPopover" Sources/`). Should be zero (it was only used in the old `StatusBarController`).

- [ ] **Step 1: Confirm no surviving references**

```bash
grep -r "PingHostDisplay\|PingColors\|PingPopover\|PingGlyphRenderer\|selectPingHost\|pingHosts\|\.surfacePlan\|\.surfaceData\|\.menuGlyph\b\|\.pingSelection" /Users/keith/src/ambit/Sources/ 2>/dev/null
```

Expected: zero matches. If any remain, fix them before deleting.

- [ ] **Step 2: Delete the file**

```bash
rm /Users/keith/src/ambit/Sources/AmbitMenuBar/PingPopover.swift
```

- [ ] **Step 3: Full build**

```bash
cd /Users/keith/src/ambit && swift build 2>&1
```

Expected: `Build complete!` with no errors. Fix any remaining errors before proceeding.

---

## Task 7: Run tests

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/keith/src/ambit && swift test 2>&1 | tail -20
```

Expected: all 350 tests pass. If any fail: inspect the test file — likely a test for a genuinely-removed type (then delete only that test) or a compile error in a test that references removed props.

---

## Task 8: Visual verification — run the app and check polling

- [ ] **Step 1: Launch the app**

```bash
bash /Users/keith/src/ambit/.claude/skills/run-ambit/launch.sh 2>&1 | tail -30
```

- [ ] **Step 2: Confirm the process is alive**

```bash
pgrep -fl "Ambit.app/Contents/MacOS/Ambit"
```

Expected: one line with the process PID.

- [ ] **Step 3: Confirm ping is polling**

```bash
sqlite3 "$HOME/Library/Application Support/Ambit/history.sqlite" \
  "SELECT entity_id,COUNT(*) FROM history_samples WHERE entity_id LIKE 'ping@%' AND timestamp>=strftime('%s','now')-30 GROUP BY entity_id;"
```

Expected: 2-3 rows (one per ping host, e.g. `ping@cloudflare-dns/probe.latency_ms|N`). If the app just launched, wait 10s and retry.

---

## Task 9: Commit

- [ ] **Step 1: Stage changed files**

```bash
cd /Users/keith/src/ambit && git add \
  Sources/AmbitMenuBar/SlotSurface.swift \
  Sources/AmbitMenuBar/SlotPopover.swift \
  Sources/AmbitMenuBar/StatusViewModel.swift \
  Sources/AmbitMenuBar/App.swift \
  Sources/AmbitMenuBar/PingOverlay.swift \
  Sources/AmbitUI/Theme.swift
git rm Sources/AmbitMenuBar/PingPopover.swift
```

- [ ] **Step 2: Check status**

```bash
cd /Users/keith/src/ambit && git status
```

Expected: `SlotSurface.swift` (new), `SlotPopover.swift` (new), `StatusViewModel.swift` (modified), `App.swift` (modified), `PingOverlay.swift` (modified), `Theme.swift` (modified), `PingPopover.swift` (deleted). No untracked files added by accident.

- [ ] **Step 3: Commit**

```bash
cd /Users/keith/src/ambit && git commit -m "$(cat <<'EOF'
P3 (4/5): slot-driven chrome -- VM slot host + generic SlotPopover

Replace five ping-specific published properties (surfaceData/surfacePlan/menuGlyph/
pingHosts/pingSelection) with slotSurfaces[SlotID:SlotSurface] + slotFocus[SlotID:
IntegrationInstanceID] + selectInstance(). Add SlotSurface struct and generic SlotPopover
(420x640, same layout as retired PingPopover). App.swift creates one StatusBarController
per slot via slotID. Rename PingGlyphRenderer -> StatusGlyphRenderer. Delete PingPopover/
PingHostDisplay/PingColors (replaced by Theme + DisplayTone.color). PingOverlay reads
slotSurfaces[pingSlotID]. Visual parity: one Ping item, same readout, same popover.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Write report

- [ ] **Step 1: Create the report**

Write to `/Users/keith/src/ambit/.superpowers/sdd/p3-phase4-report.md` summarizing: files changed, files deleted, build result, test result, polling check output, any parity concerns.

---

## Self-Review

**Spec coverage check:**

1. `SlotSurface` struct with `plan/data/glyph/hostOptions` — Task 1. ✓
2. `slotSurfaces`/`slotFocus`/`selectInstance` on StatusViewModel — Task 3. ✓
3. `refreshPing` → `buildSlotSurface` per slot — Task 3. ✓
4. Primary glyph logic (primary registry instance → fallbackPrimary → first) — Task 3, `buildSlotSurface`. ✓
5. `hostOptions` mapped from resolved records — Task 3, `buildSlotSurface`. ✓
6. Rename `PingGlyphRenderer` → `StatusGlyphRenderer` — Task 2. ✓
7. Generic `SlotPopover(slotID:)` replacing `PingPopover` — Task 2. ✓
8. InstanceSelectorCard only shown when `hostOptions.count > 1` — Task 2. ✓
9. Chrome (App.swift): one `StatusBarController` per slot — Task 5. ✓
10. Update `PingOverlay.swift` to read `slotSurfaces[pingSlotID]` — Task 4. ✓
11. Delete `PingPopover`, `PingHostDisplay`, `PingColors` — Task 6. ✓
12. `swift build` + `swift test` green — Tasks 6-7. ✓
13. Polling check — Task 8. ✓
14. Report — Task 10. ✓

**Placeholder scan:** No TBD, TODO, or vague steps. All code blocks are complete.

**Type consistency check:**
- `SlotSurface.empty` used in `SlotPopover` and `PingOverlay` — defined in Task 1. ✓
- `StatusGlyphRenderer.image(_:)` used in `StatusBarController.updateGlyph` — defined in Task 2. ✓
- `viewModel.selectInstance(slotID, id)` used in `SlotPopover` and `OverlayView` — defined in Task 3. ✓
- `viewModel.slotSurfaces[slotID]` used in `SlotPopover`, `StatusBarController`, `OverlayView` — defined in Task 3. ✓
- `viewModel.slotFocus[slotID]` used in `SlotPopover` — defined in Task 3. ✓
- `DisplayTone(latencyTone:)` used in `SlotPopover` — defined in Task 2 (added to `Theme.swift`). ✓
- `InstanceSelectorCard.Option` — already exists in AmbitUI, no change needed. ✓

One potential issue: `PingHostConfig.detailLine` is used by `PingHostDisplay.detail` (which we removed). Verify `detailLine` is still used somewhere (it is — in `PingSettings.HostsPane` via `PingHostRow.detail`). No problem.

Another: `PingHostRow` is kept in `PingSettings.swift`. Check it doesn't import from `PingPopover.swift`. It's defined in `PingSettings.swift` directly — no issue.
