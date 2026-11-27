// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// Upstream `ConflictResolution` (SFTPTypes.ts): the five answers the conflict prompt offers.
public enum ConflictResolution: Sendable {
    case overwrite, overwriteAll, skip, skipAll, cancel
}

/// The transfer queue, upstream transferQueueStore.ts with its callers (SFTPPage.tsx, osDropPipeline.ts):
/// - Each `enqueue` is one batch. A batch copies its items one at a time, in order; batches run side by
///   side with no global limit, as upstream's `for (const file of files) await runTransfer(...)` per action.
/// - Rows show newest batch first, a batch's items in the order they run. Only settled rows are capped
///   (30, upstream `MAX_TRANSFERS`); queued and running rows are never dropped.
/// - No pause: upstream has none. Cancel stops a row (a queued one never starts); Retry re-runs a cancelled
///   or failed row as a new row with `resume`, so landed files are kept; the old row stays as history.
/// - A conflict asks once per item; "all" answers hold for the rest of that batch, and Stop drops the
///   conflicting item and everything still queued in its batch.
@Observable
@MainActor
public final class TransferQueue {
    public enum Status: Equatable, Sendable {
        case queued, running, done, cancelled
        case failed(String)
    }

    public struct Transfer: Identifiable, Sendable {
        public let id: String
        /// The item's name.
        public let label: String
        /// "This Mac → deploy@web-1".
        public let route: String
        public let isDir: Bool
        public internal(set) var status = Status.queued
        public internal(set) var transferred: UInt64 = 0
        public internal(set) var total: UInt64 = 0
        /// Bytes per second.
        public internal(set) var speed: Double?
        /// Seconds left.
        public internal(set) var eta: Int?
        /// Paths the provider left out (`sftp-skipped`).
        public internal(set) var skipped: [String] = []
        /// Bytes already in place when the latest resume began.
        public internal(set) var resumedAt: UInt64?
        /// The link is down and the provider waits for it.
        public internal(set) var waiting = false
        /// The run has returned. A retry before then could race a cancelled copy still flushing (upstream `settled`).
        public internal(set) var settled = false
        let batch: UUID
        var meter = ProgressMeter()
    }

    public struct PendingConflict: Identifiable {
        public let id = UUID()
        public let conflict: TransferConflict
        /// More items of the same batch wait, so "apply to all" means something.
        public let hasMore: Bool
        let transferID: String
        let reply: CheckedContinuation<ConflictResolution, Never>
    }

    static let maxSettled = 30

    public private(set) var transfers: [Transfer] = []
    /// Open prompts, oldest first; the UI shows the first and answers it with `resolveConflict(_:_:)`.
    public private(set) var conflicts: [PendingConflict] = []

    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored private var remembered: [UUID: ConflictChoice] = [:]
    /// Rows a Skip or Stop answer removes once their run returns.
    @ObservationIgnored private var dropped: Set<String> = []
    /// Files open in an editor (`edit`), each with its copy on this Mac.
    @ObservationIgnored private var edits: [EditKey: String] = [:]
    /// How often an edited file's copy is checked for a save.
    @ObservationIgnored var editInterval = Duration.seconds(1)

    private struct EditKey: Hashable {
        var provider: ObjectIdentifier
        var path: String
    }

    private struct Job {
        var item: FileEntry
        var source: any FileProvider
        var destination: any FileProvider
        var destinationPath: String
        /// Whatever sits at `destinationPath` is replaced without asking: an edited file going back where it came from.
        var replace = false
        var onDone: (@MainActor () -> Void)?
    }

    /// - Parameter clock: seconds on a monotonic clock, for speed and ETA.
    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        _ = Self.sweptEdits
    }

    /// Where "Edit on This Mac" keeps its copies: each in a folder of its own, removed when its editing ends.
    private static let editsFolder = FileManager.default.temporaryDirectory.appending(path: "Soltz Edits")
    /// Once per launch, before any edit of this one: the copies of hosts' files an earlier run left behind (a crash,
    /// a quit mid-edit).
    private static let sweptEdits: Void = { try? FileManager.default.removeItem(at: editsFolder) }()

    /// Marks what came from a host as downloaded, as a browser does its downloads, so macOS checks an app or a
    /// script among it before its first run. Off the main actor: a folder can hold many files.
    private static func quarantine(_ path: String) {
        Task.detached(priority: .utility) {
            let downloaded: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                             kLSQuarantineAgentNameKey as String: "Soltz"]
            func mark(_ url: URL) {
                var (url, values) = (url, URLResourceValues())
                values.quarantineProperties = downloaded
                try? url.setResourceValues(values)
            }
            let root = URL(filePath: path)
            mark(root)
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL { mark(url) }
        }
    }

    /// Copies `items` from `source` into the directory `directory` of `destination`, one batch.
    /// `onDone` runs after each item that lands, e.g. to reload the destination pane.
    public func enqueue(_ items: [FileEntry], from source: any FileProvider, to destination: any FileProvider,
                        into directory: String, onDone: (@MainActor () -> Void)? = nil) {
        enqueue(items, from: source, to: destination, into: directory, replace: false, onDone: onDone)
    }

    /// The rows' ids, in order.
    @discardableResult
    private func enqueue(_ items: [FileEntry], from source: any FileProvider, to destination: any FileProvider,
                         into directory: String, replace: Bool, onDone: (@MainActor () -> Void)?) -> [String] {
        // The name was chosen by whoever listed it (a host) and is joined onto the destination folder below.
        let items = items.filter { Paths.isPlainName($0.name) }
        guard !items.isEmpty else { return [] }
        let batch = UUID()
        let rows = items.map { item in
            add(Job(item: item, source: source, destination: destination,
                    destinationPath: Paths.join(directory, item.name), replace: replace, onDone: onDone), batch: batch)
        }
        transfers.insert(contentsOf: rows, at: 0)
        run(rows.map(\.id), batch: batch, resume: false)
        return rows.map(\.id)
    }

    /// Opens a host's file in an editor on this Mac: copied into a temporary folder of its own, handed to `open`,
    /// then copied back over the original each time the editor saves it, for as long as `remote` lives. Whatever
    /// changed on the host meanwhile is replaced. Both copies are rows of the queue, so a save that does not reach
    /// the host shows there, with Retry.
    public func edit(_ item: FileEntry, on remote: any FileProvider, open: @escaping @MainActor (URL) -> Void) {
        // The name comes from the host and becomes a path on this Mac.
        guard !item.isDir, Paths.isPlainName(item.name) else { return }
        let key = EditKey(provider: ObjectIdentifier(remote), path: item.path)
        if let copy = edits[key], FileManager.default.fileExists(atPath: copy) { return open(URL(filePath: copy)) }
        let local = LocalFileProvider()
        let folder = Self.editsFolder.appending(path: UUID().uuidString).path(percentEncoded: false)
        // A folder that cannot be made fails the download, which says so in its row.
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let copy = Paths.join(folder, item.name)
        edits[key] = copy
        enqueue([item], from: remote, to: local, into: folder, replace: false) { [weak self, weak remote, editInterval] in
            // Read before the editor has the file, so its first save counts however soon it comes.
            var saved = (try? LocalFileProvider.entry(at: copy))?.modified
            open(URL(filePath: copy))
            // shortcut: the copy's date is read once a second, which sees every way an editor saves (in place, or a
            // new file swapped in); watch the folder with FSEvents if many files are ever open at once.
            Task { [weak self, weak remote] in
                var upload: String?
                while (try? await Task.sleep(for: editInterval)) != nil, let self, let remote {
                    // One upload of a file at a time: a save during one goes up when it ends.
                    guard upload.flatMap({ self[$0] })?.settled != false,
                          let entry = try? LocalFileProvider.entry(at: copy), entry.modified != saved else { continue }
                    saved = entry.modified
                    upload = self.enqueue([entry], from: local, to: remote, into: Paths.parent(item.path) ?? "/",
                                          replace: true, onDone: nil).first
                }
                self?.edits[key] = nil
                // The host's file does not outlive its editing on this Mac.
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
    }

    public func cancel(_ id: String) {
        guard let row = self[id] else { return }
        switch row.status {
        case .queued:
            update(id) { $0.status = .cancelled; $0.settled = true }
            trim()
        case .running:
            tasks[id]?.cancel()
            update(id) { $0.status = .cancelled; $0.waiting = false }
            if let i = conflicts.firstIndex(where: { $0.transferID == id }) { conflicts.remove(at: i).reply.resume(returning: .cancel) }
        default:
            return
        }
    }

    public func cancelAll() {
        for row in transfers where row.status == .queued || row.status == .running { cancel(row.id) }
    }

    /// Upstream `canRetryTransfer`: a settled row that ended cancelled or failed.
    public func canRetry(_ id: String) -> Bool {
        guard let row = self[id], row.settled, jobs[id] != nil else { return false }
        if case .failed = row.status { return true }
        return row.status == .cancelled
    }

    public func retry(_ id: String) {
        guard canRetry(id), let job = jobs[id] else { return }
        let row = add(job, batch: UUID())
        jobs[id] = nil // one retry per row: a second would copy into the same place at the same time
        transfers.insert(row, at: 0)
        run([row.id], batch: row.batch, resume: true)
    }

    /// Keeps queued and running rows.
    public func clearCompleted() {
        for row in transfers where row.settled { jobs[row.id] = nil }
        transfers.removeAll { $0.settled }
    }

    /// Answers the prompt `id`; a prompt already answered or closed is ignored.
    public func resolveConflict(_ id: PendingConflict.ID, _ resolution: ConflictResolution) {
        guard let i = conflicts.firstIndex(where: { $0.id == id }) else { return }
        conflicts.remove(at: i).reply.resume(returning: resolution)
    }

    /// Which provider runs a copy: the remote end, or either when both are local (see `FileProvider.transfer`).
    static func runner(source: any FileProvider, destination: any FileProvider) -> any FileProvider {
        destination.isLocal ? source : destination
    }

    // MARK: Running

    private subscript(id: String) -> Transfer? {
        transfers.first { $0.id == id }
    }

    private func add(_ job: Job, batch: UUID) -> Transfer {
        let row = Transfer(id: UUID().uuidString, label: job.item.name, route: "\(job.source.name) → \(job.destination.name)",
                           isDir: job.item.isDir, batch: batch)
        jobs[row.id] = job
        return row
    }

    private func update(_ id: String, _ change: (inout Transfer) -> Void) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { change(&transfers[i]) }
    }

    private func run(_ ids: [String], batch: UUID, resume: Bool) {
        Task {
            for id in ids { await runOne(id, resume: resume) }
            remembered[batch] = nil
        }
    }

    private func runOne(_ id: String, resume: Bool) async {
        guard let job = jobs[id], self[id]?.status == .queued else { return }
        update(id) { $0.status = .running }
        let (stream, events) = AsyncStream.makeStream(of: TransferEvent.self)
        let runner = Self.runner(source: job.source, destination: job.destination)
        let work = Task {
            try await runner.transfer(job.item, from: job.source, to: job.destinationPath, id: id, resume: resume,
                                      events: { events.yield($0) },
                                      onConflict: { await self.ask($0, for: id) })
        }
        tasks[id] = work
        let consumer = Task {
            for await event in stream { apply(event, to: id) }
        }
        let result = await work.result
        events.finish()
        await consumer.value
        tasks[id] = nil
        finish(id, result, job: job)
    }

    private func finish(_ id: String, _ result: Result<Void, any Error>, job: Job) {
        if dropped.remove(id) != nil {
            transfers.removeAll { $0.id == id }
            jobs[id] = nil
            return
        }
        update(id) { row in
            switch result {
            case .success:
                row.status = .done
            case .failure(let error):
                if row.status != .cancelled {
                    row.status = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                }
            }
            row.waiting = false
            row.speed = nil
            row.eta = nil
            row.settled = true
        }
        if case .success = result {
            if job.destination.isLocal, !job.source.isLocal { Self.quarantine(job.destinationPath) }
            job.onDone?()
        }
        trim()
    }

    private func ask(_ conflict: TransferConflict, for id: String) async -> ConflictChoice {
        // A row stopped before its provider got here asks nothing.
        guard let row = self[id], row.status == .running else { return .cancel }
        if jobs[id]?.replace == true { return .overwrite }
        let batch = row.batch
        if let choice = remembered[batch] { return answer(choice, for: id) }
        let hasMore = transfers.contains { $0.batch == batch && $0.status == .queued }
        let resolution = await withCheckedContinuation { reply in
            conflicts.append(PendingConflict(conflict: conflict, hasMore: hasMore, transferID: id, reply: reply))
        }
        if self[id]?.status == .cancelled { return .cancel }
        switch resolution {
        case .overwrite: return .overwrite
        case .skip: return answer(.skip, for: id)
        case .overwriteAll, .skipAll:
            let choice: ConflictChoice = resolution == .overwriteAll ? .overwrite : .skip
            remembered[batch] = choice
            return answer(choice, for: id)
        case .cancel:
            dropped.insert(id)
            for row in transfers where row.batch == batch && row.status == .queued { jobs[row.id] = nil }
            transfers.removeAll { $0.batch == batch && $0.status == .queued }
            return .cancel
        }
    }

    private func answer(_ choice: ConflictChoice, for id: String) -> ConflictChoice {
        if choice == .skip { dropped.insert(id) }
        return choice
    }

    private func apply(_ event: TransferEvent, to id: String) {
        let now = clock()
        update(id) { row in
            switch event {
            case .progress(let transferred, let total):
                (row.speed, row.eta) = row.meter.update(transferred: transferred, total: total, now: now)
                row.transferred = transferred
                row.total = total
            case .skipped(let path):
                row.skipped.append(path)
            case .resumed(let offset):
                row.meter = ProgressMeter()
                row.resumedAt = offset
                row.transferred = offset
            case .waiting(let waiting):
                row.meter = ProgressMeter()
                row.waiting = waiting
                row.speed = nil
                row.eta = nil
            }
        }
    }

    /// Drops the oldest settled rows beyond the cap.
    private func trim() {
        var settled = transfers.filter(\.settled).count
        while settled > Self.maxSettled, let i = transfers.lastIndex(where: \.settled) {
            jobs[transfers.remove(at: i).id] = nil
            settled -= 1
        }
    }
}

/// Upstream `runTransfer`'s speed rule: measured from the first progress after a start, resume or wait,
/// reported once half a second has passed; the ETA needs a speed and bytes left.
struct ProgressMeter: Sendable {
    private var base: (at: TimeInterval, bytes: UInt64)?

    mutating func update(transferred: UInt64, total: UInt64, now: TimeInterval) -> (speed: Double?, eta: Int?) {
        let base = self.base ?? (now, transferred)
        self.base = base
        let elapsed = now - base.at
        // Clamped: a provider whose count goes back without a resume must not report a negative speed.
        let speed = elapsed > 0.5 ? max(0, Double(transferred) - Double(base.bytes)) / elapsed : nil
        guard let speed, speed > 0, total > transferred else { return (speed, nil) }
        // Capped: `total` is what a host says a file's size is, and a number past Int's range would trap here.
        return (speed, Int(min((Double(total - transferred) / speed).rounded(), 1e12)))
    }
}
