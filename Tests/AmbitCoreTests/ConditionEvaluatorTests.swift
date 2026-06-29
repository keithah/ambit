import XCTest
@testable import AmbitCore

final class ConditionEvaluatorTests: XCTestCase {
    private let id = EntityID(rawValue: "fixture.metric")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testComparisonAndBooleanOperatorsEvaluateEntityState() {
        let states: [EntityID: EntityState] = [
            id: EntityState(id: id, value: .number(42), availability: .online)
        ]

        for (comparison, expected) in [
            (AlertComparison.greaterThan, true),
            (.greaterThanOrEqual, true),
            (.lessThan, false),
            (.lessThanOrEqual, false),
            (.equal, true),
            (.notEqual, false)
        ] {
            let condition = Condition.comparison(Comparison(
                lhs: .address(id),
                comparison: comparison,
                rhs: .literal(.number(comparison == .equal || comparison == .notEqual ? 42 : 40))
            ))
            var evaluator = ConditionEvaluator()

            XCTAssertEqual(evaluator.evaluate(condition, input: .init(states: states), now: t0), expected, "\(comparison)")
        }

        var evaluator = ConditionEvaluator()
        let trueCondition = Condition.comparison(Comparison(lhs: .address(id), comparison: .greaterThan, rhs: .literal(.number(10))))
        let falseCondition = Condition.comparison(Comparison(lhs: .address(id), comparison: .lessThan, rhs: .literal(.number(10))))

        XCTAssertTrue(evaluator.evaluate(.all([trueCondition, .not(falseCondition)]), input: .init(states: states), now: t0))
        XCTAssertTrue(evaluator.evaluate(.any([falseCondition, trueCondition]), input: .init(states: states), now: t0))
        XCTAssertFalse(evaluator.evaluate(.all([trueCondition, falseCondition]), input: .init(states: states), now: t0))
    }

    func testTemporalEdgesAndHeldForUseStableState() {
        let condition = Condition.temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(id), comparison: .greaterThanOrEqual, rhs: .literal(.number(10)))),
            op: .heldFor(5),
            edge: .level
        ))
        let states: [EntityID: EntityState] = [
            id: EntityState(id: id, value: .number(12), availability: .online)
        ]
        var evaluator = ConditionEvaluator()

        XCTAssertFalse(evaluator.evaluate(condition, input: .init(states: states), now: t0))
        XCTAssertFalse(evaluator.evaluate(condition, input: .init(states: states), now: t0.addingTimeInterval(4)))
        XCTAssertTrue(evaluator.evaluate(condition, input: .init(states: states), now: t0.addingTimeInterval(5)))

        let edgeBase = Condition.comparison(Comparison(lhs: .address(id), comparison: .greaterThanOrEqual, rhs: .literal(.number(10))))
        let rising = Condition.temporal(Temporal(condition: edgeBase, op: .heldFor(0), edge: .rising))
        let falling = Condition.temporal(Temporal(condition: edgeBase, op: .heldFor(0), edge: .falling))
        var edgeEvaluator = ConditionEvaluator()
        XCTAssertTrue(edgeEvaluator.evaluate(rising, input: .init(states: states), now: t0.addingTimeInterval(6)))
        XCTAssertFalse(edgeEvaluator.evaluate(rising, input: .init(states: states), now: t0.addingTimeInterval(7)))
        XCTAssertFalse(edgeEvaluator.evaluate(falling, input: .init(states: states), now: t0.addingTimeInterval(8)))

        let falseStates: [EntityID: EntityState] = [
            id: EntityState(id: id, value: .number(1), availability: .online)
        ]
        XCTAssertTrue(edgeEvaluator.evaluate(falling, input: .init(states: falseStates), now: t0.addingTimeInterval(9)))
    }

    func testWithinWindowAndRateOfChangeUseHistorySamples() {
        let samples = [
            Sample(timestamp: t0.addingTimeInterval(-20), value: 4, ok: true),
            Sample(timestamp: t0.addingTimeInterval(-5), value: 12, ok: true),
            Sample(timestamp: t0.addingTimeInterval(-1), value: nil, ok: false)
        ]
        var evaluator = ConditionEvaluator()
        let input = ConditionEvaluator.Input(samples: [id: samples])
        let recentlyHigh = Condition.temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(id), comparison: .greaterThan, rhs: .literal(.number(10)))),
            op: .withinWindow(10),
            edge: .level
        ))
        let staleHigh = Condition.temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(id), comparison: .greaterThan, rhs: .literal(.number(10)))),
            op: .withinWindow(2),
            edge: .level
        ))
        let increasingFast = Condition.temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(id), comparison: .greaterThan, rhs: .literal(.number(0)))),
            op: .rateOfChange(per: 15, .greaterThanOrEqual, .number(8)),
            edge: .level
        ))

        XCTAssertTrue(evaluator.evaluate(recentlyHigh, input: input, now: t0))
        XCTAssertFalse(evaluator.evaluate(staleHigh, input: input, now: t0))
        XCTAssertTrue(evaluator.evaluate(increasingFast, input: input, now: t0))
    }

    func testMetricThresholdCompilesToComparisonWrappedInConsecutiveSamples() {
        let policy = EntityAlertPolicy(
            threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250),
            consecutive: 3
        )
        let condition = AlertTriggerDeclaration.metricThreshold(policy).compile(metricEntityID: id, sampleInterval: 2)

        XCTAssertEqual(condition, .temporal(Temporal(
            condition: .comparison(Comparison(lhs: .address(id), comparison: .greaterThanOrEqual, rhs: .literal(.number(250)))),
            op: .consecutiveSamples(3),
            edge: .level
        )))
    }

    func testConsecutiveSamplesMatchesCountBasedSemanticsWithIrregularSamples() {
        let condition = AlertTriggerDeclaration.metricThreshold(EntityAlertPolicy(
            threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250),
            consecutive: 3
        )).compile(metricEntityID: id)
        var evaluator = ConditionEvaluator()

        let first = ConditionEvaluator.Input(states: [id: EntityState(id: id, value: .number(300), availability: .online)])
        let second = ConditionEvaluator.Input(states: [id: EntityState(id: id, value: .number(275), availability: .online)])
        let third = ConditionEvaluator.Input(states: [id: EntityState(id: id, value: .number(260), availability: .online)])
        let reset = ConditionEvaluator.Input(states: [id: EntityState(id: id, value: .number(100), availability: .online)])

        XCTAssertFalse(evaluator.evaluate(condition, input: first, now: t0))
        XCTAssertFalse(evaluator.evaluate(condition, input: second, now: t0.addingTimeInterval(97)))
        XCTAssertTrue(evaluator.evaluate(condition, input: third, now: t0.addingTimeInterval(98)))
        XCTAssertFalse(evaluator.evaluate(condition, input: reset, now: t0.addingTimeInterval(99)))
    }

    func testConditionCodableRoundTrips() throws {
        let condition = Condition.all([
            .comparison(Comparison(lhs: .address(id), comparison: .lessThanOrEqual, rhs: .literal(.duration(60)))),
            .not(.predicate(.connectivityTransition(to: .notConnected))),
            .temporal(Temporal(
                condition: .comparison(Comparison(lhs: .literal(.enumeration("rain")), comparison: .equal, rhs: .literal(.enumeration("rain")))),
                op: .withinWindow(300),
                edge: .falling
            ))
        ])

        let data = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(Condition.self, from: data)

        XCTAssertEqual(decoded, condition)
    }

    func testCompiledTriggersMatchLegacyPredicateTruth() {
        let triggers: [AlertTriggerDeclaration] = [
            .healthTransition(to: .down),
            .diagnosisVerdict(.remoteServiceDown),
            .connectivityTransition(to: .notConnected),
            .allMembersFailing(minimumCount: 2, ratio: 1),
            .metricThreshold(EntityAlertPolicy(threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250), consecutive: 1))
        ]

        for input in triggerInputs() {
            for trigger in triggers {
                var evaluator = ConditionEvaluator()
                XCTAssertEqual(
                    evaluator.evaluate(trigger.compile(metricEntityID: id, sampleInterval: 1), input: input, now: t0),
                    ConditionEvaluator.legacyEvaluate(trigger, input: input),
                    "\(trigger), \(input)"
                )
            }
        }
    }

    func testMonitoringAlertOutputsRemainIdenticalWithCompiledConditionDeclarations() {
        let declarations = PingIntegration.monitoringAlertDeclarations(networkCooldown: 300)
        XCTAssertEqual(declarations.map { $0.compiledCondition(metricEntityID: id) }.count, declarations.count)

        var legacy = MonitoringAlertStateMachine(declarations: declarations, warmUpCycles: 0)
        var compiled = MonitoringAlertStateMachine(declarations: declarations.map { declaration in
            var copy = declaration
            copy.condition = declaration.compiledCondition(metricEntityID: id)
            return copy
        }, warmUpCycles: 0)

        let healthy = alertMember(status: .healthy)
        let down = alertMember(status: .down)
        let healthyDiagnosis = MonitoringDiagnosis(
            perspectiveID: "fixture",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "All reachable"
        )
        let remoteDown = MonitoringDiagnosis(
            perspectiveID: "fixture",
            verdict: MonitoringVerdict(kind: .remoteServiceDown, affectedRole: .remoteService),
            severity: .down,
            confidence: .high,
            affectedEntityIDs: [id],
            title: "Remote down",
            detail: "Remote down"
        )

        let legacyEvents = [
            legacy.evaluate(members: [healthy], diagnosis: healthyDiagnosis, now: t0),
            legacy.evaluate(members: [down], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(1)),
            legacy.evaluate(members: [down], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(2)),
            legacy.evaluate(members: [healthy], diagnosis: remoteDown, now: t0.addingTimeInterval(302)),
            legacy.evaluate(members: [healthy], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(604))
        ].flatMap { $0.map(EventSnapshot.init) }

        let compiledEvents = [
            compiled.evaluate(members: [healthy], diagnosis: healthyDiagnosis, now: t0),
            compiled.evaluate(members: [down], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(1)),
            compiled.evaluate(members: [down], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(2)),
            compiled.evaluate(members: [healthy], diagnosis: remoteDown, now: t0.addingTimeInterval(302)),
            compiled.evaluate(members: [healthy], diagnosis: healthyDiagnosis, now: t0.addingTimeInterval(604))
        ].flatMap { $0.map(EventSnapshot.init) }

        XCTAssertEqual(compiledEvents, legacyEvents)
    }

    func testMonitoringAlertStateMachineConsumesCompiledConditionPath() {
        let impossibleCondition = Condition.comparison(Comparison(lhs: .literal(.bool(false)), comparison: .equal, rhs: .literal(.bool(true))))
        let declaration = AlertKindDeclaration(
            id: "fixture.hostDown",
            titleTemplate: "{hostName} is down",
            messageTemplate: "No response from {hostName}.",
            severity: .critical,
            defaultEnabled: true,
            target: .entity(id),
            trigger: .healthTransition(to: .down),
            condition: impossibleCondition,
            recovery: AlertRecoveryDeclaration(titleTemplate: "{hostName} recovered", messageTemplate: "{hostName} is reachable again."),
            cooldown: 60
        )
        var machine = MonitoringAlertStateMachine(declarations: [declaration], warmUpCycles: 0)

        _ = machine.evaluate(members: [alertMember(status: .healthy)], diagnosis: healthyDiagnosis(), now: t0)
        let events = machine.evaluate(members: [alertMember(status: .down)], diagnosis: healthyDiagnosis(), now: t0.addingTimeInterval(1))

        XCTAssertTrue(events.isEmpty)
    }

    private struct EventSnapshot: Equatable {
        var ruleID: String
        var providerID: String
        var target: AlertTarget?
        var phase: AlertEventPhase
        var title: String
        var message: String
        var severity: Severity

        init(_ event: AlertEvent) {
            ruleID = event.ruleID
            providerID = event.providerID
            target = event.target
            phase = event.phase
            title = event.title
            message = event.message
            severity = event.severity
        }
    }

    private func triggerInputs() -> [ConditionEvaluator.Input] {
        let remoteDown = MonitoringDiagnosis(
            perspectiveID: "fixture",
            verdict: MonitoringVerdict(kind: .remoteServiceDown),
            severity: .down,
            confidence: .high,
            affectedEntityIDs: [id],
            title: "Remote down",
            detail: "Remote down"
        )
        let allReachable = MonitoringDiagnosis(
            perspectiveID: "fixture",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "All reachable"
        )

        return [
            ConditionEvaluator.Input(
                states: [id: EntityState(id: id, value: .number(300), availability: .unavailable, severity: .down)],
                memberStatuses: [id.rawValue: .down],
                diagnosis: remoteDown,
                connectivityStatus: .notConnected,
                totalMemberCount: 2,
                failingMemberCount: 2
            ),
            ConditionEvaluator.Input(
                states: [id: EntityState(id: id, value: .number(24), availability: .online, severity: .normal)],
                memberStatuses: [id.rawValue: .healthy],
                diagnosis: allReachable,
                connectivityStatus: .connected,
                totalMemberCount: 2,
                failingMemberCount: 0
            ),
            ConditionEvaluator.Input(
                states: [id: EntityState(id: id, availability: .stale, severity: .elevated)],
                memberStatuses: [id.rawValue: .degraded],
                diagnosis: nil,
                connectivityStatus: .noInternet,
                totalMemberCount: 3,
                failingMemberCount: 1
            )
        ]
    }

    private func alertMember(status: HealthStatus) -> MonitoringAlertMember {
        MonitoringAlertMember(
            id: id.rawValue,
            name: "Fixture",
            status: status,
            target: .entity(id),
            notifyOnRecovery: true,
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
            detail: "All reachable"
        )
    }
}
