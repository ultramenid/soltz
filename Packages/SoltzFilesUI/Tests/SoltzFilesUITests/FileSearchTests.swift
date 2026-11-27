// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import SoltzFilesUI

/// A host made of a dictionary: folders by path and files' bytes by path. It lists and it downloads; everything
/// that would change it throws. Set it up before use.
final class TreeHost: FileProvider, @unchecked Sendable {
    let name = "host"
    let isLocal = false
    private var folders: [String: [FileEntry]] = [:]
    /// Folders whose listing fails.
    var denied: Set<String> = []
    /// Runs inside each listing, on the task that asked for it.
    var onList: (@Sendable (String) -> Void)?
    /// What a download writes, by the file's path.
    var contents: [String: Data] = [:]
    /// The bytes a download says have arrived, when not what it wrote.
    var reported: UInt64?
    /// A download writes, then waits to be cancelled.
    var stalls = false
    let listed = Recorder<String>()
    let downloaded = Recorder<String>()
    let (began, begin) = AsyncStream.makeStream(of: Void.self)

    init(_ paths: [String] = []) {
        paths.forEach { add($0) }
    }

    /// "/a/b/" is a folder, "/a/b" a file; the folders above it are made too.
    func add(_ path: String) {
        let isDir = path.hasSuffix("/"), path = Paths.normalize(path)
        guard let parent = Paths.parent(path) else { return }
        if isDir, folders[path] == nil { folders[path] = [] }
        if !folders[parent, default: []].contains(where: { $0.path == path }) {
            folders[parent, default: []].append(FileEntry(name: Paths.name(path), path: path, isDir: isDir))
        }
        add(parent + "/")
    }

    func list(_ path: String) async throws -> [FileEntry] {
        listed.add(path)
        onList?(path)
        guard !denied.contains(path), let entries = folders[path] else { throw FileError("Permission denied") }
        return entries
    }

    func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String, resume: Bool,
                  events: @escaping @Sendable (TransferEvent) -> Void,
                  onConflict: @escaping @Sendable (TransferConflict) async -> ConflictChoice) async throws {
        // Only ever a download: from this host to a path on this Mac.
        guard source === self, let data = contents[item.path] else { throw FileError("Read-only") }
        downloaded.add(item.path)
        try data.write(to: URL(filePath: destinationPath))
        events(.progress(transferred: reported ?? UInt64(data.count), total: UInt64(data.count)))
        if stalls {
            begin.yield()
            try await Task.sleep(for: .seconds(60))
        }
    }

    func stat(_ path: String) async throws -> Bool? { folders[path] != nil ? true : nil }
    func home() async throws -> String { "/" }
    func realpath(_ path: String) async throws -> String { Paths.normalize(path) }
    func mkdir(_ path: String) async throws { throw FileError("Read-only") }
    func createFile(_ path: String) async throws { throw FileError("Read-only") }
    func rename(_ from: String, to: String) async throws { throw FileError("Read-only") }
    func delete(_ path: String) async throws { throw FileError("Read-only") }
    func changeMode(_ paths: [String], set: UInt32, clear: UInt32, owner: String?, group: String?, recursive: Bool) async throws { throw FileError("Read-only") }
    func copy(_ path: String, to: String) async throws { throw FileError("Read-only") }
    func compress(_ paths: [String], to archive: String) async throws { throw FileError("Read-only") }
    func extract(_ archive: String, into folder: String) async throws { throw FileError("Read-only") }
    func read(_ path: String, maxBytes: Int) async throws -> Data { throw FileError("Read-only") }
    func write(_ path: String, _ data: Data) async throws { throw FileError("Read-only") }
}

@Suite struct FileSearchTests {
    let host = TreeHost(["/srv/app/Readme.md", "/srv/app/src/readme.txt", "/srv/app/src/main.c", "/srv/README/",
                         "/srv/.cache/readme", "/srv/notes.txt"])

    private func paths(_ query: String, showHidden: Bool = false) async throws -> [String] {
        try await FileSearch.run(query, under: "/srv", on: host, showHidden: showHidden).entries.map(\.path)
    }

    @Test func findsNamesInSubfoldersWhateverTheirCaseNearestFirst() async throws {
        let seen = Recorder<Int>()
        let found = try await FileSearch.run(" readme ", under: "/srv", on: host, showHidden: false) { seen.add($0.entries.count) }
        #expect(found.entries.map(\.path) == ["/srv/README", "/srv/app/Readme.md", "/srv/app/src/readme.txt"])
        #expect(found.entries.map(\.isDir) == [true, false, false])
        #expect(found.cutShort == nil)
        // The sheet's second column.
        #expect(found.entries.map { FileSearch.folder(of: $0.path, under: "/srv") } == ["", "app", "app/src"])
        // Each folder that added something was shown as it came.
        #expect(seen.all == [1, 2, 3])
    }

    @Test func foldersAreNamedFromTheRoot() {
        #expect(FileSearch.folder(of: "/a", under: "/") == "")
        #expect(FileSearch.folder(of: "/a/b/c", under: "/") == "a/b")
        #expect(FileSearch.folder(of: "/srv/app/x", under: "/srv/") == "app")
        // An item a provider places outside the root shows where it really is.
        #expect(FileSearch.folder(of: "/etc/passwd", under: "/srv") == "/etc")
    }

    @Test func aBlankQueryAsksTheHostNothing() async throws {
        #expect(try await paths("").isEmpty)
        #expect(try await paths("  \n").isEmpty)
        #expect(host.listed.all.isEmpty)
    }

    @Test func hiddenItemsAreLeftOutAndNotEnteredUnlessShown() async throws {
        #expect(try await paths("cache").isEmpty)
        #expect(!(try await paths("readme")).contains("/srv/.cache/readme"))
        #expect(!host.listed.all.contains("/srv/.cache"))
        #expect(try await paths("cache", showHidden: true) == ["/srv/.cache"])
        #expect(try await paths("readme", showHidden: true).contains("/srv/.cache/readme"))
    }

    @Test func aFolderThatCannotBeListedIsPassedOver() async throws {
        host.denied = ["/srv/app"]
        #expect(try await paths("readme") == ["/srv/README"])
    }

    @Test func theFolderSearchedFromFailingIsAnError() async {
        host.denied = ["/srv"]
        await #expect(throws: FileError.self) { try await paths("readme") }
    }

    @Test func aLinkedFolderIsFoundButNotEntered() async throws {
        try await withTempDir { dir in
            try FileManager.default.createDirectory(atPath: dir + "/a", withIntermediateDirectories: false)
            try Data().write(to: URL(filePath: dir + "/a/target.txt"))
            // Leads back up: entering it would find target.txt again and again.
            try FileManager.default.createSymbolicLink(atPath: dir + "/a/loop", withDestinationPath: dir)
            let local = LocalFileProvider()
            #expect(try await FileSearch.run("target", under: dir, on: local, showHidden: false).entries.map(\.path) == [dir + "/a/target.txt"])
            let link = try await FileSearch.run("loop", under: dir, on: local, showHidden: false)
            #expect(link.entries.map(\.path) == [dir + "/a/loop"])
            #expect(link.cutShort == nil)
        }
    }

    @Test func stopsAtTheCapsAndSaysSo() async throws {
        let big = TreeHost((0..<30).map { "/big/\($0 % 3)/f\($0)" })
        let capped = try await FileSearch.run("f", under: "/big", on: big, showHidden: false, maxResults: 10)
        #expect(capped.entries.count == 10)
        #expect(capped.cutShort == "Showing the first 10 matches. Type more to narrow them.")
        // Exactly as many as the cap is everything, not a list cut short.
        let all = try await FileSearch.run("f", under: "/big", on: big, showHidden: false, maxResults: 30)
        #expect(all.entries.count == 30)
        #expect(all.cutShort == nil)
        // Three folders and two of the first one's files, then no further.
        let fresh = TreeHost((0..<30).map { "/big/\($0 % 3)/f\($0)" })
        let visited = try await FileSearch.run("f", under: "/big", on: fresh, showHidden: false, maxVisited: 5)
        #expect(visited.entries.count == 2)
        #expect(visited.cutShort == "Stopped after 5 items. Search from a folder further in.")
        #expect(fresh.listed.all == ["/big", "/big/0"])
    }

    @Test func cancellingStopsTheWalk() async {
        host.onList = { if $0 == "/srv/app" { withUnsafeCurrentTask { $0?.cancel() } } }
        // A task of its own: the one cancelled is whichever is listing.
        let walk = Task { try await paths("readme") }
        await #expect(throws: CancellationError.self) { try await walk.value }
        #expect(host.listed.all == ["/srv", "/srv/app"])
    }
}

/// The sheet as a PNG beside the Files screen's (see `Snapshots`); it needs a window server, so only when asked.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOLTZ_SNAPSHOTS"] != nil))
struct FileSearchSnapshots {
    @Test func sheet() async throws {
        try FileManager.default.createDirectory(at: Snapshots.out, withIntermediateDirectories: true)
        let host = TreeHost(["/var/www/logs/", "/var/www/deploy.log", "/var/www/releases/42/storage/logs/laravel.log",
                             "/var/www/releases/42/app/Logger.php", "/var/www/shared/catalog.json"])
        for (query, name) in [("log", "search"), ("nothing-here", "search-empty")] {
            let sheet = FileSearchSheet(provider: host, root: "/var/www", showHidden: false, query: query) { _ in }
            for dark in [true, false] {
                try await Snapshots.render(sheet, size: CGSize(width: 552, height: 472), dark: dark, selectFirstRows: false,
                                           to: Snapshots.out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
