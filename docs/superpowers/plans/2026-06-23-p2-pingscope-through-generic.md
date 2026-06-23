# P2 — Pingscope Through Generic Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render pingscope's popover / overlay / settings entirely through the generic AmbitUI card vocabulary driven by `SurfaceComposer`, and delete the bespoke UI — the P2 eyeball checkpoint.

**Architecture:** Two entry tasks fix genericity bugs in the existing primitives (unit-generic graph axis; `graphRange` gating). The middle tasks grow the generic vocabulary (multi-line history graph, windowed summary readouts, a `Severity` field on `EntityState`, a Core diagnosis→entity synthesizer, public Engine entity accessors). The final tasks rewire the menu-bar host to build `SurfaceData`/`SurfacePlan` and render through `SurfaceView`, deleting the bespoke Canvas graph / stats grid / recent-samples table / diagnosis banner.

**Tech Stack:** Swift 5.9+, SwiftPM, XCTest, SwiftUI (macOS 13+), AppKit (status item / NSPanel).

## Global Constraints

- `swift build` AND `swift test` green after EVERY task; one small commit per task.
- Never edit `~/src/pingscope` or `~/src/glinet-travel`.
- No `EngineID` in any entity/instance id (the synthetic diagnosis id included).
- `AmbitCore` imports no SwiftUI/AppKit. `AmbitUI` is the only place tone→color / view code lives.
- No new pingscope-specific UI. A missing capability is a missing *primitive*, added to the generic vocabulary — never a pingscope special-case.
- Deleting tests for intentionally-removed bespoke UI is allowed; do not weaken tests for code that stays.
- Verb for running one test: `swift test --filter <TestClass>/<testMethod>`. Full suite: `swift test`.

---

### Task 1: Unit-generic history graph (P2-1)

Fix `GraphGeometry.niceMax`'s latency-only ladder so non-latency series scale correctly, and thread the entity's `deviceClass`/`unit` into `HistoryGraphCard` so the axis label reads the right unit (no more "12000000ms"). Covers the carried T9 unit note.

**Files:**
- Modify: `Sources/AmbitUI/GraphGeometry.swift:9-16`
- Modify: `Sources/AmbitCore/Presentation/EntityReadout.swift:46-58`
- Modify: `Sources/AmbitUI/Cards/HistoryGraphCard.swift:17-38`
- Modify: `Sources/AmbitUI/SurfaceView.swift:55-59`
- Test: `Tests/AmbitUITests/GraphGeometryTests.swift`
- Test: `Tests/AmbitCoreTests/EntityReadoutTests.swift`

**Interfaces:**
- Produces: `GraphGeometry.niceMax(_ values: [Double]) -> Double` (scale-invariant; same signature).
- Produces: `EntityReadout.format(_ value: Double, deviceClass: DeviceClass?, unit: String?) -> String` (public; used by graph axis + summary readouts).
- Produces: `HistoryGraphCard(title: String, lines: [GraphLine], deviceClass: DeviceClass? = nil, unit: String? = nil, axisMax: Double? = nil, showLegend: Bool = false)`.

- [ ] **Step 1: Write the failing niceMax tests (non-latency scale)**

Add to `Tests/AmbitUITests/GraphGeometryTests.swift` inside the class:

```swift
func testNiceMaxScalesToThroughputMagnitude() {
    // 12 Mbps worth of bits/sec must not fall through to a latency-shaped ceiling.
    XCTAssertEqual(GraphGeometry.niceMax([12_000_000]), 15_000_000)
    XCTAssertEqual(GraphGeometry.niceMax([3]), 3)
    XCTAssertEqual(GraphGeometry.niceMax([45]), 50)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GraphGeometryTests/testNiceMaxScalesToThroughputMagnitude`
Expected: FAIL (current ladder returns 12_000_000-rounded value / 50 for `[3]`).

- [ ] **Step 3: Replace the ladder with a scale-invariant mantissa ceiling**

In `Sources/AmbitUI/GraphGeometry.swift` replace lines 9-16 (the `ladder` constant and `niceMax`) with:

```swift
    // Scale-invariant "nice" ceiling: a mantissa rung × the data's order of magnitude. Works
    // for any unit (ms, bps, %, °C) — replaces the latency-only rung ladder.
    private static let mantissas: [Double] = [1, 1.5, 2, 2.5, 3, 5, 7.5, 10]

    /// Smallest "nice" ceiling at or above the max value; 100 when there is no positive data.
    public static func niceMax(_ values: [Double]) -> Double {
        guard let maxValue = values.max(), maxValue > 0 else { return 100 }
        let exponent = (log10(maxValue)).rounded(.down)
        let base = pow(10, exponent)
        for mantissa in mantissas where mantissa * base >= maxValue {
            return mantissa * base
        }
        return 10 * base
    }
```

(`log10`/`pow` come from `Foundation`, already imported.)

- [ ] **Step 4: Run niceMax tests (new + existing) to verify pass**

Run: `swift test --filter GraphGeometryTests`
Expected: PASS — including the existing `testNiceMaxRoundsUpToCleanCeiling` (`[42,120]→150`, `[600]→750`, `[]→100`, `[0]→100`), which the mantissa ladder reproduces.

- [ ] **Step 5: Write the failing formatter test**

Add to `Tests/AmbitCoreTests/EntityReadoutTests.swift` inside the class:

```swift
func testPublicFormatterIsUnitGeneric() {
    XCTAssertEqual(EntityReadout.format(150, deviceClass: .latency, unit: "ms"), "150ms")
    XCTAssertEqual(EntityReadout.format(15_000_000, deviceClass: .throughput, unit: "bps"), "15.0 Mbps")
}
```

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter EntityReadoutTests/testPublicFormatterIsUnitGeneric`
Expected: FAIL with "type 'EntityReadout' has no member 'format'" (the existing `format` is private and takes a descriptor).

- [ ] **Step 7: Extract a public formatter**

In `Sources/AmbitCore/Presentation/EntityReadout.swift` replace the private `format(_:descriptor:)` (lines 46-58) with a public deviceClass/unit overload plus a thin descriptor shim:

```swift
    public static func format(_ n: Double, deviceClass: DeviceClass?, unit: String?) -> String {
        switch deviceClass {
        case .latency: return "\(Int(n.rounded()))ms"
        case .percent, .battery: return "\(Int(n.rounded()))%"
        case .throughput: return formatThroughput(bitsPerSecond: n)
        case .count: return "\(Int(n.rounded()))"
        case .duration: return "\(Int(n.rounded()))s"
        case .power: return "\(Int(n.rounded()))W"
        case .connectivity, .none:
            if let unit { return "\(trim(n)) \(unit)" }
            return trim(n)
        }
    }

    private static func format(_ n: Double, descriptor: EntityDescriptor) -> String {
        format(n, deviceClass: descriptor.deviceClass, unit: descriptor.unit)
    }
```

- [ ] **Step 8: Run formatter + existing readout tests**

Run: `swift test --filter EntityReadoutTests`
Expected: PASS (the descriptor shim keeps all existing assertions green).

- [ ] **Step 9: Thread deviceClass/unit into HistoryGraphCard**

In `Sources/AmbitUI/Cards/HistoryGraphCard.swift` change the stored props + init (lines 20-30) and the axis-label `Text` (line 37):

Replace `let unit: String` (line 21) with:
```swift
    let deviceClass: DeviceClass?
    let unit: String?
```

Replace the init (lines 24-30) with:
```swift
    public init(title: String, lines: [GraphLine], deviceClass: DeviceClass? = nil, unit: String? = nil, axisMax: Double? = nil, showLegend: Bool = false) {
        self.title = title
        self.lines = lines
        self.axisMax = axisMax ?? GraphGeometry.niceMax(lines.flatMap { $0.samples.compactMap(\.value) })
        self.showLegend = showLegend
        self.deviceClass = deviceClass
        self.unit = unit
    }
```

Replace the axis-label `Text` (line 37) with:
```swift
                Text(EntityReadout.format(axisMax, deviceClass: deviceClass, unit: unit)).font(.system(size: 10.5)).foregroundStyle(.secondary)
```

- [ ] **Step 10: Pass the descriptor's deviceClass/unit from CardView**

In `Sources/AmbitUI/SurfaceView.swift` replace the `.historyGraph` case (lines 55-59) with:
```swift
        case .historyGraph:
            if let id = primaryID {
                let descriptor = data.descriptors[id]
                HistoryGraphCard(title: data.title(id),
                                 lines: [GraphLine(id: data.title(id), color: DisplayTone.good.color, samples: data.samples(id))],
                                 deviceClass: descriptor?.deviceClass,
                                 unit: descriptor?.unit)
            }
```

- [ ] **Step 11: Build + full test run**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass (DualLineGraphCard still compiles — it omits `deviceClass`/`unit`, which now default to `nil`).

- [ ] **Step 12: Commit**

```bash
git add Sources/AmbitUI/GraphGeometry.swift Sources/AmbitCore/Presentation/EntityReadout.swift Sources/AmbitUI/Cards/HistoryGraphCard.swift Sources/AmbitUI/SurfaceView.swift Tests/AmbitUITests/GraphGeometryTests.swift Tests/AmbitCoreTests/EntityReadoutTests.swift
git commit -m "P2-1: unit-generic history graph (niceMax ladder + axis label)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Gate graphRange to history graphs (P2-2) + doc fix

`SurfaceComposer` attaches `graphRange` to gauge/progress cards too; gate it to `.historyGraph`. Also correct the stale P1 plan-doc rule-#3 prose.

**Files:**
- Modify: `Sources/AmbitCore/Presentation/SurfaceComposer.swift:77-79`
- Modify: `docs/superpowers/plans/2026-06-23-p1-card-vocabulary.md`
- Test: `Tests/AmbitCoreTests/SurfaceComposerTests.swift`

**Interfaces:**
- Consumes: `SurfaceComposer.detailPlan(descriptors:states:config:)` (unchanged signature).
- Produces: `CardSpec.graphRange` is non-nil only when `kind == .historyGraph`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AmbitCoreTests/SurfaceComposerTests.swift` inside the class:

```swift
func testGraphRangeOnlyOnHistoryGraph() {
    let descriptors = [
        sensor("g", .percent, graphStyle: .gauge),
        sensor("p", .battery, graphStyle: .progress),
        sensor("s", .latency, graphStyle: .sparkline)
    ]
    let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
    let byID = plan.cards.flatMap { $0.children }.reduce(into: [String: CardSpec]()) { $0[$1.entities.first!.rawValue] = $1 }
    XCTAssertNil(byID["i/p.g"]?.graphRange)
    XCTAssertNil(byID["i/p.p"]?.graphRange)
    XCTAssertEqual(byID["i/p.s"]?.graphRange, .m5)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SurfaceComposerTests/testGraphRangeOnlyOnHistoryGraph`
Expected: FAIL (gauge/progress currently carry `.m5`).

- [ ] **Step 3: Gate the range**

In `Sources/AmbitCore/Presentation/SurfaceComposer.swift` replace lines 77-79 with:
```swift
        let range: GraphRange? = (kind == .historyGraph)
            ? (config.entityOverrides[d.id]?.graphRange ?? d.defaultGraphRange ?? .m5)
            : nil
```

- [ ] **Step 4: Run SurfaceComposer tests**

Run: `swift test --filter SurfaceComposerTests`
Expected: PASS (including the existing `testUnsetGraphStyleMeasurementBecomesHistoryGraph`, which asserts `.m5` on a history graph).

- [ ] **Step 5: Fix the P1 plan-doc rule-#3 prose**

In `docs/superpowers/plans/2026-06-23-p1-card-vocabulary.md`, find the Task 6 ordering rule that describes the tie-break (it reads "… then name"). Correct it to the shipped contract: ordering is `isPrimary` → `priority` descending → **stable insertion order** (the name tie-breaker was dropped). Run `grep -n "then name\|insertion order\|rule 3\|rule #3" docs/superpowers/plans/2026-06-23-p1-card-vocabulary.md` to locate it; edit the prose so it matches `SurfaceComposer.ordering` (`Sources/AmbitCore/Presentation/SurfaceComposer.swift:64-71`).

- [ ] **Step 6: Build + full test run**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add Sources/AmbitCore/Presentation/SurfaceComposer.swift Tests/AmbitCoreTests/SurfaceComposerTests.swift docs/superpowers/plans/2026-06-23-p1-card-vocabulary.md
git commit -m "P2-2: gate graphRange to historyGraph; fix P1 plan rule-#3 prose

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Multi-series history graph (the multi-host overlay, made generic)

Teach `CardView.historyGraph` to bind ALL `spec.entities` as lines, add a generic line-color palette, and teach `SurfaceComposer` to collapse multiple same-`deviceClass` measurement entities into one multi-line `historyGraph` card.

**Files:**
- Modify: `Sources/AmbitUI/Theme.swift`
- Modify: `Sources/AmbitUI/SurfaceView.swift:55-62` (the `.historyGraph` case from Task 1)
- Modify: `Sources/AmbitUI/Cards/HistoryGraphCard.swift:32-35` (hide empty title)
- Modify: `Sources/AmbitCore/Presentation/SurfaceComposer.swift:39-46` (use a collapsing card builder)
- Test: `Tests/AmbitCoreTests/SurfaceComposerTests.swift`

**Interfaces:**
- Consumes: `EntityReadout.format`, `GraphGeometry.niceMax`.
- Produces: `Theme.lineColor(_ index: Int) -> Color`.
- Produces: a `.historyGraph` `CardSpec` whose `entities` may hold N ids; multi-entity cards have `title == nil`, single-entity keep `title == descriptor.name`.

- [ ] **Step 1: Write the failing composer tests**

Add to `Tests/AmbitCoreTests/SurfaceComposerTests.swift`:

```swift
func testSameClassMeasurementSeriesCombineIntoOneGraph() {
    let descriptors = [
        sensor("lat_a", .latency, stateClass: .measurement),
        sensor("lat_b", .latency, stateClass: .measurement)
    ]
    let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
    let network = plan.cards.first { $0.title == "Network" }
    XCTAssertEqual(network?.children.count, 1)
    XCTAssertEqual(network?.children.first?.kind, .historyGraph)
    XCTAssertEqual(network?.children.first?.entities.map(\.rawValue), ["i/p.lat_a", "i/p.lat_b"])
    XCTAssertNil(network?.children.first?.title)
}

func testSingleMeasurementSeriesStaysSingleLineWithName() {
    let plan = SurfaceComposer.detailPlan(descriptors: [sensor("lat", .latency, stateClass: .measurement)], states: [:])
    let card = plan.cards.first?.children.first
    XCTAssertEqual(card?.entities.map(\.rawValue), ["i/p.lat"])
    XCTAssertEqual(card?.title, "lat")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SurfaceComposerTests/testSameClassMeasurementSeriesCombineIntoOneGraph`
Expected: FAIL (currently two separate cards, count 2).

- [ ] **Step 3: Add a collapsing card builder to SurfaceComposer**

In `Sources/AmbitCore/Presentation/SurfaceComposer.swift`, replace line 42 (`let children = ordered.map { card(for: $0, config: config) }`) with:
```swift
            let children = cards(for: ordered, config: config)
```

Then add this method to the enum (e.g. just above `private static func card`):
```swift
    /// Build a section's cards, collapsing same-deviceClass/unit measurement history graphs into
    /// one multi-line card (generic: drives the multi-host pingscope graph and P6 cores/disks).
    private static func cards(for ordered: [EntityDescriptor], config: PresentationConfig) -> [CardSpec] {
        var result: [CardSpec] = []
        var combinedIndexByKey: [String: Int] = [:]
        for d in ordered {
            guard cardKind(for: d, config: config) == .historyGraph, d.stateClass == .measurement else {
                result.append(card(for: d, config: config))
                continue
            }
            let key = "\(d.deviceClass?.rawValue ?? "none")|\(d.unit ?? "")"
            if let index = combinedIndexByKey[key] {
                result[index].entities.append(d.id)
                result[index].title = nil   // multi-line: the legend names the series, not a title
            } else {
                combinedIndexByKey[key] = result.count
                result.append(card(for: d, config: config))
            }
        }
        return result
    }
```

- [ ] **Step 4: Run composer tests**

Run: `swift test --filter SurfaceComposerTests`
Expected: PASS (existing `testGroupsEntitiesByClassificationInOrder` still passes — latency vs throughput are different keys, so they stay separate; `online` is a `statusRow`).

- [ ] **Step 5: Add the generic line palette**

In `Sources/AmbitUI/Theme.swift` append (after the `DisplayTone` extension):
```swift
/// Deterministic per-line colors for multi-series graphs (harvested from pingscope's palette).
public enum Theme {
    public static let linePalette: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
        Color(red: 0.20, green: 0.78, blue: 0.35),  // green
        Color(red: 1.00, green: 0.62, blue: 0.26),  // orange
        Color(red: 0.69, green: 0.45, blue: 0.95),  // purple
        Color(red: 0.30, green: 0.78, blue: 0.85)   // teal
    ]
    public static func lineColor(_ index: Int) -> Color { linePalette[index % linePalette.count] }
}
```

- [ ] **Step 6: Bind all entities as lines in CardView**

In `Sources/AmbitUI/SurfaceView.swift` replace the `.historyGraph` case (the version written in Task 1) with:
```swift
        case .historyGraph:
            if !spec.entities.isEmpty {
                let descriptor = spec.entities.first.flatMap { data.descriptors[$0] }
                let lines = spec.entities.enumerated().map { index, id in
                    GraphLine(id: data.title(id), color: Theme.lineColor(index), samples: data.samples(id))
                }
                HistoryGraphCard(title: spec.title ?? "",
                                 lines: lines,
                                 deviceClass: descriptor?.deviceClass,
                                 unit: descriptor?.unit,
                                 showLegend: spec.entities.count > 1)
            }
```

- [ ] **Step 7: Hide the title row when empty**

In `Sources/AmbitUI/Cards/HistoryGraphCard.swift`, in the `HStack` header (lines 34-38), wrap the title `Text` so an empty title renders nothing:
```swift
                if !title.isEmpty {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
```

- [ ] **Step 8: Build + full test run**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 9: Commit**

```bash
git add Sources/AmbitUI/Theme.swift Sources/AmbitUI/SurfaceView.swift Sources/AmbitUI/Cards/HistoryGraphCard.swift Sources/AmbitCore/Presentation/SurfaceComposer.swift Tests/AmbitCoreTests/SurfaceComposerTests.swift
git commit -m "P2: multi-series history graph (composer collapse + multi-line CardView)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Generic windowed summary readouts (Min/Avg/Max)

Render min/avg/max beneath a single-series history graph as generic readouts (decision 4), computed value-side from `SampleStats` and formatted with the Task-1 formatter. Multi-line graphs rely on the legend only.

**Files:**
- Create: `Sources/AmbitUI/GraphSummary.swift`
- Modify: `Sources/AmbitUI/Cards/HistoryGraphCard.swift` (add `summary` param + render row)
- Modify: `Sources/AmbitUI/SurfaceView.swift` (`.historyGraph` case: pass summary only when single-series)
- Test: `Tests/AmbitUITests/GraphSummaryTests.swift`

**Interfaces:**
- Produces: `struct GraphSummaryItem: Equatable { let label: String; let value: String }`.
- Produces: `GraphSummary.minAvgMax(samples: [Sample], deviceClass: DeviceClass?, unit: String?) -> [GraphSummaryItem]` (empty when no valued samples).
- Produces: `HistoryGraphCard(..., summary: [GraphSummaryItem] = [], ...)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AmbitUITests/GraphSummaryTests.swift`:
```swift
import XCTest
@testable import AmbitUI
import AmbitCore

final class GraphSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    func testLatencyMinAvgMaxFormatted() {
        let samples = [Sample(timestamp: now, value: 10), Sample(timestamp: now, value: 20), Sample(timestamp: now, value: 30)]
        let items = GraphSummary.minAvgMax(samples: samples, deviceClass: .latency, unit: "ms")
        XCTAssertEqual(items, [
            GraphSummaryItem(label: "Min", value: "10ms"),
            GraphSummaryItem(label: "Avg", value: "20ms"),
            GraphSummaryItem(label: "Max", value: "30ms")
        ])
    }

    func testThroughputUsesUnitFormatter() {
        let items = GraphSummary.minAvgMax(samples: [Sample(timestamp: now, value: 12_000_000)], deviceClass: .throughput, unit: "bps")
        XCTAssertEqual(items.first?.value, "12.0 Mbps")
    }

    func testNoValuedSamplesIsEmpty() {
        XCTAssertTrue(GraphSummary.minAvgMax(samples: [Sample(timestamp: now, value: nil, ok: false)], deviceClass: .latency, unit: "ms").isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GraphSummaryTests`
Expected: FAIL ("cannot find 'GraphSummary'").

- [ ] **Step 3: Implement GraphSummary**

Create `Sources/AmbitUI/GraphSummary.swift`:
```swift
import Foundation
import AmbitCore

/// One labeled summary value (Min/Avg/Max) for a graph's windowed series.
public struct GraphSummaryItem: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// Value-side windowed summary for a single measurement series — generic, not pingscope-specific.
public enum GraphSummary {
    public static func minAvgMax(samples: [Sample], deviceClass: DeviceClass?, unit: String?) -> [GraphSummaryItem] {
        let stats = SampleStats.from(samples)
        guard let min = stats.min, let avg = stats.avg, let max = stats.max else { return [] }
        func f(_ v: Double) -> String { EntityReadout.format(v, deviceClass: deviceClass, unit: unit) }
        return [
            GraphSummaryItem(label: "Min", value: f(min)),
            GraphSummaryItem(label: "Avg", value: f(avg)),
            GraphSummaryItem(label: "Max", value: f(max))
        ]
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GraphSummaryTests`
Expected: PASS.

- [ ] **Step 5: Render summary in HistoryGraphCard**

In `Sources/AmbitUI/Cards/HistoryGraphCard.swift`:

Add a stored prop next to `showLegend`:
```swift
    let summary: [GraphSummaryItem]
```
Add `summary: [GraphSummaryItem] = []` to the init parameter list (before `axisMax`) and `self.summary = summary` in the body.

After the legend block (the `if showLegend { … }` closing brace, before the final `}` of the `VStack`), add:
```swift
            if !summary.isEmpty {
                HStack(spacing: 18) {
                    ForEach(summary, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(item.value).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
```

- [ ] **Step 6: Pass summary from CardView for single-series only**

In `Sources/AmbitUI/SurfaceView.swift` `.historyGraph` case, compute summary and pass it:
```swift
        case .historyGraph:
            if !spec.entities.isEmpty {
                let descriptor = spec.entities.first.flatMap { data.descriptors[$0] }
                let lines = spec.entities.enumerated().map { index, id in
                    GraphLine(id: data.title(id), color: Theme.lineColor(index), samples: data.samples(id))
                }
                let summary = spec.entities.count == 1
                    ? GraphSummary.minAvgMax(samples: data.samples(spec.entities[0]), deviceClass: descriptor?.deviceClass, unit: descriptor?.unit)
                    : []
                HistoryGraphCard(title: spec.title ?? "",
                                 lines: lines,
                                 deviceClass: descriptor?.deviceClass,
                                 unit: descriptor?.unit,
                                 summary: summary,
                                 showLegend: spec.entities.count > 1)
            }
```

- [ ] **Step 7: Build + full test run**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add Sources/AmbitUI/GraphSummary.swift Sources/AmbitUI/Cards/HistoryGraphCard.swift Sources/AmbitUI/SurfaceView.swift Tests/AmbitUITests/GraphSummaryTests.swift
git commit -m "P2: generic windowed summary readouts (Min/Avg/Max) on single-series graphs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Severity field on EntityState + readout tone mapping

Add the generic `Severity` enum (parent spec §5) and an optional `EntityState.severity` so a status entity can carry a tone independent of availability; `EntityReadout` consults it.

**Files:**
- Modify: `Sources/AmbitCore/Entity.swift` (add `Severity`; add `severity` to `EntityState`)
- Modify: `Sources/AmbitCore/Presentation/EntityReadout.swift` (tone resolution)
- Test: `Tests/AmbitCoreTests/EntityReadoutTests.swift`

**Interfaces:**
- Produces: `enum Severity: Int, Sendable, Codable, Comparable { case normal, elevated, degraded, alerting, down }`.
- Produces: `EntityState(..., severity: Severity? = nil)` with `public var severity: Severity?`.
- Behavior: `EntityReadout.make` uses `severity.displayTone` when `severity >= .elevated`; otherwise availability-based tone.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AmbitCoreTests/EntityReadoutTests.swift`:
```swift
func testSeverityOverridesAvailabilityTone() {
    let d = descriptor(nil, kind: .text)
    let r = EntityReadout.make(descriptor: d, state: EntityState(id: "i/p.e", value: .text("ISP path down"), availability: .online, severity: .down))
    XCTAssertEqual(r.tone, .bad)
    XCTAssertEqual(r.text, "ISP path down")
}

func testElevatedSeverityIsWarn() {
    let d = descriptor(nil, kind: .text)
    let r = EntityReadout.make(descriptor: d, state: EntityState(id: "i/p.e", value: .text("x"), availability: .online, severity: .degraded))
    XCTAssertEqual(r.tone, .warn)
}

func testNormalSeverityFallsBackToAvailability() {
    let r = EntityReadout.make(descriptor: descriptor(.latency), state: EntityState(id: "i/p.e", value: .number(10), availability: .online, severity: .normal))
    XCTAssertEqual(r.tone, .good)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter EntityReadoutTests/testSeverityOverridesAvailabilityTone`
Expected: FAIL ("extra argument 'severity'").

- [ ] **Step 3: Add Severity and the EntityState field**

In `Sources/AmbitCore/Entity.swift`, add the enum after the `Availability` enum (line 105):
```swift
/// Generic state severity (parent spec §5). Ascending rank; UI-free. P4's attention engine reuses it.
public enum Severity: Int, Sendable, Codable, Comparable {
    case normal, elevated, degraded, alerting, down
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}
```

In `EntityState` (lines 83-103) add the stored property after `error` (line 87):
```swift
    public var severity: Severity?
```
Add `severity: Severity? = nil` as the last init parameter (after `error:`), and `self.severity = severity` as the last assignment in the init body.

- [ ] **Step 4: Map severity → tone in EntityReadout**

In `Sources/AmbitCore/Presentation/EntityReadout.swift`, replace line 21 (`let tone = toneFor(availability: state.availability)`) with:
```swift
        let tone = displayTone(for: state)
```

Add these two helpers (next to `toneFor`):
```swift
    private static func displayTone(for state: EntityState) -> DisplayTone {
        if let severity = state.severity, severity >= .elevated { return tone(for: severity) }
        return toneFor(availability: state.availability)
    }

    private static func tone(for severity: Severity) -> DisplayTone {
        switch severity {
        case .normal: return .neutral
        case .elevated, .degraded: return .warn
        case .alerting, .down: return .bad
        }
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter EntityReadoutTests`
Expected: PASS (all existing readout tests unaffected — they pass no `severity`, so availability still drives tone).

- [ ] **Step 6: Build + full test run**

Run: `swift build && swift test`
Expected: green (additive field; all `EntityState` call sites keep compiling).

- [ ] **Step 7: Commit**

```bash
git add Sources/AmbitCore/Entity.swift Sources/AmbitCore/Presentation/EntityReadout.swift Tests/AmbitCoreTests/EntityReadoutTests.swift
git commit -m "P2: add Severity + EntityState.severity; readout tone consults it

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Diagnosis → status entity synthesizer (Core)

Map a `NetworkPerspectiveDiagnosis` to a generic text/status entity carrying severity, so it renders through the `statusBanner` primitive. Verdict→severity mapping is the locked default (catastrophic vs notable).

**Files:**
- Create: `Sources/AmbitCore/PingScope/DiagnosisEntity.swift`
- Test: `Tests/AmbitCoreTests/DiagnosisEntityTests.swift`

**Interfaces:**
- Produces: `enum DiagnosisEntity` with `static let entityID: EntityID` (`"pingscope.summary.diagnosis"`), `static let instanceID: ProviderInstanceID` (`"pingscope.summary"`), and `static func make(_ diagnosis: NetworkPerspectiveDiagnosis) -> (EntityDescriptor, EntityState)?` (nil for `allReachable`/`noData`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AmbitCoreTests/DiagnosisEntityTests.swift`:
```swift
import XCTest
@testable import AmbitCore

final class DiagnosisEntityTests: XCTestCase {
    private func diag(_ scope: NetworkPerspectiveDiagnosis.Scope,
                      _ verdict: NetworkPerspectiveDiagnosis.Verdict,
                      title: String = "T", detail: String = "D") -> NetworkPerspectiveDiagnosis {
        .init(scope: scope, verdict: verdict, confidence: .high, faultTier: nil,
              affectedHostIDs: [], title: title, detail: detail, tierEvidence: [])
    }

    func testHealthyAndNoDataOmitTheBanner() {
        XCTAssertNil(DiagnosisEntity.make(diag(.allReachable, .allReachable)))
        XCTAssertNil(DiagnosisEntity.make(diag(.noData, .noData)))
    }

    func testConnectivityLossIsDown() {
        for verdict in [NetworkPerspectiveDiagnosis.Verdict.localNetworkDown, .ispPathDown, .upstreamDown] {
            let made = DiagnosisEntity.make(diag(.upstream, verdict))
            XCTAssertEqual(made?.1.severity, .down, "\(verdict)")
        }
    }

    func testRemoteServiceIsAlertingAndPartialIsDegraded() {
        XCTAssertEqual(DiagnosisEntity.make(diag(.remoteService, .remoteServiceDown(hostIDs: ["h"])))?.1.severity, .alerting)
        XCTAssertEqual(DiagnosisEntity.make(diag(.partialDegradation, .partialDegradation(tier: .ispEdge)))?.1.severity, .degraded)
    }

    func testEntityCarriesTitleAndDetail() {
        let made = DiagnosisEntity.make(diag(.localNetwork, .localNetworkDown, title: "Local network down", detail: "1/1 gateway host(s) unreachable."))
        XCTAssertEqual(made?.0.id, DiagnosisEntity.entityID)
        XCTAssertEqual(made?.0.name, "Local network down")
        XCTAssertEqual(made?.0.kind, .text)
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.value, .text("1/1 gateway host(s) unreachable."))
        XCTAssertEqual(made?.1.availability, .online)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DiagnosisEntityTests`
Expected: FAIL ("cannot find 'DiagnosisEntity'").

- [ ] **Step 3: Implement the synthesizer**

Create `Sources/AmbitCore/PingScope/DiagnosisEntity.swift`:
```swift
import Foundation

// Maps a cross-host NetworkPerspectiveDiagnosis to a generic text/status entity so it renders
// through the statusBanner primitive (no pingscope-specific UI). The diagnosis is integration-
// level, so the id is a stable synthetic summary id (no EngineID). P3/P4 can promote production
// of this entity into an aggregate / the attention engine.
public enum DiagnosisEntity {
    public static let instanceID = ProviderInstanceID(rawValue: "pingscope.summary")
    public static let entityID = EntityID(rawValue: "pingscope.summary.diagnosis")

    /// nil when the network is healthy / has no data (banner omitted).
    public static func make(_ diagnosis: NetworkPerspectiveDiagnosis) -> (EntityDescriptor, EntityState)? {
        guard let severity = severity(for: diagnosis.verdict) else { return nil }
        let descriptor = EntityDescriptor(
            id: entityID, instanceID: instanceID, name: diagnosis.title,
            kind: .text, deviceClass: nil, category: .diagnostic, access: .read
        )
        let state = EntityState(id: entityID, value: .text(diagnosis.detail), availability: .online, severity: severity)
        return (descriptor, state)
    }

    // Locked P2 default (catastrophic vs notable); only drives banner tone in P2, re-examined at P4.
    static func severity(for verdict: NetworkPerspectiveDiagnosis.Verdict) -> Severity? {
        switch verdict {
        case .allReachable, .noData: return nil
        case .partialDegradation: return .degraded
        case .localNetworkDown, .ispPathDown, .upstreamDown: return .down
        case .remoteServiceDown: return .alerting
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DiagnosisEntityTests`
Expected: PASS.

- [ ] **Step 5: Build + full test run**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/PingScope/DiagnosisEntity.swift Tests/AmbitCoreTests/DiagnosisEntityTests.swift
git commit -m "P2: diagnosis-to-status-entity synthesizer (verdict severity mapping)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Engine entity API (descriptors + projected states)

Expose the cached descriptors and current projected entity states publicly, so the menu-bar host builds `SurfaceData` from the live Engine.

**Files:**
- Modify: `Sources/AmbitCore/Engine.swift` (add two public accessors near `historySamples`, ~line 162)
- Test: `Tests/AmbitCoreTests/EngineEntityAPITests.swift`

**Interfaces:**
- Produces: `Engine.entityDescriptors() -> [ProviderInstanceID: [EntityDescriptor]]` (actor-isolated; call with `await`).
- Produces: `Engine.entityStates() -> [EntityID: EntityState]` (projects the current snapshot via `EntityProjection.states`).

- [ ] **Step 1: Write the failing test**

Create `Tests/AmbitCoreTests/EngineEntityAPITests.swift`:
```swift
import XCTest
@testable import AmbitCore

final class EngineEntityAPITests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingScopeHostConfig) async -> ProbeResult { result }
    }
    private let latencyID = EntityID(rawValue: "pingscope@1.1.1.1:443/probe.latency_ms")
    private let providerInstance = ProviderInstanceID(rawValue: "pingscope@1.1.1.1:443/probe")

    private func engine(latencyMs: Double?) -> Engine {
        let host = PingScopeHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let provider = PingScopeProvider(host: host, integrationInstanceID: host.integrationInstanceID,
                                         probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: latencyMs)))
        return Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
                      providers: [provider], registerBuiltInProviders: false)
    }

    func testExposesDescriptors() async {
        let engine = engine(latencyMs: 20)
        let descriptors = await engine.entityDescriptors()
        XCTAssertTrue(descriptors[providerInstance]?.contains { $0.id == latencyID } ?? false)
    }

    func testExposesProjectedStatesAfterPoll() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()
        let states = await engine.entityStates()
        XCTAssertEqual(states[latencyID]?.value, .number(20))
        XCTAssertEqual(states[latencyID]?.availability, .online)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter EngineEntityAPITests`
Expected: FAIL ("value of type 'Engine' has no member 'entityDescriptors'").

- [ ] **Step 3: Add the accessors**

In `Sources/AmbitCore/Engine.swift`, add immediately after `historySamples`/`historyStats` (around line 169):
```swift
    /// Static entity descriptors per provider instance (cached at assembly time).
    public func entityDescriptors() -> [ProviderInstanceID: [EntityDescriptor]] {
        descriptorsByInstance
    }

    /// Current entity states projected from the latest snapshot (missing metrics → .unavailable).
    public func entityStates() -> [EntityID: EntityState] {
        var result: [EntityID: EntityState] = [:]
        for (instanceID, descriptors) in descriptorsByInstance {
            let providerSnapshot = snapshot.providers[instanceID]?.value
            for (id, state) in EntityProjection.states(snapshot: providerSnapshot, descriptors: descriptors) {
                result[id] = state
            }
        }
        return result
    }
```

NOTE: confirm the Engine's current-snapshot stored property is named `snapshot` (it backs `currentSnapshot()` at `Engine.swift:221`). If it differs, use whatever `currentSnapshot()` returns: `let providerSnapshot = currentSnapshot().providers[instanceID]?.value`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter EngineEntityAPITests`
Expected: PASS.

- [ ] **Step 5: Build + full test run**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AmbitCore/Engine.swift Tests/AmbitCoreTests/EngineEntityAPITests.swift
git commit -m "P2: public Engine entity API (descriptors + projected states)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Popover renders through SurfaceView

Build `SurfaceData`/`SurfacePlan` in `StatusViewModel` over the selected pingscope hosts (selection → single-series; all-hosts → multi-line) plus the diagnosis banner, and replace the popover body with chrome + `SurfaceView`. Delete the bespoke Canvas graph, stats grid, recent-samples table, and diagnosis banner.

> UI tasks have no unit tests (no ViewInspector in this repo); verification is `swift build` + the P2 eyeball checkpoint. The recent-samples table is the **one parity-watch item** (intentionally dropped).

**Files:**
- Modify: `Package.swift:18-24` (add `AmbitUI` to `AmbitMenuBar` deps)
- Modify: `Sources/AmbitMenuBar/StatusViewModel.swift` (add `surfaceData`/`surfacePlan`; build them in `refreshPingScope`)
- Modify: `Sources/AmbitMenuBar/PingScopePopover.swift` (rewrite body; delete bespoke sub-views)

**Interfaces:**
- Consumes: `Engine.entityDescriptors()`, `Engine.entityStates()`, `Engine.historySamples`, `SurfaceComposer.detailPlan`, `DiagnosisEntity.make`, `AmbitUI.SurfaceView`/`SurfaceData`/`InstanceSelectorCard`.
- Produces: `StatusViewModel.surfaceData: SurfaceData`, `StatusViewModel.surfacePlan: SurfacePlan` (both `@Published`).

- [ ] **Step 1: Add the AmbitUI dependency**

In `Package.swift`, change the `AmbitMenuBar` target dependencies (line 20) from `dependencies: ["AmbitCore"],` to:
```swift
            dependencies: ["AmbitCore", "AmbitUI"],
```

- [ ] **Step 2: Add published surface state + import**

In `Sources/AmbitMenuBar/StatusViewModel.swift`, add `import AmbitUI` at the top (after `import AmbitCore`). Add these published properties next to `pingDiagnosis` (after line 32):
```swift
    @Published var surfaceData = SurfaceData()
    @Published var surfacePlan = SurfacePlan()
```

- [ ] **Step 3: Build the surface in refreshPingScope**

In `Sources/AmbitMenuBar/StatusViewModel.swift`, at the END of `refreshPingScope()` (after line 425, before the closing brace at 426), append:
```swift
        // Generic surface: latency entities of the shown hosts (single host when one is selected,
        // all enabled hosts otherwise) + the diagnosis banner. The composer collapses same-class
        // latency series into one multi-line graph; a single host stays single-series (keeps stats).
        let shown = pingScopeSelection.map { id in activeRecords.filter { $0.id == id } } ?? activeRecords
        let allDescriptors = await engine.entityDescriptors()
        let allStates = await engine.entityStates()
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var latencyDescriptors: [EntityDescriptor] = []
        for record in shown {
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
            latency.name = record.displayName    // legend/label reads the host, not "Latency"
            latencyDescriptors.append(latency)
            descriptors[latencyID] = latency
            states[latencyID] = allStates[latencyID]
            series[latencyID] = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingScopeRange.seconds))
        }

        var planCards: [CardSpec] = []
        if let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis) {
            descriptors[diagnosisDescriptor.id] = diagnosisDescriptor
            states[diagnosisDescriptor.id] = diagnosisState
            planCards.append(CardSpec(id: "card.\(diagnosisDescriptor.id.rawValue)", kind: .statusBanner,
                                      title: diagnosisDescriptor.name, entities: [diagnosisDescriptor.id], role: .banner))
        }
        planCards.append(contentsOf: SurfaceComposer.detailPlan(descriptors: latencyDescriptors, states: states).cards)
        surfaceData = SurfaceData(descriptors: descriptors, states: states, series: series)
        surfacePlan = SurfacePlan(cards: planCards)
```

(`diagnosis` is the local already computed at line 422; `now` and `activeRecords` are already in scope.)

- [ ] **Step 4: Rewrite the popover body**

In `Sources/AmbitMenuBar/PingScopePopover.swift`, add `import AmbitUI` (after `import AmbitCore`). Replace the `PingScopePopover` struct (lines 76-274) with:
```swift
struct PingScopePopover: View {
    @EnvironmentObject private var viewModel: StatusViewModel

    private var hostOptions: [InstanceSelectorCard.Option] {
        viewModel.pingHosts.map { .init(id: $0.instanceID.rawValue, label: $0.name) }
    }
    private var focus: PingHostDisplay? {
        if let id = viewModel.pingScopeSelection { return viewModel.pingHosts.first { $0.instanceID == id } }
        return viewModel.pingHosts.first { $0.isPrimary } ?? viewModel.pingHosts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rangePicker
            SurfaceView(plan: viewModel.surfacePlan, data: viewModel.surfaceData)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    private var header: some View {
        HStack(alignment: .top) {
            InstanceSelectorCard(
                options: hostOptions,
                selectedID: viewModel.pingScopeSelection?.rawValue,
                onSelect: { viewModel.selectPingScopeHost($0.map { IntegrationInstanceID(rawValue: $0) }) },
                allLabel: "All Hosts"
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focus?.readout.text ?? "--ms").font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle().fill(PingScopeColors.tone(focus?.readout.tone ?? .neutral)).frame(width: 9, height: 9)
                    Text(focus?.readout.statusLabel ?? "No Data")
                        .font(.system(size: 13)).foregroundStyle(PingScopeColors.tone(focus?.readout.tone ?? .neutral))
                }
            }
            Button { viewModel.toggleOverlay?() } label: {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 6).help("Toggle floating overlay")
            Button { viewModel.openSettings?() } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 14, weight: .semibold))
            Picker("", selection: Binding(get: { viewModel.pingScopeRange }, set: { viewModel.setPingScopeRange($0) })) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
    }
}
```

This deletes the bespoke `diagnosisBanner`, `bannerTone`, `graphSeries`, `graph`, `legend`, `stats`, `stat`, `recentSamples`, `time`, and `axisMax`/`isAllHosts`/`gearIcon`/`hosts` members. Keep the `PingHostDisplay` struct, `PingScopeColors`, `PingScopeGlyphRenderer`, and `LatencyGraph` (still used by the overlay until Task 9).

- [ ] **Step 5: Build**

Run: `swift build`
Expected: build succeeds. (`LatencyGraph` remains referenced by `PingScopeOverlay.swift`; that's fine.)

- [ ] **Step 6: Visual checkpoint**

Launch the app (`swift run Ambit`, or via the run skill / XcodeBuildMCP) and open the popover. Confirm: host selector switches hosts; single host shows a single-line graph with Min/Avg/Max readouts and the correct "ms" axis; "All Hosts" shows the multi-line graph with a legend; the diagnosis banner appears (tone-colored) only when a fault is present. Note any downgrade vs the bespoke popover for the checkpoint discussion — the recent-samples table is the known dropped item.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/AmbitMenuBar/StatusViewModel.swift Sources/AmbitMenuBar/PingScopePopover.swift
git commit -m "P2: popover renders through SurfaceView; delete bespoke graph/stats/samples/banner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Overlay renders through SurfaceView

Render the floating overlay through `SurfaceView` (graph cards only) and delete the bespoke `LatencyGraph` Canvas.

**Files:**
- Modify: `Sources/AmbitMenuBar/PingScopeOverlay.swift` (rewrite `OverlayView` body)
- Modify: `Sources/AmbitMenuBar/PingScopePopover.swift` (delete the `LatencyGraph` struct, lines 276-300)

**Interfaces:**
- Consumes: `viewModel.surfacePlan`, `viewModel.surfaceData`, `AmbitUI.SurfaceView`.

- [ ] **Step 1: Rewrite the overlay body**

In `Sources/AmbitMenuBar/PingScopeOverlay.swift`, add `import AmbitUI`. Replace the `OverlayView` `body` (lines 16-49) with one that renders the plan's graph cards only:
```swift
    var body: some View {
        let graphCards = viewModel.surfacePlan.cards
            .flatMap { $0.kind == .section ? $0.children : [$0] }
            .filter { $0.kind == .historyGraph || $0.kind == .dualLineGraph }
        VStack(spacing: 5) {
            SurfaceView(plan: SurfacePlan(cards: graphCards), data: viewModel.surfaceData)
        }
        .padding(8)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .contextMenu {
            Menu("Host") {
                Button("All Hosts") { viewModel.selectPingScopeHost(nil) }
                ForEach(viewModel.pingHosts) { host in
                    Button(host.name) { viewModel.selectPingScopeHost(host.instanceID) }
                }
            }
            Button("Open Popover", action: openPopover)
            Button("Settings…") { viewModel.openSettings?() }
            Divider()
            Button("Close Overlay", action: close)
        }
    }
```

This drops the `OverlayModel.showLegend` toggle (the multi-line graph shows its own legend). The `model` property is now unused in the body but the `@ObservedObject var model: OverlayModel` and `OverlayController` wiring stay (removing them is out of scope); leave `OverlayModel` as-is.

- [ ] **Step 2: Delete the bespoke LatencyGraph**

In `Sources/AmbitMenuBar/PingScopePopover.swift`, delete the `struct LatencyGraph` (lines 276-300). Confirm no other reference remains:
Run: `grep -rn "LatencyGraph" Sources/`
Expected: no matches.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds. If the compiler warns that `OverlayModel`/`model` is unused, that is acceptable (leave the type for the unchanged controller wiring).

- [ ] **Step 4: Visual checkpoint**

Open the overlay (popover → overlay button). Confirm the compact multi-host graph renders with a legend and resizes; host context menu still switches selection.

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitMenuBar/PingScopeOverlay.swift Sources/AmbitMenuBar/PingScopePopover.swift
git commit -m "P2: overlay renders through SurfaceView; delete bespoke LatencyGraph

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Settings host detail through generic cards

Render each host's detail line in the Settings "Hosts" pane through the generic vocabulary (a `StatusRow`-style row driven by the host's config), replacing the bespoke monospaced detail `Text`. Keep the management controls (enable/primary/delete/add) and the typed `HostEditor` — the full entity-driven, typed-control settings renderer is **P5** (it needs config-entity *values* wired through, which P2 does not build).

> Scope note: decision 3 defers the typed editor to P5. The host config entities are static placeholders today (no values), so P2 cannot render them as live config rows without P5's machinery. This task converts the host detail presentation to the generic `StatusRowCard` view; management UI + `HostEditor` stay until P5.

**Files:**
- Modify: `Sources/AmbitMenuBar/PingScopeSettings.swift` (HostsPane card detail row)

**Interfaces:**
- Consumes: `AmbitUI.StatusRowCard`, `AmbitCore.EntityReadout`.

- [ ] **Step 1: Render the host detail via the generic StatusRow card**

In `Sources/AmbitMenuBar/PingScopeSettings.swift`, add `import AmbitUI`. In `HostsPane.card(_:)` (lines 286-311), replace the bespoke detail `Text(row.detail)` (line 298) with a generic `StatusRowCard` bound to a readout built from the host config:
```swift
                StatusRowCard(title: "Target", readout: EntityReadout(text: row.detail, tone: row.enabled ? .good : .neutral))
```

`StatusRowCard.init(title: String, readout: EntityReadout)` is at `Sources/AmbitUI/Cards/StatusRowCard.swift:8`; `EntityReadout(text:fraction:tone:)` is the public memberwise init at `Sources/AmbitCore/Presentation/EntityReadout.swift:12`.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Visual checkpoint**

Open Settings ▸ Hosts. Confirm each host card shows the target via the generic row; enable/primary/delete/edit still work; Add Host + the typed editor still work.

- [ ] **Step 4: Full test run**

Run: `swift test`
Expected: green (no test changes; the bespoke-UI deletions in Tasks 8-9 had no unit tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AmbitMenuBar/PingScopeSettings.swift
git commit -m "P2: settings host detail through generic StatusRow card

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation: P2 eyeball checkpoint

After Task 10, compare pingscope-through-generic against the real `~/src/pingscope` app side by side. Bar: **at least as good as the bespoke Canvas UI.**
- Known dropped item (flagged): the recent-samples table.
- Watch the multi-line history graph specifically — if it regresses vs the bespoke Canvas one, fix the **primitive** (`HistoryGraphCard`/`GraphGeometry`/composer) before P6, not after.
- If per-host density or any layout reads as a downgrade, that is feedback for the generic vocabulary (a new primitive or a visibility rule), never a pingscope special-case.

## Deferred (not this plan)

- Slot model + generic chrome (P3). Dynamic bar readout / attention engine (P4) — and the P4 re-examination of whether `alerting` belongs on the severity scale.
- Generic 3-depth, typed-control settings renderer + config-entity values (P5).
- `statTable` tabular binding (P6).
