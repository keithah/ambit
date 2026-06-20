import Foundation
import AmbitCore

@main
struct AmbitCheck {
    static func main() async {
        let args = CommandLine.arguments
        let shouldProbeVPNMethods = args.contains("--probe-vpn-methods")
        let shouldProbeSpeedify = args.contains("--probe-speedify")
        let shouldDumpSpeedifyNetworks = args.contains("--dump-speedify-networks")
        let shouldProbeStarlink = args.contains("--probe-starlink")
        let shouldPrintUsage = args.contains("--usage")
        let positionalArgs = args.dropFirst().filter { !$0.hasPrefix("--") }
        let username = positionalArgs.dropFirst().first ?? "root"
        let password = positionalArgs.dropFirst(2).first ?? RouterDefaults.routerPassword

        let settings: AppSettings
        let host: String?
        if let first = positionalArgs.first {
            host = first
            settings = AppSettings(remoteHost: first, username: username, endpointMode: .forceRemote)
        } else {
            host = nil
            settings = AppSettings(username: username, endpointMode: .auto)
        }

        let engine = Engine(
            settings: settings,
            routerPassword: password,
            registerBuiltInProviders: true,
            activeMeasurementProcessRunner: SystemProcessRunner()
        )
        await engine.refresh()
        let snapshot = await engine.currentSnapshot()
        let selectedHost = await engine.currentSelectedEndpoint()?.host ?? host
        guard let selectedHost else {
            if shouldPrintUsage {
                await printUsage(engine: engine)
            }
            fputs("Usage: ambit-check [--usage] [--probe-vpn-methods] [--probe-speedify] [--probe-starlink] [host] [username] [password]\nCould not discover GL.iNet router endpoint: \(snapshot.router.errorMessage ?? "endpoint unavailable")\n", stderr)
            Foundation.exit(2)
        }
        guard let endpoint = URL.routerRPC(host: selectedHost) else {
            if shouldPrintUsage {
                await printUsage(engine: engine)
            }
            fputs("Invalid host: \(selectedHost)\n", stderr)
            Foundation.exit(2)
        }
        let client = GLiNetClient(endpoint: endpoint, username: username, passwordProvider: { password })
        do {
            guard let status = snapshot.router.value else {
                throw JSONRPCClientError.commandFailed(snapshot.router.errorMessage ?? "Router status unavailable.")
            }
            print("Router reachable: \(status.reachable)")
            print("Endpoint: \(selectedHost)")
            print("LAN IP: \(status.lanIP ?? "not reported")")
            print("Active WAN: \(status.activeWAN?.label ?? "unknown")")
            print("Public IP: \(status.publicIP ?? "not reported")")

            if let vpn = snapshot.vpn.value {
                if vpn.isAvailable {
                    print("VPN: \(vpn.vpnProtocol.rawValue) \(vpn.isConnected ? "connected" : "disconnected")")
                    if let server = vpn.server {
                        print("VPN server: \(server)")
                    }
                    if let profile = vpn.profile {
                        print("VPN profile: \(profile)")
                    }
                } else {
                    print("VPN: unavailable (\(vpn.unavailableReason ?? "VPN client API unavailable"))")
                }
            } else if let error = snapshot.vpn.errorMessage {
                print("VPN: unavailable (\(error))")
            }

            if shouldProbeVPNMethods {
                await probeVPNMethods(client: client)
            }

            if shouldProbeSpeedify {
                await probeSpeedify(host: selectedHost)
            }

            if shouldDumpSpeedifyNetworks {
                await dumpSpeedifyNetworks(host: selectedHost)
            }

            if shouldProbeStarlink {
                await probeStarlink()
            }

            if shouldPrintUsage {
                await printUsage(engine: engine)
            }
        } catch {
            if shouldPrintUsage {
                await printUsage(engine: engine)
            }
            fputs("Router check failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printUsage(engine: Engine) async {
        let snapshots = await engine.usageSnapshots()
        print(ModuleUsageReportFormatter.format(Array(snapshots.values)))
    }

    private static func probeVPNMethods(client: GLiNetClient) async {
        let services = [
            "wg-client",
            "wgclient",
            "wireguard",
            "wireguard-client",
            "wg-server",
            "wgserver",
            "ovpn-client",
            "ovpnclient",
            "openvpn",
            "openvpn-client",
            "ovpn-server",
            "ovpnserver",
            "tailscale",
            "tor",
            "zerotier",
            "mptun"
        ]
        let methods = ["get_status", "status", "get_config", "get_settings", "get_setting"]
        print("VPN method probe:")
        for service in services {
            for method in methods {
                do {
                    let result = try await client.call(service: service, method: method)
                    print("  \(service).\(method): ok (\(result.keys.sorted().joined(separator: ",")))")
                } catch {
                    print("  \(service).\(method): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func probeSpeedify(host: String) async {
        do {
            let status = try await RouterSpeedifyClient(timeout: 3).status(host: host)
            print("Speedify: \(status.state)")
            if let server = status.server {
                print("Speedify server: \(server)")
            }
            if let mode = status.bondingMode {
                print("Speedify bonding: \(mode.label)")
            }
            if let threshold = status.secondaryThresholdMbps {
                print("Speedify secondary threshold: < \(threshold) Mbps")
            }
            for network in status.networks {
                print("Speedify network: \(network.displayName) - \(network.priority.label)")
            }
        } catch {
            print("Speedify: unavailable (\(error.localizedDescription))")
        }
    }

    private static func dumpSpeedifyNetworks(host: String) async {
        do {
            let payloads = try await RouterSpeedifyClient(timeout: 3).networkPayloads(host: host)
            print("Speedify raw networks:")
            for payload in payloads {
                let id = firstString(payload, keys: ["guid", "id", "key"]) ?? "unknown"
                print("  \(id):")
                for key in payload.keys.sorted() {
                    guard let value = payload[key] else { continue }
                    switch value {
                    case .string(let string):
                        print("    \(key): \(string)")
                    case .number(let number):
                        print("    \(key): \(number)")
                    case .bool(let bool):
                        print("    \(key): \(bool)")
                    default:
                        break
                    }
                }
            }
        } catch {
            print("Speedify raw networks unavailable: \(error.localizedDescription)")
        }
    }

    private static func firstString(_ object: JSONObject, keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    private static func probeStarlink() async {
        let status = await StarlinkClient().status()
        guard status.isReachable else {
            print("Starlink: unavailable (\(status.state))")
            return
        }
        print("Starlink: \(status.state)")
        if let latency = status.popPingLatencyMs {
            print("Starlink latency: \(Int(latency.rounded())) ms")
        }
        if let drop = status.recentDropRate {
            print("Starlink drop rate: \(Int((drop * 100).rounded()))%")
        }
        if let down = status.downlinkThroughputBps {
            print("Starlink down: \(down) B/s")
        }
        if let up = status.uplinkThroughputBps {
            print("Starlink up: \(up) B/s")
        }
        if let obstruction = status.obstructionPercent {
            print("Starlink obstruction: \(String(format: "%.1f", obstruction))%")
        }
        if let gpsSats = status.gpsSats {
            print("Starlink GPS sats: \(gpsSats)")
        }
        if let eth = status.ethSpeedMbps {
            print("Starlink Ethernet: \(eth) Mbps")
        }
        if let outages = status.outageCount {
            print("Starlink outages in history: \(outages)")
        }
    }
}
