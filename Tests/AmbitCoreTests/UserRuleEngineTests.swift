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

    func testRunnerHonorsNotifyLifecycleEdges() async throws {
        let oneShot = cpuNotifyRule(id: "rule.cpu.oneshot")
        let boundSpec = NotifySpec(
            titleTemplate: "CPU high persistent",
            level: .active,
            lifecycle: .boundToCondition
        )
        let bound = UserRule(
            id: "rule.cpu.bound",
            displayName: "CPU high persistent",
            condition: oneShot.condition,
            reactions: [.notify(boundSpec)],
            enabled: true,
            cooldown: 60
        )
        var runner = UserRuleRunner()
        let high = ConditionEvaluator.Input(states: [
            cpuID: EntityState(id: cpuID, value: .number(95), availability: .online)
        ])
        let low = ConditionEvaluator.Input(states: [
            cpuID: EntityState(id: cpuID, value: .number(50), availability: .online)
        ])

        let first = try await runner.evaluate(rules: [oneShot, bound], input: high, now: Date(timeIntervalSince1970: 0), executor: ReactionExecutor())
        let sustained = try await runner.evaluate(rules: [oneShot, bound], input: high, now: Date(timeIntervalSince1970: 10), executor: ReactionExecutor())
        let falling = try await runner.evaluate(rules: [oneShot, bound], input: low, now: Date(timeIntervalSince1970: 20), executor: ReactionExecutor())

        XCTAssertEqual(first.map(\.executionResult), [.notified(oneShot.notifySpec), .notified(boundSpec)])
        XCTAssertTrue(sustained.isEmpty)
        XCTAssertEqual(falling.map(\.executionResult), [.notificationCleared(boundSpec)])
    }

    func testUserRuleAndEquivalentBuiltInPathShareDwellCooldownAndSleepWakeBehavior() async throws {
        let memberID = "fixture-host"
        let target: AlertTarget = .entity("fixture-host/status")
        let declaration = AlertKindDeclaration(
            id: "fixture.hostDown",
            titleTemplate: "{hostName} is down",
            messageTemplate: "No response from {hostName}.",
            severity: .critical,
            defaultEnabled: true,
            target: target,
            trigger: .healthTransition(to: .down),
            condition: .temporal(Temporal(
                condition: .predicate(.healthTransition(to: .down)),
                op: .consecutiveSamples(3),
                edge: .level
            )),
            recovery: AlertRecoveryDeclaration(
                titleTemplate: "{hostName} recovered",
                messageTemplate: "{hostName} is reachable again."
            ),
            cooldown: 60
        )
        let rule = UserRule(
            id: "rule.host.down",
            displayName: "Fixture down",
            condition: declaration.compiledCondition(),
            reactions: declaration.reactions,
            enabled: true,
            cooldown: declaration.cooldown
        )
        var machine = MonitoringAlertStateMachine(declarations: [declaration], warmUpCycles: 0)
        var runner = UserRuleRunner()
        let timeline: [(TimeInterval, HealthStatus)] = [
            (0.0, .healthy),
            (1.3, .down),
            (5.8, .down),
            (19.4, .down),
            (25.0, .down),
            (1_000.0, .down),
            (1_001.0, .healthy),
            (1_010.0, .down),
            (1_011.2, .down),
            (1_100.0, .down)
        ]

        var builtInPhases: [[AlertEventPhase]] = []
        var userResults: [[ReactionExecutionResult]] = []
        for (offset, status) in timeline {
            let now = Date(timeIntervalSince1970: offset)
            let member = MonitoringAlertMember(
                id: memberID,
                name: "Fixture",
                status: status,
                target: target,
                notifyOnRecovery: true,
                cooldown: declaration.cooldown
            )
            let builtIn = machine.evaluate(members: [member], diagnosis: healthyDiagnosis(), now: now)
            let input = ConditionEvaluator.Input(
                memberStatuses: [memberID: status],
                totalMemberCount: 1,
                failingMemberCount: status == .down ? 1 : 0
            )
            let user = try await runner.evaluate(rules: [rule], input: input, now: now, executor: ReactionExecutor())
            builtInPhases.append(builtIn.map(\.phase))
            userResults.append(user.map(\.executionResult))
        }

        XCTAssertEqual(builtInPhases, [
            [],
            [],
            [],
            [.active],
            [],
            [],
            [.recovered],
            [],
            [],
            [.active]
        ])
        XCTAssertEqual(userResults, [
            [],
            [],
            [],
            [.notified(rule.notifySpec)],
            [],
            [],
            [.notificationCleared(rule.notifySpec)],
            [],
            [],
            [.notified(rule.notifySpec)]
        ])
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
            enabled: true,
            cooldown: 60
        )
    }

    private func healthyDiagnosis() -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "fixture",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "All monitored endpoints are reachable."
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
