# P6 System Integration Design

## Goal

P6 proves the Ambit presentation thesis with a second integration: `system`, an iStat-style local host
telemetry integration for CPU, memory, disk, network I/O, battery, sensors, and fans.

The proof condition is strict: system telemetry must render through the same generic entity,
attention, slot, card, and menu-bar primitives as `ping`, with zero bespoke UI in `AmbitMenuBar`.
If a system view needs something that does not exist yet, the answer is a generic primitive or
binding rule, not a system-specific SwiftUI branch.

StarBar (`starbar.app`) is the Starlink dish app and is not part of P6.

## Settled Decisions

- `system@local` is enabled by default for P6 so the multi-provider proof is visible immediately.
- Legacy device integrations remain seeded but disabled.
- Dual-line graph pairing is inferred in `SurfaceComposer` from shared capability plus complementary
  names such as upload/download or user/system. No new descriptor field is added for P6.
- Process tables use injected `ProcessRunner` and `ps` first. `libproc` is a later optimization.
- `TableCellValue` is a separate simple enum:
  - `.text(String)`
  - `.number(Double, unit: String?)`
  - `.badge(String, Severity)`
- `CardSpec.entities` remains `[EntityID]`; one table entity binds one `statTable` card.

## Provider And Entity Shape

The system integration is a built-in, local-only integration:

```swift
IntegrationID: "system"
IntegrationInstanceID: "system@local"
```

It is split into several provider instances under the same integration instance so poll cadence,
data source, and graceful degradation can evolve independently:

```swift
system@local/overview
system@local/storage
system@local/network
system@local/processes
system@local/sensors
```

Representative entities:

```swift
system@local/overview.cpu_usage
  kind: .sensor
  deviceClass: .percent
  capability: "system.cpu"
  graphStyle: .gauge
  defaultVisibility: .auto

system@local/overview.memory_used
  kind: .sensor
  deviceClass: .percent
  capability: "system.memory"
  graphStyle: .progress

system@local/storage.volumes
  kind: .table
  deviceClass: .storage
  capability: "system.disk"

system@local/processes.top_cpu
  kind: .table
  capability: "system.cpu"

system@local/network.download_bps
system@local/network.upload_bps
  kind: .sensor
  deviceClass: .throughput
  capability: "system.network"
  graphStyle: .sparkline

system@local/overview.battery_percent
  kind: .sensor
  deviceClass: .battery
  capability: "power.battery"
  graphStyle: .progress
```

CPU and memory primarily use `.percent`; network reuses `.throughput`; battery reuses `.battery`.
P6 can add system-oriented device classes only where they carry useful generic meaning, such as
`.storage`, `.temperature`, `.fan`, or `.dataSize`.

## StatTable Binding

`statTable` becomes a card bound to a table-valued entity. This avoids descriptor-per-row churn for
dynamic data such as processes and disks.

Core model:

```swift
public enum EntityKind: String, Sendable, Codable {
    case sensor, binarySensor, toggle, select, number, button, text
    case table
}

public enum EntityValue: Equatable, Sendable, Codable {
    case number(Double)
    case bool(Bool)
    case text(String)
    case table(TableValue)
}

public enum MetricValue: Equatable, Sendable {
    case throughput(bitsPerSecond: Int)
    case latency(ms: Double)
    case percent(Double)
    case level(Double)
    case bool(Bool)
    case text(String)
    case table(TableValue)
}

public struct TableValue: Equatable, Sendable, Codable {
    public var columns: [TableColumn]
    public var rows: [TableRow]
}

public struct TableColumn: Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var alignment: TableAlignment
    public var valueStyle: TableValueStyle
}

public struct TableRow: Equatable, Identifiable, Sendable, Codable {
    public var id: String
    public var cells: [String: TableCellValue]
}

public enum TableCellValue: Equatable, Sendable, Codable {
    case text(String)
    case number(Double, unit: String?)
    case badge(String, Severity)
}
```

Row IDs are stable strings chosen by callers: mount path for disks, BSD interface name for NICs,
or `pid:name` for processes. The table model does not enforce domain-specific stability.

`SurfaceComposer` rule:

```swift
if descriptor.kind == .table { return .statTable }
```

`AmbitUI.StatTableCard` renders `TableValue` generically, while preserving the existing label/value row
path for current tests and simple entity groups.

## Phasing

### P6.1: Generic table entity binding

- Add `.table` to `EntityKind`, `EntityValue`, and `MetricValue`.
- Add `TableValue`, `TableColumn`, `TableRow`, `TableCellValue`, `TableAlignment`, and `TableValueStyle`.
- Teach `EntityProjection` to pass table metric values through.
- Teach `EntityReadout` a compact table readout.
- Teach `SurfaceComposer` to map `.table` descriptors to `.statTable`.
- Teach `StatTableCard` to render table columns/rows generically and preserve legacy label/value rows.
- Tests cover composer binding, UI table rendering, and legacy behavior.

### P6.2: Generic capability sections

- Improve generic sectioning so system CPU, memory, disk, network, battery, sensors, and fans land in coherent
  detail groups.
- Keep this in taxonomy/composer logic, not system UI.
- Existing ping/uplink layout stays stable.

### P6.3: Public system metrics reader model

- Add `Sources/AmbitCore/System/`.
- Define `SystemMetricsReading` and snapshot structs.
- Use public APIs first: `host_statistics64`/`sysctl`, volume resource keys, `getifaddrs`, IOKit power source APIs.
- Tests use fake readers.

### P6.4: System overview integration

- Register `SystemIntegration`.
- Add overview provider for CPU, memory, battery, and basic host stats.
- Add descriptors with graph defaults, display thresholds, and primary readout.
- Seed `system@local` enabled by default; legacy device integrations remain disabled.

### P6.5: Disk and process stat tables

- Add storage table entity for mounted volumes.
- Add top CPU and top memory process table entities.
- Use injected `ProcessRunner` + `ps` first.
- Test table shape, stable row IDs, and graceful parse failures.

### P6.6: Network I/O

- Add aggregate and per-interface network throughput.
- Compute bps deltas from previous counters.
- Infer upload/download dual-line graph pairs in `SurfaceComposer`.
- Handle counter reset and interface filtering.

### P6.7: Optional sensors and fans

- Add optional `SystemSensorReading`.
- Keep SMC off or unavailable by default unless explicitly enabled.
- Gracefully omit or degrade sensor entities when unavailable; never fail the integration.
- Render temperature and fan entities through the same generic cards/tables.

### P6.8: Proof and eyeball

- Verify the default app shows both ping and system through slot-driven chrome.
- Dynamic lane[0] surfaces high-attention system entities, then returns to resting primary state.
- Confirm no `AmbitMenuBar` system-specific rendering path exists.
- Run `swift build` and `swift test`.

## Non-Goals

- No custom system SwiftUI panel.
- No system-specific menu-bar branch.
- No `EngineID` in any identity.
- No required SMC dependency.
- No libproc optimization in P6.1-P6.5.
