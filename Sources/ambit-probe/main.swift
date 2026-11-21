import AmbitKit
import Foundation

// Device check from the command line: `swift run ambit-probe starlink [host]`.
// Prints what the app would read, so a device can be verified without the UI.
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "starlink":
    let host = arguments.dropFirst().first ?? StarlinkClient.defaultHost
    do {
        let status = try await StarlinkClient(host: host).status()
        print("Starlink at \(host)")
        print("  state:        \(status.outage.map(\.text) ?? "Online")")
        print("  dish:         \(status.hardwareVersion ?? "?") / \(status.softwareVersion ?? "?")")
        print("  uptime:       \(status.uptimeSeconds.map { "\($0) s" } ?? "?")")
        print("  latency:      \(status.latencyMs.map { String(format: "%.1f ms", $0) } ?? "?")")
        print("  down / up:    \(status.downlinkBps.map { String(format: "%.1f", $0 / 1e6) } ?? "?") / \(status.uplinkBps.map { String(format: "%.1f", $0 / 1e6) } ?? "?") Mbps")
        print("  obstructed:   \(status.fractionObstructed.map { String(format: "%.2f%%", $0 * 100) } ?? "?")")
        print("  stow asked:   \(status.stowRequested)")
    } catch {
        print("Starlink at \(host): failed: \(error)")
        exit(1)
    }
default:
    print("usage: ambit-probe starlink [host]")
    exit(2)
}
