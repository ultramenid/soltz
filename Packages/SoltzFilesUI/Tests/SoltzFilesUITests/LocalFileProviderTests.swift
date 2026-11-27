// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SoltzFilesUI

/// Runs `body` in a fresh directory under the temporary directory and removes it afterwards.
func withTempDir(isolation: isolated (any Actor)? = #isolation, _ body: (String) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.path(percentEncoded: false)
    let dir = try await LocalFileProvider().realpath(base) + "/SoltzFilesUITests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await body(dir)
}

final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func put(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(atPath: Paths.parent(path)!, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(filePath: path))
}

private func text(_ path: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self)
}

private func entry(_ path: String) throws -> FileEntry { try LocalFileProvider.entry(at: path) }

private func copy(_ item: FileEntry, to path: String, resume: Bool = false, choice: ConflictChoice = .cancel,
                  conflicts: Recorder<TransferConflict> = Recorder(), events: Recorder<TransferEvent> = Recorder()) async throws {
    let local = LocalFileProvider()
    try await local.transfer(item, from: local, to: path, id: "t", resume: resume, events: { events.add($0) },
                             onConflict: { conflicts.add($0); return choice })
}

private func mode(_ path: String) throws -> UInt32? { try entry(path).permissions }

/// One ustar member with any name (`prefix` is a folder before it) and, for a link, target: tar itself writes
/// no `..` or absolute name.
private func tarMember(_ name: String, prefix: String = "", link: String? = nil, _ content: String = "") -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    func set(_ text: String, at offset: Int) { header.replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8) }
    set(name, at: 0)
    set("0000644", at: 100)
    set(String(content.utf8.count, radix: 8), at: 124)
    set(link == nil ? "0" : "2", at: 156)
    set(link ?? "", at: 157)
    set("ustar", at: 257)
    set("00", at: 263)
    set(prefix, at: 345)
    // The checksum counts its own field as spaces.
    set("        ", at: 148)
    set(String(header.reduce(0) { $0 + Int($1) }, radix: 8) + "\0", at: 148)
    let body = Data(content.utf8)
    return Data(header) + body + Data(count: (512 - body.count % 512) % 512)
}

@Suite struct LocalProvider {
    let local = LocalFileProvider()

    @Test func browsingAndEditing() async throws {
        try await withTempDir { dir in
            try await local.mkdir(dir + "/docs")
            try put(dir + "/a.txt", "hello")
            try await local.createFile(dir + "/new.txt")
            #expect(try await local.stat(dir + "/new.txt") == false)
            await #expect(throws: (any Error).self) { try await local.createFile(dir + "/a.txt") }
            #expect(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8) == "hello", "a new file never empties one that is there")
            try FileManager.default.removeItem(atPath: dir + "/new.txt")
            #expect(try await local.stat(dir + "/docs") == true)
            #expect(try await local.stat(dir + "/a.txt") == false)
            #expect(try await local.stat(dir + "/none") == nil)

            let listed = try await local.list(dir).sorted(using: FileComparator(.name))
            #expect(listed.map(\.name) == ["docs", "a.txt"])
            #expect(listed[1].path == dir + "/a.txt" && listed[1].size == 5 && !listed[1].isDir)
            #expect(listed[1].modified != nil && listed[1].permissions != nil && listed[1].owner != nil)

            try await local.rename(dir + "/a.txt", to: dir + "/docs/b.txt")
            await #expect(throws: (any Error).self) { try await local.rename(dir + "/docs", to: dir + "/docs/b.txt") }
            try await local.changeMode([dir + "/docs/b.txt"], set: 0o700, clear: 0o077)
            #expect(try entry(dir + "/docs/b.txt").permissions == 0o700)

            try await local.write(dir + "/docs/b.txt", Data("bye".utf8))
            #expect(try await local.read(dir + "/docs/b.txt", maxBytes: 3) == Data("bye".utf8))
            await #expect(throws: FileError.self) { try await local.read(dir + "/docs/b.txt", maxBytes: 2) }

            try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/docs")
            #expect(try await local.realpath(dir + "/link/../docs/./b.txt") == dir + "/docs/b.txt")
            #expect(try entry(dir + "/link").isSymlink && entry(dir + "/link").isDir)
            await #expect(throws: FileError.self) { try await local.realpath(dir + "/missing") }

            try FileManager.default.removeItem(atPath: dir + "/docs")
        }
    }

    /// The only test that touches the user's Trash, and it removes what it put there.
    @Test func deleteMovesToTheTrash() async throws {
        try await withTempDir { dir in
            let name = "SoltzFilesUITests-\(UUID().uuidString).txt"
            try put(dir + "/" + name, "trash me")
            let trashed = try local.trash(dir + "/" + name)
            defer { try? FileManager.default.removeItem(at: trashed) }
            #expect(try await local.stat(dir + "/" + name) == nil)
            #expect(trashed.pathComponents.contains { $0.hasPrefix(".Trash") })
            #expect(try text(trashed.path(percentEncoded: false)) == "trash me")
            try FileManager.default.removeItem(at: trashed)
            #expect(!FileManager.default.fileExists(atPath: trashed.path(percentEncoded: false)))
        }
    }

    @Test func treeTransferCopiesEveryByteAndKeepsModesAndDates() async throws {
        try await withTempDir { dir in
            let src = dir + "/src"
            try put(src + "/a.txt", "alpha")
            try put(src + "/.hidden", "secret")
            try put(src + "/sub/deeper/c.txt", "gamma")
            let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try big.write(to: URL(filePath: src + "/sub/big.bin"))
            try FileManager.default.createDirectory(atPath: src + "/empty", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: src + "/link", withDestinationPath: src + "/a.txt")
            try FileManager.default.setAttributes([.posixPermissions: 0o751, .modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                                  ofItemAtPath: src + "/a.txt")

            let events = Recorder<TransferEvent>()
            let conflicts = Recorder<TransferConflict>()
            try await copy(try entry(src), to: dir + "/dst/copy", conflicts: conflicts, events: events)
            let dst = dir + "/dst/copy"
            #expect(conflicts.all.isEmpty)
            for rel in ["a.txt", ".hidden", "sub/deeper/c.txt", "sub/big.bin"] {
                #expect(FileManager.default.contentsEqual(atPath: src + "/" + rel, andPath: dst + "/" + rel), "\(rel)")
            }
            #expect(try await local.stat(dst + "/empty") == true)
            #expect(try await local.stat(dst + "/link") == nil)
            let copied = try entry(dst + "/a.txt")
            #expect(copied.permissions == 0o751)
            #expect(copied.modified == Date(timeIntervalSince1970: 1_000_000))
            let total = UInt64(5 + 6 + 5 + big.count)
            #expect(events.all.first == .progress(transferred: 0, total: total))
            #expect(events.all.last == .progress(transferred: total, total: total))
            #expect(!(try FileManager.default.subpathsOfDirectory(atPath: dir + "/dst")).contains { $0.hasSuffix(".soltz-part") })
        }
    }

    @Test func cancelLeavesNoPartialFile() async throws {
        try await withTempDir { dir in
            let big = Data(repeating: 7, count: 5 << 20)
            try big.write(to: URL(filePath: dir + "/big.bin"))
            try put(dir + "/out/kept.bin", "old")
            let cancelOnFirstChunk = Recorder<TransferEvent>()
            for target in ["new.bin", "kept.bin"] {
                let local = LocalFileProvider(), item = try entry(dir + "/big.bin")
                // The events closure runs on the transfer's own task, so it can cancel exactly that task.
                let task = Task {
                    try await local.transfer(item, from: local, to: dir + "/out/" + target, id: "t", resume: false,
                                             events: { event in
                                                 cancelOnFirstChunk.add(event)
                                                 if case .progress(let done, _) = event, done > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                                             },
                                             onConflict: { _ in .overwrite })
                }
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(cancelOnFirstChunk.all.contains { if case .progress(let done, _) = $0 { done > 0 } else { false } })
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/out") == ["kept.bin"])
            #expect(try text(dir + "/out/kept.bin") == "old")
        }
    }

    @Test func eachConflictChoice() async throws {
        try await withTempDir { dir in
            try put(dir + "/a.txt", "new")
            try put(dir + "/out/a.txt", "old")
            let item = try entry(dir + "/a.txt")
            let conflicts = Recorder<TransferConflict>()

            try await copy(item, to: dir + "/out/a.txt", choice: .skip, conflicts: conflicts)
            #expect(try text(dir + "/out/a.txt") == "old")
            #expect(conflicts.all == [TransferConflict(source: item, destinationPath: dir + "/out/a.txt", destinationIsDir: false)])

            await #expect(throws: CancellationError.self) { try await copy(item, to: dir + "/out/a.txt", choice: .cancel) }
            #expect(try text(dir + "/out/a.txt") == "old")

            try await copy(item, to: dir + "/out/a.txt", choice: .overwrite)
            #expect(try text(dir + "/out/a.txt") == "new")

            try put(dir + "/tree/x.txt", "x")
            await #expect(throws: FileError.self) { try await copy(try entry(dir + "/tree"), to: dir + "/out/a.txt", choice: .overwrite) }
            #expect(try text(dir + "/out/a.txt") == "new")

            let none = Recorder<TransferConflict>()
            try await copy(item, to: dir + "/out/b.txt", conflicts: none)
            #expect(none.all.isEmpty)
        }
    }

    @Test func overwritingAFolderMergesIntoIt() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/x.txt", "new x")
            try put(dir + "/out/tree/x.txt", "old x")
            try put(dir + "/out/tree/y.txt", "y stays")
            try await copy(try entry(dir + "/tree"), to: dir + "/out/tree", choice: .overwrite)
            #expect(try text(dir + "/out/tree/x.txt") == "new x")
            #expect(try text(dir + "/out/tree/y.txt") == "y stays")
        }
    }

    @Test func aFolderReachedThroughASymlinkCopiesItsContents() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/sub/x.txt", "x")
            try put(dir + "/tree/y.txt", "y")
            try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/tree")
            try FileManager.default.createSymbolicLink(atPath: dir + "/alias", withDestinationPath: dir)
            let events = Recorder<TransferEvent>()
            try await copy(try entry(dir + "/link"), to: dir + "/out1", events: events)
            try await copy(try entry(dir + "/alias/tree"), to: dir + "/out2", events: events)
            for out in ["/out1", "/out2"] {
                #expect(FileManager.default.contentsEqual(atPath: dir + "/tree", andPath: dir + out), "\(out)")
            }
            #expect(!events.all.contains { if case .skipped = $0 { true } else { false } })
            await #expect(throws: FileError.self) { try await copy(try entry(dir + "/link"), to: dir + "/alias/tree/inner") }
        }
    }

    @Test func aFolderCannotBeCopiedIntoItself() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/x.txt", "x")
            await #expect(throws: FileError.self) { try await copy(try entry(dir + "/tree"), to: dir + "/tree/tree") }
            #expect(try await local.stat(dir + "/tree/tree") == nil)
        }
    }

    @Test func aRetryKeepsFilesThatAlreadyLanded() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/x.txt", "xxxx")
            try put(dir + "/tree/y.txt", "yyyy")
            try await copy(try entry(dir + "/tree"), to: dir + "/out")
            // Same size and date as the source: a resumed copy must leave it alone, a fresh one must not.
            let date = try FileManager.default.attributesOfItem(atPath: dir + "/out/x.txt")[.modificationDate] as! Date
            try put(dir + "/out/x.txt", "XXXX")
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir + "/out/x.txt")
            try FileManager.default.removeItem(atPath: dir + "/out/y.txt")

            try await copy(try entry(dir + "/tree"), to: dir + "/out", resume: true, choice: .overwrite)
            #expect(try text(dir + "/out/x.txt") == "XXXX")
            #expect(try text(dir + "/out/y.txt") == "yyyy")
            try await copy(try entry(dir + "/tree"), to: dir + "/out", choice: .overwrite)
            #expect(try text(dir + "/out/x.txt") == "xxxx")
        }
    }

    @Test func copyDuplicatesAFileOrATreeAndWritesOverNothing() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/sub/x.txt", "x")
            try put(dir + "/a.txt", "a")
            try await local.copy(dir + "/a.txt", to: dir + "/a copy.txt")
            try await local.copy(dir + "/tree", to: dir + "/tree copy")
            #expect(try text(dir + "/a copy.txt") == "a")
            #expect(FileManager.default.contentsEqual(atPath: dir + "/tree", andPath: dir + "/tree copy"))

            try put(dir + "/a.txt", "changed")
            await #expect(throws: (any Error).self) { try await local.copy(dir + "/a.txt", to: dir + "/a copy.txt") }
            await #expect(throws: (any Error).self) { try await local.copy(dir + "/a.txt", to: dir + "/tree copy") }
            #expect(try text(dir + "/a copy.txt") == "a")
            #expect(try await local.stat(dir + "/tree copy/a.txt") == nil)
        }
    }

    @Test func compressStoresNamesOfTheFolderAndExtractBringsThemBack() async throws {
        try await withTempDir { dir in
            try put(dir + "/tree/sub/@at.txt", "at")
            try put(dir + "/-dash.txt", "dash")
            // The first bytes say what tar made of each ending.
            let magic: [String: [UInt8]] = [".tar.gz": [0x1F, 0x8B], ".tbz2": [0x42, 0x5A], ".tar.xz": [0xFD, 0x37], ".zip": [0x50, 0x4B], ".tar": Array("./".utf8)]
            for (ending, bytes) in magic {
                let archive = dir + "/pack" + ending, out = dir + "/out" + ending
                try await local.compress([dir + "/tree", dir + "/-dash.txt"], to: archive)
                let made = try Data(contentsOf: URL(filePath: archive))
                #expect(Array(made.prefix(2)) == bytes, "\(ending)")
                await #expect(throws: (any Error).self, "\(ending)") { try await local.compress([dir + "/-dash.txt"], to: archive) }
                #expect(try Data(contentsOf: URL(filePath: archive)) == made, "an archive that is there stays as it is")

                try await local.mkdir(out)
                try await local.extract(archive, into: out)
                #expect(try FileManager.default.contentsOfDirectory(atPath: out).sorted() == ["-dash.txt", "tree"], "\(ending)")
                #expect(FileManager.default.contentsEqual(atPath: dir + "/tree", andPath: out + "/tree"), "\(ending)")
                #expect(try text(out + "/-dash.txt") == "dash")
            }

            await #expect(throws: FileError.self) { try await local.compress([dir + "/missing"], to: dir + "/failed.tar.gz") }
            #expect(try await local.stat(dir + "/failed.tar.gz") == nil, "a failed compress leaves no archive")
            await #expect(throws: FileError.self) { try await local.compress([dir + "/tree", dir + "/tree/sub"], to: dir + "/two.tar.gz") }
            await #expect(throws: FileError.self) { try await local.compress([dir + "/tree"], to: dir + "/loud.ZIP") }
            await #expect(throws: FileError.self) { try await local.extract(dir + "/-dash.txt", into: dir + "/tree") }
        }
    }

    @Test func extractWritesNothingOutsideItsFolder() async throws {
        try await withTempDir { dir in
            try await local.mkdir(dir + "/outside")
            try FileManager.default.createDirectory(atPath: dir + "/deep/into", withIntermediateDirectories: true)
            let evil = tarMember("ok.txt", "fine") + tarMember("../dotdot.txt", "out")
                + tarMember("outside/abs.txt", prefix: dir, "out")
                + tarMember("link", link: "../../outside") + tarMember("link/through.txt", "out") + Data(count: 1024)
            try evil.write(to: URL(filePath: dir + "/evil.tar"))
            try? await local.extract(dir + "/evil.tar", into: dir + "/deep/into")
            #expect(try text(dir + "/deep/into/ok.txt") == "fine")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/outside").isEmpty)
            #expect(try await local.stat(dir + "/deep/dotdot.txt") == nil)
        }
    }

    @Test func changeModeReachesEverythingInsideAFolderButNothingALinkPointsTo() async throws {
        try await withTempDir { dir in
            let fm = FileManager.default
            try put(dir + "/tree/sub/x.txt", "x")
            try put(dir + "/outside/y.txt", "y")
            try fm.createSymbolicLink(atPath: dir + "/tree/link", withDestinationPath: dir + "/outside")
            let untouched = [try mode(dir + "/outside"), try mode(dir + "/outside/y.txt")]
            let group = try fm.attributesOfItem(atPath: dir + "/tree")[.groupOwnerAccountName] as? String

            try await local.changeMode([dir + "/tree"], set: 0o050, clear: 0, owner: nil, group: nil, recursive: false)
            #expect(try mode(dir + "/tree") == 0o750 | (try mode(dir + "/tree/sub") ?? 0), "the folder alone")

            // Its own owner and group: the only ones a test may give.
            try await local.changeMode([dir + "/tree"], set: 0o700, clear: 0o7777, owner: NSUserName(), group: group, recursive: true)
            for path in ["/tree", "/tree/sub", "/tree/sub/x.txt"] { #expect(try mode(dir + path) == 0o700, "\(path)") }
            #expect([try mode(dir + "/outside"), try mode(dir + "/outside/y.txt")] == untouched)
            #expect(try entry(dir + "/tree/sub/x.txt").owner == NSUserName())

            // A folder that loses its read bit is still changed all the way down.
            try await local.changeMode([dir + "/tree"], set: 0, clear: 0o400, owner: nil, group: nil, recursive: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir + "/tree")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir + "/tree/sub")
            #expect(try mode(dir + "/tree/sub/x.txt") == 0o300)

            for owner in ["root", "soltz-no-such-user"] {
                await #expect(throws: (any Error).self, "\(owner)") {
                    try await local.changeMode([dir + "/tree"], set: 0, clear: 0, owner: owner, group: nil, recursive: false)
                }
            }
        }
    }
}
