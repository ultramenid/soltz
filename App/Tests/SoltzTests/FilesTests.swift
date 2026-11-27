// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@testable import Soltz
import SoltzCore
import SoltzFilesUI
import SoltzModel
import Testing

/// `SftpFileProvider`'s pure parts on the core's JSON shapes (no SFTP session opens).
@MainActor struct FilesTests {
    @Test func listingsBecomeEntries() throws {
        let json = """
            [{"name":"lib","path":"/home/u/lib","size":4096,"is_dir":true,"is_symlink":true,"modified":null,"permissions":null},
             {"name":"a.txt","path":"/home/u/a.txt","size":12,"is_dir":false,"is_symlink":false,"modified":1700000000,"permissions":33188}]
            """
        #expect(try SftpFileProvider.entries(json) == [
            FileEntry(name: "lib", path: "/home/u/lib", size: 4096, isDir: true, isSymlink: true),
            FileEntry(name: "a.txt", path: "/home/u/a.txt", size: 12, modified: Date(timeIntervalSince1970: 1_700_000_000),
                      permissions: 0o100644),
        ])
        #expect(throws: FileError.self) { try SftpFileProvider.entries(#"{"not":"a list"}"#) }
    }

    @Test func sinkEventsTranslate() {
        #expect(SftpFileProvider.event("sftp-progress", #"{"transferred":512,"total":2048}"#) == .progress(transferred: 512, total: 2048))
        #expect(SftpFileProvider.event("sftp-resumed", #"{"offset":1024}"#) == .resumed(offset: 1024))
        #expect(SftpFileProvider.event("sftp-waiting", #"{"waiting":true}"#) == .waiting(true))
        #expect(SftpFileProvider.event("sftp-skipped", #""/srv/a:b""#) == .skipped("/srv/a:b"))
        #expect(SftpFileProvider.event("sftp-accel", #"{"mode":"tar"}"#) == nil)
        #expect(SftpFileProvider.event("sftp-progress", "not json") == nil)
    }

    @Test func coreErrorsBecomeFileErrors() {
        func message(_ error: any Error) -> String? { (SftpFileProvider.translate(error) as? FileError)?.message }
        #expect(message(CoreError.Failed(message: #"{"kind":"too_large","size":5000000,"limit":1048576}"#))
            == "File too large (5000000 bytes, limit 1048576). Download it instead.")
        #expect(message(CoreError.Failed(message: #"{"kind":"binary"}"#)) == "Binary file — can’t edit. Download it instead.")
        #expect(message(CoreError.Failed(message: #"{"kind":"io","message":"No such file"}"#)) == "No such file")
        #expect(message(CoreError.Failed(message: "Transfer cancelled")) == "Transfer cancelled")
        #expect(message(CoreError.Coded(code: .permissionDenied, message: "EACCES")) == "Permission denied")
        #expect(SftpFileProvider.translate(CancellationError()) is CancellationError)
    }

    @Test func theRunnerPicksTheCoreCall() {
        let core = Core(), local = LocalFileProvider()
        let host = SftpFileProvider(core: core, sessionID: "s1", name: "a"), other = SftpFileProvider(core: core, sessionID: "s2", name: "b")
        let file = FileEntry(name: "f", path: "/f"), dir = FileEntry(name: "d", path: "/d", isDir: true)
        #expect(SftpFileProvider.call(file, from: local, by: host) == .upload)
        #expect(SftpFileProvider.call(dir, from: local, by: host) == .uploadDir)
        #expect(SftpFileProvider.call(file, from: host, by: host) == .download)
        #expect(SftpFileProvider.call(dir, from: host, by: host) == .downloadDir)
        #expect(SftpFileProvider.call(file, from: other, by: host) == .transfer)
        #expect(SftpFileProvider.call(dir, from: other, by: host) == .transferDir)
    }
}
