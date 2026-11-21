import Foundation
import Testing
@testable import AmbitKit

private func stats(ms: Double? = 10, loss: Double = 0, failures: Int = 0, count: Int = 12) -> HopStats {
    HopStats(sampleCount: count, medianMs: ms, lastMs: ms, lossFraction: loss, consecutiveFailures: failures)
}

@Suite struct VerdictTests {
    @Test func noGatewayMeansNoNetwork() {
        #expect(diagnose(hasGateway: false, router: .empty, internet: .empty, dns: .empty) == .noNetwork)
    }

    @Test func noSamplesMeansChecking() {
        #expect(diagnose(hasGateway: true, router: .empty, internet: .empty, dns: .empty) == .checking)
    }

    @Test func allHealthyIsOnline() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 3), internet: stats(ms: 38), dns: stats()) == .online)
    }

    @Test func routerAndInternetDownBlamesRouter() {
        let down = stats(ms: nil, loss: 1, failures: 5)
        #expect(diagnose(hasGateway: true, router: down, internet: down, dns: down) == .routerUnreachable)
    }

    @Test func routerIgnoringPingsIsNotBlamedWhenInternetWorks() {
        let down = stats(ms: nil, loss: 1, failures: 5)
        #expect(diagnose(hasGateway: true, router: down, internet: stats(ms: 40), dns: stats()) == .online)
    }

    @Test func internetDownWithHealthyRouterBlamesProvider() {
        let down = stats(ms: nil, loss: 1, failures: 3)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: down, dns: down) == .internetDown)
    }

    @Test func twoFailuresIsNotYetDown() {
        let flaky = stats(ms: 40, loss: 0.16, failures: 2)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: flaky, dns: stats()) == .online)
    }

    @Test func dnsOnlyFailure() {
        let down = stats(ms: nil, loss: 1, failures: 4)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: stats(ms: 40), dns: down) == .dnsFailing)
    }

    @Test func slowRouterBlamesWiFi() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 120), internet: stats(ms: 160), dns: stats()) == .wifiSlow)
    }

    @Test func lossyRouterBlamesWiFi() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 5, loss: 0.3), internet: stats(ms: 40), dns: stats()) == .wifiSlow)
    }

    @Test func slowInternetWithFastRouterBlamesProvider() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: stats(ms: 400), dns: stats()) == .internetSlow)
    }

    @Test func oneEarlyFailureIsNotLoss() {
        let first = stats(ms: nil, loss: 1, failures: 1, count: 1)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4, count: 1), internet: first, dns: first) == .online)
    }

    @Test func lossyInternetBlamesProvider() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: stats(ms: 40, loss: 0.3), dns: stats()) == .internetSlow)
    }

    @Test func everyVerdictHasCopy() {
        for verdict in Verdict.allCases {
            #expect(!verdict.title.isEmpty)
            #expect(verdict.detail.hasSuffix("."))
        }
    }
}

@Suite struct HopStatsTests {
    @Test func computesMedianLossAndTrailingFailures() {
        let samples = [
            ProbeSample(latencyMs: 10), ProbeSample(latencyMs: 30), ProbeSample(latencyMs: 20),
            ProbeSample(failure: .timeout), ProbeSample(failure: .timeout),
        ]
        let stats = HopStats(samples: samples)
        #expect(stats.sampleCount == 5)
        #expect(stats.medianMs == 20)
        #expect(stats.lastMs == nil)
        #expect(stats.lossFraction == 0.4)
        #expect(stats.consecutiveFailures == 2)
    }

    @Test func onlyUsesTheWindow() {
        let old = Array(repeating: ProbeSample(failure: .timeout), count: 20)
        let recent = Array(repeating: ProbeSample(latencyMs: 5), count: 12)
        let stats = HopStats(samples: old + recent, window: 12)
        #expect(stats.lossFraction == 0)
        #expect(stats.consecutiveFailures == 0)
    }
}

@Suite struct ProbeParsingTests {
    @Test func parsesPingLatency() {
        let output = "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms\n"
        #expect(ICMPProbe.parseLatencyMs(output) == 12.345)
        #expect(ICMPProbe.parseLatencyMs("Request timeout for icmp_seq 0") == nil)
    }

    @Test func classifiesPingFailures() {
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 68, stdout: "", stderr: "ping: cannot resolve nope: Unknown host")) == .dns)
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 2, stdout: "", stderr: "ping: sendto: No route to host")) == .unreachable)
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 2, stdout: "", stderr: "")) == .timeout)
    }

    @Test func rejectsHostsThatLookLikeOptions() {
        #expect(ProbeTarget.isValidHost("192.168.8.1"))
        #expect(ProbeTarget.isValidHost("fe80::1"))
        #expect(ProbeTarget.isValidHost("example.com"))
        #expect(!ProbeTarget.isValidHost("-f"))
        #expect(!ProbeTarget.isValidHost(""))
        #expect(!ProbeTarget.isValidHost("a b"))
        #expect(!ProbeTarget.isValidHost("host;rm"))
    }

    @Test func icmpProbeRefusesInvalidHostWithoutRunningAnything() async {
        let sample = await ICMPProbe(runner: FailingRunner()).measure(ProbeTarget(host: "-c 9999"))
        #expect(sample.failure == .invalidTarget)
    }

    @Test func parsesDefaultGateway() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.8.1
          interface: en0
        """
        #expect(RouteGatewayFinder.parseGateway(output) == "192.168.8.1")
        #expect(RouteGatewayFinder.parseGateway("route: writing to routing socket: not in table") == nil)
    }
}

private struct FailingRunner: ProcessRunner {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        Issue.record("process must not run for an invalid host")
        return ProcessResult(exitCode: 1, stdout: "", stderr: "")
    }
}

private struct FixedProbe: Probe {
    var sample: ProbeSample
    func measure(_ target: ProbeTarget) async -> ProbeSample { sample }
}

private struct FixedGateway: GatewayFinding {
    var address: String?
    func defaultGateway() async -> String? { address }
}

@Suite struct DiagnosisMonitorTests {
    @Test func reportsProviderDownAfterThreeFailedCycles() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: "192.168.8.1"),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(failure: .timeout)),
            dns: FixedProbe(sample: ProbeSample(failure: .dns))
        )
        var snapshot = await monitor.runCycle()
        #expect(snapshot.verdict == .online)
        snapshot = await monitor.runCycle()
        snapshot = await monitor.runCycle()
        #expect(snapshot.verdict == .internetDown)
        #expect(snapshot.gateway == "192.168.8.1")
        #expect(snapshot.internetHistory.count == 3)
    }

    @Test func noGatewayIsNoNetwork() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: nil),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(failure: .unreachable)),
            dns: FixedProbe(sample: ProbeSample(failure: .dns))
        )
        #expect(await monitor.runCycle().verdict == .noNetwork)
    }
}

@Suite struct ConnectionAlertsTests {
    @Test func alertsOnceAfterSustainedOutageThenOnRecovery() {
        var alerts = ConnectionAlerts(offlineAfter: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(alerts.evaluate(verdict: .online, now: start) == nil)
        #expect(alerts.evaluate(verdict: .internetDown, now: start.addingTimeInterval(5)) == nil)
        #expect(alerts.evaluate(verdict: .internetDown, now: start.addingTimeInterval(20)) == nil)
        let offline = alerts.evaluate(verdict: .internetDown, now: start.addingTimeInterval(36))
        #expect(offline?.title == "Your internet provider is down")
        #expect(alerts.evaluate(verdict: .internetDown, now: start.addingTimeInterval(60)) == nil)
        let back = alerts.evaluate(verdict: .online, now: start.addingTimeInterval(125))
        #expect(back == AlertMessage(title: "Back online", body: "The outage lasted 2 min."))
        #expect(alerts.evaluate(verdict: .online, now: start.addingTimeInterval(130)) == nil)
    }

    @Test func shortBlipIsSilent() {
        var alerts = ConnectionAlerts(offlineAfter: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(alerts.evaluate(verdict: .routerUnreachable, now: start) == nil)
        #expect(alerts.evaluate(verdict: .online, now: start.addingTimeInterval(10)) == nil)
    }
}
