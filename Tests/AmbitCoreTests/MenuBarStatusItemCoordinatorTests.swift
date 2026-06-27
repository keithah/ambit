import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

final class MenuBarStatusItemCoordinatorTests: XCTestCase {
    func testReconcilerAddsMissingSlotsAndPreservesExistingOrder() {
        let ping = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping))
        let system = Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal))

        let plan = MenuBarStatusItemReconciler.plan(existing: [ping.id], desired: [ping, system])

        XCTAssertEqual(plan.idsToCreate, [system.id])
        XCTAssertEqual(plan.idsToRemove, [])
        XCTAssertEqual(plan.orderedIDs, [ping.id, system.id])
    }

    func testReconcilerRemovesDeletedSlots() {
        let ping = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping))

        let plan = MenuBarStatusItemReconciler.plan(existing: [ping.id, "system@local"], desired: [ping])

        XCTAssertEqual(plan.idsToCreate, [])
        XCTAssertEqual(plan.idsToRemove, ["system@local"])
        XCTAssertEqual(plan.orderedIDs, [ping.id])
    }

    func testReconcilerReordersWithoutRecreatingStableSlots() {
        let ping = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping))
        let system = Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal))

        let plan = MenuBarStatusItemReconciler.plan(existing: [ping.id, system.id], desired: [system, ping])

        XCTAssertEqual(plan.idsToCreate, [])
        XCTAssertEqual(plan.idsToRemove, [])
        XCTAssertEqual(plan.orderedIDs, [system.id, ping.id])
    }

    func testReconcilerNoOpsWhenSlotsAreUnchanged() {
        let ping = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping))
        let system = Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal))

        let plan = MenuBarStatusItemReconciler.plan(existing: [ping.id, system.id], desired: [ping, system])

        XCTAssertEqual(plan.idsToCreate, [])
        XCTAssertEqual(plan.idsToRemove, [])
        XCTAssertEqual(plan.orderedIDs, [ping.id, system.id])
    }
}
