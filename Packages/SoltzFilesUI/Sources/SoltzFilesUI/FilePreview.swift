// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A file on this Mac for Quick Look to show. A host's file is copied here first, into a folder of its own as
/// "Edit on This Mac" does, but nothing ever goes back to the host.
enum FilePreview {
    /// Nothing larger is fetched from a host just to be looked at.
    static let maxBytes: UInt64 = 50_000_000

    /// Where the copies live, each as "<copies>/<UUID>/<name>".
    private static let copies = FileManager.default.temporaryDirectory.appending(path: "Soltz Previews")
    /// Once per launch, before any copy of this one: what an earlier run left behind (a crash, a quit mid-preview).
    private static let swept: Void = { try? FileManager.default.removeItem(at: copies) }()

    /// A file URL on this Mac showing `entry`: the file itself when `provider.isLocal`, otherwise a copy
    /// downloaded to a temporary folder of its own. Throws for a folder, for a host's file above `maxBytes`,
    /// and when the task is cancelled.
    static func url(for entry: FileEntry, on provider: any FileProvider) async throws -> URL {
        _ = swept
        return try await url(for: entry, on: provider, in: copies)
    }

    /// Removes the temporary copy `url(for:on:)` made. Does nothing for any other URL.
    static func discard(_ url: URL) {
        discard(url, in: copies)
    }

    /// `root` holds the copies. Tests pass a folder of their own, so a running app's previews are never swept by them.
    static func url(for entry: FileEntry, on provider: any FileProvider, in root: URL) async throws -> URL {
        guard !entry.isDir else { throw FileError("“\(entry.name)” is a folder.") }
        if provider.isLocal { return URL(filePath: entry.path) }
        // The name comes from the host and becomes a path on this Mac.
        guard Paths.isPlainName(entry.name) else { throw FileError("“\(entry.name)” has a name this Mac can’t use.") }
        guard entry.size <= maxBytes else { throw tooLarge(entry) }
        let folder = root.appending(path: UUID().uuidString).path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let copy = Paths.join(folder, entry.name)
        let (progress, events) = AsyncStream.makeStream(of: TransferEvent.self)
        let download = Task {
            defer { events.finish() }
            // Run by the host with itself as the source: a download (see `FileProvider.transfer`). The folder is
            // new, so nothing is there to ask about.
            try await provider.transfer(entry, from: provider, to: copy, id: UUID().uuidString, resume: false,
                                        events: { events.yield($0) }, onConflict: { _ in .cancel })
        }
        // The size checked above is what the host's listing said; what actually arrives is counted too.
        let overran = Task {
            for await event in progress {
                if case .progress(let transferred, let total) = event, max(transferred, total) > maxBytes {
                    download.cancel()
                    return true
                }
            }
            return false
        }
        let result = await withTaskCancellationHandler { await download.result } onCancel: { download.cancel() }
        do {
            if await overran.value { throw tooLarge(entry) }
            try Task.checkCancellation()
            try result.get()
        } catch {
            // The download has returned, so nothing is still writing into the folder.
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
        // Quick Look offers to open what it shows: marked as downloaded, as the queue marks what it fetches, so
        // macOS checks an app or a script before its first run.
        var (url, values) = (URL(filePath: copy), URLResourceValues())
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                       kLSQuarantineAgentNameKey as String: "Soltz"]
        try? url.setResourceValues(values)
        return url
    }

    static func discard(_ url: URL, in root: URL) {
        // Only a copy's own folder, "<root>/<UUID>", is ever removed: any other URL is somebody's file. `normalize`
        // settles ".." first, so a path cannot name the folder and mean another.
        let path = Paths.normalize(url.path(percentEncoded: false))
        guard url.isFileURL, let folder = Paths.parent(path), UUID(uuidString: Paths.name(folder)) != nil,
              Paths.parent(folder) == Paths.normalize(root.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private static func tooLarge(_ entry: FileEntry) -> FileError {
        FileError("“\(entry.name)” is too large to preview (over \(FileRules.size(maxBytes))). Download it to look at it.")
    }
}
