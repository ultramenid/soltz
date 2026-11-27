// SPDX-License-Identifier: AGPL-3.0-only
// Hand-written beside the generated SoltzCore.swift, for what UniFFI does not generate.

/// `description` is Rust's Display (the plain message); with this conformance it is
/// also what `localizedDescription` and string interpolation show, not the Swift case.
extension CoreError: CustomStringConvertible {}

// UniFFI's async calls ignore task cancellation, so this one hands the Rust connect
// a `Cancellation` to fire.
extension Core {
    /// `sshConnect(sink:argsJson:cancel:)`, stopped by cancelling the calling task:
    /// the connect is abandoned, nothing stays open, and this throws `CancellationError`.
    public func sshConnect(sink: SessionSink, argsJson: String) async throws -> Session {
        let cancel = Cancellation()
        let session: Session
        do {
            session = try await withTaskCancellationHandler {
                try await sshConnect(sink: sink, argsJson: argsJson, cancel: cancel)
            } onCancel: {
                cancel.cancel()
            }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
        // A cancel that landed as the connect finished.
        if Task.isCancelled {
            try? await session.close()
            throw CancellationError()
        }
        return session
    }
}
