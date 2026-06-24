# P1 — Generic Card Vocabulary + AmbitUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the generic, UI-free card-binding model (`CardSpec`/`SurfacePlan`/`SurfaceComposer`) in `AmbitCore`, the descriptor presentation-default fields, and a new `AmbitUI` SwiftUI library that renders the card vocabulary — harvested from pingscope's M5 UI — without touching the menu-bar app.

**Architecture:** `AmbitCore` decides *which card binds to which entity* (a pure, testable `SurfacePlan`); `AmbitUI` renders a `SurfacePlan` against injected entity states + history samples. Values flow separately from layout. The pre-entity `Metric`-based display models are retired, their grouping coverage ported to `SurfaceComposer` tests.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package Manager, SwiftUI (macOS 13), XCTest.

## Global Constraints

- `swift build` and `swift test` MUST be green after every task; one small commit per task.
- `AmbitCore` MUST NOT import SwiftUI or AppKit. The card-binding model is UI-free.
- `AmbitUI` is a new library target, macOS 13 floor, depends only on `AmbitCore`.
- The menu-bar app (`AmbitMenuBar`) is NOT modified in P1 (additive milestone).
- Never edit `~/src/pingscope` or `~/src/glinet-travel`.
- Do not weaken or delete tests for code that stays. Retiring a model legitimately deletes its tests, but its coverage must be ported first (Task 5/6).
- No `EngineID` in any entity/instance id.
- New types are `Sendable`; value types `Equatable`; persisted types `Codable`.

## Graph-range decision (settled here, per §6 of the spec)

Graph range is modeled as a **per-entity presentation default** (`EntityDescriptor.defaultGraphRange`) plus a user override (`EntityPresentationOverride.graphRange`). The set of selectable windows is harvested from pingscope's `TimeRange` (1m / 5m / 10m / 1h). The layer fallback when an entity declares none is **5 minutes** (`.m5`). The *interactive* range picker (a transient, surface-wide control) is deferred to P2's popover chrome; P1 only lands the type, the descriptor default, and plumbs `GraphRange` into the history-graph view + loader.

## File structure

| File | Responsibility |
|---|---|
| `Package.swift` | Add `AmbitUI` library + `AmbitUITests` test target. |
| `Sources/AmbitCore/Presentation/PresentationDefaults.swift` | `GlanceVisibility`, `DisplayThreshold`, `GraphStyle`, `GraphRange`, `DisplayTone`. |
| `Sources/AmbitCore/Entity.swift` | Add presentation-default fields to `EntityDescriptor`. |
| `Sources/AmbitCore/Presentation/CardSpec.swift` | `CardKind`, `CardRole`, `CardSpec`, `SurfacePlan`. |
| `Sources/AmbitCore/Presentation/PresentationConfig.swift` | `PresentationConfig`, `EntityPresentationOverride`, `IntegrationPresentationOverride`. |
| `Sources/AmbitCore/Presentation/EntityReadout.swift` | Pure value→(text, fraction, tone) formatting. |
| `Sources/AmbitCore/Presentation/SurfaceComposer.swift` | `SurfaceComposer.detailPlan(...)` — the binding decision. |
| `Sources/AmbitUI/GraphGeometry.swift` | Pure axis/path math (harvested from `LatencyGraph`). |
| `Sources/AmbitUI/Theme.swift` | `DisplayTone` → SwiftUI `Color`. |
| `Sources/AmbitUI/Cards/*.swift` | One SwiftUI view per card kind. |
| `Sources/AmbitUI/SurfaceView.swift` | `CardView` dispatcher + `SurfaceView(plan:data:)`. |
| `Sources/AmbitUI/HistoryGraphLoader.swift` | Reads `HistoryService` → `[Sample]` for a graph. |
| `Tests/AmbitCoreTests/*` | Composer + readout + defaults tests (incl. ported grouping coverage). |
| `Tests/AmbitUITests/*` | Geometry + loader tests. |

**Files DELETED in Task 6:** `Sources/AmbitCore/ProviderDisplayModel.swift`, `ProviderSurfaceModel.swift`, `ProviderMetricSection.swift`; `Tests/AmbitCoreTests/ProviderDisplayModelTests.swift`, `ProviderSurfaceModelTests.swift`, `ProviderMetricSectionTests.swift`.

---

### Task 1: Scaffold the AmbitUI + AmbitUITests targets

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AmbitUI/AmbitUI.swift`
- Test: `Tests/AmbitUITests/SmokeTests.swift`

**Interfaces:**
- Produces: an `AmbitUI` library target depending on `AmbitCore`; an `AmbitUITests` target depending on both.

- [ ] **Step 1: Add the targets to `Package.swift`**

Replace the `products` and `targets` arrays:

```swift
    products: [
        .library(name: "AmbitCore", targets: ["AmbitCore"]),
        .library(name: "AmbitUI", targets: ["AmbitUI"]),
        .executable(name: "Ambit", targets: ["AmbitMenuBar"]),
        .executable(name: "ambit-check", targets: ["AmbitCheck"])
    ],
    targets: [
        .target(name: "AmbitCore"),
        .target(name: "AmbitUI", dependencies: ["AmbitCore"]),
        .executableTarget(
            name: "AmbitMenuBar",
            dependencies: ["AmbitCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(name: "AmbitCheck", dependencies: ["AmbitCore"]),
        .testTarget(name: "AmbitCoreTests", dependencies: ["AmbitCore"]),
        .testTarget(name: "AmbitUITests", dependencies: ["AmbitUI", "AmbitCore"])
    ]
```

- [ ] **Step 2: Create a placeholder so the target compiles**

`Sources/AmbitUI/AmbitUI.swift`:

```swift
import SwiftUI
import AmbitCore

// AmbitUI: the generic, reusable SwiftUI presentation layer for Ambit surfaces.
// Renders an AmbitCore SurfacePlan against injected entity states + history samples.
public enum AmbitUI {
    public static let version = "p1"
}
```

- [ ] **Step 3: Write a smoke test**

`Tests/AmbitUITests/SmokeTests.swift`:

```swift
import XCTest
@testable import AmbitUI

final class SmokeTests: XCTestCase {
    func testTargetBuildsAndExposesVersion() {
        XCTAssertEqual(AmbitUI.version, "p1")
    }
}
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: builds; `SmokeTests` passes; existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AmbitUI Tests/AmbitUITests
git commit -m "P1: scaffold AmbitUI library + test target"
```

---

### Task 2: Presentation-default types + descriptor fields

**Files:**
- Create: `Sources/AmbitCore/Presentation/PresentationDefaults.swift`
- Modify: `Sources/AmbitCore/Entity.swift:11-60` (EntityDescriptor stored fields + init)
- Test: `Tests/AmbitCoreTests/PresentationDefaultsTests.swift`

**Interfaces:**
- Produces:
  - `enum GlanceVisibility: String, Sendable, Codable { case always, auto, never }`
  - `enum GraphStyle: String, Sendable, Codable { case sparkline, gauge, progress, none }`
  - `enum GraphRange: String, Sendable, Codable, CaseIterable { case m1, m5, m10, h1; var seconds: TimeInterval; var label: String }`
  - `struct DisplayThreshold: Equatable, Sendable, Codable { var comparison: AlertComparison; var value: Double; var consecutive: Int }`
  - `enum DisplayTone: String, Sendable, Codable { case neutral, good, warn, bad }`
  - `EntityDescriptor` gains: `defaultVisibility: GlanceVisibility` (default `.auto`), `displayThreshold: DisplayThreshold?`, `graphStyle: GraphStyle?`, `defaultGraphRange: GraphRange?`, `isPrimary: Bool` (default `false`), `priority: Int?`.

- [ ] **Step 1: Write the failing test**

`Tests/AmbitCoreTests/PresentationDefaultsTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class PresentationDefaultsTests: XCTestCase {
    func testGraphRangeSeconds() {
        XCTAssertEqual(GraphRange.m1.seconds, 60)
        XCTAssertEqual(GraphRange.m5.seconds, 300)
        XCTAssertEqual(GraphRange.m10.seconds, 600)
        XCTAssertEqual(GraphRange.h1.seconds, 3600)
        XCTAssertEqual(GraphRange.allCases.count, 4)
    }

    func testDisplayThresholdRoundTrips() throws {
        let t = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(DisplayThreshold.self, from: data), t)
    }

    func testDescriptorPresentationDefaultsHaveSensibleFallbacks() {
        let d = EntityDescriptor(
            id: "glinet/router.latency",
            instanceID: "glinet/router",
            name: "Latency",
            kind: .sensor
        )
        XCTAssertEqual(d.defaultVisibility, .auto)
        XCTAssertFalse(d.isPrimary)
        XCTAssertNil(d.graphStyle)
        XCTAssertNil(d.defaultGraphRange)
        XCTAssertNil(d.priority)
    }

    func testDescriptorCarriesPresentationDefaults() {
        let d = EntityDescriptor(
            id: "ping/probe.latency", instanceID: "ping/probe", name: "Latency", kind: .sensor,
            stateClass: .measurement,
            graphStyle: .sparkline, defaultGraphRange: .m5, isPrimary: true, priority: 3
        )
        XCTAssertEqual(d.graphStyle, .sparkline)
        XCTAssertEqual(d.defaultGraphRange, .m5)
        XCTAssertTrue(d.isPrimary)
        XCTAssertEqual(d.priority, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PresentationDefaultsTests`
Expected: FAIL — `GraphRange`/`DisplayThreshold` undefined; init has no `graphStyle`/`isPrimary` params.

- [ ] **Step 3: Create the presentation-default types**

`Sources/AmbitCore/Presentation/PresentationDefaults.swift`:

```swift
import Foundation

// Presentation defaults an integration declares on its EntityDescriptors and the generic
// layer reads (all overridable by the user via PresentationConfig). presentation-model.md §6.

/// Whether an entity appears on glance surfaces (menu bar, Island, …). `auto` = conditional
/// on health / alert / display-threshold; resolved by the Attention engine (P4).
public enum GlanceVisibility: String, Sendable, Codable { case always, auto, never }

/// How a single sensor visualizes on the detail surface.
public enum GraphStyle: String, Sendable, Codable { case sparkline, gauge, progress, none }

/// The default time window a history graph shows. Windows harvested from pingscope's TimeRange.
public enum GraphRange: String, Sendable, Codable, CaseIterable {
    case m1, m5, m10, h1

    public var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        case .m10: return 600
        case .h1: return 3600
        }
    }

    public var label: String {
        switch self {
        case .m1: return "1m"
        case .m5: return "5m"
        case .m10: return "10m"
        case .h1: return "1h"
        }
    }
}

/// The "surface" tier condition — distinct from the alert threshold (presentation-model.md §4a).
/// Reuses the existing AlertComparison so display + alert thresholds speak one comparison vocabulary.
public struct DisplayThreshold: Equatable, Sendable, Codable {
    public var comparison: AlertComparison
    public var value: Double
    public var consecutive: Int   // sustained-samples debounce, mirrors the M4 pattern

    public init(comparison: AlertComparison, value: Double, consecutive: Int = 1) {
        self.comparison = comparison
        self.value = value
        self.consecutive = consecutive
    }
}

/// Generic display tone for a value/row. UI-free; AmbitUI maps it to a Color (Theme.swift).
public enum DisplayTone: String, Sendable, Codable { case neutral, good, warn, bad }
```

- [ ] **Step 4: Add the fields to `EntityDescriptor`**

In `Sources/AmbitCore/Entity.swift`, add the stored properties after `metricID` (line 26):

```swift
    public var metricID: String?
    // Presentation defaults (presentation-model.md §6). Additive; all defaulted.
    public var defaultVisibility: GlanceVisibility
    public var displayThreshold: DisplayThreshold?
    public var graphStyle: GraphStyle?
    public var defaultGraphRange: GraphRange?
    public var isPrimary: Bool
    public var priority: Int?
```

Extend the initializer parameter list (after `metricID: String? = nil`) and assignments:

```swift
        metricID: String? = nil,
        defaultVisibility: GlanceVisibility = .auto,
        displayThreshold: DisplayThreshold? = nil,
        graphStyle: GraphStyle? = nil,
        defaultGraphRange: GraphRange? = nil,
        isPrimary: Bool = false,
        priority: Int? = nil
    ) {
```

…and at the end of the init body, after `self.metricID = metricID`:

```swift
        self.metricID = metricID
        self.defaultVisibility = defaultVisibility
        self.displayThreshold = displayThreshold
        self.graphStyle = graphStyle
        self.defaultGraphRange = defaultGraphRange
        self.isPrimary = isPrimary
        self.priority = priority
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter PresentationDefaultsTests && swift build`
Expected: PASS; whole package still builds (existing descriptor call sites use defaulted params).

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/Presentation/PresentationDefaults.swift Sources/AmbitCore/Entity.swift Tests/AmbitCoreTests/PresentationDefaultsTests.swift
git commit -m "P1: add presentation-default fields to EntityDescriptor"
```

---

### Task 3: Card vocabulary types (`CardSpec`/`SurfacePlan`)

**Files:**
- Create: `Sources/AmbitCore/Presentation/CardSpec.swift`
- Test: `Tests/AmbitCoreTests/CardSpecTests.swift`

**Interfaces:**
- Produces:
  - `enum CardKind: String, Equatable, Sendable, Codable { case statusRow, gauge, historyGraph, dualLineGraph, progress, statTable, control, instanceSelector, section, statusBanner }`
  - `enum CardRole: String, Equatable, Sendable, Codable { case primary, secondary, banner }`
  - `struct CardSpec: Identifiable, Equatable, Sendable { var id: String; var kind: CardKind; var title: String?; var entities: [EntityID]; var graphStyle: GraphStyle?; var graphRange: GraphRange?; var children: [CardSpec]; var role: CardRole }`
  - `struct SurfacePlan: Equatable, Sendable { var cards: [CardSpec] }`

- [ ] **Step 1: Write the failing test**

`Tests/AmbitCoreTests/CardSpecTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class CardSpecTests: XCTestCase {
    func testCardKindCoversTheVocabulary() {
        let kinds: Set<CardKind> = [
            .statusRow, .gauge, .historyGraph, .dualLineGraph, .progress,
            .statTable, .control, .instanceSelector, .section, .statusBanner
        ]
        XCTAssertEqual(kinds.count, 10)
    }

    func testSectionCardNestsChildren() {
        let child = CardSpec(id: "c1", kind: .statusRow, entities: ["glinet/router.health"])
        let section = CardSpec(id: "s1", kind: .section, title: "Network", children: [child])
        XCTAssertEqual(section.children.first, child)
        XCTAssertEqual(section.kind, .section)
    }

    func testSurfacePlanEquatable() {
        let a = SurfacePlan(cards: [CardSpec(id: "x", kind: .gauge, entities: ["e"])])
        let b = SurfacePlan(cards: [CardSpec(id: "x", kind: .gauge, entities: ["e"])])
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardSpecTests`
Expected: FAIL — `CardKind`/`CardSpec`/`SurfacePlan` undefined.

- [ ] **Step 3: Create the types**

`Sources/AmbitCore/Presentation/CardSpec.swift`:

```swift
import Foundation

// The fixed, generic card vocabulary (presentation-model.md §2). A CardSpec is the
// render-agnostic decision "this kind of card, bound to these entities" — produced by
// SurfaceComposer, consumed by AmbitUI. Values flow separately (live EntityState + history).

public enum CardKind: String, Equatable, Sendable, Codable {
    case statusRow
    case gauge
    case historyGraph
    case dualLineGraph
    case progress
    case statTable
    case control
    case instanceSelector
    case section
    case statusBanner
}

public enum CardRole: String, Equatable, Sendable, Codable {
    case primary
    case secondary
    case banner
}

public struct CardSpec: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: CardKind
    public var title: String?
    public var entities: [EntityID]      // 1 for a gauge, 2 for dual-line, N for a table, 0 for a section
    public var graphStyle: GraphStyle?
    public var graphRange: GraphRange?
    public var children: [CardSpec]      // populated for .section
    public var role: CardRole

    public init(
        id: String,
        kind: CardKind,
        title: String? = nil,
        entities: [EntityID] = [],
        graphStyle: GraphStyle? = nil,
        graphRange: GraphRange? = nil,
        children: [CardSpec] = [],
        role: CardRole = .secondary
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.entities = entities
        self.graphStyle = graphStyle
        self.graphRange = graphRange
        self.children = children
        self.role = role
    }
}

public struct SurfacePlan: Equatable, Sendable {
    public var cards: [CardSpec]
    public init(cards: [CardSpec] = []) { self.cards = cards }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter CardSpecTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitCore/Presentation/CardSpec.swift Tests/AmbitCoreTests/CardSpecTests.swift
git commit -m "P1: add CardSpec/SurfacePlan card vocabulary types"
```

---

### Task 4: `PresentationConfig` (overrides store)

**Files:**
- Create: `Sources/AmbitCore/Presentation/PresentationConfig.swift`
- Test: `Tests/AmbitCoreTests/PresentationConfigTests.swift`

**Interfaces:**
- Produces:
  - `struct EntityPresentationOverride: Equatable, Sendable, Codable { var visibility: GlanceVisibility?; var pinned: Bool?; var displayThreshold: DisplayThreshold?; var alertPolicy: AlertPolicy?; var graphStyle: GraphStyle?; var graphRange: GraphRange?; var enabled: Bool?; var interval: TimeInterval? }`
  - `struct IntegrationPresentationOverride: Equatable, Sendable, Codable { var enabled: Bool?; var pinned: Bool? }`
  - `struct PresentationConfig: Equatable, Sendable, Codable { var entityOverrides: [EntityID: EntityPresentationOverride]; var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]; static var empty: PresentationConfig }`
- Note: the `slots: [Slot]` field is added in P3 when the slot model lands; P1 omits it.

- [ ] **Step 1: Write the failing test**

`Tests/AmbitCoreTests/PresentationConfigTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class PresentationConfigTests: XCTestCase {
    func testEmptyConfigHasNoOverrides() {
        let c = PresentationConfig.empty
        XCTAssertTrue(c.entityOverrides.isEmpty)
        XCTAssertTrue(c.integrationOverrides.isEmpty)
    }

    func testConfigRoundTripsThroughCodable() throws {
        var c = PresentationConfig.empty
        c.entityOverrides["ping/probe.latency"] = EntityPresentationOverride(
            visibility: .always, graphStyle: .sparkline, graphRange: .m1, enabled: true
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PresentationConfigTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Create the types**

`Sources/AmbitCore/Presentation/PresentationConfig.swift`:

```swift
import Foundation

// User overrides over descriptor presentation-defaults (presentation-model.md §5–6). All
// optional: nil means "use the descriptor default". The generic settings renderer (P5) writes
// these; SurfaceComposer + the Attention engine read them.

public struct EntityPresentationOverride: Equatable, Sendable, Codable {
    public var visibility: GlanceVisibility?
    public var pinned: Bool?
    public var displayThreshold: DisplayThreshold?
    public var alertPolicy: AlertPolicy?
    public var graphStyle: GraphStyle?
    public var graphRange: GraphRange?
    public var enabled: Bool?
    public var interval: TimeInterval?

    public init(
        visibility: GlanceVisibility? = nil,
        pinned: Bool? = nil,
        displayThreshold: DisplayThreshold? = nil,
        alertPolicy: AlertPolicy? = nil,
        graphStyle: GraphStyle? = nil,
        graphRange: GraphRange? = nil,
        enabled: Bool? = nil,
        interval: TimeInterval? = nil
    ) {
        self.visibility = visibility
        self.pinned = pinned
        self.displayThreshold = displayThreshold
        self.alertPolicy = alertPolicy
        self.graphStyle = graphStyle
        self.graphRange = graphRange
        self.enabled = enabled
        self.interval = interval
    }
}

public struct IntegrationPresentationOverride: Equatable, Sendable, Codable {
    public var enabled: Bool?
    public var pinned: Bool?
    public init(enabled: Bool? = nil, pinned: Bool? = nil) {
        self.enabled = enabled
        self.pinned = pinned
    }
}

public struct PresentationConfig: Equatable, Sendable, Codable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]

    public init(
        entityOverrides: [EntityID: EntityPresentationOverride] = [:],
        integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride] = [:]
    ) {
        self.entityOverrides = entityOverrides
        self.integrationOverrides = integrationOverrides
    }

    public static var empty: PresentationConfig { PresentationConfig() }
}
```

> Note: `[EntityID: …]` and `[IntegrationInstanceID: …]` are `Codable` because those id types
> conform to `Codable` with a `RawRepresentable(String)` backing. If the compiler rejects the
> dictionary `Codable` synthesis (non-`String`/`Int` key), confirm `EntityID`/`IntegrationInstanceID`
> already conform to `Codable` (they do, per `Identity.swift`); Swift encodes such keyed dictionaries
> as an array. The round-trip test guards this.

- [ ] **Step 4: Run tests**

Run: `swift test --filter PresentationConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitCore/Presentation/PresentationConfig.swift Tests/AmbitCoreTests/PresentationConfigTests.swift
git commit -m "P1: add PresentationConfig override store"
```

---

### Task 5: `EntityReadout` (value → text / fraction / tone)

**Files:**
- Create: `Sources/AmbitCore/Presentation/EntityReadout.swift`
- Test: `Tests/AmbitCoreTests/EntityReadoutTests.swift`

**Interfaces:**
- Consumes: `EntityDescriptor`, `EntityState`, `EntityValue`, `DeviceClass`, `Availability`, `DisplayTone`, `ValueRange`.
- Produces:
  - `struct EntityReadout: Equatable, Sendable { var text: String; var fraction: Double?; var tone: DisplayTone }`
  - `static func EntityReadout.make(descriptor: EntityDescriptor, state: EntityState?) -> EntityReadout`

- [ ] **Step 1: Write the failing test**

`Tests/AmbitCoreTests/EntityReadoutTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class EntityReadoutTests: XCTestCase {
    private func descriptor(_ deviceClass: DeviceClass?, kind: EntityKind = .sensor, unit: String? = nil, range: ValueRange? = nil) -> EntityDescriptor {
        EntityDescriptor(id: "i/p.e", instanceID: "i/p", name: "E", kind: kind, deviceClass: deviceClass, unit: unit, range: range)
    }

    func testLatencyFormatsAsMilliseconds() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(42.4), availability: .online))
        XCTAssertEqual(r.text, "42ms")
        XCTAssertEqual(r.tone, .good)
        XCTAssertNil(r.fraction)
    }

    func testPercentProducesFraction() {
        let r = EntityReadout.make(descriptor: descriptor(.percent), state: EntityState(id: "i/p.e", value: .number(64), availability: .online))
        XCTAssertEqual(r.text, "64%")
        XCTAssertEqual(r.fraction, 0.64, accuracy: 0.0001)
    }

    func testBatteryUsesRangeWhenPresent() {
        let r = EntityReadout.make(descriptor: descriptor(.battery, range: ValueRange(min: 0, max: 100)), state: EntityState(id: "i/p.e", value: .number(20), availability: .online))
        XCTAssertEqual(r.fraction, 0.20, accuracy: 0.0001)
    }

    func testBoolBinarySensorTextAndTone() {
        let r = EntityReadout.make(descriptor: descriptor(.connectivity, kind: .binarySensor), state: EntityState(id: "i/p.e", value: .bool(true), availability: .online))
        XCTAssertEqual(r.text, "Yes")
        XCTAssertEqual(r.tone, .good)
    }

    func testUnavailableIsBadAndDashed() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: nil, availability: .unavailable))
        XCTAssertEqual(r.text, "—")
        XCTAssertEqual(r.tone, .bad)
    }

    func testStaleIsWarn() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(10), availability: .stale))
        XCTAssertEqual(r.tone, .warn)
    }

    func testNilStateIsNeutralDash() {
        let r = EntityReadout.make(descriptor: descriptor(.latency), state: nil)
        XCTAssertEqual(r.text, "—")
        XCTAssertEqual(r.tone, .neutral)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EntityReadoutTests`
Expected: FAIL — `EntityReadout` undefined.

- [ ] **Step 3: Implement `EntityReadout`**

`Sources/AmbitCore/Presentation/EntityReadout.swift`:

```swift
import Foundation

// Pure, UI-free formatting of an entity's current value into display text, an optional 0…1
// fraction (for gauges/progress), and a generic tone. AmbitUI maps DisplayTone to a Color.
// This replaces the ad-hoc per-metric formatting in the retired display models.

public struct EntityReadout: Equatable, Sendable {
    public var text: String
    public var fraction: Double?
    public var tone: DisplayTone

    public init(text: String, fraction: Double? = nil, tone: DisplayTone = .neutral) {
        self.text = text
        self.fraction = fraction
        self.tone = tone
    }

    public static func make(descriptor: EntityDescriptor, state: EntityState?) -> EntityReadout {
        guard let state else { return EntityReadout(text: "—", tone: .neutral) }

        let tone = toneFor(availability: state.availability, value: state.value)
        guard let value = state.value else {
            return EntityReadout(text: "—", tone: tone)
        }

        switch value {
        case .number(let n):
            return EntityReadout(text: format(n, descriptor: descriptor),
                                 fraction: fraction(n, descriptor: descriptor),
                                 tone: tone)
        case .bool(let b):
            return EntityReadout(text: b ? "Yes" : "No", tone: tone)
        case .text(let s):
            return EntityReadout(text: s, tone: tone)
        }
    }

    private static func toneFor(availability: Availability, value: EntityValue?) -> DisplayTone {
        switch availability {
        case .unavailable: return .bad
        case .stale: return .warn
        case .online: return .good
        }
    }

    private static func format(_ n: Double, descriptor: EntityDescriptor) -> String {
        switch descriptor.deviceClass {
        case .latency: return "\(Int(n.rounded()))ms"
        case .percent, .battery: return "\(Int(n.rounded()))%"
        case .throughput: return formatThroughput(bitsPerSecond: n)
        case .count: return "\(Int(n.rounded()))"
        case .duration: return "\(Int(n.rounded()))s"
        case .power: return "\(Int(n.rounded()))W"
        case .connectivity, .none:
            if let unit = descriptor.unit { return "\(trim(n)) \(unit)" }
            return trim(n)
        }
    }

    private static func fraction(_ n: Double, descriptor: EntityDescriptor) -> Double? {
        switch descriptor.deviceClass {
        case .percent, .battery:
            let maxV = descriptor.range?.max ?? 100
            guard maxV > 0 else { return nil }
            return Swift.min(Swift.max(n / maxV, 0), 1)
        default:
            return nil
        }
    }

    private static func trim(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }

    private static func formatThroughput(bitsPerSecond bps: Double) -> String {
        let mbps = bps / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%.0f Kbps", bps / 1_000)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter EntityReadoutTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitCore/Presentation/EntityReadout.swift Tests/AmbitCoreTests/EntityReadoutTests.swift
git commit -m "P1: add EntityReadout value formatting"
```

---

### Task 6: `SurfaceComposer.detailPlan` + ported grouping coverage; retire the old models

**Files:**
- Create: `Sources/AmbitCore/Presentation/SurfaceComposer.swift`
- Test: `Tests/AmbitCoreTests/SurfaceComposerTests.swift`
- Delete: `Sources/AmbitCore/ProviderDisplayModel.swift`, `Sources/AmbitCore/ProviderSurfaceModel.swift`, `Sources/AmbitCore/ProviderMetricSection.swift`
- Delete: `Tests/AmbitCoreTests/ProviderDisplayModelTests.swift`, `Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift`, `Tests/AmbitCoreTests/ProviderMetricSectionTests.swift`

**Interfaces:**
- Consumes: `EntityDescriptor`, `EntityState`, `PresentationConfig`, `CardSpec`, `SurfacePlan`, `GraphStyle`, `GraphRange`.
- Produces:
  - `static func SurfaceComposer.detailPlan(descriptors: [EntityDescriptor], states: [EntityID: EntityState], config: PresentationConfig = .empty) -> SurfacePlan`

**Composition rules (the binding decision):**
1. Drop entities whose `config.entityOverrides[id]?.enabled == false`, and `category == .config` entities (config belongs to settings, P5).
2. Group survivors into ordered sections: **Network** (`.connectivity`/`.throughput`/`.latency`), **Power** (`.battery`/`.power`), **State** (binarySensor/text with no networking/power class), **Controls** (toggle/select/number/button), **Other** (everything else). This preserves the retired `ProviderMetricSection` grouping intent on entities (deviceClass wins over kind).
3. Within a section: `isPrimary` first, then descending `priority` (nil last), then stable insertion order.
4. Per descriptor → a `CardSpec` via `cardKind(for:)`:
   - control kinds → `.control`
   - `binarySensor` / `text` → `.statusRow`
   - `sensor`/`number`: effective `graphStyle` (override → descriptor → derived) maps `.gauge`→`.gauge`, `.progress`→`.progress`, `.sparkline`→`.historyGraph`, `.none`→`.statusRow`; when unset, `stateClass == .measurement` ⇒ `.historyGraph`, else `.statusRow`.
   - history/graph cards carry effective `graphRange` (override → descriptor → `.m5`).
5. Each non-empty section → a `.section` `CardSpec` (title, children); primary-role for the section containing an `isPrimary` entity.

- [ ] **Step 1: Write the failing tests (incl. ported grouping coverage)**

`Tests/AmbitCoreTests/SurfaceComposerTests.swift`:

```swift
import XCTest
@testable import AmbitCore

final class SurfaceComposerTests: XCTestCase {
    private func sensor(_ key: String, _ deviceClass: DeviceClass?, kind: EntityKind = .sensor,
                        stateClass: StateClass? = nil, graphStyle: GraphStyle? = nil,
                        isPrimary: Bool = false, priority: Int? = nil, category: EntityCategory = .primary) -> EntityDescriptor {
        EntityDescriptor(id: EntityID(rawValue: "i/p.\(key)"), instanceID: "i/p", name: key, kind: kind,
                         deviceClass: deviceClass, category: category, stateClass: stateClass,
                         graphStyle: graphStyle, isPrimary: isPrimary, priority: priority)
    }

    // Ported from ProviderMetricSectionTests: grouping by classification, deviceClass wins.
    func testGroupsEntitiesByClassificationInOrder() {
        let descriptors = [
            sensor("latency", .latency, stateClass: .measurement),
            sensor("download", .throughput, stateClass: .measurement),
            sensor("battery", .battery),
            sensor("online", .connectivity, kind: .binarySensor),
            sensor("note", nil, kind: .text)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        // online is connectivity → Network; note (text, no class) → State.
        XCTAssertEqual(plan.cards.map { $0.title }, ["Network", "Power", "State"])
        let network = plan.cards[0]
        XCTAssertEqual(network.children.map { $0.entities.first?.rawValue }, ["i/p.latency", "i/p.download", "i/p.online"])
    }

    func testDeviceClassWinsOverValueShape() {
        // A battery sensor whose value is a percentage still groups under Power.
        let descriptors = [
            sensor("soc", .battery),
            sensor("load", .power),
            sensor("note", nil, kind: .text)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        XCTAssertEqual(plan.cards.map { $0.title }, ["Power", "State"])
        XCTAssertEqual(plan.cards[0].children.map { $0.entities.first?.rawValue }, ["i/p.soc", "i/p.load"])
    }

    func testSensorGraphStyleSelectsCardKind() {
        let descriptors = [
            sensor("g", .percent, graphStyle: .gauge),
            sensor("p", .battery, graphStyle: .progress),
            sensor("s", .latency, graphStyle: .sparkline),
            sensor("r", .latency, graphStyle: GraphStyle.none)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        let kinds = plan.cards.flatMap { $0.children }.reduce(into: [String: CardKind]()) { $0[$1.entities.first!.rawValue] = $1.kind }
        XCTAssertEqual(kinds["i/p.g"], .gauge)
        XCTAssertEqual(kinds["i/p.p"], .progress)
        XCTAssertEqual(kinds["i/p.s"], .historyGraph)
        XCTAssertEqual(kinds["i/p.r"], .statusRow)
    }

    func testUnsetGraphStyleMeasurementBecomesHistoryGraph() {
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("m", .latency, stateClass: .measurement)], states: [:])
        XCTAssertEqual(plan.cards.first?.children.first?.kind, .historyGraph)
        XCTAssertEqual(plan.cards.first?.children.first?.graphRange, .m5)  // layer default
    }

    func testControlsGroupSeparately() {
        let toggle = EntityDescriptor(id: "i/p.vpn", instanceID: "i/p", name: "VPN", kind: .toggle,
                                      command: CommandRef(commandID: "vpn.toggle"))
        let plan = SurfaceComposer.detailPlan(descriptors: [toggle], states: [:])
        XCTAssertEqual(plan.cards.map { $0.title }, ["Controls"])
        XCTAssertEqual(plan.cards.first?.children.first?.kind, .control)
    }

    func testPrimarySortsFirstWithinSection() {
        let descriptors = [
            sensor("a", .latency, priority: 1),
            sensor("b", .latency, isPrimary: true)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        XCTAssertEqual(plan.cards[0].children.first?.entities.first?.rawValue, "i/p.b")
        XCTAssertEqual(plan.cards[0].role, .primary)
    }

    func testConfigEntitiesExcludedFromDetail() {
        let cfg = sensor("host", nil, kind: .text, category: .config)
        let plan = SurfaceComposer.detailPlan(descriptors: [cfg], states: [:])
        XCTAssertTrue(plan.cards.isEmpty)
    }

    func testDisabledOverrideDropsEntity() {
        var config = PresentationConfig.empty
        config.entityOverrides["i/p.latency"] = EntityPresentationOverride(enabled: false)
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("latency", .latency)], states: [:], config: config)
        XCTAssertTrue(plan.cards.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SurfaceComposerTests`
Expected: FAIL — `SurfaceComposer` undefined.

- [ ] **Step 3: Implement `SurfaceComposer`**

`Sources/AmbitCore/Presentation/SurfaceComposer.swift`:

```swift
import Foundation

// The entity-driven binding decision: descriptors + states + user config → a SurfacePlan.
// Replaces the Metric-based ProviderDisplayModel / ProviderSurfaceModel / ProviderMetricSection.
// UI-free and pure, so AmbitCheck and tests assert layout without SwiftUI.

public enum SurfaceComposer {

    private enum Section: Int, CaseIterable {
        case network, power, state, controls, other
        var title: String {
            switch self {
            case .network: return "Network"
            case .power: return "Power"
            case .state: return "State"
            case .controls: return "Controls"
            case .other: return "Other"
            }
        }
    }

    public static func detailPlan(
        descriptors: [EntityDescriptor],
        states: [EntityID: EntityState],
        config: PresentationConfig = .empty
    ) -> SurfacePlan {
        let visible = descriptors.filter { descriptor in
            if descriptor.category == .config { return false }
            if config.entityOverrides[descriptor.id]?.enabled == false { return false }
            return true
        }

        var bySection: [Section: [EntityDescriptor]] = [:]
        for descriptor in visible {
            bySection[section(for: descriptor), default: []].append(descriptor)
        }

        var cards: [CardSpec] = []
        for section in Section.allCases {
            guard let group = bySection[section], !group.isEmpty else { continue }
            let ordered = group.sorted(by: ordering)
            let children = ordered.map { card(for: $0, config: config) }
            let role: CardRole = ordered.contains(where: \.isPrimary) ? .primary : .secondary
            cards.append(CardSpec(id: "section.\(section.title)", kind: .section,
                                  title: section.title, children: children, role: role))
        }
        return SurfacePlan(cards: cards)
    }

    private static func section(for d: EntityDescriptor) -> Section {
        if isControl(d.kind) { return .controls }
        switch d.deviceClass {
        case .connectivity, .throughput, .latency: return .network
        case .battery, .power: return .power
        case .percent, .count, .duration: return .other
        case .none:
            switch d.kind {
            case .binarySensor, .text: return .state
            default: return .other
            }
        }
    }

    private static func ordering(_ a: EntityDescriptor, _ b: EntityDescriptor) -> Bool {
        if a.isPrimary != b.isPrimary { return a.isPrimary }
        let pa = a.priority ?? Int.min
        let pb = b.priority ?? Int.min
        if pa != pb { return pa > pb }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private static func card(for d: EntityDescriptor, config: PresentationConfig) -> CardSpec {
        let role: CardRole = d.isPrimary ? .primary : .secondary
        let kind = cardKind(for: d, config: config)
        let style = effectiveGraphStyle(d, config: config)
        let range: GraphRange? = (kind == .historyGraph || kind == .gauge || kind == .progress)
            ? (config.entityOverrides[d.id]?.graphRange ?? d.defaultGraphRange ?? .m5)
            : nil
        return CardSpec(id: "card.\(d.id.rawValue)", kind: kind, title: d.name,
                        entities: [d.id], graphStyle: style, graphRange: range, role: role)
    }

    private static func cardKind(for d: EntityDescriptor, config: PresentationConfig) -> CardKind {
        if isControl(d.kind) { return .control }
        if d.kind == .binarySensor || d.kind == .text { return .statusRow }
        switch effectiveGraphStyle(d, config: config) {
        case .gauge: return .gauge
        case .progress: return .progress
        case .sparkline: return .historyGraph
        case .none: return .statusRow
        case nil:
            return d.stateClass == .measurement ? .historyGraph : .statusRow
        }
    }

    private static func effectiveGraphStyle(_ d: EntityDescriptor, config: PresentationConfig) -> GraphStyle? {
        config.entityOverrides[d.id]?.graphStyle ?? d.graphStyle
    }

    private static func isControl(_ kind: EntityKind) -> Bool {
        switch kind {
        case .toggle, .select, .number, .button: return true
        case .sensor, .binarySensor, .text: return false
        }
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter SurfaceComposerTests`
Expected: PASS.

- [ ] **Step 5: Delete the retired models and their tests**

Coverage is now ported (grouping → `SurfaceComposerTests`, value formatting → `EntityReadoutTests`). Delete:

```bash
git rm Sources/AmbitCore/ProviderDisplayModel.swift \
       Sources/AmbitCore/ProviderSurfaceModel.swift \
       Sources/AmbitCore/ProviderMetricSection.swift \
       Tests/AmbitCoreTests/ProviderDisplayModelTests.swift \
       Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift \
       Tests/AmbitCoreTests/ProviderSurfaceModelTests.swift \
       Tests/AmbitCoreTests/ProviderMetricSectionTests.swift
```

> If any non-test file fails to build after deletion, it was an undiscovered consumer — STOP and
> reconcile (the spec expects no production consumers; the menu bar renders pingscope directly). Do
> not silently re-add the models.

- [ ] **Step 6: Build and run the full suite**

Run: `swift build && swift test`
Expected: whole package builds; all tests green; no reference to the deleted models remains.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "P1: add SurfaceComposer.detailPlan; retire Metric-based display models"
```

---

### Task 7: `GraphGeometry` — pure axis + path math (harvested)

**Files:**
- Create: `Sources/AmbitUI/GraphGeometry.swift`
- Test: `Tests/AmbitUITests/GraphGeometryTests.swift`

**Interfaces:**
- Consumes: `Sample` (AmbitCore), `CoreGraphics`.
- Produces:
  - `enum GraphGeometry { static func niceMax(_ values: [Double]) -> Double; static func points(samples: [Sample], in size: CGSize, axisMax: Double) -> [CGPoint] }`

- [ ] **Step 1: Write the failing test**

`Tests/AmbitUITests/GraphGeometryTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import AmbitUI
import AmbitCore

final class GraphGeometryTests: XCTestCase {
    func testNiceMaxRoundsUpToCleanCeiling() {
        XCTAssertEqual(GraphGeometry.niceMax([42, 120]), 150)
        XCTAssertEqual(GraphGeometry.niceMax([600]), 750)
        XCTAssertEqual(GraphGeometry.niceMax([]), 100)
        XCTAssertEqual(GraphGeometry.niceMax([0]), 100)
    }

    func testPointsMapValuesIntoBox() {
        let now = Date(timeIntervalSince1970: 0)
        let samples = [
            Sample(timestamp: now, value: 0),
            Sample(timestamp: now, value: 50),
            Sample(timestamp: now, value: 100)
        ]
        let pts = GraphGeometry.points(samples: samples, in: CGSize(width: 100, height: 100), axisMax: 100)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(pts[0].y, 100, accuracy: 0.001)   // value 0 → bottom
        XCTAssertEqual(pts[2].x, 100, accuracy: 0.001)
        XCTAssertEqual(pts[2].y, 0, accuracy: 0.001)     // value == axisMax → top
        XCTAssertEqual(pts[1].y, 50, accuracy: 0.001)
    }

    func testMissingValueTreatedAsZero() {
        let now = Date(timeIntervalSince1970: 0)
        let pts = GraphGeometry.points(samples: [Sample(timestamp: now, value: nil, ok: false), Sample(timestamp: now, value: 100)],
                                       in: CGSize(width: 10, height: 10), axisMax: 100)
        XCTAssertEqual(pts[0].y, 10, accuracy: 0.001)  // nil → 0 → bottom
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GraphGeometryTests`
Expected: FAIL — `GraphGeometry` undefined.

- [ ] **Step 3: Implement `GraphGeometry`**

`Sources/AmbitUI/GraphGeometry.swift`:

```swift
import CoreGraphics
import Foundation
import AmbitCore

// Pure time-series geometry, harvested from pingscope's LatencyGraph Canvas math. Kept
// separate from the View so it is unit-testable and reusable by every graph card.
public enum GraphGeometry {

    private static let ladder: [Double] = [50, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000]

    /// Smallest "nice" ceiling at or above the max value; 100 when there is no positive data.
    public static func niceMax(_ values: [Double]) -> Double {
        guard let maxValue = values.max(), maxValue > 0 else { return 100 }
        if let step = ladder.first(where: { $0 >= maxValue }) { return step }
        return (maxValue / 1000).rounded(.up) * 1000
    }

    /// Sample series mapped into a box: x spreads evenly across width, y inverts value/axisMax.
    /// Missing values render as 0 (bottom), matching the harvested LatencyGraph behavior.
    public static func points(samples: [Sample], in size: CGSize, axisMax: Double) -> [CGPoint] {
        guard samples.count > 1, axisMax > 0 else {
            if samples.count == 1 {
                let value = samples[0].value ?? 0
                let y = size.height * (1 - min(value / max(axisMax, 1), 1))
                return [CGPoint(x: 0, y: y)]
            }
            return []
        }
        return samples.enumerated().map { index, sample in
            let x = size.width * Double(index) / Double(samples.count - 1)
            let value = sample.value ?? 0
            let y = size.height * (1 - min(value / axisMax, 1))
            return CGPoint(x: x, y: y)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter GraphGeometryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitUI/GraphGeometry.swift Tests/AmbitUITests/GraphGeometryTests.swift
git commit -m "P1: harvest generic GraphGeometry from pingscope LatencyGraph"
```

---

### Task 8: Theme + simple cards (StatusRow, StatusBanner, Progress, Gauge)

**Files:**
- Create: `Sources/AmbitUI/Theme.swift`
- Create: `Sources/AmbitUI/Cards/StatusRowCard.swift`
- Create: `Sources/AmbitUI/Cards/StatusBannerCard.swift`
- Create: `Sources/AmbitUI/Cards/ProgressCard.swift`
- Create: `Sources/AmbitUI/Cards/GaugeCard.swift`
- Test: `Tests/AmbitUITests/ThemeTests.swift`

**Interfaces:**
- Consumes: `DisplayTone`, `EntityReadout` (AmbitCore), `GraphGeometry`.
- Produces:
  - `extension DisplayTone { var color: Color }`
  - `struct StatusRowCard: View` init `(title: String, readout: EntityReadout)`
  - `struct StatusBannerCard: View` init `(title: String, detail: String?, tone: DisplayTone, badge: String?)`
  - `struct ProgressCard: View` init `(title: String, readout: EntityReadout)`
  - `struct GaugeCard: View` init `(title: String, readout: EntityReadout)`

- [ ] **Step 1: Write the failing test (Theme is the unit-testable seam)**

`Tests/AmbitUITests/ThemeTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import AmbitUI
import AmbitCore

final class ThemeTests: XCTestCase {
    func testEveryToneHasAColorMapping() {
        let mapped = [DisplayTone.neutral, .good, .warn, .bad].map { $0.color }
        XCTAssertEqual(mapped.count, 4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ThemeTests`
Expected: FAIL — `DisplayTone.color` undefined.

- [ ] **Step 3: Implement Theme**

`Sources/AmbitUI/Theme.swift`:

```swift
import SwiftUI
import AmbitCore

// Maps the UI-free DisplayTone to concrete colors. The single place tone → color is decided,
// harvested from pingscope's PingScopeColors.tone.
public extension DisplayTone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .warn: return Color(red: 0.90, green: 0.70, blue: 0.29)
        case .bad: return Color(red: 1.0, green: 0.32, blue: 0.28)
        }
    }
}
```

- [ ] **Step 4: Implement the four simple cards**

`Sources/AmbitUI/Cards/StatusRowCard.swift`:

```swift
import SwiftUI
import AmbitCore

/// label + value + health dot. The universal fallback card for any entity.
public struct StatusRowCard: View {
    let title: String
    let readout: EntityReadout
    public init(title: String, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        HStack(spacing: 8) {
            Circle().fill(readout.tone.color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(readout.text).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(readout.tone == .neutral ? Color.primary : readout.tone.color)
        }
        .padding(.vertical, 4)
    }
}
```

`Sources/AmbitUI/Cards/StatusBannerCard.swift` (harvested from the pingscope diagnosis banner):

```swift
import SwiftUI
import AmbitCore

/// A top-level summary message bound to a summary "status" entity (P2 binds pingscope's
/// diagnosis to this). Generic — no provider-specific model.
public struct StatusBannerCard: View {
    let title: String
    let detail: String?
    let tone: DisplayTone
    let badge: String?
    public init(title: String, detail: String? = nil, tone: DisplayTone = .warn, badge: String? = nil) {
        self.title = title
        self.detail = detail
        self.tone = tone
        self.badge = badge
    }
    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(tone.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
    }
}
```

`Sources/AmbitUI/Cards/ProgressCard.swift`:

```swift
import SwiftUI
import AmbitCore

/// A bounded value as a linear bar (battery, percent).
public struct ProgressCard: View {
    let title: String
    let readout: EntityReadout
    public init(title: String, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(readout.text).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            ProgressView(value: readout.fraction ?? 0)
                .tint(readout.tone.color)
        }
        .padding(.vertical, 4)
    }
}
```

`Sources/AmbitUI/Cards/GaugeCard.swift`:

```swift
import SwiftUI
import AmbitCore

/// A bounded value as a ring/donut. Uses SwiftUI Gauge on macOS 13.
public struct GaugeCard: View {
    let title: String
    let readout: EntityReadout
    public init(title: String, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        VStack(spacing: 6) {
            Gauge(value: readout.fraction ?? 0) {
                EmptyView()
            } currentValueLabel: {
                Text(readout.text).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(readout.tone.color)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test --filter ThemeTests`
Expected: builds; `ThemeTests` passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitUI/Theme.swift Sources/AmbitUI/Cards Tests/AmbitUITests/ThemeTests.swift
git commit -m "P1: add theme + StatusRow/StatusBanner/Progress/Gauge cards"
```

---

### Task 9: Graph + table cards (HistoryGraph, DualLineGraph, StatTable)

**Files:**
- Create: `Sources/AmbitUI/Cards/HistoryGraphCard.swift`
- Create: `Sources/AmbitUI/Cards/DualLineGraphCard.swift`
- Create: `Sources/AmbitUI/Cards/StatTableCard.swift`

**Interfaces:**
- Consumes: `Sample`, `SampleStats` (AmbitCore), `GraphGeometry`, `GraphRange`.
- Produces:
  - `struct GraphLine: Identifiable { var id: String; var color: Color; var samples: [Sample] }`
  - `struct HistoryGraphCard: View` init `(title: String, lines: [GraphLine], axisMax: Double? = nil, showLegend: Bool = false)`
  - `struct DualLineGraphCard: View` init `(title: String, lines: [GraphLine])` (two lines; reuses the line renderer)
  - `struct StatTableCard.Row: Identifiable { var id: String; var label: String; var value: String }`
  - `struct StatTableCard: View` init `(title: String?, rows: [StatTableCard.Row])`

> These views render only when handed data; their geometry is covered by `GraphGeometryTests`.
> No new unit test is added here (SwiftUI bodies are validated by `swift build`); the harvested
> math is already under test.

- [ ] **Step 1: Implement the line renderer + HistoryGraphCard**

`Sources/AmbitUI/Cards/HistoryGraphCard.swift`:

```swift
import SwiftUI
import AmbitCore

public struct GraphLine: Identifiable, Equatable {
    public var id: String
    public var color: Color
    public var samples: [Sample]
    public init(id: String, color: Color, samples: [Sample]) {
        self.id = id
        self.color = color
        self.samples = samples
    }
}

/// Sparkline / multi-line history graph. Generic replacement for pingscope's LatencyGraph;
/// all geometry comes from GraphGeometry so this view is a thin Canvas wrapper.
public struct HistoryGraphCard: View {
    let title: String
    let lines: [GraphLine]
    let axisMax: Double
    let showLegend: Bool

    public init(title: String, lines: [GraphLine], axisMax: Double? = nil, showLegend: Bool = false) {
        self.title = title
        self.lines = lines
        self.axisMax = axisMax ?? GraphGeometry.niceMax(lines.flatMap { $0.samples.compactMap(\.value) })
        self.showLegend = showLegend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(axisMax))ms").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                for fraction in [0.0, 0.5, 1.0] {
                    let y = size.height * (1 - fraction)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)
                }
                for line in lines where line.samples.count > 1 {
                    let pts = GraphGeometry.points(samples: line.samples, in: size, axisMax: axisMax)
                    var path = Path()
                    for (index, point) in pts.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(line.color), lineWidth: 1.5)
                }
            }
            .frame(height: 130)
            if showLegend {
                HStack(spacing: 12) {
                    ForEach(lines) { line in
                        HStack(spacing: 5) {
                            Circle().fill(line.color).frame(width: 8, height: 8)
                            Text(line.id).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Implement DualLineGraphCard (up/down, user/system)**

`Sources/AmbitUI/Cards/DualLineGraphCard.swift`:

```swift
import SwiftUI
import AmbitCore

/// Two related series (up/down throughput, user/system %). Thin specialization of the
/// history graph that always shows a legend for the two lines.
public struct DualLineGraphCard: View {
    let title: String
    let lines: [GraphLine]
    public init(title: String, lines: [GraphLine]) {
        self.title = title
        self.lines = Array(lines.prefix(2))
    }
    public var body: some View {
        HistoryGraphCard(title: title, lines: lines, showLegend: true)
    }
}
```

- [ ] **Step 3: Implement StatTableCard (stats grid + process/disk rows)**

`Sources/AmbitUI/Cards/StatTableCard.swift`:

```swift
import SwiftUI

/// Rows of label/value (pingscope's TX/RX/Loss/Min/Avg/Max grid; later process & disk lists).
/// The tabular *binding* (how a group of entities maps to rows/columns) is settled in P6; this
/// view just renders the rows it is handed.
public struct StatTableCard: View {
    public struct Row: Identifiable, Equatable {
        public var id: String
        public var label: String
        public var value: String
        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }
    let title: String?
    let rows: [Row]
    public init(title: String? = nil, rows: [Row]) {
        self.title = title
        self.rows = rows
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.vertical, 4)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text(row.label).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value).font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(index.isMultiple(of: 2) ? Color.clear : Color(white: 0.11))
            }
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build && swift test`
Expected: builds; all tests still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitUI/Cards
git commit -m "P1: add HistoryGraph/DualLineGraph/StatTable cards"
```

---

### Task 10: Control, InstanceSelector, Section cards

**Files:**
- Create: `Sources/AmbitUI/Cards/ControlCard.swift`
- Create: `Sources/AmbitUI/Cards/InstanceSelectorCard.swift`
- Create: `Sources/AmbitUI/Cards/SectionCard.swift`

**Interfaces:**
- Consumes: `EntityDescriptor`, `EntityState`, `EntityKind`, `EntityOption`, `EntityValue` (AmbitCore).
- Produces:
  - `struct ControlCard: View` init `(descriptor: EntityDescriptor, state: EntityState?, onToggle: @escaping (Bool) -> Void, onSelect: @escaping (String) -> Void, onButton: @escaping () -> Void, onNumber: @escaping (Double) -> Void)`
  - `struct InstanceSelectorCard.Option: Identifiable { var id: String; var label: String }`
  - `struct InstanceSelectorCard: View` init `(options: [Option], selectedID: String?, onSelect: @escaping (String?) -> Void, allLabel: String)`
  - `struct SectionCard<Content: View>: View` init `(title: String?, @ViewBuilder content: () -> Content)`

- [ ] **Step 1: Implement ControlCard**

`Sources/AmbitUI/Cards/ControlCard.swift`:

```swift
import SwiftUI
import AmbitCore

/// toggle / select / number / button, chosen from the entity's kind. Commands are dispatched
/// by the host through the supplied closures (the host owns the Engine).
public struct ControlCard: View {
    let descriptor: EntityDescriptor
    let state: EntityState?
    let onToggle: (Bool) -> Void
    let onSelect: (String) -> Void
    let onButton: () -> Void
    let onNumber: (Double) -> Void

    public init(descriptor: EntityDescriptor, state: EntityState?,
                onToggle: @escaping (Bool) -> Void = { _ in },
                onSelect: @escaping (String) -> Void = { _ in },
                onButton: @escaping () -> Void = {},
                onNumber: @escaping (Double) -> Void = { _ in }) {
        self.descriptor = descriptor
        self.state = state
        self.onToggle = onToggle
        self.onSelect = onSelect
        self.onButton = onButton
        self.onNumber = onNumber
    }

    private var boolValue: Bool {
        if case .bool(let b)? = state?.value { return b }
        return false
    }
    private var textValue: String {
        if case .text(let s)? = state?.value { return s }
        return ""
    }
    private var numberValue: Double {
        if case .number(let n)? = state?.value { return n }
        return descriptor.range?.min ?? 0
    }

    public var body: some View {
        HStack {
            Text(descriptor.name).font(.system(size: 13))
            Spacer()
            switch descriptor.kind {
            case .toggle:
                Toggle("", isOn: Binding(get: { boolValue }, set: onToggle)).labelsHidden()
            case .select:
                Picker("", selection: Binding(get: { textValue }, set: onSelect)) {
                    ForEach(descriptor.options ?? [], id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden().fixedSize()
            case .number:
                Stepper(value: Binding(get: { numberValue }, set: onNumber),
                        in: (descriptor.range?.min ?? 0)...(descriptor.range?.max ?? 100),
                        step: descriptor.range?.step ?? 1) {
                    Text(String(Int(numberValue))).font(.system(.body, design: .monospaced))
                }
                .fixedSize()
            case .button:
                Button(descriptor.name, action: onButton)
            case .sensor, .binarySensor, .text:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Implement InstanceSelectorCard (harvested host menu)**

`Sources/AmbitUI/Cards/InstanceSelectorCard.swift`:

```swift
import SwiftUI

/// Switch among a multi-instance integration's instances (pingscope hosts). `selectedID == nil`
/// means the aggregate "all" view. Harvested from the pingscope host Menu.
public struct InstanceSelectorCard: View {
    public struct Option: Identifiable, Equatable {
        public var id: String
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    let options: [Option]
    let selectedID: String?
    let onSelect: (String?) -> Void
    let allLabel: String

    public init(options: [Option], selectedID: String?, onSelect: @escaping (String?) -> Void, allLabel: String = "All") {
        self.options = options
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.allLabel = allLabel
    }

    private var currentLabel: String {
        guard let selectedID, let match = options.first(where: { $0.id == selectedID }) else { return allLabel }
        return match.label
    }

    public var body: some View {
        Menu {
            Button(allLabel) { onSelect(nil) }
            Divider()
            ForEach(options) { option in
                Button(option.label) { onSelect(option.id) }
            }
        } label: {
            Text(currentLabel).font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
```

- [ ] **Step 3: Implement SectionCard**

`Sources/AmbitUI/Cards/SectionCard.swift`:

```swift
import SwiftUI

/// A titled group of cards (capability- or category-grouped).
public struct SectionCard<Content: View>: View {
    let title: String?
    let content: Content
    public init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build && swift test`
Expected: builds; tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitUI/Cards
git commit -m "P1: add Control/InstanceSelector/Section cards"
```

---

### Task 11: `SurfaceView` dispatcher

**Files:**
- Create: `Sources/AmbitUI/SurfaceView.swift`
- Test: `Tests/AmbitUITests/SurfaceDataTests.swift`

**Interfaces:**
- Consumes: `SurfacePlan`, `CardSpec`, `CardKind`, `EntityDescriptor`, `EntityState`, `EntityReadout`, `Sample`, all cards above.
- Produces:
  - `struct SurfaceData { var descriptors: [EntityID: EntityDescriptor]; var states: [EntityID: EntityState]; var series: [EntityID: [Sample]]; func readout(_ id: EntityID) -> EntityReadout; init(...) }`
  - `struct CardView: View` init `(spec: CardSpec, data: SurfaceData)`
  - `struct SurfaceView: View` init `(plan: SurfacePlan, data: SurfaceData)`

- [ ] **Step 1: Write the failing test (SurfaceData lookup is the testable seam)**

`Tests/AmbitUITests/SurfaceDataTests.swift`:

```swift
import XCTest
@testable import AmbitUI
import AmbitCore

final class SurfaceDataTests: XCTestCase {
    func testReadoutResolvesDescriptorAndState() {
        let descriptor = EntityDescriptor(id: "i/p.lat", instanceID: "i/p", name: "Latency", kind: .sensor, deviceClass: .latency)
        let data = SurfaceData(
            descriptors: ["i/p.lat": descriptor],
            states: ["i/p.lat": EntityState(id: "i/p.lat", value: .number(12), availability: .online)],
            series: [:]
        )
        XCTAssertEqual(data.readout("i/p.lat").text, "12ms")
    }

    func testReadoutForUnknownEntityIsDash() {
        let data = SurfaceData(descriptors: [:], states: [:], series: [:])
        XCTAssertEqual(data.readout("missing").text, "—")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SurfaceDataTests`
Expected: FAIL — `SurfaceData` undefined.

- [ ] **Step 3: Implement `SurfaceData`, `CardView`, `SurfaceView`**

`Sources/AmbitUI/SurfaceView.swift`:

```swift
import SwiftUI
import AmbitCore

// The value side of the layout/value split: a snapshot of descriptors + live states + history
// the cards read from. Wiring to the live Engine/HistoryService happens when a surface host
// adopts AmbitUI (P2+); P1 hands it pre-resolved data, which keeps the views testable.
public struct SurfaceData {
    public var descriptors: [EntityID: EntityDescriptor]
    public var states: [EntityID: EntityState]
    public var series: [EntityID: [Sample]]

    public init(descriptors: [EntityID: EntityDescriptor] = [:],
                states: [EntityID: EntityState] = [:],
                series: [EntityID: [Sample]] = [:]) {
        self.descriptors = descriptors
        self.states = states
        self.series = series
    }

    public func readout(_ id: EntityID) -> EntityReadout {
        guard let descriptor = descriptors[id] else { return EntityReadout(text: "—", tone: .neutral) }
        return EntityReadout.make(descriptor: descriptor, state: states[id])
    }

    public func title(_ id: EntityID) -> String { descriptors[id]?.name ?? id.rawValue }
    public func samples(_ id: EntityID) -> [Sample] { series[id] ?? [] }
}

/// Renders one CardSpec by dispatching on its kind. Unknown/compound kinds with no single-entity
/// binding fall back to the generic status row.
public struct CardView: View {
    let spec: CardSpec
    let data: SurfaceData
    public init(spec: CardSpec, data: SurfaceData) {
        self.spec = spec
        self.data = data
    }

    private var primaryID: EntityID? { spec.entities.first }

    public var body: some View {
        switch spec.kind {
        case .section:
            SectionCard(title: spec.title) {
                ForEach(spec.children) { child in
                    CardView(spec: child, data: data)
                }
            }
        case .statusRow:
            if let id = primaryID { StatusRowCard(title: data.title(id), readout: data.readout(id)) }
        case .gauge:
            if let id = primaryID { GaugeCard(title: data.title(id), readout: data.readout(id)) }
        case .progress:
            if let id = primaryID { ProgressCard(title: data.title(id), readout: data.readout(id)) }
        case .historyGraph:
            if let id = primaryID {
                HistoryGraphCard(title: data.title(id),
                                 lines: [GraphLine(id: data.title(id), color: DisplayTone.good.color, samples: data.samples(id))])
            }
        case .dualLineGraph:
            DualLineGraphCard(title: spec.title ?? "",
                              lines: spec.entities.map { GraphLine(id: data.title($0), color: DisplayTone.good.color, samples: data.samples($0)) })
        case .control:
            if let id = primaryID, let descriptor = data.descriptors[id] {
                ControlCard(descriptor: descriptor, state: data.states[id])
            }
        case .statTable:
            StatTableCard(title: spec.title,
                          rows: spec.entities.map { StatTableCard.Row(id: $0.rawValue, label: data.title($0), value: data.readout($0).text) })
        case .statusBanner:
            if let id = primaryID {
                let r = data.readout(id)
                StatusBannerCard(title: data.title(id), detail: r.text, tone: r.tone)
            }
        case .instanceSelector:
            EmptyView()  // bound by the host (needs selection state + action); wired in P3 chrome.
        }
    }
}

/// Renders a full SurfacePlan top to bottom.
public struct SurfaceView: View {
    let plan: SurfacePlan
    let data: SurfaceData
    public init(plan: SurfacePlan, data: SurfaceData) {
        self.plan = plan
        self.data = data
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.cards) { card in
                CardView(spec: card, data: data)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SurfaceDataTests && swift build`
Expected: PASS; builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitUI/SurfaceView.swift Tests/AmbitUITests/SurfaceDataTests.swift
git commit -m "P1: add SurfaceView/CardView dispatcher"
```

---

### Task 12: `HistoryGraphLoader` — read `HistoryService` into a graph

**Files:**
- Create: `Sources/AmbitUI/HistoryGraphLoader.swift`
- Test: `Tests/AmbitUITests/HistoryGraphLoaderTests.swift`

**Interfaces:**
- Consumes: `HistoryService`, `Sample`, `EntityID`, `GraphRange` (AmbitCore).
- Produces:
  - `enum HistoryGraphLoader { static func samples(for id: EntityID, range: GraphRange, from history: HistoryService, now: Date) async -> [Sample] }`

> This is the seam that satisfies "the history graph reads HistoryService" without wiring the
> menu bar: a host calls this to fill a `SurfaceData.series` entry; the View stays dumb.

- [ ] **Step 1: Write the failing test**

`Tests/AmbitUITests/HistoryGraphLoaderTests.swift`:

```swift
import XCTest
@testable import AmbitUI
import AmbitCore

final class HistoryGraphLoaderTests: XCTestCase {
    func testLoadsSamplesWithinTheRangeWindow() async {
        let history = HistoryService()
        let id: EntityID = "i/p.lat"
        let now = Date(timeIntervalSince1970: 10_000)
        await history.record(Sample(timestamp: now.addingTimeInterval(-30), value: 10), for: id)   // inside 1m
        await history.record(Sample(timestamp: now.addingTimeInterval(-120), value: 99), for: id)  // outside 1m

        let recent = await HistoryGraphLoader.samples(for: id, range: .m1, from: history, now: now)
        XCTAssertEqual(recent.map(\.value), [10])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryGraphLoaderTests`
Expected: FAIL — `HistoryGraphLoader` undefined.

- [ ] **Step 3: Implement `HistoryGraphLoader`**

`Sources/AmbitUI/HistoryGraphLoader.swift`:

```swift
import Foundation
import AmbitCore

// Bridges the shared HistoryService to a graph card: given an entity + range, return the
// sample window the View plots. Keeps HistoryService access in one tested place.
public enum HistoryGraphLoader {
    public static func samples(for id: EntityID, range: GraphRange, from history: HistoryService, now: Date = Date()) async -> [Sample] {
        await history.samples(id, since: now.addingTimeInterval(-range.seconds))
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter HistoryGraphLoaderTests`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift build && swift test`
Expected: entire package builds; all tests green.

```bash
git add Sources/AmbitUI/HistoryGraphLoader.swift Tests/AmbitUITests/HistoryGraphLoaderTests.swift
git commit -m "P1: add HistoryGraphLoader reading HistoryService"
```

---

## Self-review

**Spec coverage (P1 section of the design + the four refinements):**
- New `AmbitUI` target → Task 1. ✓
- `CardKind`/`CardSpec`/`SurfacePlan`/`GraphStyle`/`CardRole` → Tasks 3. ✓
- `SurfaceComposer` (entity-driven) → Task 6. ✓
- Descriptor presentation-default fields (brought forward to P1) → Task 2. ✓
- Graph-range question settled → Task 2 (decision documented at top; `GraphRange` + `defaultGraphRange` + plumbed in Tasks 6/9/11/12). ✓
- One SwiftUI view per card kind harvested from pingscope M5 → Tasks 8–10 (statusRow, gauge, historyGraph, dualLineGraph, progress, statTable, control, instanceSelector, section, statusBanner). ✓
- History graph reads `HistoryService` → Task 12. ✓
- Test retirement + ported coverage → Task 6 (grouping → SurfaceComposerTests; formatting → EntityReadoutTests) then delete. ✓
- Menubar untouched → no task modifies `AmbitMenuBar`. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code.

**Type consistency:** `EntityReadout.make(descriptor:state:)`, `SurfaceComposer.detailPlan(descriptors:states:config:)`, `GraphGeometry.niceMax/points`, `SurfaceData.readout/title/samples`, `HistoryGraphLoader.samples(for:range:from:now:)`, `CardSpec(id:kind:title:entities:graphStyle:graphRange:children:role:)` are used consistently across producing and consuming tasks. `GraphStyle.none` is referenced as `GraphStyle.none` in tests to disambiguate from `Optional.none`.

**Note for executor:** SwiftUI card *bodies* are validated by `swift build`, not unit tests; the risky pure logic (geometry, formatting, composition, lookup, history windowing) is all under XCTest.
