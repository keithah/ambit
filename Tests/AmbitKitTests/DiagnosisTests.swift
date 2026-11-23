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

    @Test func internetThatHasNeverAnsweredIsNotOnline() {
        let first = stats(ms: nil, loss: 1, failures: 1, count: 1)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4, count: 1), internet: first, dns: first) == .checking)
    }

    @Test func oneEarlyFailureAfterASuccessIsNotLoss() {
        let early = stats(ms: 40, loss: 0.5, failures: 1, count: 2)
        #expect(diagnose(hasGateway: true, router: stats(ms: 4, count: 2), internet: early, dns: stats()) == .online)
    }

    @Test func lossyInternetBlamesProvider() {
        #expect(diagnose(hasGateway: true, router: stats(ms: 4), internet: stats(ms: 40, loss: 0.3), dns: stats()) == .internetSlow)
    }

    @Test func silentRouterIsNeverBlamed() {
        let down = stats(ms: nil, loss: 1, failures: 5)
        #expect(diagnose(hasGateway: true, routerHasAnswered: false, router: down, internet: down, dns: down) == .connectionDown)
    }

    @Test func nothingAnsweredYetKeepsChecking() {
        let first = stats(ms: nil, loss: 1, failures: 1, count: 1)
        #expect(diagnose(hasGateway: true, router: first, internet: first, dns: first) == .checking)
    }

    @Test func workingInternetWithoutGatewayIsNotNoNetwork() {
        #expect(diagnose(hasGateway: false, router: .empty, internet: stats(ms: 30), dns: stats()) == .online)
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

    @Test func evenCountMedianAveragesTheMiddlePair() {
        let stats = HopStats(samples: [ProbeSample(latencyMs: 20), ProbeSample(latencyMs: 90)])
        #expect(stats.medianMs == 55)
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

    @Test func readsTheAddressAPingWasAnsweredFrom() {
        #expect(ICMPProbe.parseAnsweringAddress("PING one.one.one.one (1.1.1.1): 56 data bytes\n64 bytes from 1.0.0.1: icmp_seq=0 ttl=57 time=12.345 ms\n") == "1.0.0.1")
        #expect(ICMPProbe.parseAnsweringAddress("Request timeout for icmp_seq 0") == nil)
    }

    @Test func onlyPublicAddressesAreOnTheInternet() {
        for address in ["1.1.1.1", "9.9.9.9", "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.167.1.1", "223.255.255.1"] {
            #expect(ProbeTarget.isOnTheInternet(ipv4: address), "\(address)")
        }
        for address in ["10.0.0.2", "192.168.8.1", "192.168.100.1", "172.16.0.1", "172.31.255.1", "127.0.0.1", "169.254.1.1",
                        "100.64.0.1", "100.127.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
                        "", "1.1.1", "1.1.1.1.1", "1.1.1.256", "a.b.c.d", "1.1.1.-1", "2606:4700::1111", "example.com"] {
            #expect(!ProbeTarget.isOnTheInternet(ipv4: address), "\(address)")
        }
    }

    @Test func classifiesPingFailures() {
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 68, stdout: "", stderr: "ping: cannot resolve nope: Unknown host")) == .dns)
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 2, stdout: "", stderr: "ping: sendto: No route to host")) == .unreachable)
        #expect(ICMPProbe.classify(ProcessResult(exitCode: 2, stdout: "", stderr: "")) == .timeout)
    }

    @Test func rejectsHostsThatLookLikeOptions() {
        #expect(ProbeTarget.isValidHost("192.168.8.1"))
        #expect(ProbeTarget.isValidHost("fe80::1"))
        for target in DiagnosisConfig().internetTargets { #expect(ProbeTarget.isValidHost(target.host)) }
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

/// Holds probes until opened, and reports when the first probe has arrived.
private actor Gate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct GatedProbe: Probe {
    let gate: Gate
    func measure(_ target: ProbeTarget) async -> ProbeSample {
        await gate.pass()
        return ProbeSample(latencyMs: 30)
    }
}

/// Returns a gateway for the first `successes` lookups, then fails every lookup.
private actor FailingAfter: GatewayFinding {
    struct Failure: Error {}
    private var remaining: Int
    init(successes: Int) { remaining = successes }
    func defaultGateway() async throws -> String? {
        guard remaining > 0 else { throw Failure() }
        remaining -= 1
        return "192.168.8.1"
    }
}

private struct FixedGateway: GatewayFinding {
    var address: String?
    func defaultGateway() async -> String? { address }
}

private actor SwitchingGateway: GatewayFinding {
    private var address: String? = "192.168.8.1"
    func set(_ value: String?) { address = value }
    func defaultGateway() async -> String? { address }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesAllOutputAndExitCode() async throws {
        let result = try await SystemProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "seq 1 20000; echo done >&2; exit 3"], timeout: 10
        )
        #expect(result.exitCode == 3)
        #expect(result.stdout.split(separator: "\n").count == 20000)
        #expect(result.stderr == "done\n")
    }

    @Test func timesOutAndKillsAChildThatIgnoresTerm() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ambit-test-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // `exec` keeps one process, so the PID written is the one that ignores SIGTERM.
        await #expect(throws: ProcessTimedOut.self) {
            _ = try await SystemProcessRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo $$ > \"$0\"; exec sleep 30", pidFile.path],
                timeout: 0.3
            )
        }
        let pid = try #require(pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(kill(pid, 0) != 0, "child should have been killed after ignoring SIGTERM")
    }
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
        #expect(snapshot.verdict == .checking)
        snapshot = await monitor.runCycle()
        snapshot = await monitor.runCycle()
        #expect(snapshot.verdict == .internetDown)
        #expect(snapshot.gateway == "192.168.8.1")
        #expect(snapshot.internetHistory.count == 3)
    }

    @Test func earlierSamplesGoOnTheGraphButNotIntoTheVerdict() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: "192.168.8.1"),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(latencyMs: 20)),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        let earlier = (0..<4).map { ProbeSample(date: Date(timeIntervalSinceNow: -600 + Double($0)), failure: .timeout) }
        await monitor.seed(history: earlier)
        let snapshot = await monitor.runCycle()
        #expect(snapshot.internetHistory.count == 5)
        #expect(snapshot.cycles == 1)
        #expect(snapshot.internetHistory.first == earlier.first)
        #expect(snapshot.internet.sampleCount == 1)
        #expect(snapshot.verdict == .online)
        // Once there are samples, seeding again changes nothing.
        await monitor.seed(history: earlier)
        #expect(await monitor.runCycle().internetHistory.count == 6)
    }

    @Test func aPingTargetOnTheInternetThatAnswersShowsTheInternetIsReachable() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: "192.168.8.1"),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(failure: .timeout)),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        func answer(from address: String?, age: TimeInterval = 0) -> ProbeSample {
            var sample = ProbeSample(date: Date(timeIntervalSinceNow: -age), latencyMs: 40)
            sample.answeredFrom = address
            return sample
        }
        // Nothing reported: the built-in targets fail.
        #expect(await monitor.runCycle().internet.lastMs == nil)
        // An answer from a local address, or from an unknown one, shows nothing.
        await monitor.report(answer(from: "192.168.8.20"), fromTarget: "nas")
        await monitor.report(answer(from: nil), fromTarget: "unknown")
        #expect(await monitor.runCycle().internet.lastMs == nil)
        // An answer from the internet counts.
        await monitor.report(answer(from: "9.9.9.9"), fromTarget: "quad9")
        #expect(await monitor.runCycle().internet.lastMs == 40)
        // An old answer does not.
        await monitor.report(answer(from: "9.9.9.9", age: 60), fromTarget: "quad9")
        #expect(await monitor.runCycle().internet.lastMs == nil)
        // Neither does a target that stopped answering, or one that was removed.
        await monitor.report(answer(from: "9.9.9.9"), fromTarget: "quad9")
        await monitor.report(ProbeSample(failure: .timeout), fromTarget: "quad9")
        #expect(await monitor.runCycle().internet.lastMs == nil)
        await monitor.report(answer(from: "9.9.9.9"), fromTarget: "quad9")
        await monitor.forget(target: "quad9")
        #expect(await monitor.runCycle().internet.lastMs == nil)
    }

    @Test func aPingTargetDoesNotReplaceABuiltInAnswer() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: "192.168.8.1"),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(latencyMs: 80)),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        var sample = ProbeSample(latencyMs: 2)
        sample.answeredFrom = "9.9.9.9"
        await monitor.report(sample, fromTarget: "quad9")
        #expect(await monitor.runCycle().internet.lastMs == 80)
    }

    @Test func gatewayChangeResetsDiagnosisButKeepsChart() async {
        let gateway = SwitchingGateway()
        let monitor = DiagnosisMonitor(
            gatewayFinder: gateway,
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(latencyMs: 400)),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        for _ in 0..<4 { await monitor.runCycle() }
        await gateway.set("10.0.0.1")
        let snapshot = await monitor.runCycle()
        #expect(snapshot.gateway == "10.0.0.1")
        #expect(snapshot.internet.sampleCount == 1)
        #expect(snapshot.internetHistory.count == 5)
    }

    @Test func overlappingCyclesShareOneResult() async {
        let gate = Gate()
        let monitor = DiagnosisMonitor(
            gatewayFinder: FixedGateway(address: "192.168.8.1"),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: GatedProbe(gate: gate),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        let first = Task { await monitor.runCycle() }
        await gate.waitUntilEntered()
        // The first cycle is now parked inside its probe, so this call must join it.
        let second = Task { await monitor.runCycle() }
        for _ in 0..<50 { await Task.yield() }
        await gate.open()
        #expect(await first.value.internetHistory.count == 1)
        #expect(await second.value.internetHistory.count == 1)
        #expect(await monitor.runCycle().internetHistory.count == 2)
    }

    @Test func failedGatewayLookupKeepsTheLastGatewayAndItsSamples() async {
        let monitor = DiagnosisMonitor(
            gatewayFinder: FailingAfter(successes: 3),
            icmp: FixedProbe(sample: ProbeSample(latencyMs: 3)),
            tcp: FixedProbe(sample: ProbeSample(latencyMs: 30)),
            dns: FixedProbe(sample: ProbeSample(latencyMs: 5))
        )
        for _ in 0..<3 { await monitor.runCycle() }
        let snapshot = await monitor.runCycle()
        #expect(snapshot.gateway == "192.168.8.1")
        #expect(snapshot.internet.sampleCount == 4)
        #expect(snapshot.router.sampleCount == 4)
        #expect(snapshot.verdict == .online)
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

    @Test func sleepDoesNotCountAsOutageTime() {
        var alerts = ConnectionAlerts(offlineAfter: 30, maxGap: 20)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(alerts.evaluate(verdict: .noNetwork, now: start) == nil)
        let wake = start.addingTimeInterval(8 * 3600)
        #expect(alerts.evaluate(verdict: .noNetwork, now: wake) == nil)
        #expect(alerts.evaluate(verdict: .online, now: wake.addingTimeInterval(5)) == nil)
    }

    @Test func checkingInterruptsAnUnannouncedOutage() {
        var alerts = ConnectionAlerts(offlineAfter: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(alerts.evaluate(verdict: .internetDown, now: start) == nil)
        for offset in stride(from: 5.0, through: 30, by: 5) {
            #expect(alerts.evaluate(verdict: .checking, now: start.addingTimeInterval(offset)) == nil)
        }
        #expect(alerts.evaluate(verdict: .internetDown, now: start.addingTimeInterval(35)) == nil)
    }

    @Test func shortBlipIsSilent() {
        var alerts = ConnectionAlerts(offlineAfter: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(alerts.evaluate(verdict: .routerUnreachable, now: start) == nil)
        #expect(alerts.evaluate(verdict: .online, now: start.addingTimeInterval(10)) == nil)
    }
}
