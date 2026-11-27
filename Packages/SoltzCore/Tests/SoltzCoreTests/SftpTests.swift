// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import Synchronization
import Testing

/// The SFTP calls through the bindings, on their error paths: no SSH server runs
/// from Swift, so opening, listing and transferring against a host are the Rust tests'.
struct SftpTests {
    final class Events: TransferSink {
        let names = Mutex<[String]>([])
        func event(name: String, payloadJson: String) { names.withLock { $0.append(name) } }
    }

    @Test func callsOnAnUnknownSessionFailWithUpstreamsMessages() async throws {
        let core = Core()
        #expect(await message { try await core.sftpOpen(sessionId: "soltz-none") } == "Session not found")
        #expect(
            await message { try await core.sftpListDir(sftpId: "nope", path: "/") }
                == "SFTP session 'nope' not found")
        #expect(
            await message { try await core.sftpStat(sftpId: "nope", path: "/") }
                == "SFTP session 'nope' not found")
        await core.sftpClose(sftpId: "nope")

        // The editor's refusals are upstream's error object, as JSON.
        let refused = await message { try await core.sftpReadFile(sftpId: "nope", path: "/a", maxBytes: 10) }
        let object = try JSONSerialization.jsonObject(with: Data(try #require(refused).utf8)) as? [String: String]
        #expect(object == ["kind": "io", "message": "SFTP session 'nope' not found"])
    }

    @Test func transfersTakeAbsoluteLocalPathsAndHonourAnEarlyCancel() async throws {
        let core = Core()
        let events = Events()
        #expect(
            await message {
                try await core.sftpDownload(
                    sftpId: "nope", remotePath: "/a", localPath: "relative", transferId: "t1", sink: events)
            } == "Local paths must be absolute")

        // A cancel that comes before its transfer stops it before it starts.
        await core.sftpCancelTransfer(transferId: "t2")
        #expect(
            await message {
                try await core.sftpUpload(
                    sftpId: "nope", localPath: "/tmp/a", remotePath: "/a", transferId: "t2", sink: events)
            } == "Transfer cancelled")
        #expect(events.names.withLock { $0.isEmpty })
    }
}
