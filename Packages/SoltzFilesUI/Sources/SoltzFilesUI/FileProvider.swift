// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One directory entry: upstream `RemoteFile` (commands/sftp/mod.rs), as `sftp_list_dir`
/// and `fs_list_dir` return it. `modified` is its unix seconds, `permissions` its `st_mode` (only the low
/// twelve bits are shown or changed). `owner` is not part of `RemoteFile`: a provider fills it from
/// `sftp_owners` (`OwnerInfo.user`) when it has it, or leaves it nil.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var size: UInt64
    public var isDir: Bool
    public var isSymlink: Bool
    public var modified: Date?
    public var permissions: UInt32?
    public var owner: String?

    public var id: String { path }

    public init(name: String, path: String, size: UInt64 = 0, isDir: Bool = false, isSymlink: Bool = false,
                modified: Date? = nil, permissions: UInt32? = nil, owner: String? = nil) {
        self.name = name
        self.path = path
        self.size = size
        self.isDir = isDir
        self.isSymlink = isSymlink
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
    }
}

/// What a running transfer reports. Upstream emits each as the event `sftp-{kind}-{transfer_id}`
/// (`emit` in commands/sftp/resume/mod.rs, `report_skipped` in sftp/backend.rs).
public enum TransferEvent: Sendable, Equatable {
    /// `sftp-progress-{tid}` with `TransferProgress { transferred, total }`: bytes of the whole item, a tree included.
    case progress(transferred: UInt64, total: UInt64)
    /// `sftp-skipped-{tid}` with a path: an entry left out (a name the destination cannot hold, an unreadable
    /// entry, a directory that loops back on itself).
    case skipped(String)
    /// `sftp-resumed-{tid}` with `{ offset }`: bytes already in place when an interrupted copy picked up again.
    case resumed(offset: UInt64)
    /// `sftp-waiting-{tid}` with `{ waiting }`: the link dropped and the copy waits for it (true) or is back (false).
    case waiting(Bool)
}

public extension FileProvider {
    /// The modes alone, of the paths themselves.
    func changeMode(_ paths: [String], set: UInt32, clear: UInt32) async throws {
        try await changeMode(paths, set: set, clear: clear, owner: nil, group: nil, recursive: false)
    }
}

/// The archives the panes pack and unpack, told by a name's ending.
public enum Archives {
    /// What Compress makes: tar is on every host, zip often is not.
    public static let made = ".tar.gz"
    /// What Extract understands, longest ending first.
    public static let endings = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".tar", ".zip"]

    public static func isArchive(_ name: String) -> Bool { ending(of: name) != nil }

    /// The archive's ending, nil for anything else (or a name that is nothing but the ending).
    public static func ending(of name: String) -> String? {
        let lower = name.lowercased()
        return endings.first { lower.hasSuffix($0) && lower.count > $0.count }
    }

    /// The name without its archive ending: the folder Extract makes.
    public static func stem(_ name: String) -> String {
        ending(of: name).map { String(name.dropLast($0.count)) } ?? name
    }
}

/// The destination already holds an item with the source's name. Upstream asks before it copies
/// (`queueAfterConflicts` in osDropPipeline.ts) after `sftp_stat`, whose `Some(is_dir)` is `destinationIsDir`.
public struct TransferConflict: Sendable, Equatable {
    public var source: FileEntry
    public var destinationPath: String
    public var destinationIsDir: Bool

    public init(source: FileEntry, destinationPath: String, destinationIsDir: Bool) {
        self.source = source
        self.destinationPath = destinationPath
        self.destinationIsDir = destinationIsDir
    }
}

/// A provider's answer to one conflict. Upstream `ConflictResolution` (SFTPTypes.ts) also has "overwrite all"
/// and "skip all": `TransferQueue` keeps those for the rest of the batch, so a provider only sees these three.
public enum ConflictChoice: Sendable, Equatable {
    case overwrite
    case skip
    /// Stop: the transfer throws `CancellationError` without writing anything.
    case cancel
}

/// An error with a message ready for an alert.
public struct FileError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A file system the panes browse and the queue copies between: the local disk (`LocalFileProvider`) or a
/// remote session (the Rust bridge, one instance per `sftp_id`). Paths are absolute POSIX paths on both.
/// Errors surface as their `localizedDescription`; a cancelled transfer throws `CancellationError`.
public protocol FileProvider: AnyObject, Sendable {
    /// Shown in the path bar's root and in the queue, e.g. "This Mac" or "deploy@web-1".
    var name: String { get }
    /// Paths are this Mac's: they drag out to Finder as file URLs and are copied by `LocalFileProvider`.
    var isLocal: Bool { get }

    /// `sftp_list_dir(sftp_id, path)` / `fs_list_dir(path)`, in any order.
    func list(_ path: String) async throws -> [FileEntry]
    /// `sftp_stat` / `fs_stat`: whether `path` is a directory, nil when nothing is there.
    func stat(_ path: String) async throws -> Bool?
    /// `fs_home_dir`; on SFTP `sftp_canonicalize(".")`, where a session starts (panelSftpStore.ts).
    func home() async throws -> String
    /// `sftp_canonicalize`: the absolute path with symlinks resolved; throws when nothing is there.
    func realpath(_ path: String) async throws -> String
    /// `sftp_mkdir` / `fs_mkdir`.
    func mkdir(_ path: String) async throws
    /// `sftp_touch`: a new, empty file at `path`. Fails when something is there: nothing is ever emptied.
    func createFile(_ path: String) async throws
    /// `sftp_rename` / `fs_rename`; fails when `to` exists, as SFTP v3 rename does.
    func rename(_ from: String, to: String) async throws
    /// `sftp_delete`: removes a directory with everything in it, for good. `LocalFileProvider` moves the item
    /// to the Trash instead (upstream's `fs_delete` is permanent), so the pane words its confirmation by `isLocal`.
    func delete(_ path: String) async throws
    /// `sftp_set_attrs` / `fs_set_attrs` with `AttrChange { paths, set, clear, owner, group, recurse }`: each path's
    /// mode becomes `(mode & ~clear) | set`; `owner` and `group` (names; nil leaves them) become its owner and group;
    /// `recursive` does the same to everything inside a folder. On a host the last three need a remote shell.
    func changeMode(_ paths: [String], set: UInt32, clear: UInt32, owner: String?, group: String?, recursive: Bool) async throws
    /// A copy of `path` (a file, or a folder with everything in it) at `to`, on the same file system. Fails when
    /// something is at `to`. On a host it is made by the host itself (a remote shell), not sent through this Mac.
    func copy(_ path: String, to: String) async throws
    /// Packs `paths` (items of one folder, stored by their names) into a new archive at `archive`, of the kind its
    /// extension says (`Archives`). Fails when something is at `archive`. On a host it needs a remote shell.
    func compress(_ paths: [String], to archive: String) async throws
    /// Unpacks the archive at `archive` (a kind `Archives.isArchive` knows) into `folder`, which is there and empty:
    /// the pane makes it first, so nothing that exists is ever written over. On a host it needs a remote shell.
    func extract(_ archive: String, into folder: String) async throws
    /// `sftp_read_file(path, max_bytes)`: the bytes of a small file; throws when it is larger than `maxBytes`.
    func read(_ path: String, maxBytes: Int) async throws -> Data
    /// `sftp_write_file(path, content)`; the bridge sends `data` as UTF-8 text, as upstream's editor does.
    func write(_ path: String, _ data: Data) async throws

    /// Copies `item` (a file, or a directory with everything under it) from `source` to `destinationPath`,
    /// the full path it gets. `TransferQueue` calls this on the remote end of the pair (the destination when
    /// both are remote, `source` when only the destination is local, either when both are local), so:
    /// - destination self, source local: `sftp_upload` / `sftp_upload_dir(local_path, remote_path)`
    /// - source self, destination local: `sftp_download` / `sftp_download_dir(remote_path, local_path)`
    /// - both remote: `sftp_transfer` / `sftp_transfer_dir(src_sftp_id, src_path, dst_sftp_id, dst_path)`
    /// `id` is the `transfer_id`; `resume` means `sftp_mark_resume(id)` first (a Retry: landed files are kept);
    /// cancelling the calling task is `sftp_cancel_transfer(id)`; `events` carries `sftp-*-{id}`.
    /// When something already sits at `destinationPath`, ask `onConflict` before writing (the bridge
    /// `sftp_stat`s first, as upstream's UI does); inside a directory tree files are overwritten, as upstream's
    /// `copy_tree` does. A file never replaces a directory or the other way round.
    func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String,
                  resume: Bool, events: @escaping @Sendable (TransferEvent) -> Void,
                  onConflict: @escaping @Sendable (TransferConflict) async -> ConflictChoice) async throws
}
