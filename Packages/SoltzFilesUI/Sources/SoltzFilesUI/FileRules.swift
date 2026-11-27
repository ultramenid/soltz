// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// POSIX path rules for both sides: Soltz runs on macOS and SFTP paths are `/`-separated, so upstream's
/// Windows branches (moveTargetCore.ts) have nothing to do here. The only local/remote difference, `~`,
/// goes through each provider's `home()`.
enum Paths {
    /// Upstream `joinPath`.
    static func join(_ dir: String, _ name: String) -> String {
        var base = dir
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + name
    }

    /// nil at the root.
    static func parent(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.isEmpty else { return nil }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// An absolute path without `.`, `..`, doubled or trailing slashes.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// What the path bar's text field means: `~` is `home`, a relative path starts at `cwd`.
    static func resolve(_ typed: String, cwd: String, home: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return cwd }
        if text == "~" { return normalize(home) }
        if text.hasPrefix("~/") { return normalize(home + text.dropFirst()) }
        return normalize(text.hasPrefix("/") ? text : join(cwd, text))
    }

    /// Root first: "/a/b" is "/", "/a", "/a/b". Inside `home` everything up to it is one "~" crumb.
    static func breadcrumb(_ path: String, home: String? = nil) -> [Crumb] {
        var crumbs = [Crumb(name: "/", path: "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            crumbs.append(Crumb(name: String(part), path: current))
        }
        guard let home, home != "/", let at = crumbs.firstIndex(where: { $0.path == normalize(home) }) else { return crumbs }
        return [Crumb(name: "~", path: crumbs[at].path)] + crumbs[(at + 1)...]
    }

    /// Upstream `isSameOrUnder`.
    static func isSameOrUnder(_ path: String, _ dir: String) -> Bool {
        let p = normalize(path), d = normalize(dir)
        return p == d || p.hasPrefix(d == "/" ? d : d + "/")
    }

    /// Upstream `isPlainName` (remoteName.ts), POSIX: one path component a user may create.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

struct Crumb: Hashable {
    var name: String
    var path: String
}

/// The listing's columns.
public enum FileColumn: String, Sendable, Hashable {
    case name, size, modified, permissions, owner
}

/// Folders first whichever way the column sorts, as upstream's FilePane does; ties fall back to the name.
public struct FileComparator: SortComparator, Hashable, Sendable {
    public var column: FileColumn
    public var order: SortOrder

    public init(_ column: FileColumn, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    public func compare(_ a: FileEntry, _ b: FileEntry) -> ComparisonResult {
        if a.isDir != b.isDir { return a.isDir ? .orderedAscending : .orderedDescending }
        let result = switch column {
        case .name: ComparisonResult.orderedSame
        case .size: Self.compare(a.size, b.size)
        case .modified: Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .permissions: Self.compare((a.permissions ?? 0) & 0o7777, (b.permissions ?? 0) & 0o7777)
        case .owner: (a.owner ?? "").localizedStandardCompare(b.owner ?? "")
        }
        let decided = result == .orderedSame ? a.name.localizedStandardCompare(b.name) : result
        return order == .forward ? decided : Self.flip(decided)
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    private static func flip(_ r: ComparisonResult) -> ComparisonResult {
        r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// Folders kept per file system, to jump back to. Only paths are kept: nothing secret.
// shortcut: keyed by the provider's name ("This Mac", "deploy@web-1"), so two hosts shown under one name share
// a list; key it by the host's id once the pane is given one.
enum Favourites {
    static let key = "SoltzFilesUI.favourites"

    static func list(for name: String, in defaults: UserDefaults = .standard) -> [String] {
        (defaults.dictionary(forKey: key)?[name] as? [String]) ?? []
    }

    /// Adds `path`, or removes it when it is there; the list after.
    @discardableResult
    static func toggle(_ path: String, for name: String, in defaults: UserDefaults = .standard) -> [String] {
        var all = (defaults.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        var list = all[name] ?? []
        if let index = list.firstIndex(of: path) { list.remove(at: index) } else { list.append(path) }
        all[name] = list.isEmpty ? nil : list
        defaults.set(all, forKey: key)
        return list
    }
}

enum FileRules {
    /// A file name's ending, which stays last when the name gets a suffix: an archive's whole ending (".tar.gz"),
    /// else its extension; none for a dot file's own name.
    static func ending(_ name: String) -> String {
        if let archive = Archives.ending(of: name) { return String(name.suffix(archive.count)) }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.count + 1 >= name.count ? "" : "." + ext
    }

    /// `stem` and `ending`, with " 2", " 3"… between them until the name is not in `taken`.
    static func freeName(_ stem: String, ending: String = "", taken: Set<String>) -> String {
        var name = stem + ending, n = 2
        while taken.contains(name) {
            name = "\(stem) \(n)\(ending)"
            n += 1
        }
        return name
    }

    /// The name Duplicate gives a copy of `entry`, as Finder does: "a copy.txt", then "a copy 2.txt".
    static func copyName(_ entry: FileEntry, taken: Set<String>) -> String {
        let ending = entry.isDir ? "" : ending(entry.name)
        return freeName(String(entry.name.dropLast(ending.count)) + " copy", ending: ending, taken: taken)
    }

    /// What a pane shows: upstream hides dot files unless asked and filters by a case- and accent-blind
    /// substring of the name (`searchMatcher`).
    static func visible(_ entries: [FileEntry], showHidden: Bool, filter: String, sort: [FileComparator]) -> [FileEntry] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries
            .filter { (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedStandardContains(query)) }
            .sorted(using: sort.isEmpty ? [FileComparator(.name)] : sort)
    }

    /// Upstream `copyPathText`: one path per line.
    static func copyPathText(_ entries: [FileEntry]) -> String {
        entries.map(\.path).joined(separator: "\n")
    }

    // MARK: Formatting

    /// The system file-size style (decimal units, as Finder shows them) rather than upstream's binary `formatSize`.
    static func size(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    /// Short relative dates: "Today 10:42", "Yesterday", month and day this year, the year only before it.
    static func modified(_ date: Date, now: Date = .now, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + date.formatted(style.hour().minute()) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let thisYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(thisYear ? style.month(.abbreviated).day() : style.year().month(.abbreviated).day())
    }

    /// `ls -l` mode string, special bits as s/S and t/T.
    static func symbolic(_ mode: UInt32) -> String {
        let bits = PermissionBits.tri([mode])
        let triad = { (i: Int, lower: Character, upper: Character) -> String in
            let x: Character = bits[9 + i] == true ? (bits[i * 3 + 2] == true ? lower : upper) : (bits[i * 3 + 2] == true ? "x" : "-")
            return String([bits[i * 3] == true ? "r" : "-", bits[i * 3 + 1] == true ? "w" : "-", x])
        }
        return triad(0, "s", "S") + triad(1, "s", "S") + triad(2, "t", "T")
    }

    /// Upstream `formatTransferProgress`: "transferred of total · speed/s · eta", unknown parts left out; a unit
    /// both sizes share is written once ("1.9 of 2.6 GB").
    static func progress(transferred: UInt64, total: UInt64, speed: Double?, eta: Int?,
                         locale: Locale = .autoupdatingCurrent) -> String {
        let done = size(transferred, locale: locale)
        var text = done
        if total > 0 {
            let all = size(total, locale: locale)
            let unit = { (text: String) in text.lastIndex(where: \.isWhitespace).map { text[$0...] } }
            if let shared = unit(done), shared == unit(all) {
                text = String(done[..<shared.startIndex]) + " of " + all
            } else {
                text = "\(done) of \(all)"
            }
        }
        if let speed { text += " · \(size(UInt64(speed.rounded()), locale: locale))/s" }
        if let eta, eta > 0 { text += " · " + (eta < 60 ? "\(eta)s" : "\(Int((Double(eta) / 60).rounded()))m") }
        return text
    }

    /// The Transfers card's line: the route, the state in words, then "x of y", speed and time left when known.
    static func transferLine(_ row: TransferQueue.Transfer, locale: Locale = .autoupdatingCurrent) -> String {
        let amount = row.total == 0 && row.transferred == 0 ? nil
            : progress(transferred: row.transferred, total: row.total, speed: row.speed, eta: row.eta, locale: locale)
        let state: [String?] = switch row.status {
        case .queued: ["Queued"]
        case .running where row.waiting: ["Waiting for connection", amount]
        case .running: [row.resumedAt == nil ? nil : "Resumed", amount ?? "Starting"]
        case .done: ["Done"]
        case .cancelled: ["Stopped"]
        case .failed(let message): ["Failed: \(message)"]
        }
        return ([row.route] + state.compactMap { $0 }).joined(separator: " · ")
    }
}

/// The permissions sheet's model, upstream permissionsModel.ts: twelve bits in grid order (owner, group,
/// others rwx, then setuid, setgid, sticky), each true, false or nil when the selection disagrees.
enum PermissionBits {
    static let masks: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001, 0o4000, 0o2000, 0o1000]

    static func tri(_ modes: [UInt32]) -> [Bool?] {
        masks.map { bit in
            let on = modes.filter { $0 & bit != 0 }.count
            return on == 0 ? false : on == modes.count ? true : nil
        }
    }

    /// nil while any bit is mixed.
    static func mode(_ bits: [Bool?]) -> UInt32? {
        guard !bits.contains(nil) else { return nil }
        return zip(masks, bits).reduce(UInt32(0)) { $1.1 == true ? $0 | $1.0 : $0 }
    }

    /// Three digits, four when a special bit is set; nil while any bit is mixed.
    static func octal(_ bits: [Bool?]) -> String? {
        guard let mode = mode(bits) else { return nil }
        let digits = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, (mode > 0o777 ? 4 : 3) - digits.count)) + digits
    }

    /// Three digits keep the special bits of `current`; four replace them.
    static func parseOctal(_ text: String, current: [Bool?]) -> [Bool?]? {
        guard (3...4).contains(text.count), text.allSatisfy({ ("0"..."7").contains($0) }),
              let mode = UInt32(text, radix: 8) else { return nil }
        return masks.enumerated().map { i, bit in i >= 9 && text.count == 3 ? current[i] : mode & bit != 0 }
    }

    /// Only the bits the user changed. (Upstream `modeChange` sends every settled rwx bit: the same for the items
    /// themselves, but passed on to what is inside a folder it gave every file there the folder's own mode.)
    static func change(from initial: [Bool?], to edited: [Bool?]) -> (set: UInt32, clear: UInt32) {
        var set: UInt32 = 0, clear: UInt32 = 0
        for (i, bit) in masks.enumerated() {
            guard let on = edited[i], edited[i] != initial[i] else { continue }
            if on { set |= bit } else { clear |= bit }
        }
        return (set, clear)
    }
}

/// A pane's Back and Forward, as a browser keeps them: moving somewhere new forgets what was ahead.
struct PathHistory {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []

    /// The pane left `path` for a folder the user picked.
    mutating func moved(from path: String) {
        back.append(path)
        forward = []
    }

    /// The folder Back leads to from `path`, which goes on Forward's list; nil with nowhere to go.
    mutating func goBack(from path: String) -> String? { Self.step(&back, &forward, path) }
    mutating func goForward(from path: String) -> String? { Self.step(&forward, &back, path) }

    private static func step(_ from: inout [String], _ to: inout [String], _ path: String) -> String? {
        guard let folder = from.popLast() else { return nil }
        to.append(path)
        return folder
    }
}
