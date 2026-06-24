import Foundation

// Built-in entity descriptors (entity-model.md §13).
//
// Each built-in overrides entityDescriptors() to declare its correct static shape. Device
// classes, categories and capabilities follow §13; where §13 sketches a metric the provider
// does not actually emit (the code is ground truth), the descriptor is mapped onto the real
// metric id or omitted so no entity is permanently unavailable.

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}

// MARK: gl.inet router (glinet/router)

public extension GLiNetRouterProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("wan_up"), instanceID: instance, name: "WAN Up",
                kind: .binarySensor, deviceClass: .connectivity, category: .primary,
                capability: "wan", access: .read, metricID: "reachable"
            ),
            EntityDescriptor(
                id: instance.entity("active_wan"), instanceID: instance, name: "Active WAN",
                kind: .text, category: .diagnostic, capability: "wan", access: .read,
                metricID: "active_wan"
            ),
            EntityDescriptor(
                id: instance.entity("wan_ip"), instanceID: instance, name: "WAN IP",
                kind: .text, category: .diagnostic, capability: "wan", access: .read,
                metricID: "public_ip"
            ),
            EntityDescriptor(
                id: instance.entity("clients"), instanceID: instance, name: "Clients",
                kind: .sensor, deviceClass: .count, category: .primary, capability: "clients",
                access: .read, metricID: "clients"
            ),
            EntityDescriptor(
                id: instance.entity("hostname"), instanceID: instance, name: "Hostname",
                kind: .text, category: .diagnostic, access: .read, metricID: "hostname"
            ),
            EntityDescriptor(
                id: instance.entity("device_model"), instanceID: instance, name: "Model",
                kind: .text, category: .diagnostic, access: .read, metricID: "device_model"
            ),
            // Config (shared gl.inet credentials/target) — entity-model.md §13.
            EntityDescriptor(
                id: instance.entity("host"), instanceID: instance, name: "Host",
                kind: .text, category: .config, access: .readWrite
            ),
            EntityDescriptor(
                id: instance.entity("password"), instanceID: instance, name: "Password",
                kind: .text, category: .config, access: .write
            )
        ]
    }
}

// MARK: gl.inet VPN (glinet/vpn)

public extension GLiNetVPNProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("vpn_connected"), instanceID: instance, name: "VPN Connected",
                kind: .toggle, deviceClass: .connectivity, category: .primary,
                capability: "vpnClient", access: .readWrite,
                command: CommandRef(commandID: ProviderCommandIDs.vpnToggle),
                metricID: "connected"
            ),
            EntityDescriptor(
                id: instance.entity("protocol"), instanceID: instance, name: "Protocol",
                kind: .text, category: .diagnostic, capability: "vpnClient", access: .read,
                metricID: "protocol"
            )
        ]
    }
}

// MARK: Reachability (reachability/reachability)

public extension ReachabilityProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("network_path"), instanceID: instance, name: "Network Path",
                kind: .binarySensor, deviceClass: .connectivity, category: .primary,
                capability: "uplink", access: .read, metricID: "network_path"
            ),
            EntityDescriptor(
                id: instance.entity("latency_ms"), instanceID: instance, name: "Latency",
                kind: .sensor, deviceClass: .latency, category: .primary, capability: "uplink",
                access: .read, unit: "ms", stateClass: .measurement, metricID: "latency_ms"
            )
        ]
    }
}

// MARK: Speedify (speedify/speedify)

public extension SpeedifyProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("connected"), instanceID: instance, name: "Connected",
                kind: .toggle, deviceClass: .connectivity, category: .primary,
                capability: "vpnClient", access: .readWrite,
                command: CommandRef(commandID: ProviderCommandIDs.speedifyToggle),
                metricID: "connected"
            ),
            EntityDescriptor(
                id: instance.entity("bonding_mode"), instanceID: instance, name: "Bonding Mode",
                kind: .select, category: .primary, capability: "bonding", access: .readWrite,
                options: [
                    EntityOption(value: "SP", label: "Speed"),
                    EntityOption(value: "RD", label: "Redundant"),
                    EntityOption(value: "STR", label: "Streaming")
                ],
                command: CommandRef(commandID: ProviderCommandIDs.speedifySetBondingMode, argumentKey: "mode"),
                metricID: "bonding_mode"
            ),
            EntityDescriptor(
                id: instance.entity("download_bps"), instanceID: instance, name: "Download",
                kind: .sensor, deviceClass: .throughput, category: .primary, capability: "tunnelStats",
                access: .read, unit: "bps", stateClass: .measurement, metricID: "download_bps"
            ),
            EntityDescriptor(
                id: instance.entity("upload_bps"), instanceID: instance, name: "Upload",
                kind: .sensor, deviceClass: .throughput, category: .primary, capability: "tunnelStats",
                access: .read, unit: "bps", stateClass: .measurement, metricID: "upload_bps"
            ),
            // Multi-parameter command → button (opens ProviderDetail), never an auto form.
            EntityDescriptor(
                id: instance.entity("set_network_priority"), instanceID: instance, name: "Set Network Priority",
                kind: .button, category: .config, access: .write,
                command: CommandRef(commandID: ProviderCommandIDs.speedifySetNetworkPriority)
            )
        ]
    }
}

// MARK: Starlink (starlink/starlink)

public extension StarlinkProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("online"), instanceID: instance, name: "Online",
                kind: .binarySensor, deviceClass: .connectivity, category: .primary,
                capability: "uplink", access: .read, metricID: "reachable"
            ),
            EntityDescriptor(
                id: instance.entity("downlink_bps"), instanceID: instance, name: "Downlink",
                kind: .sensor, deviceClass: .throughput, category: .primary, access: .read,
                unit: "bps", stateClass: .measurement, metricID: "downlink_bps"
            ),
            EntityDescriptor(
                id: instance.entity("uplink_bps"), instanceID: instance, name: "Uplink",
                kind: .sensor, deviceClass: .throughput, category: .primary, access: .read,
                unit: "bps", stateClass: .measurement, metricID: "uplink_bps"
            ),
            EntityDescriptor(
                id: instance.entity("latency_ms"), instanceID: instance, name: "POP Latency",
                kind: .sensor, deviceClass: .latency, category: .primary, access: .read,
                unit: "ms", stateClass: .measurement, metricID: "pop_latency_ms"
            ),
            EntityDescriptor(
                id: instance.entity("obstruction_percent"), instanceID: instance, name: "Obstruction",
                kind: .sensor, deviceClass: .percent, category: .primary, capability: "obstruction",
                access: .read, unit: "%", stateClass: .measurement, metricID: "obstruction_percent"
            ),
            EntityDescriptor(
                id: instance.entity("outage_count"), instanceID: instance, name: "Outages",
                kind: .sensor, deviceClass: .count, category: .diagnostic, access: .read,
                stateClass: .totalIncreasing, metricID: "outage_count"
            ),
            EntityDescriptor(
                id: instance.entity("drop_percent"), instanceID: instance, name: "Drop Rate",
                kind: .sensor, deviceClass: .percent, category: .diagnostic, access: .read,
                unit: "%", stateClass: .measurement, metricID: "drop_percent"
            ),
            EntityDescriptor(
                id: instance.entity("state"), instanceID: instance, name: "State",
                kind: .text, category: .diagnostic, access: .read, metricID: "state"
            )
        ]
    }
}

// MARK: EcoFlow (ecoflow/ecoflow)

public extension EcoFlowProvider {
    func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("battery_percent"), instanceID: instance, name: "Battery",
                kind: .sensor, deviceClass: .battery, category: .primary, capability: "battery",
                access: .read, unit: "%", stateClass: .measurement, metricID: "battery_percent"
            ),
            EntityDescriptor(
                id: instance.entity("input_watts"), instanceID: instance, name: "Input",
                kind: .sensor, deviceClass: .power, category: .diagnostic, access: .read,
                unit: "W", stateClass: .measurement, metricID: "input_watts"
            ),
            EntityDescriptor(
                id: instance.entity("output_watts"), instanceID: instance, name: "Output",
                kind: .sensor, deviceClass: .power, category: .diagnostic, access: .read,
                unit: "W", stateClass: .measurement, metricID: "output_watts"
            ),
            EntityDescriptor(
                id: instance.entity("time_remaining"), instanceID: instance, name: "Time Remaining",
                kind: .sensor, deviceClass: .duration, category: .primary, access: .read,
                unit: "min", stateClass: .measurement, metricID: "time_remaining"
            ),
            outputToggle(instance: instance, key: "ac_output", name: "AC Output", target: "ac"),
            outputToggle(instance: instance, key: "dc_output", name: "DC Output", target: "dc"),
            outputToggle(instance: instance, key: "usb_output", name: "USB Output", target: "usb")
        ]
    }

    private func outputToggle(instance: ProviderInstanceID, key: String, name: String, target: String) -> EntityDescriptor {
        EntityDescriptor(
            id: instance.entity(key), instanceID: instance, name: name,
            kind: .toggle, deviceClass: .power, category: .primary, capability: "powerOutput",
            access: .readWrite,
            command: CommandRef(
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                argumentKey: "state",
                fixedArguments: ["target": .string(target)]
            ),
            metricID: key
        )
    }
}

// MARK: iperf3 (iperf3/iperf3) — actor, nonisolated descriptors

public extension Iperf3Provider {
    nonisolated func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            EntityDescriptor(
                id: instance.entity("run"), instanceID: instance, name: "Run iperf3",
                kind: .button, category: .primary, access: .write,
                command: CommandRef(commandID: ProviderCommandIDs.iperf3Run)
            ),
            EntityDescriptor(
                id: instance.entity("download_bps"), instanceID: instance, name: "Download",
                kind: .sensor, deviceClass: .throughput, category: .primary, access: .read,
                unit: "bps", stateClass: .measurement, metricID: "download_bps"
            ),
            EntityDescriptor(
                id: instance.entity("upload_bps"), instanceID: instance, name: "Upload",
                kind: .sensor, deviceClass: .throughput, category: .primary, access: .read,
                unit: "bps", stateClass: .measurement, metricID: "upload_bps"
            )
        ]
    }
}
