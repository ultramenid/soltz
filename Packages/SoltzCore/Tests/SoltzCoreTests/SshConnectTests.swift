// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import Synchronization
import Testing

/// `Core.sshConnect` through the bindings, against loopback ports nothing listens
/// on: the Rust tests cover connecting to a host (no SSH server runs from Swift).
struct SshConnectTests {
    final class Events: SessionSink {
        let names = Mutex<[String]>([])
        func output(data: Data) {}
        func closed(cleanExit: Bool) {}
        func event(name: String, payloadJson: String) { names.withLock { $0.append(name) } }
    }

    /// Port 1 on loopback refuses: no service listens there on macOS.
    let refused = #"{"host":"127.0.0.1","port":1,"username":"soltz","password":"pw","persist":false}"#

    @Test func aFailureCarriesItsCodeAndDescribesItselfByItsMessage() async throws {
        do {
            _ = try await Core().sshConnect(sink: Events(), argsJson: refused)
            Issue.record("connected to a closed port")
        } catch let error as CoreError {
            guard case let .Coded(code, message) = error else {
                Issue.record("uncoded: \(error)")
                return
            }
            #expect(code == .connectionRefused)
            #expect(message.hasPrefix("Connection failed: "))
            #expect(error.localizedDescription == message)
        }

        await #expect {
            try await Core().sshConnect(sink: Events(), argsJson: "{}")
        } throws: { error in
            guard case let CoreError.Failed(message) = error else { return false }
            return error.localizedDescription == message
        }
    }

    @Test func cancellingTheTaskStopsTheConnect() async throws {
        // The knock's settle time holds the connect for a minute.
        let args = #"""
            {"host":"127.0.0.1","port":1,"username":"soltz","password":"pw","persist":false,
             "knock":{"steps":[{"port":1,"protocol":"tcp"}],"delay_ms":10,"settle_ms":60000}}
            """#
        let sink = Events()
        let started = ContinuousClock.now
        let connecting = Task { try await Core().sshConnect(sink: sink, argsJson: args) }
        try await waitFor("the knock") { sink.names.withLock { $0.contains("ssh-step") } }
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}
