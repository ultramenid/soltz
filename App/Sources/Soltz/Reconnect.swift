// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Network
import SoltzCore

/// Upstream's connection lifecycle (src/stores/reconnectBackoffCore.ts): what a closed channel means, and the reconnect
/// backoff with its schedule and the failures it stops on. Pure: the clock, the network and the attempt are passed in.
enum Backoff {
    /// `FAST_DELAYS_MS`: 1.5 s, 3 s, 5 s, 8 s, then 10 s until the waits add up to 3 minutes.
    static let fastDelays: [Duration] = {
        var delays: [Duration] = [.milliseconds(1500), .seconds(3), .seconds(5), .seconds(8)]
        while delays.reduce(.zero, +) < .seconds(180) { delays.append(.seconds(10)) }
        return delays
    }()
    /// `SLOW_RETRY_MS`: every wait after the fast phase, with no end.
    static let slowRetry = Duration.seconds(30)
    /// `CATCH_UP_DELAYS_MS`: a tab that never connected gets only these when the network returns, then its error again.
    static let catchUpDelays: [Duration] = [.milliseconds(300), .seconds(2), .seconds(5)]

    /// `retryDelay`
    static func retryDelay(_ step: Int) -> Duration { fastDelays.indices.contains(step) ? fastDelays[step] : slowRetry }

    /// What the pane says while it waits (upstream `reconnectWait`); nil shows the connect steps.
    enum Wait { case offline, slow }

    enum Outcome {
        case connected
        /// The persistent session is gone on the host (`SESSION_ENDED`): the tab goes.
        case ended
        /// A failure retrying cannot fix, or a catch-up's last one: shown.
        case stopped(any Error)
        /// Cancel, the tab closing, or another connect taking over (upstream's superseded loop).
        case cancelled
    }

    /// `FINAL_CODES`: wrong credentials stay wrong, and retrying them gets the host banned by fail2ban.
    static let finalCodes: Set<ErrorCode> = [
        .vaultUnreadable, .vaultLocked, .sshKeyRejected, .sshPasswordRejected, .sshPasswordExpired, .sshPromptUnanswerable,
        .sshNoUsableAuthMethod, .deviceFileAccessOff, .deviceAccessDenied, .deviceApprovalTimedOut, .deviceAccessExpired,
        .deviceForgotten,
    ]

    /// `stopsRetrying`: by code where there is one, else by upstream's texts for an uncoded failure (a passphrase or
    /// username needed, a refused or changed host key, a rejected login, e.g. wrapped by a jump host).
    static func stopsRetrying(_ error: any Error) -> Bool {
        if case CoreError.Coded(let code, _) = error, finalCodes.contains(code) { return true }
        let message = describe(error)
        return message.lowercased().contains("invalid passphrase") || [
            "The key is encrypted", "No authentication method provided", "No username provided", "Connection aborted by user.",
            "Host key changed for", "authentication rejected", "No usable authentication method", "can't be answered automatically",
            "requires a new password", "FTP login failed",
        ].contains(where: message.contains)
    }

    /// `isSessionEnded`
    static func isSessionEnded(_ error: any Error) -> Bool { describe(error).contains("SESSION_ENDED") }

    /// `strandedByNetwork` for an SSH session whose connect failed with `error` (nil: it did not fail, or was cancelled).
    static func strandedByNetwork(_ error: (any Error)?) -> Bool {
        error.map { !isSessionEnded($0) && !stopsRetrying($0) } ?? false
    }

    /// What a closed channel does (`handleSessionClosed`).
    enum Closed: Equatable { case closeTab, markEnded, reconnect, ignore }

    /// `handleSessionClosed`: a local shell that exited cleanly (status 0) closes its tab, one that failed stays so its
    /// error can be read. An SSH session that was connected closes on a clean remote exit (`exit` typed: an exit-status
    /// came, and a persistent session's multiplexer is gone) and reconnects on anything else; a close while it is
    /// not connected (a duplicate, or the disconnect inside an attempt) is ignored, so no second loop starts.
    static func closed(ssh: Bool, connected: Bool, cleanExit: Bool) -> Closed {
        guard ssh else { return cleanExit ? .closeTab : .markEnded }
        guard connected else { return .ignore }
        return cleanExit ? .closeTab : .reconnect
    }

    /// `runBackoff`: waits, then attempts, until one connects. Each failure is silent and retried on the schedule; it
    /// holds off while offline; a wake (`sleep` returning true) attempts at once and starts the schedule over.
    /// With `catchUp`, only those attempts are made. Task cancellation stands in for upstream's generations.
    @MainActor
    static func run(sleep: (Duration) async -> Bool, online: () -> Bool, setWait: (Wait?) -> Void,
                    attempt: () async -> (any Error)?, catchUp: [Duration]? = nil) async -> Outcome {
        setWait(nil)
        var step = 0
        while true {
            let woken = await sleep(catchUp.map { $0[step] } ?? retryDelay(step))
            if Task.isCancelled { return .cancelled }
            if woken { step = 0 }
            guard online() else {
                setWait(.offline)
                step = 0
                continue
            }
            guard let error = await attempt() else { return .connected }
            if Task.isCancelled { return .cancelled }
            if isSessionEnded(error) { return .ended }
            if stopsRetrying(error) { return .stopped(error) }
            step += 1
            if let catchUp, step >= catchUp.count { return .stopped(error) }
            setWait(catchUp == nil && retryDelay(step) == slowRetry ? .slow : nil)
        }
    }
}

/// Upstream `createWakeableSleeps`, for one session: a wait that `wake()` cuts short.
@MainActor
final class Waker {
    private var sleeper: Task<Void, Never>?

    var isSleeping: Bool { sleeper != nil }

    /// Waits `delay`; true when woken (or cancelled) before it passed.
    func sleep(_ delay: Duration) async -> Bool {
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: delay) }
        self.sleeper = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        if self.sleeper == sleeper { self.sleeper = nil }
        return sleeper.isCancelled
    }

    /// Whether a wait was cut short.
    @discardableResult
    func wake() -> Bool {
        guard let sleeper else { return false }
        sleeper.cancel()
        self.sleeper = nil
        return true
    }
}

/// Closed channels, the automatic reconnect, the pane's Reconnect, and the network watch (src/stores/reconnectBackoff.ts).
extension Workspace {
    /// The core reported `session`'s channel closed (`Backoff.closed`). Closing a tab on a clean exit is upstream's
    /// `closeSession` while still connected: an SSH host's post-command runs and its persistent session is ended.
    func sessionClosed(_ session: TerminalSession, cleanExit: Bool) {
        // A files pane's shell is never seen: when it exits by itself (a host's idle timeout), the files must not go
        // with it, so it counts as a dropped connection and is reconnected.
        switch Backoff.closed(ssh: session.args != nil, connected: session.isAttached && !session.ended,
                              cleanExit: cleanExit && !session.showsFiles) {
        case .closeTab: close(session.id)
        case .markEnded: session.end()
        case .reconnect: reconnectWithBackoff(session)
        case .ignore: break
        }
    }

    /// Upstream `reconnectWithBackoff`: the pane holds "connecting" across attempts made on `Backoff`'s schedule, showing
    /// only an offline or slow wait. It ends connected (the pre-command runs, as after any Reconnect), with its tab gone
    /// (`SESSION_ENDED`), on a failure retrying cannot fix (shown, the pane then offers Reconnect), or on Cancel.
    func reconnectWithBackoff(_ session: TerminalSession, catchUp: [Duration]? = nil) {
        session.connectTask?.cancel()
        let dropped = session.restart()
        let first = !session.everConnected
        session.autoReconnecting = true
        session.connectTask = Task {
            var old = dropped
            let outcome = await Backoff.run(
                sleep: { await session.waker.sleep($0) }, online: { online(for: session) }, setWait: { session.reconnectWait = $0 },
                attempt: {
                    defer { old = nil }
                    do { try await reconnectAttempt(session, disconnecting: old) } catch { return error }
                    return nil
                },
                catchUp: catchUp)
            // Cancelled before a first attempt: the dropped session is let go as an attempt lets it go, so a later
            // Reconnect takes over its id the same way.
            _ = try? await old?.disconnect(postCommand: nil, killPersistent: false, attached: false, reconnecting: true)
            session.autoReconnecting = false
            session.reconnectWait = nil
            switch outcome {
            case .connected: await connected(session, first: first)
            case .ended: close(session.id)
            case .stopped(let error): failed(session, error)
            case .cancelled: session.end()
            }
        }
    }

    /// The pane's Reconnect. While the backoff waits it is upstream's "Retry now" (`wakeBackoff`): an attempt at once and
    /// the schedule from the top. Otherwise upstream `reconnect` (src/stores/sessionStore.ts:958): one attempt, its
    /// failure shown.
    func reconnect(_ session: TerminalSession) {
        if session.autoReconnecting {
            session.waker.wake()
            return
        }
        let old = session.restart()
        let first = !session.everConnected
        session.connectTask = Task {
            do {
                try await reconnectAttempt(session, disconnecting: old)
                await connected(session, first: first)
            } catch {
                failed(session, error)
            }
        }
    }

    /// Upstream `reconnectAttempt` (sessionStore.ts:1020): `old`, the dropped core session, disconnected as the first half
    /// of a reconnect (its SFTP sessions wait for the new connection), then `ssh_connect` under the same id,
    /// only attaching to a persistent session that was connected once (`attachOnly`), never moving its directory. A
    /// saved host's login and options are read again, as upstream resolves them per attempt; a login typed into Quick
    /// Connect, which the vault does not hold, stays the one the session opened with.
    func reconnectAttempt(_ session: TerminalSession, disconnecting old: Session?) async throws {
        _ = try? await old?.disconnect(postCommand: nil, killPersistent: false, attached: false, reconnecting: true)
        guard let opened = session.args, var args = try currentArgs(of: session) else {
            throw ConnectProblem("This session has nothing to reconnect.")
        }
        args["sessionId"] = opened["sessionId"]
        args["attachOnly"] = .bool(session.everConnected && opened["persist"] == .bool(true))
        args["initialCwd"] = .null
        session.reconnectAttempts += 1
        try await connectSsh(session, args)
    }

    /// A connect or reconnect that failed. As upstream (`isSessionEnded`): the host no longer has the persistent session an
    /// attach-only reconnect asked for, so its tab goes, no alert. Otherwise the pane ends offering Reconnect, and the
    /// failure is shown unless it was a cancel.
    func failed(_ session: TerminalSession, _ error: any Error) {
        if Backoff.isSessionEnded(error) { return close(session.id) }
        session.end()
        guard !(error is CancellationError) else { return }
        session.failure = error
        if sessions[session.id] != nil { failure = Failure(title: "Couldn’t Connect", message: describe(error)) }
    }

    // MARK: - Network

    /// Upstream's `online` check, `navigator.onLine`, from the system's network path.
    // Divergence: a loopback host needs no network, so it is always reachable here.
    func online(for session: TerminalSession) -> Bool {
        (networkUp ?? true) || ["127.0.0.1", "::1", "localhost"].contains(session.args?["host"]?.string ?? "")
    }

    /// Upstream `startNetworkWatch`: the network coming back (`networkBack`), and the app coming to the front, which cuts
    /// every waiting reconnect short (`wakeAllBackoffs`).
    func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeAllBackoffs() }
        }
    }

    /// A path update: any usable one after the first is upstream's `online` or `network-changed` (a new address).
    func networkChanged(_ up: Bool) {
        let known = networkUp != nil
        networkUp = up
        if up && known { networkBack() }
    }

    /// Upstream `networkBack`: every waiting reconnect tries now, and an SSH tab whose connect failed in a way the network
    /// can fix tries again: on the full schedule if it was connected once, else a short catch-up (it may be a typo).
    func networkBack() {
        lastWakeAll = nil
        wakeAllBackoffs()
        for session in sessions.values where session.args != nil && session.ended && Backoff.strandedByNetwork(session.failure) {
            reconnectWithBackoff(session, catchUp: session.everConnected ? nil : Backoff.catchUpDelays)
        }
    }

    /// Upstream `wakeAllBackoffs`: at most every 5 s, each waiting reconnect woken after up to 1 s of jitter, so a dozen
    /// tabs on one host do not all handshake in the same instant.
    func wakeAllBackoffs() {
        let now = ContinuousClock.now
        if let lastWakeAll, now - lastWakeAll < .seconds(5) { return }
        lastWakeAll = now
        for session in sessions.values where session.waker.isSleeping {
            Task {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0..<1000)))
                session.waker.wake()
            }
        }
    }
}
