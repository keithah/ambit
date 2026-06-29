import XCTest
@testable import AmbitCore

final class UserRuleEngineTests: XCTestCase {
    private let cpuID: EntityID = "system@local/overview.cpu_usage_percent"

    func testUserRuleCodableRoundTripsCurrentSchema() throws {
        let rule = cpuNotifyRule(id: "rule.cpu.hot")
        let data = try JSONEncoder().encode(UserRuleDocument(rules: [rule]))
        let decoded = try JSONDecoder().decode(UserRuleDocument.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, UserRule.currentSchemaVersion)
        XCTAssertEqual(decoded.rules, [rule])
    }

    func testUserRuleStorePersistsCreateUpdateDeleteReorderAndSurvivesReload() throws {
        let suite = "UserRuleEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsUserRuleStore(defaults: defaults)
        let first = cpuNotifyRule(id: "rule.first", name: "First")
        let second = cpuNotifyRule(id: "rule.second", name: "Second")

        store.create(first)
        store.create(second)
        XCTAssertEqual(store.load().map(\.id), [first.id, second.id])

        var updated = second
        updated.displayName = "Updated second"
        store.update(updated)
        store.reorder(ids: [second.id, first.id])

        let reloaded = UserDefaultsUserRuleStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.first?.displayName, "Updated second")

        store.delete(id: second.id)
        XCTAssertEqual(store.load().map(\.id), [first.id])
    }

    func testCorruptUserRuleStoreLoadsEmpty() {
        let suite = "UserRuleEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsUserRuleStore.defaultKey)

        XCTAssertEqual(UserDefaultsUserRuleStore(defaults: defaults).load(), [])
    }

    func testMigratesVersionZeroFixtureLosslessly() throws {
        let fixture = LegacyUserRuleDocument(schemaVersion: 0, rules: [
            LegacyUserRule(
                id: "rule.legacy",
                displayName: "Legacy CPU",
                condition: .comparison(Comparison(
                    lhs: .address(cpuID),
                    comparison: .greaterThan,
                    rhs: .literal(.number(90))
                )),
                reactions: [
                    .notify(NotifySpec(
                        titleTemplate: "CPU high",
                        bodyTemplate: "CPU is above 90%.",
                        level: .active,
                        lifecycle: .oneShot
                    ))
                ],
                enabled: true
            )
        ])
        let data = try JSONEncoder().encode(fixture)

        let document = try JSONDecoder().decode(UserRuleDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, UserRule.currentSchemaVersion)
        XCTAssertEqual(document.rules.first?.schemaVersion, UserRule.currentSchemaVersion)
        XCTAssertEqual(document.rules.first?.source, .user)
        XCTAssertEqual(document.rules.first?.displayName, "Legacy CPU")
    }

    func testPlacementShowsNotifyOnlyUnderNotificationsAndNonNotifyAlsoUnderAutomations() {
        let notifyOnly = cpuNotifyRule(id: "rule.notify")
        let automation = UserRule(
            id: "rule.automation",
            displayName: "Automation",
            condition: notifyOnly.condition,
            reactions: notifyOnly.reactions + [
                .runCommand(CommandInvocation(providerID: "fixture", commandID: "test"))
            ],
            enabled: true
        )

        XCTAssertEqual(UserRulePlacement.rules([notifyOnly], for: .notifications), [notifyOnly])
        XCTAssertEqual(UserRulePlacement.rules([notifyOnly], for: .automations), [])
        XCTAssertEqual(UserRulePlacement.rules([automation], for: .notifications), [automation])
        XCTAssertEqual(UserRulePlacement.rules([automation], for: .automations), [automation])
    }

    func testRunnerEvaluatesUserRuleAndDispatchesReaction() async throws {
        let rule = cpuNotifyRule(id: "rule.cpu.hot")
        var runner = UserRuleRunner()
        let input = ConditionEvaluator.Input(states: [
            cpuID: EntityState(id: cpuID, value: .number(95), availability: .online)
        ])

        let results = try await runner.evaluate(
            rules: [rule],
            input: input,
            now: Date(timeIntervalSince1970: 100),
            executor: ReactionExecutor()
        )

        XCTAssertEqual(results.map(\.ruleID), [rule.id])
        XCTAssertEqual(results.map(\.reaction), rule.reactions)
        XCTAssertEqual(results.map(\.executionResult), [.notified(rule.notifySpec)])
    }

    func testUserRuleAndEquivalentBuiltInConditionUseSameDwellUnderIrregularPolling() async throws {
        let declaration = AlertKindDeclaration(
            id: "fixture.cpu.high",
            titleTemplate: "CPU high",
            messageTemplate: "CPU is high.",
            severity: .warning,
            defaultEnabled: true,
            target: .entity(cpuID),
            trigger: .metricThreshold(EntityAlertPolicy(
                enabled: true,
                threshold: AlertThreshold(comparison: .greaterThan, value: 90),
                consecutive: 3,
                cooldown: 60
            )),
            cooldown: 60
        )
        let condition = declaration.compiledCondition(metricEntityID: cpuID)
        let rule = UserRule(
            id: "rule.cpu.high",
            displayName: "CPU high",
            condition: condition,
            reactions: declaration.reactions,
            enabled: true
        )
        var builtInEvaluator = ConditionEvaluator()
        var runner = UserRuleRunner()
        let times = [0.0, 1.7, 7.9, 80.0, 81.0, 90.0].map(Date.init(timeIntervalSince1970:))
        let values = [91.0, 92.0, 93.0, 50.0, 94.0, 95.0]

        var builtInMatches: [Bool] = []
        var userMatches: [Bool] = []
        for (time, value) in zip(times, values) {
            let input = ConditionEvaluator.Input(states: [
                cpuID: EntityState(id: cpuID, value: .number(value), availability: .online)
            ])
            builtInMatches.append(builtInEvaluator.evaluate(condition, input: input, now: time))
            let results = try await runner.evaluate(rules: [rule], input: input, now: time, executor: ReactionExecutor())
            userMatches.append(!results.isEmpty)
        }

        XCTAssertEqual(userMatches, builtInMatches)
        XCTAssertEqual(userMatches, [false, false, true, false, false, false])
    }

    private func cpuNotifyRule(id: UserRuleID, name: String = "CPU hot") -> UserRule {
        UserRule(
            id: id,
            displayName: name,
            condition: .comparison(Comparison(
                lhs: .address(cpuID),
                comparison: .greaterThan,
                rhs: .literal(.number(90))
            )),
            reactions: [
                .notify(NotifySpec(
                    titleTemplate: "CPU high",
                    bodyTemplate: "CPU is above 90%.",
                    level: .active,
                    lifecycle: .oneShot
                ))
            ],
            enabled: true
        )
    }
}

private extension UserRule {
    var notifySpec: NotifySpec {
        guard case .notify(let spec) = reactions.first else {
            fatalError("Expected notify reaction")
        }
        return spec
    }
}

private struct LegacyUserRuleDocument: Codable {
    var schemaVersion: Int
    var rules: [LegacyUserRule]
}

private struct LegacyUserRule: Codable {
    var id: UserRuleID
    var displayName: String
    var condition: Condition
    var reactions: [Reaction]
    var enabled: Bool
}
