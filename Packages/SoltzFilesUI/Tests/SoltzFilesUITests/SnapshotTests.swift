// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import SoltzFilesUI

/// Renders the Files screen to PNGs for a human to compare with the design. It needs a window server, so it
/// runs only when asked:
///
///     SOLTZ_SNAPSHOTS=1 swift test --filter Snapshots
///
/// The PNGs land in `<repo>/build/snapshots/filesui/`. The window is never ordered on screen.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOLTZ_SNAPSHOTS"] != nil))
struct Snapshots {
    static let out = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../build/snapshots/filesui")
        .standardized

    @Test func filesScreen() async throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try await withTempDir { dir in
            let left = try Self.folder(dir + "/left/var/www", [
                ("releases", nil, 0, 10, 42), ("shared", nil, -3, 9, 0),
                ("db-dump-1123.sql.gz", 2_600_000_000, -1, 23, 10), ("deploy.log", 148_000, 0, 10, 44),
            ])
            let right = try Self.folder(dir + "/right/Users/you/Backups", [
                ("db-dump-1121.sql.gz", 2_500_000_000, -3, 4, 0), ("README.txt", 1_000, -53, 12, 0),
            ])
            _ = (left, right)
            let web = MappedProvider(name: "prod-web-01", isLocal: false, root: dir + "/left", home: "/home/deploy")
            let mac = MappedProvider(name: "This Mac", isLocal: true, root: dir + "/right", home: "/Users/you")

            // One transfer in flight, resumed, as in the design.
            let remote = ScriptedRemote(name: "prod-web-01")
            let queue = TransferQueue()
            queue.enqueue([FileEntry(name: "db-dump-1123.sql.gz", path: "/var/www/db-dump-1123.sql.gz", size: 2_600_000_000)],
                          from: remote, to: mac, into: "/Users/you/Backups")
            remote.send("db-dump-1123.sql.gz", .event(.resumed(offset: 1_000_000_000)))
            remote.send("db-dump-1123.sql.gz", .event(.progress(transferred: 1_900_000_000, total: 2_600_000_000)))
            defer { remote.send("db-dump-1123.sql.gz", .finish) }

            let screen = DualPaneView(left: web, right: mac, queue: queue, leftPath: "/var/www", rightPath: "/Users/you/Backups",
                                      leftSource: AnyView(Self.standInPopup("prod-web-01 · SFTP")),
                                      rightSource: AnyView(Self.standInPopup("This Mac")))
            for dark in [true, false] {
                try await Self.render(screen, size: CGSize(width: 1180, height: 640), dark: dark, selectFirstRows: true,
                                to: Self.out.appending(path: dark ? "files-dark.png" : "files-light.png"))
            }

            // Every state the card can show, and how it sizes with several rows.
            let states = TransferQueue()
            let names = ["running.bin", "queued.bin", "failed.tar", "waiting.iso", "done.txt", "stopped.zip"]
            states.enqueue(names.prefix(2).map { FileEntry(name: $0, path: "/" + $0) }, from: remote, to: mac, into: "/Users/you")
            for name in names.dropFirst(2) { states.enqueue([FileEntry(name: name, path: "/" + name)], from: remote, to: mac, into: "/Users/you") }
            try await Self.spin(seconds: 3, until: { remote.running.isSuperset(of: ["running.bin", "failed.tar", "waiting.iso", "done.txt", "stopped.zip"]) })
            remote.send("running.bin", .event(.progress(transferred: 300_000_000, total: 1_200_000_000)))
            remote.send("failed.tar", .fail("Connection reset by peer"))
            remote.send("waiting.iso", .event(.progress(transferred: 40_000_000, total: 700_000_000)))
            remote.send("waiting.iso", .event(.waiting(true)))
            remote.send("done.txt", .finish)
            states.cancel(states.transfers.first { $0.label == "stopped.zip" }!.id)
            try await Self.spin(seconds: 3, until: { states.transfers.filter(\.settled).count == 3 })
            try await Self.render(TransferQueueView(queue: states).padding(10), size: CGSize(width: 900, height: 300), dark: true,
                            selectFirstRows: false, to: Self.out.appending(path: "transfers-states-dark.png"))
            states.cancelAll()
            for name in names { remote.send(name, .finish) }
        }
    }

    /// What the app passes as a pane's source: a popup button.
    static func standInPopup(_ title: String) -> some View {
        Picker("Source", selection: .constant(0)) { Text(title).tag(0) }.labelsHidden().fixedSize()
    }

    /// Creates `path` with `(name, size or nil for a folder, days from today, hour, minute)` items.
    static func folder(_ path: String, _ items: [(String, UInt64?, Int, Int, Int)]) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let today = Calendar.current.startOfDay(for: .now)
        for (name, size, days, hour, minute) in items {
            let item = path + "/" + name
            if let size {
                FileManager.default.createFile(atPath: item, contents: nil)
                // Sparse: a 2.6 GB file costs no disk.
                let handle = try FileHandle(forWritingTo: URL(filePath: item))
                try handle.truncate(atOffset: size)
                try handle.close()
            } else {
                try FileManager.default.createDirectory(atPath: item, withIntermediateDirectories: false)
            }
            let date = Calendar.current.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: today)!
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item)
        }
        return path
    }

    /// Lets the main actor's jobs (the panes' listings, the queue) run while suspended, and the run loop's
    /// observers (SwiftUI's updates) in between; neither happens while this job holds the main queue.
    static func spin(seconds: TimeInterval = 1, until done: () -> Bool = { false }) async throws {
        let end = Date.now.addingTimeInterval(seconds)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            pump(0.02)
        } while !done() && Date.now < end
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: .now.addingTimeInterval(seconds))
    }

    static func render(_ view: some View, size: CGSize, dark: Bool, selectFirstRows: Bool, to url: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let backdrop = Color(white: 0.5) // stand-in for the app's blurred backdrop
        let host = NSHostingView(rootView: view.padding(16).frame(width: size.width, height: size.height).background(backdrop))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        try await spin()
        if selectFirstRows {
            for table in tables(in: host) { table.selectRowIndexes([0], byExtendingSelection: false) }
        }
        try await spin(seconds: 0.3)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
    }
}

/// A temp folder shown under made-up absolute paths, so a pane reads "/var/www" or "~/Backups".
final class MappedProvider: FileProvider, @unchecked Sendable {
    let name: String
    let isLocal: Bool
    private let root: String
    private let homePath: String
    private let local = LocalFileProvider()

    init(name: String, isLocal: Bool, root: String, home: String) {
        self.name = name
        self.isLocal = isLocal
        self.root = root
        self.homePath = home
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await local.list(root + path).map { entry in
            var entry = entry
            entry.path = Paths.join(path, entry.name)
            return entry
        }
    }

    func stat(_ path: String) async throws -> Bool? { try await local.stat(root + path) }
    func home() async throws -> String { homePath }
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
    func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String, resume: Bool,
                  events: @escaping @Sendable (TransferEvent) -> Void,
                  onConflict: @escaping @Sendable (TransferConflict) async -> ConflictChoice) async throws {
        throw FileError("Read-only")
    }
}
