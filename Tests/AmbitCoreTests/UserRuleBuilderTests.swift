import XCTest
@testable import AmbitCore

final class UserRuleBuilderTests: XCTestCase {
    private let cpuID: EntityID = "system@local/overview.cpu_usage_percent"
    private let memoryID: EntityID = "system@local/overview.memory_used_percent"

    func testSignalPickerListsRegisteredEntityReadouts() {
        let items = SignalPickerModel.items(from: descriptors)

        XCTAssertEqual(items.map(\.id), [cpuID, memoryID])
        XCTAssertEqual(items.first?.title, "CPU")
        XCTAssertEqual(items.first?.subtitle, "sensor · percent · %")
    }

    func testDraftBuildsRuleFromSelectedSignalComparisonTemporalAndNotifyReaction() throws {
        let draft = UserRuleBuilderDraft(
            displayName: "CPU high",
            selectedSignalID: cpuID,
            comparison: .greaterThan,
            comparisonValue: .number(90),
            temporal: .consecutiveSamples(2),
            reactions: [.notify(NotifySpec(titleTemplate: "CPU high", level: .active, lifecycle: .oneShot))]
        )

        let rule = try draft.buildRule(id: "rule.cpu.high", descriptors: descriptors)

        XCTAssertEqual(rule.displayName, "CPU high")
        XCTAssertEqual(rule.condition, .temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(cpuID), comparison: .greaterThan, rhs: .literal(.number(90)))),
            op: .consecutiveSamples(2),
            edge: .level
        )))
        XCTAssertEqual(UserRuleExpressionFormatter.string(for: rule.condition, descriptors: descriptors), "CPU > 90 for 2 samples")
    }

    func testDraftRejectsMalformedRuleInsteadOfPersistingIt() {
        let draft = UserRuleBuilderDraft(
            displayName: "Broken",
            selectedSignalID: nil,
            comparison: .greaterThan,
            comparisonValue: .number(90),
            reactions: []
        )

        XCTAssertThrowsError(try draft.buildRule(id: "rule.broken", descriptors: descriptors)) { error in
            XCTAssertEqual(error as? UserRuleBuilderValidationError, .missingSignal)
        }
    }

    func testAuthoringRoundTripPersistsReloadsAndFiresThroughRunner() async throws {
        let suite = "UserRuleBuilderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsUserRuleStore(defaults: defaults)
        let draft = UserRuleBuilderDraft(
            displayName: "CPU high",
            selectedSignalID: cpuID,
            comparison: .greaterThan,
            comparisonValue: .number(90),
            temporal: .heldFor(0),
            reactions: [.notify(NotifySpec(titleTemplate: "CPU high", level: .active, lifecycle: .oneShot))]
        )
        let rule = try draft.buildRule(id: "rule.cpu.high", descriptors: descriptors)

        store.create(rule)
        let reloaded = UserDefaultsUserRuleStore(defaults: defaults).load()
        var runner = UserRuleRunner()
        let results = try await runner.evaluate(
            rules: reloaded,
            input: ConditionEvaluator.Input(states: [
                cpuID: EntityState(id: cpuID, value: .number(94), availability: .online)
            ]),
            now: Date(timeIntervalSince1970: 100),
            executor: ReactionExecutor()
        )

        XCTAssertEqual(reloaded, [rule])
        XCTAssertEqual(results.map(\.ruleID), [rule.id])
    }

    private var descriptors: [EntityDescriptor] {
        [
            EntityDescriptor(
                id: cpuID,
                instanceID: ProviderInstanceIDs.systemOverview,
                name: "CPU",
                kind: .sensor,
                deviceClass: .percent,
                capability: "system.cpu",
                unit: "%",
                stateClass: .measurement
            ),
            EntityDescriptor(
                id: memoryID,
                instanceID: ProviderInstanceIDs.systemOverview,
                name: "Memory",
                kind: .sensor,
                deviceClass: .percent,
                capability: "system.memory",
                unit: "%",
                stateClass: .measurement
            )
        ]
    }
}
