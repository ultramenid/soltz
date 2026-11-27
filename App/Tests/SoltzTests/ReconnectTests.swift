// SPDX-License-Identifier: AGPL-3.0-only
@testable import Soltz
import SoltzCore
import Testing

/// Upstream's reconnect rules, the cases of src/stores/reconnectBackoff.test.ts ported. The clock is a recorder that
/// returns at once, so the schedule runs without real waits.
@MainActor struct ReconnectTests {
    /// The injected clock, network and attempt; `result(n)` answers attempt n (1-based), nil connecting.
    @MainActor final class Loop {
        var slept: [Duration] = []
        var waits: [Backoff.Wait?] = []
        var attempts = 0
        var online: () -> Bool = { true }
        /// Whether sleep number n (1-based) is woken early.
        var woken: (Int) -> Bool = { _ in false }
        let result: (Int) -> (any Error)?

        init(_ result: @escaping (Int) -> (any Error)?) { self.result = result }

        func run(catchUp: [Duration]? = nil) async -> Backoff.Outcome {
            await Backoff.run(
                sleep: { self.slept.append($0); return self.woken(self.slept.count) }, online: { self.online() },
                setWait: { self.waits.append($0) }, attempt: { self.attempts += 1; return self.result(self.attempts) },
                catchUp: catchUp)
        }
    }

    func failed(_ message: String) -> CoreError { .Failed(message: message) }

    @Test func theScheduleIsFastForThreeMinutesThenSlowForever() {
        let delays = Backoff.fastDelays
        #expect(delays.prefix(4) == [.milliseconds(1500), .seconds(3), .seconds(5), .seconds(8)], "fast initial backoff steps")
        #expect(delays.allSatisfy { $0 <= .seconds(10) }, "no single fast delay exceeds 10s")
        #expect(delays.reduce(.zero, +) >= .seconds(180), "fast phase spans at least ~3 minutes")
        #expect(Backoff.retryDelay(delays.count) == .seconds(30), "past the fast phase, retries slow down instead of stopping")
        #expect(Backoff.retryDelay(delays.count + 500) == .seconds(30), "the slow phase has no end")
    }

    @Test func aSuccessfulAttemptConnects() async {
        let loop = Loop { _ in nil }
        guard case .connected = await loop.run() else { Issue.record("not connected"); return }
        #expect(loop.attempts == 1 && loop.slept == [.milliseconds(1500)] && loop.waits == [nil])
    }

    @Test func transientFailuresStayCalmAndRetryOnTheSchedule() async {
        let loop = Loop { $0 >= 3 ? nil : CoreError.Coded(code: .hostUnreachable, message: "host unreachable") }
        guard case .connected = await loop.run() else { Issue.record("not connected"); return }
        #expect(loop.attempts == 3, "retries through transient failures")
        #expect(loop.slept == [.milliseconds(1500), .seconds(3), .seconds(5)])
        #expect(loop.waits == [nil, nil, nil], "never surfaces a transient error")
    }

    @Test func failuresRetryingCannotFixStopAfterOneAttempt() async {
        let final: [any Error] = [
            failed("The key is encrypted"),
            CoreError.Coded(code: .vaultUnreadable, message: "Coffre illisible"),
            failed("Connection aborted by user."),
            failed("WARNING: Host key changed for 127.0.0.1:22!"),
            failed("Password authentication rejected — check the username and password."),
            failed("The server requires a new password — sign in once from a terminal and change it there."),
            CoreError.Coded(code: .sshPasswordRejected, message: "Authentification par mot de passe refusée"),
            CoreError.Coded(code: .sshKeyRejected, message: "Public key authentication rejected"),
        ]
        for error in final {
            let loop = Loop { _ in error }
            guard case .stopped(let shown) = await loop.run() else { Issue.record("kept retrying \(error)"); continue }
            #expect(loop.attempts == 1, "\(error)")
            #expect((shown as? CoreError) == (error as? CoreError), "the code travels with the message")
        }
    }

    @Test func anEndedSessionTearsDownWithoutAnError() async {
        let loop = Loop { _ in failed("SESSION_ENDED") }
        guard case .ended = await loop.run() else { Issue.record("not ended"); return }
        #expect(loop.attempts == 1)
    }

    @Test func aLongOutageSlowsDownButNeverStops() async {
        let failures = Backoff.fastDelays.count + 20
        let loop = Loop { $0 > failures ? nil : failed("Network is unreachable") }
        guard case .connected = await loop.run() else { Issue.record("gave up"); return }
        #expect(loop.attempts == failures + 1, "never stops on a transient failure")
        #expect(loop.waits.firstIndex(of: .slow) == Backoff.fastDelays.count, "slows down only after the fast phase")
        #expect(loop.slept.suffix(20).allSatisfy { $0 == .seconds(30) })
    }

    @Test func offlineItWaitsWithoutAttempting() async {
        var checks = 0
        let loop = Loop { _ in nil }
        loop.online = {
            checks += 1
            return checks > 3
        }
        guard case .connected = await loop.run() else { Issue.record("not connected"); return }
        #expect(loop.attempts == 1, "makes no attempt while offline")
        #expect(loop.waits == [nil, .offline, .offline, .offline], "tells the pane it is waiting for the network")
        #expect(loop.slept.allSatisfy { $0 == .milliseconds(1500) }, "offline restarts the schedule")
    }

    @Test func cancellingStopsTheLoopWithoutAttempting() async {
        let loop = Loop { _ in failed("unreachable") }
        let task = Task { await loop.run() }
        task.cancel()
        guard case .cancelled = await task.value else { Issue.record("not cancelled"); return }
        #expect(loop.attempts == 0)
    }

    @Test func aCatchUpMakesOnlyItsAttemptsThenShowsTheLastError() async {
        let loop = Loop { CoreError.Failed(message: "unreachable \($0)") }
        guard case .stopped(let error) = await loop.run(catchUp: Backoff.catchUpDelays) else { Issue.record("no error"); return }
        #expect(loop.attempts == 3 && loop.slept == Backoff.catchUpDelays)
        #expect(describe(error) == "unreachable 3", "the latest failure is shown again")
        #expect(!loop.waits.contains(.slow), "a catch-up never claims to be retrying slowly")

        let settles = Loop { $0 >= 2 ? nil : failed("DHCP not done") }
        guard case .connected = await settles.run(catchUp: Backoff.catchUpDelays) else { Issue.record("not connected"); return }
    }

    @Test func aWakeAttemptsAtOnceAndRestartsTheSchedule() async {
        let loop = Loop { $0 >= 4 ? nil : failed("refused") }
        loop.woken = { $0 == 3 } // the third wait (5 s) is cut short
        guard case .connected = await loop.run() else { Issue.record("not connected"); return }
        #expect(loop.slept == [.milliseconds(1500), .seconds(3), .seconds(5), .seconds(3)], "3 s next, not the 8 s it had reached")
    }

    @Test func aClosedChannelIsRoutedAsUpstreamRoutesIt() {
        #expect(Backoff.closed(ssh: true, connected: true, cleanExit: false) == .reconnect, "ssh drop on a connected session reconnects")
        #expect(Backoff.closed(ssh: true, connected: false, cleanExit: false) == .ignore, "a close while reconnecting or connecting is ignored")
        #expect(Backoff.closed(ssh: true, connected: true, cleanExit: true) == .closeTab, "a clean remote exit closes instead of reconnecting")
        #expect(Backoff.closed(ssh: false, connected: true, cleanExit: true) == .closeTab, "a clean local exit closes the tab")
        #expect(Backoff.closed(ssh: false, connected: true, cleanExit: false) == .markEnded, "a failed local exit keeps the tab")
    }

    @Test func onlyFailuresTheNetworkCanFixAreRevived() {
        #expect(Backoff.strandedByNetwork(failed("Network is unreachable")))
        #expect(Backoff.strandedByNetwork(CoreError.Coded(code: .hostUnreachable, message: "")), "a coded network failure is revived")
        #expect(!Backoff.strandedByNetwork(failed("Connection aborted by user.")), "a refused host key is not asked again")
        #expect(!Backoff.strandedByNetwork(failed("The key is encrypted")), "a passphrase prompt is not dismissed")
        #expect(!Backoff.strandedByNetwork(CoreError.Coded(code: .vaultUnreadable, message: "")), "a vault error is not retried")
        #expect(!Backoff.strandedByNetwork(failed("SESSION_ENDED")), "an ended session is not resurrected")
        #expect(!Backoff.strandedByNetwork(nil), "a cancelled connect stays cancelled")
    }

    @Test func aWakerCutsItsWaitShort() async {
        let waker = Waker()
        #expect(!waker.wake(), "nothing to wake")
        let sleep = Task { await waker.sleep(.seconds(60)) }
        while !waker.isSleeping { await Task.yield() }
        #expect(waker.wake())
        #expect(await sleep.value, "woken early")
        #expect(await waker.sleep(.milliseconds(1)) == false, "a wait that passes is not woken")
    }
}
