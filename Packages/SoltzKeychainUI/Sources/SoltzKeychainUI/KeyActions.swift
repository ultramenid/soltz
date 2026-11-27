// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzModel

/// Copy and export for a stored key, shared by the list and the editor. Each returns the message
/// to show the user, or nil when it worked or was cancelled.
@MainActor
enum KeyActions {
    static let noPublicKey = "This key has no public half. Edit it and paste its .pub line, or add its passphrase so the public half can be derived from the private one."

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyPublicKey(_ key: SshKey, _ operations: KeyOperations) async -> String? {
        do {
            guard let text = try await operations.publicKey(key), !text.isEmpty else { return noPublicKey }
            copy(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func export(_ key: SshKey, publicHalf: Bool, _ operations: KeyOperations) async -> String? {
        do {
            let text = try await publicHalf ? operations.publicKey(key) : operations.privateKey(key)
            guard let text, !text.isEmpty else { return publicHalf ? noPublicKey : "No private key is stored for this key." }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = KeyText.exportFileName(keyType: key.keyType, publicHalf: publicHalf)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return write(KeyText.fileContents(text), to: url, mode: publicHalf ? 0o644 : 0o600)
        } catch {
            return error.localizedDescription
        }
    }

    /// Created with `mode` and narrowed to it if it existed, so a private key is never readable by
    /// others, not even for a moment (ssh also refuses such a file).
    static func write(_ text: String, to url: URL, mode: mode_t) -> String? {
        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard fd >= 0 else { return "Couldn't write \(url.lastPathComponent)." }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard fchmod(fd, mode) == 0, Darwin.write(fd, bytes, bytes.count) == bytes.count else {
            return "Couldn't write \(url.lastPathComponent)."
        }
        return nil
    }
}
