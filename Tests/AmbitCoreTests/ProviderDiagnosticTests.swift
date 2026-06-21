import XCTest
@testable import AmbitCore

final class ProviderDiagnosticTests: XCTestCase {
    func testBuildsStarlinkEndpointDiagnosticFromCommonGrpcFailure() {
        let diagnostic = ProviderDiagnostic.make(
            providerID: ProviderIDs.starlink,
            providerName: "Starlink",
            snapshot: ProviderSnapshot(
                health: .down,
                error: "Failed to dial target host \"192.168.100.1:9200\": context deadline exceeded"
            )
        )

        XCTAssertEqual(diagnostic?.title, "Starlink endpoint unreachable")
        XCTAssertEqual(diagnostic?.message, "Failed to dial target host \"192.168.100.1:9200\": context deadline exceeded")
        XCTAssertEqual(diagnostic?.nextStep, "Confirm the dish is reachable at 192.168.100.1:9200 and that grpcurl is installed.")
    }

    func testBuildsRetryDiagnosticWhenSnapshotCarriesRetryDelay() {
        let diagnostic = ProviderDiagnostic.make(
            providerID: ProviderIDs.router,
            providerName: "GL.iNet",
            snapshot: ProviderSnapshot(
                health: .degraded,
                error: "Router login paused for 1m 30s.",
                retryAfterSeconds: 90
            )
        )

        XCTAssertEqual(diagnostic?.title, "GL.iNet is backing off")
        XCTAssertEqual(diagnostic?.nextStep, "Retry after about 1m 30s, or check the router password if the pause repeats.")
    }

    func testReportIncludesDiagnosisAndNextStepForErrors() {
        let lines = ProviderSnapshotReport.lines(
            providerID: ProviderIDs.ecoflow,
            providerName: "EcoFlow",
            snapshot: ProviderSnapshot(
                health: .down,
                error: "EcoFlow daemon endpoint unresolved."
            )
        )

        XCTAssertEqual(lines, [
            "Provider: EcoFlow (ecoflow)",
            "Health: down",
            "Error: EcoFlow daemon endpoint unresolved.",
            "Diagnosis: EcoFlow daemon unavailable",
            "Next: Enable EcoFlow in settings and confirm the daemon is reachable on http://router-ip:8787.",
            "Metrics: none"
        ])
    }
}
