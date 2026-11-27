// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import Synchronization
import Testing

/// Keeps what a session sends; the Rust core calls it from its own threads.
final class Recorder: SessionSink {
    private let state = Mutex<(output: Data, closed: Bool?)>((Data(), nil))

    func output(data: Data) { state.withLock { $0.output.append(data) } }
    func closed(cleanExit: Bool) { state.withLock { $0.closed = cleanExit } }
    func event(name: String, payloadJson: String) {}

    var lines: [String] {
        state.withLock { String(decoding: $0.output, as: UTF8.self) }
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
    var closedCleanly: Bool? { state.withLock { $0.closed } }
}

func waitFor(_ what: String, _ done: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !done() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct WaitTimedOut: Error { let what: String }

/// What `call` fails with, as its description; nil when it succeeds.
func message(_ call: () async throws -> some Any) async -> String? {
    do {
        _ = try await call()
        return nil
    } catch {
        return "\(error)"
    }
}

@Test func aLocalShellRunsWhatIsWrittenThroughTheRustCore() async throws {
    // `/bin/sh` reads no user rc files and draws no prompt over its output, so the
    // command's own output is a line of its own (the Rust test covers the login shell).
    setenv("SHELL", "/bin/sh", 1)
    let sink = Recorder()
    let shell = try await Core().openLocalShell(sink: sink, cols: 80, rows: 24)

    try await shell.write(data: Data("echo soltz-ok\n".utf8))
    try await waitFor("soltz-ok") { sink.lines.contains("soltz-ok") }

    try await shell.resize(cols: 100, rows: 30)
    try await shell.write(data: Data("exit\n".utf8))
    try await waitFor("the close") { sink.closedCleanly != nil }
    #expect(sink.closedCleanly == true)
    try await shell.close()
}
