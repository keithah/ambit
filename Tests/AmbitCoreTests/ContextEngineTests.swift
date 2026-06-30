import XCTest
@testable import AmbitCore

final class ContextEngineTests: XCTestCase {
    private let cpuID: EntityID = "system@local/overview.cpu_usage_percent"
    private let latencyID: EntityID = "ping@gateway/probe.latency_ms"
    private let slotID: SlotID = "slot.system"
    private let alertKindID: AlertKindID = "fixture.alert"

    func testResolveWithNoActiveContextsReturnsBaseByteIdenticalAndEmptyTrace() throws {
        let base = baseConfig()

        let resolved = ContextResolver.resolve(base: base, activeContexts: [])

        XCTAssertEqual(resolved.config, base)
        XCTAssertTrue(resolved.traces.isEmpty)
        XCTAssertEqual(try canonicalJSON(resolved.config), try canonicalJSON(base))
    }

    func testResolveStacksContextsByPriorityWithLastWriterWinsAndWhyTrace() {
        let base = baseConfig()
        let home = context(
            id: "ctx.home",
            name: "Home",
            priority: 1,
            overlay: ContextOverlay(
                entityOverrides: [
                    cpuID: EntityPresentationOverride(visibility: .auto)
                ],
                slotOverrides: [
                    slotID: SlotPresentationOverride(tableRowLimit: 5)
                ],
                alertKindOverrides: [
                    alertKindID: AlertKindOverride(enabled: false)
                ]
            )
        )
        let evening = context(
            id: "ctx.evening",
            name: "Evening",
            priority: 5,
            overlay: ContextOverlay(
                entityOverrides: [
                    cpuID: EntityPresentationOverride(visibility: .always, pinned: true)
                ],
                slotOverrides: [
                    slotID: SlotPresentationOverride(tableRowLimit: 3)
                ],
                alertKindOverrides: [
                    alertKindID: AlertKindOverride(enabled: true)
                ]
            )
        )

        let resolved = ContextResolver.resolve(base: base, activeContexts: [evening, home])

        XCTAssertEqual(resolved.config.entityOverrides[cpuID]?.visibility, .always)
        XCTAssertEqual(resolved.config.entityOverrides[cpuID]?.pinned, true)
        XCTAssertEqual(resolved.config.slotOverrides[slotID]?.tableRowLimit, 3)
        XCTAssertEqual(resolved.config.alertKindOverrides[alertKindID]?.enabled, true)

        let entityTrace = resolved.traces[.entity(cpuID)]
        XCTAssertEqual(entityTrace?.layers.map(\.source), [.base, .context(home.id), .context(evening.id)])
        XCTAssertEqual(entityTrace?.winningSource, .context(evening.id))

        let slotTrace = resolved.traces[.slot(slotID)]
        XCTAssertEqual(slotTrace?.layers.map(\.source), [.base, .context(home.id), .context(evening.id)])
        XCTAssertEqual(slotTrace?.winningSource, .context(evening.id))
    }

    func testContextStateMachineHonorsDwellAndManualOverrides() {
        let condition = Condition.comparison(Comparison(
            lhs: .address(cpuID),
            comparison: .greaterThan,
            rhs: .literal(.number(80))
        ))
        let auto = context(id: "ctx.auto", name: "Auto", priority: 1, condition: condition)
        let pinnedActive = context(
            id: "ctx.active",
            name: "Pinned Active",
            priority: 2,
            condition: condition,
            manualOverride: .pinnedActive
        )
        let pinnedInactive = context(
            id: "ctx.inactive",
            name: "Pinned Inactive",
            priority: 3,
            condition: condition,
            manualOverride: .pinnedInactive
        )
        var machine = ContextStateMachine(dwell: 5)
        let input = ConditionEvaluator.Input(states: [
            cpuID: EntityState(id: cpuID, value: .number(90), availability: .online)
        ])

        let first = machine.evaluate(contexts: [auto, pinnedActive, pinnedInactive], input: input, now: Date(timeIntervalSince1970: 0))
        let second = machine.evaluate(contexts: [auto, pinnedActive, pinnedInactive], input: input, now: Date(timeIntervalSince1970: 6))

        XCTAssertEqual(first.activeIDs, [pinnedActive.id])
        XCTAssertEqual(second.activeIDs, [auto.id, pinnedActive.id])
        XCTAssertEqual(second.states[ContextActiveEntity.id(for: auto.id)]?.value, .bool(true))
        XCTAssertEqual(second.states[ContextActiveEntity.id(for: pinnedInactive.id)]?.value, .bool(false))
    }

    func testContextStateMachineDoesNotDoubleWrapTemporalConditions() {
        let temporalCondition = Condition.temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(cpuID), comparison: .greaterThan, rhs: .literal(.number(80)))),
            op: .heldFor(0),
            edge: .level
        ))
        let declaration = context(id: "ctx.temporal", name: "Temporal", priority: 1, condition: temporalCondition)
        var machine = ContextStateMachine(dwell: 60)
        let input = ConditionEvaluator.Input(states: [
            cpuID: EntityState(id: cpuID, value: .number(90), availability: .online)
        ])

        let evaluated = machine.evaluate(contexts: [declaration], input: input, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(evaluated.activeIDs, [declaration.id])
    }

    func testApplyContextReactionCanSetContextActiveState() async throws {
        let id = ContextID(rawValue: "ctx.rain")
        let rule = UserRule(
            id: "rule.apply.context",
            displayName: "Apply rain context",
            condition: .comparison(Comparison(lhs: .address(cpuID), comparison: .greaterThan, rhs: .literal(.number(50)))),
            reactions: [.applyContext(id: id.rawValue, active: true)],
            enabled: true
        )
        let declaration = context(id: id, name: "Rain", priority: 1)
        var runner = UserRuleRunner()
        var machine = ContextStateMachine(dwell: 0)

        let results = try await runner.evaluate(
            rules: [rule],
            input: ConditionEvaluator.Input(states: [
                cpuID: EntityState(id: cpuID, value: .number(60), availability: .online)
            ]),
            now: Date(timeIntervalSince1970: 0),
            executor: ReactionExecutor()
        )
        machine.apply(results)
        let evaluated = machine.evaluate(contexts: [declaration], input: .init(), now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(results.map(\.executionResult), [.contextApplied(id.rawValue, active: true)])
        XCTAssertEqual(evaluated.activeIDs, [id])
        XCTAssertEqual(evaluated.states[ContextActiveEntity.id(for: id)]?.value, .bool(true))
    }

    func testCycleDetectionDisablesOffendingRuleAndReportsDiagnostic() {
        let context = context(
            id: "ctx.work",
            name: "Work",
            priority: 1,
            overlay: ContextOverlay(ruleToggles: ["rule.work": true])
        )
        let rule = UserRule(
            id: "rule.work",
            displayName: "Activate work",
            condition: .comparison(Comparison(lhs: .address(cpuID), comparison: .greaterThan, rhs: .literal(.number(50)))),
            reactions: [.applyContext(id: context.id.rawValue, active: true)],
            enabled: true
        )

        let validated = ContextCycleDetector.validate(contexts: [context], rules: [rule])

        XCTAssertEqual(validated.rules.first?.enabled, false)
        XCTAssertEqual(validated.contexts, [context])
        XCTAssertEqual(validated.diagnostics.map(\.message), ["Disabled rule.work because it forms a context cycle through ctx.work."])
    }

    func testContextStorePersistsCreateUpdateDeleteReorderAndSurvivesReload() {
        let suite = "ContextEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsContextStore(defaults: defaults)
        let first = context(id: "ctx.first", name: "First", priority: 0)
        let second = context(id: "ctx.second", name: "Second", priority: 1)

        store.create(first)
        store.create(second)
        store.reorder(ids: [second.id, first.id])
        var updated = second
        updated.displayName = "Updated Second"
        store.update(updated)

        let reloaded = UserDefaultsContextStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.first?.displayName, "Updated Second")

        store.delete(id: second.id)
        XCTAssertEqual(store.load().map(\.id), [first.id])
    }

    func testCorruptContextStoreLoadsEmpty() {
        let suite = "ContextEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsContextStore.defaultKey)

        XCTAssertEqual(UserDefaultsContextStore(defaults: defaults).load(), [])
    }

    private func baseConfig() -> PresentationConfig {
        PresentationConfig(
            entityOverrides: [
                cpuID: EntityPresentationOverride(visibility: .never),
                latencyID: EntityPresentationOverride(visibility: .auto)
            ],
            slotOverrides: [
                slotID: SlotPresentationOverride(tableRowLimit: 8)
            ],
            alertKindOverrides: [
                alertKindID: AlertKindOverride(enabled: true)
            ],
            slots: [
                Slot(id: slotID, title: "System", selection: .integration("system@local"))
            ]
        )
    }

    private func context(
        id: ContextID,
        name: String,
        priority: Int,
        condition: Condition = .comparison(Comparison(lhs: .literal(.bool(true)), comparison: .equal, rhs: .literal(.bool(true)))),
        manualOverride: ContextManualOverride = .auto,
        overlay: ContextOverlay = ContextOverlay()
    ) -> ContextDeclaration {
        ContextDeclaration(
            id: id,
            displayName: name,
            icon: nil,
            condition: condition,
            priority: priority,
            manualOverride: manualOverride,
            overlay: overlay
        )
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? ""
    }
}
