// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import os
import SoltzCore
import SoltzModel
import SoltzTerminal

/// Terminal font settings, as stored by the Settings scene.
struct TerminalFont: Equatable {
    var family = ""
    var size = Theme.terminalSize
    var lineHeight = Theme.terminalLineHeight
}

/// One shell: a core `Session` bridged both ways to the terminal that shows it.
///
/// Threads: the core calls the sink on its own threads; output goes straight into the thread-safe
/// `feed`, everything else hops to the main actor. Ghostty calls `onInput` on its I/O thread, which
/// only enqueues into `input`; the workspace routes that on the main actor into each
/// target's outbox, and one detached task per session drains the outbox into the current core session,
/// in order. A Reconnect swaps that core session; the terminal and the outbox stay.
@MainActor @Observable
final class TerminalSession {
    enum Outgoing: Sendable {
        case data(Data)
        case resize(cols: UInt16, rows: UInt16)
    }

    /// The core session written to, and the terminal's last grid size; shared with the drain and `onResize`.
    struct Link {
        var session: Session?
        var size: (cols: UInt16, rows: UInt16)?
    }

    nonisolated let id = UUID().uuidString
    @ObservationIgnored let terminal: SoltzTerminalModel
    /// Keystrokes and terminal replies, for the workspace to route.
    @ObservationIgnored let input: AsyncStream<Data>
    var title: String
    /// The shell exited or the connection dropped (or never opened).
    private(set) var ended = false
    /// Ended by the transport rather than by the shell exiting: an SSH session offers Reconnect.
    private(set) var dropped = false
    /// The latest `ssh-step` while connecting.
    private(set) var step: String?
    /// The working directory: an SSH session's from `ssh-cwd`, a local shell's from the terminal (OSC 7).
    private(set) var cwd: String?
    /// A persistent SSH session's multiplexer once attached, from `ssh-mux-mode`: "tmux" or "screen".
    private(set) var muxMode: String?
    /// A changed host key waiting for the user's answer.
    var conflict: HostKeyConflict?
    /// A pane shows "Connecting…" until it is set.
    private(set) var isAttached = false
    /// SSH only: the `ssh_connect` arguments it was opened with, for Reconnect and Split.
    @ObservationIgnored var args: JSONObject?
    /// The saved host it was opened from, for its post-command on close.
    @ObservationIgnored var hostID: String?
    /// Its pane shows the host's files (FilesView.swift) instead of the terminal. The shell is open all the same: the
    /// files travel over its connection.
    var showsFiles = false
    /// The folder a files pane shows; empty opens the host's home.
    var filesPath = ""
    /// What marks a files session in the sidebar, on its tab and in its pane: a drive on a network, not the folder
    /// a group of hosts has.
    static let filesSymbol = "externaldrive.connected.to.line.below"
    /// The connect in flight; cancelling it cancels the connect.
    @ObservationIgnored var connectTask: Task<Void, Never>?
    /// It was connected once: a persistent session's Reconnect then only attaches (`attachOnly`).
    @ObservationIgnored private(set) var everConnected = false
    /// The automatic reconnect is running (Reconnect.swift), and what it waits for, if the pane says so.
    var autoReconnecting = false
    var reconnectWait: Backoff.Wait?
    /// Reconnect attempts made, automatic or not.
    @ObservationIgnored var reconnectAttempts = 0
    /// Why the last connect failed; nil after a cancel. The network coming back retries some (`Backoff.strandedByNetwork`).
    @ObservationIgnored var failure: (any Error)?
    /// The automatic reconnect's wait, which the pane's Reconnect and the network coming back cut short.
    @ObservationIgnored let waker = Waker()
    /// The core reported the channel closed (`Workspace.sessionClosed`); without it the pane just ends.
    @ObservationIgnored var onClosed: ((_ cleanExit: Bool) -> Void)?

    @ObservationIgnored private let link: OSAllocatedUnfairLock<Link>
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var draining = false
    @ObservationIgnored private let outgoing: AsyncStream<Outgoing>
    @ObservationIgnored private let outbox: AsyncStream<Outgoing>.Continuation
    @ObservationIgnored private let typed: AsyncStream<Data>.Continuation

    init(title: String, font: TerminalFont) {
        let (outgoing, outbox) = AsyncStream.makeStream(of: Outgoing.self)
        let (input, typed) = AsyncStream.makeStream(of: Data.self)
        let link = OSAllocatedUnfairLock(initialState: Link())
        self.outgoing = outgoing
        self.outbox = outbox
        self.input = input
        self.typed = typed
        self.link = link
        self.title = title
        terminal = SoltzTerminalModel(
            fontFamily: font.family.isEmpty ? nil : font.family, fontSize: font.size, lineHeight: font.lineHeight,
            onInput: { typed.yield($0) },
            onResize: { size in
                let cols = UInt16(clamping: size.columns), rows = UInt16(clamping: size.rows)
                link.withLock { $0.size = (cols, rows) }
                outbox.yield(.resize(cols: cols, rows: rows))
            }
        )
        terminal.onTitleChange = { [weak self] in self?.title = $0 }
        terminal.onWorkingDirectoryChange = { [weak self] in if self?.args == nil { self?.cwd = $0 } }
    }

    /// The core session's id (`ssh_connect`'s `sessionId`).
    var coreID: String? { args?["sessionId"]?.string }

    /// What to hand the core when opening this session.
    var sink: any SessionSink { Sink(terminal: terminal, owner: self) }

    /// The terminal's grid, once it has been laid out.
    var size: (cols: UInt16, rows: UInt16)? { link.withLock { $0.size } }

    /// Takes the opened core session and starts writing to it. One that arrives after `close()` is closed at once.
    func attach(_ session: Session) {
        guard !isClosed else {
            Task { try? await session.close() }
            return
        }
        link.withLock { $0.session = session }
        isAttached = true
        everConnected = true
        ended = false
        dropped = false
        step = nil
        failure = nil
        guard !draining else { return }
        draining = true
        let outgoing = outgoing, link = link
        Task.detached {
            for await op in outgoing {
                guard let session = link.withLock({ $0.session }) else { continue }
                switch op {
                case .data(let data): try? await session.write(data: data)
                case .resize(let cols, let rows):
                    // A size the terminal has already left is not worth a round trip: the newest one follows.
                    guard link.withLock({ $0.size.map { $0 == (cols, rows) } ?? true }) else { continue }
                    try? await session.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    /// Before a Reconnect: back to connecting, handing back the dropped core session to disconnect.
    func restart() -> Session? {
        ended = false
        dropped = false
        isAttached = false
        failure = nil
        muxMode = nil
        return link.withLock { link in
            defer { link.session = nil }
            return link.session
        }
    }

    /// Answers the changed-host-key question, if one is waiting.
    func answer(_ action: HostKeyAction, via core: Core) {
        guard let conflict else { return }
        self.conflict = nil
        Task { await core.resolveHostKey(sessionId: conflict.sessionId, fingerprint: conflict.newFingerprint ?? "", action: action) }
    }

    func send(_ data: Data) {
        if !ended { outbox.yield(.data(data)) }
    }

    func setFont(_ font: TerminalFont) {
        terminal.setFont(family: font.family.isEmpty ? nil : font.family, size: font.size, lineHeight: font.lineHeight)
    }

    /// The shell or connection ended by itself (or never opened); `dropped` when the transport did.
    func end(dropped: Bool = true) {
        ended = true
        self.dropped = dropped
        step = nil
    }

    /// Ends the core session (its sink then gets no `closed`) and both streams, and cancels a connect in flight.
    /// A live SSH session ends as upstream closes its tab (`ssh_disconnect`, src/stores/sessionStore.ts:826):
    /// `postCommand` first, then its tmux session killed. A dropped one is only closed, so its tmux session stays
    /// detached until the TTL, as in upstream.
    func close(postCommand: String? = nil) {
        isClosed = true
        connectTask?.cancel()
        outbox.finish()
        typed.finish()
        let session = link.withLock { link in
            defer { link.session = nil }
            return link.session
        }
        let live = args != nil && !ended
        Task {
            guard let session else { return }
            guard live else {
                try? await session.close()
                return
            }
            _ = try? await session.disconnect(postCommand: postCommand, killPersistent: true, attached: true)
        }
    }

    /// Screen and scrollback as trimmed lines.
    var screenLines: [String] {
        (terminal.readScreenText() ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    fileprivate func closed(cleanExit: Bool) {
        if let onClosed { onClosed(cleanExit) } else { end(dropped: !cleanExit) }
    }

    fileprivate func handle(_ name: String, _ payload: String) {
        switch name {
        case "ssh-step": step = Self.decode(SshStep.self, payload)?.step
        case "ssh-host-key-conflict": conflict = Self.decode(HostKeyConflict.self, payload)
        case "ssh-cwd": cwd = Self.decode(String.self, payload) ?? cwd
        case "ssh-mux-mode": muxMode = Self.decode(MuxMode.self, payload).map { $0.tmux ? "tmux" : "screen" }
        default: break
        }
    }

    /// An event payload; the core writes its fields in snake case.
    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ payload: String) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: Data(payload.utf8))
    }
}

struct SshStep: Decodable { let step: String }

/// The `ssh-mux-mode` payload: `{control, tmux}`; not tmux is GNU screen.
struct MuxMode: Decodable { let tmux: Bool }

/// The `ssh-host-key-conflict` payload: a host's key to decide on, seen for the first time or changed. Only the
/// session id is required: without it the connection could never be answered and would wait forever.
struct HostKeyConflict: Decodable, Equatable {
    struct Stored: Decodable, Equatable { let fingerprint: String }

    let sessionId: String
    let host: String?
    let port: Int?
    let newFingerprint: String?
    /// The keys trusted for this host until now; empty when it is seen for the first time.
    let storedEntries: [Stored]?

    /// Only when the core says so: a payload without the list is treated as a changed key, the stricter question.
    var isFirstSight: Bool { storedEntries?.isEmpty == true }
}

/// Called by the core on its own threads.
private final class Sink: SessionSink {
    let terminal: SoltzTerminalModel
    weak let owner: TerminalSession?

    init(terminal: SoltzTerminalModel, owner: TerminalSession) {
        self.terminal = terminal
        self.owner = owner
    }

    func output(data: Data) { terminal.feed(data) }

    func closed(cleanExit: Bool) {
        Task { @MainActor [owner] in owner?.closed(cleanExit: cleanExit) }
    }

    func event(name: String, payloadJson: String) {
        Task { @MainActor [owner] in owner?.handle(name, payloadJson) }
    }
}

/// A core or vault error's own message (they describe themselves as their Swift case otherwise).
func describe(_ error: any Error) -> String {
    switch error {
    case CoreError.Coded(let code, let message): code.text ?? message
    case CoreError.Failed(let message), VaultError.WrongKey(let message), VaultError.Failed(let message): message
    case VaultError.Locked: "The vault is locked."
    default: error.localizedDescription
    }
}
