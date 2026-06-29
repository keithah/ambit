import XCTest
@testable import AmbitCore

final class TopologyDiagnosisEngineTests: XCTestCase {
    func testTopologyDiagnosisMatchesLegacyNetworkDiagnoserAcrossGoldenMatrix() {
        let legacy = NetworkPerspectiveDiagnoser()
        let engine = TopologyDiagnosisEngine()

        for sensitivity in DiagnosisSensitivity.allCases {
            for networkStatus in NetworkConnectivityStatus.allCases {
                for tier in NetworkTier.allCases {
                    for stale in [false, true] {
                        for scenario in DiagnosisHealthScenario.allCases {
                            let hosts = hostsForDiagnosis(tier: tier, scenario: scenario, stale: stale)
                            let legacyDiagnosis = legacy.diagnose(hosts: hosts, networkStatus: networkStatus)
                            let perspective = MonitoringPerspective(
                                id: "test.network",
                                title: "Test Network",
                                members: hosts.map(MonitoringPerspectiveMember.init),
                                linkStatus: networkStatus,
                                sensitivity: sensitivity
                            )
                            let topologyDiagnosis = engine.diagnose(perspective)

                            XCTAssertEqual(
                                TopologyDiagnosisSnapshot(legacyDiagnosis),
                                TopologyDiagnosisSnapshot(topologyDiagnosis),
                                "Mismatch for \(sensitivity.rawValue).\(networkStatus.rawValue).\(tier.rawValue).\(stale ? "stale" : "fresh").\(scenario.rawValue)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testNonPingFixtureProducesTopologyDiagnosisWithoutPingTypes() {
        let engine = TopologyDiagnosisEngine()
        let perspective = MonitoringPerspective(
            id: "fixture.wan",
            title: "Fixture WAN",
            members: [
                MonitoringPerspectiveMember(
                    entityID: "fixture@local/wan.status",
                    instanceID: "fixture@local",
                    displayName: "Fixture WAN",
                    role: .upstreamInternet,
                    status: .down,
                    isStale: false,
                    consecutiveFailures: 3
                )
            ],
            linkStatus: .connected,
            sensitivity: .balanced
        )

        let diagnosis = engine.diagnose(perspective)

        XCTAssertEqual(diagnosis.title, "Internet unreachable")
        XCTAssertEqual(diagnosis.verdict.kind, .upstreamDown)
        XCTAssertEqual(diagnosis.affectedEntityIDs, ["fixture@local/wan.status"])
        XCTAssertEqual(diagnosis.evidence.map(\.role), [.upstreamInternet])
    }
}

private enum DiagnosisHealthScenario: String, CaseIterable {
    case healthySingle
    case degradedSingle
    case downSingle
    case downMixed
    case noDataSingle
}

private struct TopologyDiagnosisSnapshot: Equatable {
    var title: String
    var detail: String
    var severity: Severity?
    var confidence: String
    var affectedEntityIDs: [String]
    var verdictKind: String
    var evidence: [EvidenceSnapshot]

    init(_ diagnosis: NetworkPerspectiveDiagnosis) {
        title = diagnosis.title
        detail = diagnosis.detail
        severity = Self.severity(for: diagnosis.verdict)
        confidence = diagnosis.confidence.rawValue
        affectedEntityIDs = diagnosis.affectedHostIDs
        verdictKind = Self.kind(for: diagnosis.verdict)
        evidence = diagnosis.tierEvidence.map(EvidenceSnapshot.init)
    }

    init(_ diagnosis: MonitoringDiagnosis) {
        title = diagnosis.title
        detail = diagnosis.detail
        severity = diagnosis.severity
        confidence = diagnosis.confidence.rawValue
        affectedEntityIDs = diagnosis.affectedEntityIDs.map(\.rawValue)
        verdictKind = diagnosis.verdict.kind.rawValue
        evidence = diagnosis.evidence.map(EvidenceSnapshot.init)
    }

    private static func kind(for verdict: NetworkPerspectiveDiagnosis.Verdict) -> String {
        switch verdict {
        case .noData: return "noData"
        case .monitoringStalled: return "monitoringStalled"
        case .allReachable: return "allReachable"
        case .localNetworkDown: return "localNetworkDown"
        case .ispPathDown: return "accessNetworkDown"
        case .upstreamDown: return "upstreamDown"
        case .remoteServiceDown: return "remoteServiceDown"
        case .partialDegradation: return "partialDegradation"
        }
    }

    private static func severity(for verdict: NetworkPerspectiveDiagnosis.Verdict) -> Severity? {
        switch verdict {
        case .allReachable, .noData: return .normal
        case .monitoringStalled: return .elevated
        case .partialDegradation: return .degraded
        case .localNetworkDown, .ispPathDown, .upstreamDown: return .down
        case .remoteServiceDown: return .alerting
        }
    }
}

private struct EvidenceSnapshot: Equatable {
    var role: String
    var total: Int
    var healthy: Int
    var degraded: Int
    var down: Int
    var status: String
    var summary: String

    init(_ evidence: NetworkPerspectiveDiagnosis.TierEvidence) {
        role = MonitoringRole(tier: evidence.tier).rawValue
        total = evidence.total
        healthy = evidence.healthy
        degraded = evidence.degraded
        down = evidence.down
        status = String(describing: evidence.status)
        summary = evidence.summary
    }

    init(_ evidence: MonitoringEvidence) {
        role = evidence.role.rawValue
        total = evidence.total
        healthy = evidence.healthy
        degraded = evidence.degraded
        down = evidence.down
        status = String(describing: evidence.status)
        summary = evidence.summary
    }
}

private extension MonitoringPerspectiveMember {
    init(_ host: DiagnosisHost) {
        self.init(
            entityID: EntityID(rawValue: host.id),
            instanceID: IntegrationInstanceID(rawValue: host.id),
            displayName: host.id,
            role: MonitoringRole(tier: host.tier),
            status: host.status,
            isStale: host.isStale,
            consecutiveFailures: host.consecutiveFailures
        )
    }
}

private extension MonitoringRole {
    init(tier: NetworkTier) {
        switch tier {
        case .localGateway: self = .localGateway
        case .ispEdge: self = .accessNetwork
        case .upstream: self = .upstreamInternet
        case .remoteService: self = .remoteService
        }
    }
}

private func hostsForDiagnosis(tier: NetworkTier, scenario: DiagnosisHealthScenario, stale: Bool) -> [DiagnosisHost] {
    var hosts = NetworkTier.allCases
        .filter { $0.depth < tier.depth }
        .map { DiagnosisHost(id: "\($0.rawValue).healthy", tier: $0, status: .healthy) }
    let id = "\(tier.rawValue).primary"
    switch scenario {
    case .healthySingle:
        hosts.append(DiagnosisHost(id: id, tier: tier, status: .healthy, consecutiveFailures: 0, isStale: stale))
    case .degradedSingle:
        hosts.append(DiagnosisHost(id: id, tier: tier, status: .degraded, consecutiveFailures: 1, isStale: stale))
    case .downSingle:
        hosts.append(DiagnosisHost(id: id, tier: tier, status: .down, consecutiveFailures: 3, isStale: stale))
    case .downMixed:
        hosts.append(DiagnosisHost(id: id, tier: tier, status: .down, consecutiveFailures: 3, isStale: stale))
        hosts.append(DiagnosisHost(id: "\(tier.rawValue).peer", tier: tier, status: .healthy, consecutiveFailures: 0, isStale: stale))
    case .noDataSingle:
        hosts.append(DiagnosisHost(id: id, tier: tier, status: .noData, consecutiveFailures: 0, isStale: stale))
    }
    return hosts
}
