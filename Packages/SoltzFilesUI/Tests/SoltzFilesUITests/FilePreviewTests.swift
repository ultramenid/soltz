// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SoltzFilesUI

/// Every copy goes to a folder of the test's own (`in:`), never the app's "Soltz Previews".
@Suite struct FilePreviewTests {
    let host = TreeHost()

    private func hosted(_ name: String, _ text: String = "hello", size: UInt64? = nil) -> FileEntry {
        host.contents["/srv/" + name] = Data(text.utf8)
        return FileEntry(name: name, path: "/srv/" + name, size: size ?? UInt64(text.utf8.count))
    }

    private func items(_ dir: String) -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: dir)) ?? []
    }

    @Test func aFileOfThisMacIsShownItselfAndNeverDiscarded() async throws {
        try await withTempDir { dir in
            try Data("mine".utf8).write(to: URL(filePath: dir + "/mine.txt"))
            let url = try await FilePreview.url(for: LocalFileProvider.entry(at: dir + "/mine.txt"), on: LocalFileProvider(),
                                                in: URL(filePath: dir + "/previews"))
            #expect(url == URL(filePath: dir + "/mine.txt"))
            FilePreview.discard(url, in: URL(filePath: dir + "/previews"))
            FilePreview.discard(url)
            #expect(items(dir) == ["mine.txt"])
        }
    }

    @Test func aFolderHasNoPreview() async throws {
        try await withTempDir { dir in
            let root = URL(filePath: dir)
            await #expect(throws: FileError.self) {
                try await FilePreview.url(for: FileEntry(name: "www", path: "/srv/www", isDir: true), on: host, in: root)
            }
            await #expect(throws: FileError.self) {
                try await FilePreview.url(for: LocalFileProvider.entry(at: dir), on: LocalFileProvider(), in: root)
            }
            #expect(items(dir).isEmpty)
        }
    }

    @Test func aHostsFileIsCopiedToAFolderOfItsOwnAndDiscarded() async throws {
        try await withTempDir { dir in
            let root = URL(filePath: dir + "/previews")
            let url = try await FilePreview.url(for: hosted("run.command", "#!/bin/sh\n"), on: host, in: root)
            #expect(url.lastPathComponent == "run.command")
            #expect(try Data(contentsOf: url) == Data("#!/bin/sh\n".utf8))
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false) == dir + "/previews/")
            #expect(UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil)
            // Marked as downloaded: Quick Look can open what it shows.
            #expect(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
            // One download and nothing else: anything sent to the host would have thrown.
            #expect(host.downloaded.all == ["/srv/run.command"])
            // A second look gets a copy of its own, and discarding one leaves the other.
            let again = try await FilePreview.url(for: hosted("run.command", "#!/bin/sh\n"), on: host, in: root)
            #expect(again != url)
            FilePreview.discard(url, in: root)
            #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: again.path(percentEncoded: false)))
            FilePreview.discard(again, in: root)
            #expect(items(dir) == ["previews"])
        }
    }

    @Test func aFileTheListingSaysIsTooLargeIsNotFetched() async throws {
        try await withTempDir { dir in
            let error = await #expect(throws: FileError.self) {
                try await FilePreview.url(for: hosted("dump.sql", size: FilePreview.maxBytes + 1), on: host, in: URL(filePath: dir))
            }
            #expect(error?.message == "“dump.sql” is too large to preview (over 50 MB). Download it to look at it.")
            #expect(host.downloaded.all.isEmpty)
            #expect(items(dir).isEmpty)
            // At the limit is fine.
            FilePreview.discard(try await FilePreview.url(for: hosted("dump.sql", size: FilePreview.maxBytes), on: host, in: URL(filePath: dir)),
                                in: URL(filePath: dir))
        }
    }

    @Test func aFileThatArrivesLargerThanItsListingSaidIsStoppedAndRemoved() async throws {
        try await withTempDir { dir in
            host.reported = FilePreview.maxBytes + 1
            // Once finishing anyway, once still sending when it is stopped.
            for stalls in [false, true] {
                host.stalls = stalls
                await #expect(throws: FileError.self) {
                    try await FilePreview.url(for: hosted("grown.log", size: 5), on: host, in: URL(filePath: dir))
                }
                #expect(items(dir).isEmpty)
            }
            #expect(host.downloaded.all.count == 2)
        }
    }

    @Test(arguments: ["../../escape.txt", "a/b", "..", ".", "", "nul\0byte"])
    func aNameThatIsNotPlainNeverBecomesAPath(name: String) async throws {
        try await withTempDir { dir in
            host.contents["/srv/x"] = Data("x".utf8)
            await #expect(throws: FileError.self) {
                try await FilePreview.url(for: FileEntry(name: name, path: "/srv/x", size: 1), on: host, in: URL(filePath: dir + "/previews"))
            }
            #expect(host.downloaded.all.isEmpty)
            #expect(items(dir).isEmpty)
        }
    }

    @Test func cancellingStopsTheDownloadAndLeavesNothing() async throws {
        try await withTempDir { dir in
            host.stalls = true
            let entry = hosted("big.bin")
            let task = Task { try await FilePreview.url(for: entry, on: host, in: URL(filePath: dir)) }
            // The partial file is on disk by now.
            for await _ in host.began { break }
            #expect(items(dir).count == 2)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(items(dir).isEmpty)
        }
    }

    @Test func aDownloadThatFailsLeavesNothing() async throws {
        try await withTempDir { dir in
            await #expect(throws: FileError.self) {
                try await FilePreview.url(for: FileEntry(name: "gone.txt", path: "/srv/gone.txt"), on: host, in: URL(filePath: dir))
            }
            #expect(items(dir).isEmpty)
        }
    }

    @Test func discardRemovesNothingButACopysOwnFolder() async throws {
        try await withTempDir { dir in
            let root = URL(filePath: dir + "/previews"), id = UUID().uuidString
            for folder in ["/home/\(id)", "/previews/\(id)", "/previews/not-a-copy", "/previews/\(id)/sub"] {
                try FileManager.default.createDirectory(atPath: dir + folder, withIntermediateDirectories: true)
            }
            let files = ["/home/report.pdf", "/home/\(id)/report.pdf", "/previews/loose.txt", "/previews/not-a-copy/a.txt",
                         "/previews/\(id)/copy.txt", "/previews/\(id)/sub/deep.txt"]
            for file in files { try Data("keep".utf8).write(to: URL(filePath: dir + file)) }
            let before = items(dir).sorted()
            let strangers = [
                URL(filePath: dir + "/home/report.pdf"),
                // A user's folder that happens to be named like a copy's.
                URL(filePath: dir + "/home/\(id)/report.pdf"),
                // In the copies' folder, but not a copy in a folder of its own.
                URL(filePath: dir + "/previews/loose.txt"),
                URL(filePath: dir + "/previews/not-a-copy/a.txt"),
                URL(filePath: dir + "/previews/\(id)/sub/deep.txt"),
                // The copies' folder and what holds it.
                root, URL(filePath: dir), URL(filePath: "/"),
                // Names a copy's folder on the way to somewhere else.
                URL(filePath: dir + "/previews/\(id)/../../home/\(id)/report.pdf"),
                URL(filePath: dir + "/previews/\(id)/../../home/report.pdf"),
                URL(string: "https://example.com\(dir)/previews/\(id)/copy.txt")!,
            ]
            for url in strangers {
                FilePreview.discard(url, in: root)
                // The app's own folder is another place again.
                FilePreview.discard(url)
            }
            #expect(items(dir).sorted() == before)
            // The one thing it does remove.
            FilePreview.discard(URL(filePath: dir + "/previews/\(id)/copy.txt"), in: root)
            #expect(!FileManager.default.fileExists(atPath: dir + "/previews/\(id)"))
            #expect(items(dir).count == before.count - 4)
        }
    }
}
