// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// This Mac's disk through `FileManager`, the `fs_*` half of upstream. It runs local-to-local copies;
/// any copy with a remote end is run by the remote provider (see `FileProvider.transfer`).
public final class LocalFileProvider: FileProvider {
    public let name = "This Mac"
    public let isLocal = true

    /// Bytes per read: 1 MiB, larger than upstream's 256 KiB `CHUNK_SIZE` because a local disk is no wire.
    static let chunk = 1 << 20

    public init() {}

    public func list(_ path: String) async throws -> [FileEntry] {
        // An entry that vanishes between listing and stat is left out rather than failing the folder.
        try FileManager.default.contentsOfDirectory(atPath: path).compactMap { try? Self.entry(at: Paths.join(path, $0)) }
    }

    public func stat(_ path: String) async throws -> Bool? {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) ? isDir.boolValue : nil
    }

    public func home() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    }

    public func realpath(_ path: String) async throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw Self.posixError(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func mkdir(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    /// Fails, as `copyItem` does, when something is at `to`.
    public func copy(_ path: String, to: String) async throws {
        try FileManager.default.copyItem(atPath: path, toPath: to)
    }

    /// With `/usr/bin/tar` (bsdtar), which makes every kind in `Archives`, zip included, by the ending (`-a`).
    public func compress(_ paths: [String], to archive: String) async throws {
        // `-a` reads the ending as written, and makes a plain tar of one it does not know.
        guard let folder = paths.first.flatMap(Paths.parent), paths.allSatisfy({ Paths.parent($0) == folder }),
              Archives.endings.contains(where: { archive.hasSuffix($0) }) else {
            throw FileError("“\(Paths.name(archive))” can’t be made from these items.")
        }
        // Made empty first, never over a file that is there; so it is this call's own to remove if tar fails.
        try await createFile(archive)
        do {
            // `./name`: a name is then never an option (`-x`) or an archive to include (`@x`). No `._name`
            // files beside each item: the archive is as likely unpacked on a host as on a Mac.
            try await Self.tar(["-a", "-cf", archive, "--no-mac-metadata", "-C", folder] + paths.map { "./" + Paths.name($0) })
        } catch {
            try? FileManager.default.removeItem(atPath: archive)
            throw error
        }
    }

    /// bsdtar reads every kind in `Archives`. Without `-P` it drops `/` and `..` from a member's name and writes
    /// through no link it unpacked, so nothing lands outside `folder`.
    public func extract(_ archive: String, into folder: String) async throws {
        try await Self.tar(["-xf", archive, "-C", folder])
    }

    /// Runs `/usr/bin/tar` with `arguments` on a thread of its own and throws what it printed when it fails.
    private static func tar(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                done.resume(with: Result {
                    let process = Process(), errors = Pipe()
                    process.executableURL = URL(filePath: "/usr/bin/tar")
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errors
                    try process.run()
                    // Read to the end before waiting: tar would stop for good on a full pipe.
                    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw FileError(said.isEmpty ? "tar failed (exit \(process.terminationStatus))." : said.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                })
            }
        }
    }

    /// Never over a file that is there.
    public func createFile(_ path: String) async throws {
        try Data().write(to: URL(filePath: path), options: .withoutOverwriting)
    }

    public func rename(_ from: String, to: String) async throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    /// Moves to the Trash. Where that fails (a volume without one) the error surfaces; nothing is deleted for good.
    public func delete(_ path: String) async throws {
        try trash(path)
    }

    /// Where the item went in the Trash.
    @discardableResult
    func trash(_ path: String) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: &trashed)
        guard let trashed else { throw FileError("“\(Paths.name(path))” couldn’t be moved to the Trash.") }
        return trashed as URL
    }

    /// The owner and group change only for who may change them (root, or the owner to a group of theirs):
    /// the system's error surfaces otherwise.
    public func changeMode(_ paths: [String], set: UInt32, clear: UInt32, owner: String?, group: String?, recursive: Bool) async throws {
        let fm = FileManager.default
        var change: [FileAttributeKey: Any] = [:]
        // By id: `FileManager` quietly leaves the owner alone when given a name nobody has.
        if let owner {
            guard let user = getpwnam(owner) else { throw FileError("There’s no user named “\(owner)” on this Mac.") }
            change[.ownerAccountID] = NSNumber(value: user.pointee.pw_uid)
        }
        if let group {
            guard let found = getgrnam(group) else { throw FileError("There’s no group named “\(group)” on this Mac.") }
            change[.groupOwnerAccountID] = NSNumber(value: found.pointee.gr_gid)
        }
        func apply(_ path: String, top: Bool) throws {
            let attributes = try fm.attributesOfItem(atPath: path)
            // A link inside is left alone, as `chmod -R` leaves it: changing it changes what it points to.
            if !top, attributes[.type] as? FileAttributeType == .typeSymbolicLink { return }
            let walks = recursive && attributes[.type] as? FileAttributeType == .typeDirectory
            // Listed before the change (a folder losing its read bit could not be listed after) and, where that
            // fails, after it (a folder only now gaining the bit).
            var inside = walks ? try? fm.contentsOfDirectory(atPath: path) : []
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
            change[.posixPermissions] = NSNumber(value: (mode & ~clear) | set)
            try fm.setAttributes(change, ofItemAtPath: path)
            if inside == nil { inside = try fm.contentsOfDirectory(atPath: path) }
            for name in inside ?? [] { try apply(Paths.join(path, name), top: false) }
        }
        for top in paths { try apply(top, top: true) }
    }

    public func read(_ path: String, maxBytes: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw FileError("“\(Paths.name(path))” is larger than \(FileRules.size(UInt64(maxBytes))).") }
        return data
    }

    public func write(_ path: String, _ data: Data) async throws {
        try data.write(to: URL(filePath: path), options: .atomic)
    }

    public func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String,
                         resume: Bool, events: @escaping @Sendable (TransferEvent) -> Void,
                         onConflict: @escaping @Sendable (TransferConflict) async -> ConflictChoice) async throws {
        guard source.isLocal else { throw FileError("A copy from \(source.name) is run by \(source.name), not this Mac.") }
        // Resolved once: the walk reports resolved paths, so a folder reached through a symlink (or a pane
        // opened through one) must be walked, and checked against its destination, by its real path.
        let real = try await realpath(item.path)
        if item.isDir, let parent = Paths.parent(destinationPath),
           Paths.isSameOrUnder(Paths.join((try? await realpath(parent)) ?? parent, Paths.name(destinationPath)), real) {
            throw FileError("“\(item.name)” can’t be copied into itself.")
        }
        if let existingIsDir = try await stat(destinationPath) {
            switch await onConflict(TransferConflict(source: item, destinationPath: destinationPath, destinationIsDir: existingIsDir)) {
            case .skip: return
            case .cancel: throw CancellationError()
            case .overwrite:
                guard existingIsDir == item.isDir else {
                    throw FileError("“\(item.name)” can’t replace a \(existingIsDir ? "folder" : "file") with the same name.")
                }
            }
        }
        let (dirs, files) = try plan(real, isDir: item.isDir, to: destinationPath, events: events)
        let total = files.reduce(0) { $0 + $1.size }
        var done: UInt64 = 0
        events(.progress(transferred: 0, total: total))
        for dir in dirs where !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        for file in files {
            try Task.checkCancellation()
            if !(resume && Self.landed(file)) {
                try Self.copy(file) { done += $0; events(.progress(transferred: done, total: total)) }
            } else {
                done += file.size
            }
        }
        events(.progress(transferred: done, total: total))
    }

    // MARK: Copy engine

    struct PlannedFile {
        var from: String
        var to: String
        var size: UInt64
        var attributes: [FileAttributeKey: Any]
    }

    /// The directories to create (the root first) and the files to copy from `source`, a resolved path.
    /// Symlinks inside a tree are left out, as upstream's `visit` does; unreadable entries are reported as skipped.
    private func plan(_ source: String, isDir: Bool, to destination: String,
                      events: @Sendable (TransferEvent) -> Void) throws -> ([String], [PlannedFile]) {
        guard isDir else {
            let attributes = try FileManager.default.attributesOfItem(atPath: source)
            return ([], [PlannedFile(from: source, to: destination, size: Self.size(attributes), attributes: attributes)])
        }
        let root = URL(filePath: source, directoryHint: .isDirectory)
        var dirs = [destination], files: [PlannedFile] = [], unreadable: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) { url, _ in
            unreadable.append(url.path(percentEncoded: false))
            return true
        }
        while let url = walker?.nextObject() as? URL {
            let rel = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            let from = Paths.join(source, rel), to = Paths.join(destination, rel)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: from) else {
                unreadable.append(from)
                continue
            }
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory: dirs.append(to)
            case .typeRegular: files.append(PlannedFile(from: from, to: to, size: Self.size(attributes), attributes: attributes))
            default: continue
            }
        }
        unreadable.forEach { events(.skipped($0)) }
        return (dirs, files)
    }

    /// Upstream `landed`: a Retry keeps a file whose size and mtime already match.
    private static func landed(_ file: PlannedFile) -> Bool {
        guard let there = try? FileManager.default.attributesOfItem(atPath: file.to),
              let mine = file.attributes[.modificationDate] as? Date,
              let theirs = there[.modificationDate] as? Date else { return false }
        return size(there) == file.size && abs(mine.timeIntervalSince(theirs)) < 1
    }

    /// Writes a hidden temp file beside the target and renames it over the target once complete, as upstream's
    /// `.soltz-part` files do, so a cancelled or failed copy never leaves a partial file under the final
    /// name. The copy keeps the source's mode and modification date.
    // shortcut: reads and writes block a cooperative-pool thread for the whole file; move them to a
    // dedicated queue if many large local copies ever run at once.
    private static func copy(_ file: PlannedFile, progress: (UInt64) -> Void) throws {
        let dir = Paths.parent(file.to) ?? "/"
        // shortcut: a name near 255 bytes makes the temp name too long and the copy fails; trim it like
        // Upstream `temp_name` if that ever shows up.
        let part = Paths.join(dir, ".\(Paths.name(file.to)).\(UUID().uuidString.prefix(8)).soltz-part")
        guard FileManager.default.createFile(atPath: part, contents: nil) else {
            throw FileError("Couldn’t write to “\(Paths.name(dir))”.")
        }
        do {
            let input = try FileHandle(forReadingFrom: URL(filePath: file.from))
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: URL(filePath: part))
            defer { try? output.close() }
            while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
                progress(UInt64(data.count))
            }
            try Task.checkCancellation()
            try FileManager.default.setAttributes(file.attributes.filter { $0.key == .posixPermissions || $0.key == .modificationDate },
                                                  ofItemAtPath: part)
            guard Darwin.rename(part, file.to) == 0 else { throw posixError(file.to) }
        } catch {
            try? FileManager.default.removeItem(atPath: part)
            throw error
        }
    }

    // MARK: Helpers

    static func entry(at path: String) throws -> FileEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        var isDir: ObjCBool = false
        // A symlink lists as the folder it points to, so it can be opened.
        let dir = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        return FileEntry(name: Paths.name(path), path: path, size: size(attributes), isDir: dir,
                         isSymlink: attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                         modified: attributes[.modificationDate] as? Date,
                         permissions: (attributes[.posixPermissions] as? NSNumber)?.uint32Value,
                         owner: attributes[.ownerAccountName] as? String)
    }

    private static func size(_ attributes: [FileAttributeKey: Any]) -> UInt64 {
        (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func posixError(_ path: String) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return FileError("“\(Paths.name(path))”: \(String(cString: strerror(code.rawValue))).")
    }
}
