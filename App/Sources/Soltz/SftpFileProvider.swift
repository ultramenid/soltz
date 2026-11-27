// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import os
import SoltzCore
import SoltzFilesUI
import SoltzModel

/// One SSH session's files through the core's SFTP calls (upstream `sftp_*`), for the panes and the queue. The SFTP
/// session opens on first use with `sftp_open` on the SSH session's id, which the core follows across a Reconnect, as upstream's terminal panel rides the terminal's connection (src/stores/panelSftpStore.ts:68).
/// It closes with `close()` (its SSH session closed) or when the provider goes away: the core keeps it otherwise.
final class SftpFileProvider: FileProvider {
    let name: String
    let isLocal = false
    private let core: Core
    private let sessionID: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var opening: Task<String, any Error>?
        var closed = false
    }

    /// - Parameter sessionID: the core SSH session's id (`ssh_connect`'s `sessionId`), not the terminal's.
    init(core: Core, sessionID: String, name: String) {
        self.core = core
        self.sessionID = sessionID
        self.name = name
    }

    deinit { close() }

    /// Closes the SFTP session; later calls fail. Transfers still running on it fail too.
    func close() {
        let opening = state.withLock { state in
            state.closed = true
            defer { state.opening = nil }
            return state.opening
        }
        guard let opening else { return }
        Task { [core] in if let id = try? await opening.value { await core.sftpClose(sftpId: id) } }
    }

    /// The SFTP session's id, opened once; a failed open is tried again on the next call.
    func sftpID() async throws -> String {
        let opening = try state.withLock { state in
            guard !state.closed else { throw FileError("The session was closed.") }
            if let opening = state.opening { return opening }
            let opening = Task { [core, sessionID] in try await core.sftpOpen(sessionId: sessionID) }
            state.opening = opening
            return opening
        }
        do {
            return try await opening.value
        } catch {
            state.withLock { if $0.opening == opening { $0.opening = nil } }
            throw Self.translate(error)
        }
    }

    // MARK: - FileProvider

    func list(_ path: String) async throws -> [FileEntry] {
        try Self.entries(try await call { try await core.sftpListDir(sftpId: $0, path: path) })
    }

    func stat(_ path: String) async throws -> Bool? {
        try await call { try await core.sftpStat(sftpId: $0, path: path) }
    }

    func home() async throws -> String {
        try await realpath(".")
    }

    func realpath(_ path: String) async throws -> String {
        try await call { try await core.sftpCanonicalize(sftpId: $0, path: path) }
    }

    func mkdir(_ path: String) async throws {
        try await call { try await core.sftpMkdir(sftpId: $0, path: path) }
    }

    func createFile(_ path: String) async throws {
        try await call { try await core.sftpTouch(sftpId: $0, path: path) }
    }

    func rename(_ from: String, to: String) async throws {
        try await call { try await core.sftpRename(sftpId: $0, from: from, to: to) }
    }

    func delete(_ path: String) async throws {
        try await call { try await core.sftpDelete(sftpId: $0, path: path) }
    }

    func copy(_ path: String, to: String) async throws {
        try await call { try await core.sftpCopy(sftpId: $0, from: path, to: to) }
    }

    func compress(_ paths: [String], to archive: String) async throws {
        try await call { try await core.sftpCompress(sftpId: $0, paths: paths, archive: archive) }
    }

    func extract(_ archive: String, into folder: String) async throws {
        try await call { try await core.sftpExtract(sftpId: $0, archive: archive, dir: folder) }
    }

    func changeMode(_ paths: [String], set: UInt32, clear: UInt32, owner: String?, group: String?, recursive: Bool) async throws {
        var change: JSONObject = ["paths": .array(paths.map(JSONValue.string)), "set": .int(Int64(set)), "clear": .int(Int64(clear))]
        if let owner { change["owner"] = .string(owner) }
        if let group { change["group"] = .string(group) }
        if recursive { change["recurse"] = .string("all") }
        let json = try jsonString(change)
        try await call { try await core.sftpSetAttrs(sftpId: $0, changeJson: json) }
    }

    func read(_ path: String, maxBytes: Int) async throws -> Data {
        let json = try await call { try await core.sftpReadFile(sftpId: $0, path: path, maxBytes: UInt64(max(0, maxBytes))) }
        guard let file = TerminalSession.decode(ReadFile.self, json) else { throw FileError("The file couldn’t be read.") }
        return Data(file.content.utf8)
    }

    /// The bridge takes text; anything else is refused rather than written mangled.
    func write(_ path: String, _ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw FileError("Only text can be written to \(name).") }
        try await call { try await core.sftpWriteFile(sftpId: $0, path: path, content: text) }
    }

    /// Upstream's conflict check (`queueAfterConflicts`: `sftp_stat` / `fs_stat` of the destination, then ask), `resume` as
    /// `sftp_mark_resume`, then the core call `call(_:from:by:)` picks; cancelling the task is `sftp_cancel_transfer`.
    func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String, resume: Bool,
                  events: @escaping @Sendable (TransferEvent) -> Void,
                  onConflict: @escaping @Sendable (SoltzFilesUI.TransferConflict) async -> ConflictChoice) async throws {
        let call = Self.call(item, from: source, by: self)
        let toLocal = call == .download || call == .downloadDir
        if let existingIsDir = toLocal ? try await LocalFileProvider().stat(destinationPath) : try await stat(destinationPath) {
            switch await onConflict(.init(source: item, destinationPath: destinationPath, destinationIsDir: existingIsDir)) {
            case .skip: return
            case .cancel: throw CancellationError()
            case .overwrite:
                guard existingIsDir == item.isDir else {
                    throw FileError("“\(item.name)” can’t replace a \(existingIsDir ? "folder" : "file") with the same name.")
                }
            }
        }
        let mine = try await sftpID()
        let sink = Sink(events)
        if resume { core.sftpMarkResume(transferId: id) }
        try await withTaskCancellationHandler {
            do {
                switch call {
                case .upload: try await core.sftpUpload(sftpId: mine, localPath: item.path, remotePath: destinationPath, transferId: id, sink: sink)
                case .uploadDir: try await core.sftpUploadDir(sftpId: mine, localPath: item.path, remotePath: destinationPath, transferId: id, sink: sink)
                case .download: try await core.sftpDownload(sftpId: mine, remotePath: item.path, localPath: destinationPath, transferId: id, sink: sink)
                case .downloadDir: try await core.sftpDownloadDir(sftpId: mine, remotePath: item.path, localPath: destinationPath, transferId: id, sink: sink)
                case .transfer, .transferDir:
                    guard let remote = source as? SftpFileProvider else { throw FileError("Soltz can’t copy from \(source.name) to \(name).") }
                    let from = try await remote.sftpID()
                    if call == .transferDir {
                        try await core.sftpTransferDir(srcSftpId: from, srcPath: item.path, dstSftpId: mine, dstPath: destinationPath, transferId: id, sink: sink)
                    } else {
                        try await core.sftpTransfer(srcSftpId: from, srcPath: item.path, dstSftpId: mine, dstPath: destinationPath, transferId: id, sink: sink)
                    }
                }
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                throw Self.translate(error)
            }
        } onCancel: { [core] in
            Task { await core.sftpCancelTransfer(transferId: id) }
        }
    }

    // MARK: - Translation (pure)

    /// The core call that copies `item` when `runner` runs it: `TransferQueue` hands a copy to its remote end, the
    /// destination when both ends are remote (see `FileProvider.transfer`).
    enum Call: Equatable { case upload, uploadDir, download, downloadDir, transfer, transferDir }

    static func call(_ item: FileEntry, from source: any FileProvider, by runner: SftpFileProvider) -> Call {
        if source.isLocal { return item.isDir ? .uploadDir : .upload }
        if source === runner { return item.isDir ? .downloadDir : .download }
        return item.isDir ? .transferDir : .transfer
    }

    /// `sftp_list_dir`'s JSON, upstream `RemoteFile` (commands/sftp/mod.rs:46).
    static func entries(_ json: String) throws -> [FileEntry] {
        guard let listed = TerminalSession.decode([Listed].self, json) else { throw FileError("The folder listing couldn’t be read.") }
        return listed.map {
            FileEntry(name: $0.name, path: $0.path, size: $0.size, isDir: $0.isDir, isSymlink: $0.isSymlink,
                      modified: $0.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) }, permissions: $0.permissions)
        }
    }

    /// A `TransferSink` event; nil for one Soltz does not show or cannot read.
    static func event(_ name: String, _ payload: String) -> TransferEvent? {
        switch name {
        case "sftp-progress": TerminalSession.decode(Progress.self, payload).map { .progress(transferred: $0.transferred, total: $0.total) }
        case "sftp-resumed": TerminalSession.decode(Resumed.self, payload).map { .resumed(offset: $0.offset) }
        case "sftp-waiting": TerminalSession.decode(Waiting.self, payload).map { .waiting($0.waiting) }
        case "sftp-skipped": TerminalSession.decode(String.self, payload).map(TransferEvent.skipped)
        default: nil
        }
    }

    /// A core error as a `FileError` with its alert text: upstream's code text, or the `sftp_read_file` refusal JSON in
    /// Upstream's editor words (src/i18n/locales/en/fileTransfer.json `tab.error`). Cancellation stays itself.
    static func translate(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, is FileError: error
        case CoreError.Failed(let message), CoreError.Coded(_, let message):
            FileError(refusal(message) ?? describe(error))
        default: FileError(describe(error))
        }
    }

    private static func refusal(_ message: String) -> String? {
        guard let refusal = TerminalSession.decode(Refusal.self, message) else { return nil }
        return switch refusal.kind {
        case "too_large": "File too large (\(refusal.size ?? 0) bytes, limit \(refusal.limit ?? 0)). Download it instead."
        case "binary": "Binary file — can’t edit. Download it instead."
        case "image": "Image file — can’t edit. Download it instead."
        case "io": refusal.message ?? "Failed to open file."
        default: nil
        }
    }

    // MARK: - Payloads

    private struct Listed: Decodable {
        let name: String
        let path: String
        let size: UInt64
        let isDir: Bool
        let isSymlink: Bool
        let modified: UInt64?
        let permissions: UInt32?
    }

    private struct Progress: Decodable { let transferred: UInt64, total: UInt64 }
    private struct Resumed: Decodable { let offset: UInt64 }
    private struct Waiting: Decodable { let waiting: Bool }
    private struct ReadFile: Decodable { let content: String }
    private struct Refusal: Decodable { let kind: String, size: UInt64?, limit: UInt64?, message: String? }

    private func call<T: Sendable>(_ body: (String) async throws -> T) async throws -> T {
        let id = try await sftpID()
        do {
            return try await body(id)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Called by the core on its own threads.
    private final class Sink: TransferSink {
        let forward: @Sendable (TransferEvent) -> Void
        init(_ forward: @escaping @Sendable (TransferEvent) -> Void) { self.forward = forward }
        func event(name: String, payloadJson: String) { SftpFileProvider.event(name, payloadJson).map(forward) }
    }
}
