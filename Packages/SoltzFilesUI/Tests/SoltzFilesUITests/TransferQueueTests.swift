// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SoltzFilesUI

/// A remote whose transfers do exactly what the test sends them, one step at a time.
final class ScriptedRemote: FileProvider, @unchecked Sendable {
    enum Step: Sendable {
        case event(TransferEvent)
        case conflict
        case finish
        case fail(String)
    }

    let name: String
    let isLocal = false

    init(name: String = "remote") {
        self.name = name
    }
    private let lock = NSLock()
    private var scripts: [String: (AsyncStream<Step>?, AsyncStream<Step>.Continuation)] = [:]
    private var log: [(name: String, resume: Bool)] = []
    private var live: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    /// Names whose transfer first waits for `open(_:)`, deaf to cancellation like an SFTP stat in flight,
    /// then asks about a conflict.
    var asksLate: Set<String> = []

    /// Names in the order their transfers started, a retry counting again.
    var started: [String] { lock.withLock { log.map(\.name) } }
    var resumed: [Bool] { lock.withLock { log.map(\.resume) } }
    var running: Set<String> { lock.withLock { live } }

    func open(_ name: String) {
        lock.withLock { gates.removeValue(forKey: name) }?.resume()
    }

    func send(_ name: String, _ step: Step) {
        lock.withLock { script(name).1 }.yield(step)
    }

    private func script(_ name: String) -> (AsyncStream<Step>?, AsyncStream<Step>.Continuation) {
        if let script = scripts[name] { return script }
        let (stream, continuation) = AsyncStream.makeStream(of: Step.self)
        scripts[name] = (stream, continuation)
        return (stream, continuation)
    }

    func transfer(_ item: FileEntry, from source: any FileProvider, to destinationPath: String, id: String, resume: Bool,
                  events: @escaping @Sendable (TransferEvent) -> Void,
                  onConflict: @escaping @Sendable (TransferConflict) async -> ConflictChoice) async throws {
        let stream = lock.withLock {
            log.append((item.name, resume))
            live.insert(item.name)
            let stream = script(item.name).0!
            scripts[item.name]!.0 = nil
            return stream
        }
        // The next run of this name (a retry) gets a fresh script.
        defer { lock.withLock { scripts[item.name] = nil; live.remove(item.name) } }
        if asksLate.contains(item.name) {
            await withCheckedContinuation { gate in lock.withLock { gates[item.name] = gate } }
            let choice = await onConflict(TransferConflict(source: item, destinationPath: destinationPath, destinationIsDir: false))
            if choice == .cancel { throw CancellationError() }
        }
        for await step in stream {
            switch step {
            case .event(let event): events(event)
            case .finish: return
            case .fail(let message): throw FileError(message)
            case .conflict:
                switch await onConflict(TransferConflict(source: item, destinationPath: destinationPath, destinationIsDir: false)) {
                case .overwrite: continue
                case .skip: return
                case .cancel: throw CancellationError()
                }
            }
        }
        throw CancellationError()
    }

    func list(_ path: String) async throws -> [FileEntry] { [] }
    func stat(_ path: String) async throws -> Bool? { nil }
    func home() async throws -> String { "/" }
    func realpath(_ path: String) async throws -> String { path }
    func mkdir(_ path: String) async throws {}
    func createFile(_ path: String) async throws {}
    func rename(_ from: String, to: String) async throws {}
    func delete(_ path: String) async throws {}
    func changeMode(_ paths: [String], set: UInt32, clear: UInt32, owner: String?, group: String?, recursive: Bool) async throws {}
    func copy(_ path: String, to: String) async throws {}
    func compress(_ paths: [String], to archive: String) async throws {}
    func extract(_ archive: String, into folder: String) async throws {}
    func read(_ path: String, maxBytes: Int) async throws -> Data { Data() }
    func write(_ path: String, _ data: Data) async throws {}
}

@MainActor
private func until(_ what: Comment, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<3000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    throw CancellationError()
}

@MainActor
final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor
final class Counter {
    var count = 0
}

private func items(_ names: String...) -> [FileEntry] {
    names.map { FileEntry(name: $0, path: "/src/" + $0, size: 100) }
}

@MainActor
@Suite struct QueueStateMachine {
    let remote = ScriptedRemote()
    let local = LocalFileProvider()
    let clock = FakeClock()
    let queue: TransferQueue

    init() {
        let clock = clock
        queue = TransferQueue(clock: { clock.now })
    }

    private func status(_ name: String) -> TransferQueue.Status? {
        queue.transfers.first { $0.label == name }?.status
    }

    @Test func aBatchRunsInOrderOneAtATimeWhileBatchesRunSideBySide() async throws {
        let landed = Counter()
        queue.enqueue(items("a", "b"), from: local, to: remote, into: "/dst", onDone: { landed.count += 1 })
        queue.enqueue(items("c"), from: local, to: remote, into: "/dst")
        #expect(queue.transfers.map(\.label) == ["c", "a", "b"])
        #expect(queue.transfers.allSatisfy { $0.route == "This Mac → remote" })
        try await until("a and c to start") { remote.running == ["a", "c"] }
        #expect(status("a") == .running && status("b") == .queued && status("c") == .running)

        remote.send("a", .finish)
        try await until("b to start") { remote.running == ["b", "c"] }
        #expect(status("a") == .done && landed.count == 1)
        remote.send("b", .finish)
        remote.send("c", .finish)
        try await until("all done") { queue.transfers.allSatisfy { $0.status == .done && $0.settled } }
        #expect(remote.started.filter { $0 != "c" } == ["a", "b"])
        #expect(landed.count == 2)
    }

    @Test func progressSpeedAndETAFollowTheInjectedClock() async throws {
        queue.enqueue(items("a"), from: remote, to: local, into: "/dst")
        try await until("start") { remote.running == ["a"] }
        let row = { queue.transfers[0] }

        remote.send("a", .event(.progress(transferred: 0, total: 1000)))
        try await until("first progress") { row().total == 1000 }
        #expect(row().speed == nil && row().eta == nil)

        clock.now = 0.4
        remote.send("a", .event(.progress(transferred: 400, total: 1000)))
        try await until("400") { row().transferred == 400 }
        #expect(row().speed == nil, "no speed before half a second")

        clock.now = 1
        remote.send("a", .event(.progress(transferred: 500, total: 1000)))
        try await until("500") { row().transferred == 500 }
        #expect(row().speed == 500 && row().eta == 1)

        remote.send("a", .event(.resumed(offset: 200)))
        try await until("resumed") { row().resumedAt == 200 }
        #expect(row().transferred == 200)
        clock.now = 2
        remote.send("a", .event(.progress(transferred: 300, total: 1000)))
        try await until("300") { row().transferred == 300 }
        #expect(row().speed == nil, "a resume restarts the measurement")
        clock.now = 3
        remote.send("a", .event(.progress(transferred: 700, total: 1000)))
        try await until("700") { row().transferred == 700 }
        #expect(row().speed == 400 && row().eta == 1)

        clock.now = 4
        remote.send("a", .event(.progress(transferred: 100, total: 1000)))
        try await until("backwards") { row().transferred == 100 }
        #expect(row().speed == 0 && row().eta == nil, "a count that goes back never makes a negative speed")

        remote.send("a", .event(.waiting(true)))
        try await until("waiting") { row().waiting }
        #expect(row().speed == nil && row().eta == nil)
        remote.send("a", .event(.waiting(false)))
        remote.send("a", .event(.skipped("/src/a/bad:name")))
        remote.send("a", .finish)
        try await until("done") { row().settled }
        #expect(row().status == .done && !row().waiting && row().skipped == ["/src/a/bad:name"])
    }

    @Test func cancelStopsRunningAndQueuedRowsAndRetryResumes() async throws {
        queue.enqueue(items("a", "b"), from: remote, to: local, into: "/dst")
        try await until("a to start") { remote.running == ["a"] }
        let (a, b) = (queue.transfers[0].id, queue.transfers[1].id)
        #expect(!queue.canRetry(a))

        queue.cancel(b)
        #expect(status("b") == .cancelled && queue.canRetry(b))
        queue.cancel(a)
        #expect(status("a") == .cancelled)
        try await until("a to settle") { queue.canRetry(a) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(remote.started == ["a"], "a cancelled queued row never starts")

        queue.retry(a)
        #expect(queue.transfers.map(\.label) == ["a", "a", "b"])
        #expect(queue.transfers[1].id == a && queue.transfers[1].status == .cancelled, "the old row stays as history")
        try await until("retry to start") { remote.started.count == 2 }
        #expect(remote.resumed == [false, true])
        #expect(!queue.canRetry(a), "one retry per row")
        queue.retry(a)
        #expect(queue.transfers.count == 3)
        remote.send("a", .finish)
        try await until("retry done") { queue.transfers[0].status == .done }
        #expect(!queue.canRetry(queue.transfers[0].id))
    }

    @Test func aFailureIsShownAndRetryable() async throws {
        queue.enqueue(items("a"), from: remote, to: local, into: "/dst")
        try await until("start") { remote.running == ["a"] }
        remote.send("a", .fail("Connection lost"))
        try await until("failed") { queue.transfers[0].settled }
        #expect(queue.transfers[0].status == .failed("Connection lost"))
        #expect(queue.canRetry(queue.transfers[0].id))
    }

    @Test func cancelAllStopsEveryBatch() async throws {
        queue.enqueue(items("a", "b"), from: remote, to: local, into: "/dst")
        queue.enqueue(items("c"), from: remote, to: local, into: "/dst")
        try await until("start") { remote.running == ["a", "c"] }
        queue.cancelAll()
        try await until("settled") { queue.transfers.allSatisfy(\.settled) }
        #expect(queue.transfers.allSatisfy { $0.status == .cancelled })
        #expect(Set(remote.started) == ["a", "c"])
    }

    @Test func overwriteAllHoldsForTheRestOfTheBatch() async throws {
        queue.enqueue(items("a", "b", "c"), from: local, to: remote, into: "/dst")
        try await until("a to start") { remote.running == ["a"] }
        remote.send("a", .conflict)
        try await until("a prompt") { queue.conflicts.count == 1 }
        #expect(queue.conflicts[0].hasMore)
        #expect(queue.conflicts[0].conflict.destinationPath == "/dst/a")
        queue.resolveConflict(queue.conflicts[0].id, .overwriteAll)
        remote.send("a", .finish)
        try await until("b to start") { remote.running == ["b"] }
        remote.send("b", .conflict)
        remote.send("b", .finish)
        try await until("c to start") { remote.running == ["c"] }
        #expect(queue.conflicts.isEmpty)
        remote.send("c", .conflict)
        remote.send("c", .finish)
        try await until("done") { queue.transfers.allSatisfy { $0.status == .done } }
        #expect(queue.transfers.count == 3)
    }

    @Test func skipAndSkipAllDropTheirRows() async throws {
        queue.enqueue(items("a", "b", "c"), from: local, to: remote, into: "/dst")
        try await until("a") { remote.running == ["a"] }
        remote.send("a", .conflict)
        try await until("a prompt") { queue.conflicts.count == 1 }
        queue.resolveConflict(queue.conflicts[0].id, .skip)
        try await until("b") { remote.running == ["b"] }
        #expect(queue.transfers.map(\.label) == ["b", "c"])
        remote.send("b", .conflict)
        try await until("b prompt") { queue.conflicts.count == 1 }
        queue.resolveConflict(queue.conflicts[0].id, .skipAll)
        try await until("c") { remote.running == ["c"] }
        remote.send("c", .conflict)
        try await until("c dropped") { queue.transfers.isEmpty }
        #expect(remote.started == ["a", "b", "c"])
    }

    @Test func stopDropsTheRestOfTheBatchOnly() async throws {
        queue.enqueue(items("a", "b", "c"), from: local, to: remote, into: "/dst")
        queue.enqueue(items("other"), from: local, to: remote, into: "/dst")
        try await until("a") { remote.running == ["a", "other"] }
        remote.send("a", .conflict)
        try await until("prompt") { queue.conflicts.count == 1 }
        #expect(queue.conflicts[0].hasMore)
        queue.resolveConflict(queue.conflicts[0].id, .cancel)
        try await until("batch gone") { queue.transfers.map(\.label) == ["other"] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(remote.started.sorted() == ["a", "other"])
        #expect(status("other") == .running)
        remote.send("other", .finish)
        try await until("other done") { status("other") == .done }
    }

    @Test func cancellingARowWithAnOpenPromptClosesIt() async throws {
        queue.enqueue(items("a"), from: local, to: remote, into: "/dst")
        try await until("a") { remote.running == ["a"] }
        remote.send("a", .conflict)
        try await until("prompt") { queue.conflicts.count == 1 }
        #expect(!queue.conflicts[0].hasMore)
        queue.cancel(queue.transfers[0].id)
        #expect(queue.conflicts.isEmpty)
        try await until("settled") { queue.transfers[0].settled }
        #expect(queue.transfers[0].status == .cancelled)
    }

    @Test func aRowStoppedBeforeItsProviderAsksGetsNoPrompt() async throws {
        remote.asksLate = ["a"]
        queue.enqueue(items("a"), from: local, to: remote, into: "/dst")
        try await until("a") { remote.running == ["a"] }
        queue.cancel(queue.transfers[0].id)
        remote.open("a")
        try await until("settled") { queue.transfers[0].settled }
        #expect(queue.conflicts.isEmpty)
        #expect(queue.transfers[0].status == .cancelled)
    }

    @Test func aPromptIsAnsweredByItsOwnIDOnly() async throws {
        queue.enqueue(items("a"), from: local, to: remote, into: "/dst")
        queue.enqueue(items("b"), from: local, to: remote, into: "/dst")
        try await until("both") { remote.running == ["a", "b"] }
        remote.send("a", .conflict)
        try await until("a prompt") { queue.conflicts.count == 1 }
        remote.send("b", .conflict)
        try await until("b prompt") { queue.conflicts.count == 2 }
        let (first, second) = (queue.conflicts[0], queue.conflicts[1])
        queue.resolveConflict(second.id, .skip)
        queue.resolveConflict(second.id, .overwrite)
        #expect(queue.conflicts.map(\.id) == [first.id], "the other prompt stays open")
        try await until("b dropped") { !queue.transfers.contains { $0.label == second.conflict.source.name } }
        queue.resolveConflict(first.id, .overwrite)
        remote.send(first.conflict.source.name, .finish)
        try await until("first done") { queue.transfers.allSatisfy { $0.status == .done } }
        #expect(queue.transfers.count == 1)
    }

    @Test func clearCompletedKeepsActiveRowsAndSettledRowsAreCapped() async throws {
        queue.enqueue(items("live"), from: remote, to: local, into: "/dst")
        try await until("live") { remote.running == ["live"] }
        let names = (0..<35).map { "q\($0)" }
        queue.enqueue(names.map { FileEntry(name: $0, path: "/src/" + $0) }, from: remote, to: local, into: "/dst")
        queue.cancelAll()
        try await until("settled") { queue.transfers.allSatisfy(\.settled) }
        #expect(queue.transfers.map(\.label) == Array(names.prefix(TransferQueue.maxSettled)), "the oldest settled rows go first")

        queue.enqueue(items("next"), from: remote, to: local, into: "/dst")
        try await until("next") { remote.running.contains("next") }
        queue.clearCompleted()
        #expect(queue.transfers.map(\.label) == ["next"])
        remote.send("next", .finish)
    }

    @Test func theRemoteEndRunsTheCopy() {
        #expect(TransferQueue.runner(source: local, destination: remote) === remote)
        #expect(TransferQueue.runner(source: remote, destination: local) === remote)
        let other = ScriptedRemote()
        #expect(TransferQueue.runner(source: other, destination: remote) === remote)
        #expect(TransferQueue.runner(source: local, destination: LocalFileProvider()) === local)
    }

    @Test func aNameThatIsNotOnePlainPathComponentIsNeverTransferred() {
        // A host lists whatever names it likes; one of these joined onto the destination would leave it.
        queue.enqueue(items("../../.zshenv", "a/../../b", "..", ""), from: remote, to: local, into: "/tmp/soltz-nowhere")
        #expect(queue.transfers.isEmpty)
        queue.enqueue(items("../x", "plain.txt"), from: remote, to: local, into: "/tmp/soltz-nowhere")
        #expect(queue.transfers.map(\.label) == ["plain.txt"])
        queue.cancelAll()
    }

    @Test func whatComesFromAHostIsMarkedAsDownloaded() async throws {
        try await withTempDir { dir in
            for folder in ["/mac", "/copy"] { try FileManager.default.createDirectory(atPath: dir + folder, withIntermediateDirectories: false) }
            let marked = { (path: String) in (try? URL(filePath: path).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil }
            // What the scripted host's transfer "wrote".
            try Data("#!/bin/sh\n".utf8).write(to: URL(filePath: dir + "/mac/run.command"))
            queue.enqueue(items("run.command"), from: remote, to: local, into: dir + "/mac")
            try await until("started") { remote.running.contains("run.command") }
            #expect(!marked(dir + "/mac/run.command"))
            remote.send("run.command", .finish)
            try await until("marked as downloaded") { marked(dir + "/mac/run.command") }
            // A copy between folders of this Mac is not a download.
            queue.enqueue([try LocalFileProvider.entry(at: dir + "/mac/run.command")], from: local, to: local, into: dir + "/copy")
            try await until("copied") { queue.transfers.allSatisfy(\.settled) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(FileManager.default.fileExists(atPath: dir + "/copy/run.command"))
        }
    }

    @Test func aLocalTreeThroughTheQueue() async throws {
        try await withTempDir { dir in
            try FileManager.default.createDirectory(atPath: dir + "/tree/sub", withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(filePath: dir + "/tree/sub/x.txt"))
            try FileManager.default.createDirectory(atPath: dir + "/out", withIntermediateDirectories: false)
            queue.enqueue([try LocalFileProvider.entry(at: dir + "/tree")], from: local, to: local, into: dir + "/out")
            try await until("done") { queue.transfers.first?.settled == true }
            #expect(queue.transfers[0].status == .done && queue.transfers[0].total == 1 && queue.transfers[0].transferred == 1)
            #expect(FileManager.default.contentsEqual(atPath: dir + "/tree", andPath: dir + "/out/tree"))
        }
    }

    @Test func anEditedFileGoesBackOnEachSave() async throws {
        try await withTempDir { dir in
            let host = LocalFileProvider() // stands for a host: `edit` only copies through the queue
            let path = dir + "/notes.txt"
            try Data("one".utf8).write(to: URL(filePath: path))
            let item = try LocalFileProvider.entry(at: path)
            let opened = Recorder<URL>()
            queue.editInterval = .milliseconds(20)

            queue.edit(item, on: host) { opened.add($0) }
            try await until("opened") { opened.all.count == 1 }
            let copy = opened.all[0]
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            #expect(copy.lastPathComponent == "notes.txt" && copy.path(percentEncoded: false) != path)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "one")

            // An editor's save replaces the host's file without a prompt, each time.
            for text in ["two", "three"] {
                try Data(text.utf8).write(to: copy, options: .atomic)
                try await until("\(text) on the host") { (try? String(contentsOfFile: path, encoding: .utf8)) == text }
            }
            #expect(queue.conflicts.isEmpty)
            #expect(queue.transfers.count == 3 && queue.transfers.allSatisfy { $0.label == "notes.txt" })

            // Opening it again shows the same copy; a name that would leave the folder is not copied at all.
            queue.edit(item, on: host) { opened.add($0) }
            #expect(opened.all == [copy, copy])
            queue.edit(FileEntry(name: "../notes.txt", path: path), on: host) { opened.add($0) }
            #expect(queue.transfers.count == 3)
        }
    }
}
