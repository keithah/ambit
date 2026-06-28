import XCTest
@testable import AmbitCore

final class AlertNotificationServiceTests: XCTestCase {
    func testAuthorizedDeliveryEmitsOneIntentPerResolvedEvent() async {
        let notifier = FakeNotificationDeliverer(status: .authorized)
        let service = AlertNotificationService()
        let event = ResolvedAlertEvent(
            event: AlertEvent(
                id: "alert-1",
                ruleID: "cpu.high",
                providerID: ProviderInstanceIDs.systemOverview.rawValue,
                target: .entity("system@local/overview.cpu_usage_percent"),
                title: "CPU high",
                message: "CPU crossed threshold",
                severity: .elevated,
                triggeredAt: Date(timeIntervalSince1970: 10)
            ),
            entityIDs: ["system@local/overview.cpu_usage_percent"]
        )

        let results = await service.deliver([event], using: notifier)
        let delivered = await notifier.delivered

        XCTAssertEqual(results, [.delivered("alert-1")])
        XCTAssertEqual(delivered, [
            NotificationIntent(
                id: "alert-1",
                title: "CPU high",
                body: "CPU crossed threshold",
                severity: .elevated,
                entityIDs: ["system@local/overview.cpu_usage_percent"],
                phase: .active,
                triggeredAt: Date(timeIntervalSince1970: 10)
            )
        ])
    }

    func testDeniedPermissionSkipsDelivery() async {
        let notifier = FakeNotificationDeliverer(status: .denied)
        let service = AlertNotificationService()
        let event = ResolvedAlertEvent(event: alert(id: "alert-1"), entityIDs: ["entity"])

        let results = await service.deliver([event], using: notifier)

        let delivered = await notifier.deliveredIntents()
        XCTAssertEqual(results, [.skipped("alert-1", reason: .permissionDenied)])
        XCTAssertEqual(delivered, [])
    }

    func testNotDeterminedRequestsAuthorizationBeforeDelivery() async {
        let notifier = FakeNotificationDeliverer(status: .notDetermined, requestedStatus: .authorized)
        let service = AlertNotificationService()
        let event = ResolvedAlertEvent(event: alert(id: "alert-1"), entityIDs: ["entity"])

        let results = await service.deliver([event], using: notifier)

        let requestCount = await notifier.authorizationRequestCount()
        let delivered = await notifier.deliveredIntents()
        XCTAssertEqual(results, [.delivered("alert-1")])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(delivered.count, 1)
    }

    func testRecoveryEventPreservesPhaseAndInfoSeverity() async {
        let notifier = FakeNotificationDeliverer(status: .authorized)
        let service = AlertNotificationService()
        let event = ResolvedAlertEvent(
            event: AlertEvent(
                id: "recovery-1",
                ruleID: "cpu.high",
                providerID: ProviderInstanceIDs.systemOverview.rawValue,
                phase: .recovered,
                title: "CPU recovered",
                message: "Back to normal",
                severity: .info
            ),
            entityIDs: ["entity"]
        )

        _ = await service.deliver([event], using: notifier)

        let delivered = await notifier.deliveredIntents()
        XCTAssertEqual(delivered.first?.phase, .recovered)
        XCTAssertEqual(delivered.first?.severity, .info)
    }

    func testUnresolvedEventIsSkipped() async {
        let notifier = FakeNotificationDeliverer(status: .authorized)
        let service = AlertNotificationService()
        let event = ResolvedAlertEvent(event: alert(id: "alert-1"), entityIDs: [])

        let results = await service.deliver([event], using: notifier)

        let delivered = await notifier.deliveredIntents()
        XCTAssertEqual(results, [.skipped("alert-1", reason: .unresolvedTarget)])
        XCTAssertEqual(delivered, [])
    }

    func testRequestAuthorizationCanBeCalledProactively() async {
        let notifier = FakeNotificationDeliverer(status: .notDetermined, requestedStatus: .authorized)
        let service = AlertNotificationService()

        let status = await service.requestAuthorization(using: notifier)
        let requestCount = await notifier.authorizationRequestCount()

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(requestCount, 1)
    }

    func testTestNotificationIntentUsesGenericBody() {
        let intent = NotificationIntent.testNotification(now: Date(timeIntervalSince1970: 42))

        XCTAssertEqual(intent.id, "notification.test.42")
        XCTAssertEqual(intent.title, "Ambit test notification")
        XCTAssertEqual(intent.entityIDs, Set<EntityID>())
        XCTAssertEqual(intent.phase, .active)
    }

    private func alert(id: String) -> AlertEvent {
        AlertEvent(id: id, ruleID: "rule", providerID: "provider", title: "Title", message: "Body", severity: .elevated)
    }
}

private actor FakeNotificationDeliverer: NotificationDelivering {
    var delivered: [NotificationIntent] = []
    var requestCount = 0
    private var status: NotificationAuthorizationStatus
    private let requestedStatus: NotificationAuthorizationStatus

    init(status: NotificationAuthorizationStatus, requestedStatus: NotificationAuthorizationStatus = .denied) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> NotificationAuthorizationStatus {
        requestCount += 1
        status = requestedStatus
        return status
    }

    func deliver(_ intent: NotificationIntent) async throws {
        delivered.append(intent)
    }

    func deliveredIntents() -> [NotificationIntent] {
        delivered
    }

    func authorizationRequestCount() -> Int {
        requestCount
    }
}
