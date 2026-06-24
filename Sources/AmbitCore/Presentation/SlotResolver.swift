import Foundation

// Resolves a slot's SELECTION to the entity descriptors it binds, against the LIVE descriptor
// set (only active/enabled, currently-polling instances are present) plus the registry records
// (which give instance→integration and the current instance set for .integrationType). UI-free.
//
// Because resolution runs against the live descriptors, a disabled or not-yet-polling host
// never ghosts in as a blank row — and .integrationType needs no stored membership list.

public enum SlotResolver {
    public static func resolve(
        _ selection: SlotSelection,
        descriptors: [EntityDescriptor],
        records: [IntegrationInstanceRecord]
    ) -> [EntityDescriptor] {
        switch selection {
        case .integration(let id):
            return descriptors.filter { $0.instanceID.integrationInstanceID == id }
        case .integrations(let ids):
            let set = Set(ids)
            return descriptors.filter { set.contains($0.instanceID.integrationInstanceID) }
        case .integrationType(let integrationID):
            // Current ENABLED instances of the integration; the live-descriptor filter then drops
            // any that aren't actually polling yet.
            let instances = Set(records.filter { $0.integrationID == integrationID && $0.enabled }.map(\.id))
            return descriptors.filter { instances.contains($0.instanceID.integrationInstanceID) }
        case .capability(let capability):
            return descriptors.filter { $0.capability == capability }
        case .entities(let ids):
            let set = Set(ids)
            return descriptors.filter { set.contains($0.id) }
        }
    }
}
