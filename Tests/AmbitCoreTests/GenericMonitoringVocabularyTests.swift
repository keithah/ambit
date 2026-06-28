import XCTest
@testable import AmbitCore

final class GenericMonitoringVocabularyTests: XCTestCase {
    func testPingDescriptorPopulatesMonitoringMetadataWithoutChangingPresentationDefaults() {
        let host = PingHostConfig(
            displayName: "Gateway",
            address: "192.168.8.1",
            method: .icmp
        )
        let provider = PingProvider(
            host: host,
            integrationInstanceID: "ping@gateway"
        )
        let descriptor = provider.entityDescriptors().first { $0.metricID == "latency_ms" }

        XCTAssertEqual(descriptor?.monitoring?.role, .localGateway)
        XCTAssertEqual(descriptor?.monitoring?.address?.scope, .privateNetwork)
        XCTAssertEqual(descriptor?.monitoring?.roleAssignment?.source, .addressClassifier)
        XCTAssertEqual(descriptor?.defaultVisibility, .auto)
        XCTAssertEqual(descriptor?.metricID, "latency_ms")
        XCTAssertTrue(descriptor?.isPrimary == true)
    }

    func testAddressClassifierCoversLoopbackLinkLocalPrivatePublicAndHostname() {
        XCTAssertEqual(AddressClassifier.scope(for: "127.0.0.1"), .loopback)
        XCTAssertEqual(AddressClassifier.scope(for: "::1"), .loopback)
        XCTAssertEqual(AddressClassifier.scope(for: "localhost"), .loopback)
        XCTAssertEqual(AddressClassifier.scope(for: "169.254.1.20"), .linkLocal)
        XCTAssertEqual(AddressClassifier.scope(for: "192.168.8.1"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(for: "10.0.0.1"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(for: "172.16.0.1"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(for: "1.1.1.1"), .publicInternet)
        XCTAssertEqual(AddressClassifier.scope(for: "example.com"), .hostname)

        XCTAssertEqual(AddressClassifier.derivedRole(for: "192.168.8.1"), .localGateway)
        XCTAssertEqual(AddressClassifier.derivedRole(for: "1.1.1.1"), .upstreamInternet)
        XCTAssertEqual(AddressClassifier.derivedRole(for: "example.com"), .remoteService)
    }

    func testAlertTemplateRendererReproducesCurrentNotificationCopy() {
        let context = AlertTemplateContext(
            hostName: "Cloudflare DNS",
            entityName: "Gateway",
            affectedCount: 1,
            totalCount: 2,
            moreCount: 1,
            roleName: "gateway",
            gatewayOld: "192.168.101.1",
            gatewayNew: "192.168.8.1",
            statusOld: "notConnected",
            statusNew: "connected"
        )

        XCTAssertEqual(AlertTemplateRenderer.render("{hostName} is down", context: context), "Cloudflare DNS is down")
        XCTAssertEqual(AlertTemplateRenderer.render("No response from {hostName}.", context: context), "No response from Cloudflare DNS.")
        XCTAssertEqual(AlertTemplateRenderer.render("{hostName} recovered", context: context), "Cloudflare DNS recovered")
        XCTAssertEqual(AlertTemplateRenderer.render("{hostName} is reachable again.", context: context), "Cloudflare DNS is reachable again.")
        XCTAssertEqual(AlertTemplateRenderer.render("{affectedCount}/{totalCount} gateway host(s) unreachable.", context: context), "1/2 gateway host(s) unreachable.")
        XCTAssertEqual(AlertTemplateRenderer.render("No response from Cloudflare DNS, Google DNS, +{moreCount} more host(s).", context: context), "No response from Cloudflare DNS, Google DNS, +1 more host(s).")
        XCTAssertEqual(AlertTemplateRenderer.render("{affectedCount}/{totalCount} monitored hosts are unreachable.", context: context), "1/2 monitored hosts are unreachable.")
        XCTAssertEqual(AlertTemplateRenderer.render("The system network path is connected again.", context: context), "The system network path is connected again.")
        XCTAssertEqual(AlertTemplateRenderer.render("Gateway changed from {gatewayOld} to {gatewayNew}.", context: context), "Gateway changed from 192.168.101.1 to 192.168.8.1.")
    }

    func testMinimalNonPingFixtureIntegrationDeclaresPerspectiveAndAlertKindThroughRealProtocol() {
        let integration = MonitoringFixtureIntegration()
        let instance = IntegrationInstanceRecord(
            id: "fixture@wan",
            integrationID: integration.id,
            displayName: "Fixture WAN",
            enabled: true
        )
        let descriptor = integration.fixtureDescriptor(instance: instance)
        let states = [
            descriptor.id: EntityState(
                id: descriptor.id,
                value: .bool(false),
                availability: .online,
                severity: .down
            )
        ]

        let perspectives = integration.monitoringPerspectives(
            instance: instance,
            descriptors: [descriptor],
            states: states
        )
        let declarations = integration.alertKindDeclarations(instance: instance)

        XCTAssertEqual(perspectives.map(\.id.rawValue), ["fixture.wan"])
        XCTAssertEqual(perspectives.first?.members.map(\.role), [.accessNetwork])
        XCTAssertEqual(perspectives.first?.members.map(\.entityID), [descriptor.id])
        XCTAssertEqual(declarations.map(\.id.rawValue), ["fixture.wanDown"])
        XCTAssertEqual(declarations.first?.target, .entity(descriptor.id))
        XCTAssertEqual(declarations.first?.severity, .down)
    }
}

private struct MonitoringFixtureIntegration: Integration {
    let id: IntegrationID = "fixture-monitor"
    let displayName = "Fixture Monitor"

    func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] { [] }

    func fixtureDescriptor(instance: IntegrationInstanceRecord) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "\(instance.id.rawValue)/wan.connected"),
            instanceID: ProviderInstanceID(rawValue: "\(instance.id.rawValue)/wan"),
            name: "WAN Connected",
            kind: .binarySensor,
            deviceClass: .connectivity,
            category: .primary,
            capability: "network.connectivity",
            stateClass: .measurement,
            defaultVisibility: .auto,
            isPrimary: true,
            monitoring: MonitoringMetadata(
                role: .accessNetwork,
                perspectiveID: "fixture.wan",
                alertKindIDs: ["fixture.wanDown"],
                diagnosticSummary: .member,
                address: MonitoredAddress(rawValue: "203.0.113.1"),
                roleAssignment: MonitoringRoleAssignment(
                    explicitRole: .accessNetwork,
                    derivedRole: .upstreamInternet,
                    source: .explicit
                )
            )
        )
    }

    func monitoringPerspectives(
        instance: IntegrationInstanceRecord,
        descriptors: [EntityDescriptor],
        states: [EntityID: EntityState]
    ) -> [MonitoringPerspective] {
        descriptors.compactMap { descriptor -> MonitoringPerspective? in
            guard let metadata = descriptor.monitoring, let role = metadata.role else { return nil }
            let state = states[descriptor.id]
            return MonitoringPerspective(
                id: metadata.perspectiveID ?? "fixture.wan",
                title: "Fixture WAN",
                members: [
                    MonitoringPerspectiveMember(
                        entityID: descriptor.id,
                        instanceID: instance.id,
                        displayName: descriptor.name,
                        role: role,
                        status: Self.healthStatus(for: state),
                        isStale: state?.availability == .stale,
                        consecutiveFailures: state?.severity == .down ? 1 : 0
                    )
                ],
                linkStatus: .connected,
                sensitivity: .balanced
            )
        }
    }

    func alertKindDeclarations(instance: IntegrationInstanceRecord) -> [AlertKindDeclaration] {
        [
            AlertKindDeclaration(
                id: "fixture.wanDown",
                titleTemplate: "{entityName} is down",
                messageTemplate: "No response from {entityName}.",
                severity: .down,
                defaultEnabled: true,
                target: .entity(EntityID(rawValue: "\(instance.id.rawValue)/wan.connected")),
                trigger: .healthTransition(to: .down),
                recovery: AlertRecoveryDeclaration(
                    titleTemplate: "{entityName} recovered",
                    messageTemplate: "{entityName} is reachable again."
                ),
                cooldown: 300
            )
        ]
    }

    private static func healthStatus(for state: EntityState?) -> HealthStatus {
        guard let state else { return .noData }
        switch state.severity {
        case .down, .alerting:
            return .down
        case .degraded:
            return .degraded
        default:
            return state.availability == .online ? .healthy : .noData
        }
    }
}
