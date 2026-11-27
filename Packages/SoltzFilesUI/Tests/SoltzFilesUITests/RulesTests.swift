// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
@testable import SoltzFilesUI

private func file(_ name: String, dir: Bool = false, size: UInt64 = 0, modified: TimeInterval? = nil,
                  mode: UInt32? = nil, owner: String? = nil) -> FileEntry {
    FileEntry(name: name, path: "/x/" + name, size: size, isDir: dir, modified: modified.map(Date.init(timeIntervalSince1970:)),
              permissions: mode, owner: owner)
}

@Suite struct NamingRules {
    @Test func copiesAndArchivesGetNamesNotInUse() {
        #expect(FileRules.copyName(file("a.txt"), taken: ["a.txt"]) == "a copy.txt")
        #expect(FileRules.copyName(file("a.txt"), taken: ["a.txt", "a copy.txt", "a copy 2.txt"]) == "a copy 3.txt")
        #expect(FileRules.copyName(file("site.tar.gz"), taken: []) == "site copy.tar.gz", "an archive keeps its whole ending")
        #expect(FileRules.copyName(file(".bashrc"), taken: []) == ".bashrc copy")
        #expect(FileRules.copyName(file("v1.2", dir: true), taken: []) == "v1.2 copy", "a folder's dot is part of its name")
        #expect(FileRules.freeName("Archive", ending: Archives.made, taken: ["Archive.tar.gz"]) == "Archive 2.tar.gz")
        #expect(Archives.isArchive("Site.TAR.GZ") && Archives.stem("Site.TAR.GZ") == "Site" && Archives.stem("a.zip") == "a")
        #expect(!Archives.isArchive("notes.txt") && !Archives.isArchive(".zip") && Archives.stem("notes.txt") == "notes.txt")
    }

    @Test func favouritesAreKeptPerFileSystem() throws {
        let suite = "soltz-test-\(UUID().uuidString)" // never the app's own defaults
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Favourites.toggle("/var/www", for: "deploy@web", in: defaults) == ["/var/www"])
        #expect(Favourites.toggle("/etc", for: "deploy@web", in: defaults) == ["/var/www", "/etc"])
        #expect(Favourites.list(for: "This Mac", in: defaults).isEmpty)
        #expect(Favourites.toggle("/var/www", for: "deploy@web", in: defaults) == ["/etc"])
        #expect(Favourites.toggle("/etc", for: "deploy@web", in: defaults).isEmpty && Favourites.list(for: "deploy@web", in: defaults).isEmpty)
    }
}

@Suite struct PathRules {
    @Test func joinParentAndName() {
        #expect(Paths.join("/", "a") == "/a")
        #expect(Paths.join("/a//", "b") == "/a/b")
        #expect(Paths.parent("/a/b") == "/a")
        #expect(Paths.parent("/a") == "/")
        #expect(Paths.parent("/") == nil)
        #expect(Paths.name("/a/b/") == "b")
        #expect(Paths.name("/") == "/")
    }

    @Test func normalizeAndResolveTypedPaths() {
        #expect(Paths.normalize("/a//b/./c/../d/") == "/a/b/d")
        #expect(Paths.normalize("/../..") == "/")
        #expect(Paths.resolve("  ", cwd: "/srv", home: "/home/me") == "/srv")
        #expect(Paths.resolve("~", cwd: "/srv", home: "/home/me/") == "/home/me")
        #expect(Paths.resolve("~/logs/../etc", cwd: "/srv", home: "/home/me") == "/home/me/etc")
        #expect(Paths.resolve("sub", cwd: "/srv", home: "/home/me") == "/srv/sub")
        #expect(Paths.resolve("../var", cwd: "/srv/app", home: "/home/me") == "/srv/var")
        #expect(Paths.resolve("/etc//nginx/", cwd: "/srv", home: "/home/me") == "/etc/nginx")
    }

    @Test func breadcrumbStartsAtTheRoot() {
        #expect(Paths.breadcrumb("/") == [Crumb(name: "/", path: "/")])
        #expect(Paths.breadcrumb("/a/b").map(\.path) == ["/", "/a", "/a/b"])
        #expect(Paths.breadcrumb("/a/b").map(\.name) == ["/", "a", "b"])
    }

    @Test func breadcrumbFoldsHomeIntoATilde() {
        #expect(Paths.breadcrumb("/Users/me/Backups", home: "/Users/me/").map(\.name) == ["~", "Backups"])
        #expect(Paths.breadcrumb("/Users/me/Backups", home: "/Users/me").map(\.path) == ["/Users/me", "/Users/me/Backups"])
        #expect(Paths.breadcrumb("/Users/me", home: "/Users/me").map(\.name) == ["~"])
        #expect(Paths.breadcrumb("/Users/meow", home: "/Users/me").map(\.name) == ["/", "Users", "meow"])
        #expect(Paths.breadcrumb("/var/www", home: "/").map(\.name) == ["/", "var", "www"])
    }

    @Test func sameOrUnderMatchesWholeComponents() {
        #expect(Paths.isSameOrUnder("/a/b", "/a/b/"))
        #expect(Paths.isSameOrUnder("/a/b/c", "/a/b"))
        #expect(!Paths.isSameOrUnder("/a/bc", "/a/b"))
        #expect(Paths.isSameOrUnder("/x", "/"))
    }

    @Test func plainNames() {
        #expect(Paths.isPlainName("notes.txt"))
        #expect(Paths.isPlainName(".env"))
        for bad in ["", ".", "..", "a/b", "nul\0l"] { #expect(!Paths.isPlainName(bad)) }
    }
}

@Suite struct ListingRules {
    let entries = [
        file("b.txt", size: 30, modified: 300, mode: 0o644, owner: "root"),
        file("A.txt", size: 10, modified: 100, mode: 0o600, owner: "me"),
        file("zed", dir: true, modified: 50),
        file("Alpha", dir: true, modified: 400),
        file(".env", size: 5),
        file("file10", size: 10), file("file9", size: 10),
    ]

    @Test func foldersComeFirstInBothDirections() {
        let up = FileRules.visible(entries, showHidden: false, filter: "", sort: [FileComparator(.name)])
        #expect(up.map(\.name) == ["Alpha", "zed", "A.txt", "b.txt", "file9", "file10"])
        let down = FileRules.visible(entries, showHidden: false, filter: "", sort: [FileComparator(.name, order: .reverse)])
        #expect(down.map(\.name) == ["zed", "Alpha", "file10", "file9", "b.txt", "A.txt"])
    }

    @Test func columnsSortWithNameAsTieBreak() {
        let bySize = FileRules.visible(entries, showHidden: true, filter: "", sort: [FileComparator(.size)])
        #expect(bySize.map(\.name) == ["Alpha", "zed", ".env", "A.txt", "file9", "file10", "b.txt"])
        let byDate = FileRules.visible(entries, showHidden: false, filter: "", sort: [FileComparator(.modified, order: .reverse)])
        #expect(byDate.prefix(4).map(\.name) == ["Alpha", "zed", "b.txt", "A.txt"])
        let byOwner = FileRules.visible(entries, showHidden: false, filter: "txt", sort: [FileComparator(.owner)])
        #expect(byOwner.map(\.name) == ["A.txt", "b.txt"])
        let byMode = FileRules.visible(entries, showHidden: false, filter: "txt", sort: [FileComparator(.permissions)])
        #expect(byMode.map(\.name) == ["A.txt", "b.txt"])
    }

    @Test func hiddenAndFilter() {
        #expect(!FileRules.visible(entries, showHidden: false, filter: "", sort: []).contains { $0.name == ".env" })
        #expect(FileRules.visible(entries, showHidden: true, filter: "", sort: []).contains { $0.name == ".env" })
        let cafe = [file("Café Menu.pdf"), file("tea.pdf")]
        #expect(FileRules.visible(cafe, showHidden: false, filter: " cafe ", sort: []).map(\.name) == ["Café Menu.pdf"])
        #expect(FileRules.copyPathText(cafe) == "/x/Café Menu.pdf\n/x/tea.pdf")
    }
}

@Suite struct Formatting {
    let us = Locale(identifier: "en_US")

    /// The system's file-size style (decimal, SI "kB"), as Finder shows sizes.
    @Test func sizesFollowTheSystem() {
        #expect(FileRules.size(999, locale: us) == "1 kB")
        #expect(FileRules.size(1_500_000, locale: us) == "1.5 MB")
    }

    @Test func modifiedIsTodayYesterdayDayThisYearDateBefore() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = { (y: Int, m: Int, d: Int, h: Int, min: Int) in
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let modified = { (date: Date, now: Date, locale: Locale) in FileRules.modified(date, now: now, calendar: calendar, locale: locale) }
        let now = at(2026, 11, 24, 12, 0)
        #expect(modified(at(2026, 11, 24, 10, 42), now, us) == "Today 10:42\u{202F}AM")
        #expect(modified(at(2026, 11, 24, 10, 42), now, Locale(identifier: "en_GB")) == "Today 10:42")
        #expect(modified(at(2026, 11, 23, 23, 59), now, us) == "Yesterday")
        #expect(modified(at(2026, 11, 22, 23, 59), now, us) == "Nov 22")
        #expect(modified(at(2026, 1, 1, 0, 0), at(2026, 1, 2, 9, 0), us) == "Yesterday", "yesterday across a year boundary is still yesterday")
        #expect(modified(at(2025, 12, 31, 9, 0), at(2026, 1, 1, 9, 0), us) == "Yesterday")
        #expect(modified(at(2025, 12, 30, 9, 0), at(2026, 1, 1, 9, 0), us) == "Dec 30, 2025")
        #expect(modified(at(2026, 10, 2, 9, 5), now, us) == "Oct 2")
        #expect(modified(at(2025, 3, 3, 9, 5), now, us) == "Mar 3, 2025")
    }

    @Test func symbolicModes() {
        #expect(FileRules.symbolic(0o644) == "rw-r--r--")
        #expect(FileRules.symbolic(0o40755) == "rwxr-xr-x")
        #expect(FileRules.symbolic(0o4755) == "rwsr-xr-x")
        #expect(FileRules.symbolic(0o4644) == "rwSr--r--")
        #expect(FileRules.symbolic(0o1777) == "rwxrwxrwt")
    }

    @Test func progressLine() {
        #expect(FileRules.progress(transferred: 500_000, total: 1_000_000, speed: 250_000, eta: 2, locale: us)
            == "500 kB of 1 MB · 250 kB/s · 2s")
        #expect(FileRules.progress(transferred: 2_000, total: 0, speed: nil, eta: nil, locale: us) == "2 kB")
        #expect(FileRules.progress(transferred: 1, total: 2, speed: nil, eta: 150, locale: us).hasSuffix(" · 3m"))
        #expect(FileRules.progress(transferred: 1_900_000_000, total: 2_600_000_000, speed: nil, eta: nil, locale: us) == "1.9 of 2.6 GB")
    }

    @Test func transferLineSaysTheRealState() {
        let row = { (status: TransferQueue.Status, waiting: Bool, resumedAt: UInt64?, transferred: UInt64, total: UInt64) in
            TransferQueue.Transfer(id: "1", label: "db.sql.gz", route: "web → This Mac", isDir: false, status: status,
                                   transferred: transferred, total: total, resumedAt: resumedAt, waiting: waiting, batch: UUID())
        }
        let line = { FileRules.transferLine($0, locale: us) }
        #expect(line(row(.queued, false, nil, 0, 0)) == "web → This Mac · Queued")
        #expect(line(row(.running, false, nil, 0, 0)) == "web → This Mac · Starting")
        #expect(line(row(.running, false, nil, 500_000, 1_000_000)) == "web → This Mac · 500 kB of 1 MB")
        #expect(line(row(.running, false, 1_000, 1_900_000_000, 2_600_000_000)) == "web → This Mac · Resumed · 1.9 of 2.6 GB")
        #expect(line(row(.running, true, nil, 1_900_000_000, 2_600_000_000)) == "web → This Mac · Waiting for connection · 1.9 of 2.6 GB")
        #expect(line(row(.done, false, nil, 10, 10)) == "web → This Mac · Done")
        #expect(line(row(.cancelled, false, nil, 5, 10)) == "web → This Mac · Stopped")
        #expect(line(row(.failed("Connection lost"), false, nil, 5, 10)) == "web → This Mac · Failed: Connection lost")
    }
}

@Suite struct Permissions {
    @Test func triStateAcrossASelection() {
        let bits = PermissionBits.tri([0o755, 0o750])
        #expect(bits[0...5].allSatisfy { $0 == true || $0 == false })
        #expect(bits[6] == nil && bits[7] == false && bits[8] == nil)
        #expect(PermissionBits.octal(bits) == nil)
        #expect(PermissionBits.octal(PermissionBits.tri([0o755])) == "755")
        #expect(PermissionBits.octal(PermissionBits.tri([0o4755])) == "4755")
        #expect(PermissionBits.octal(PermissionBits.tri([0o7])) == "007")
    }

    @Test func threeDigitsKeepSpecialBitsFourReplaceThem() {
        let current = PermissionBits.tri([0o4755])
        #expect(PermissionBits.octal(PermissionBits.parseOctal("644", current: current)!) == "4644")
        #expect(PermissionBits.octal(PermissionBits.parseOctal("0644", current: current)!) == "644")
        for bad in ["64", "648", "77777", "rw-", ""] { #expect(PermissionBits.parseOctal(bad, current: current) == nil) }
    }

    @Test func changeAppliesOnlyTheBitsEdited() {
        let initial = PermissionBits.tri([0o4755, 0o4750])
        var edited = initial
        #expect(PermissionBits.change(from: initial, to: edited) == (0, 0), "nothing touched: no mode goes to what is inside a folder")
        edited[6] = true
        let change = PermissionBits.change(from: initial, to: edited)
        #expect(change.set == 0o004 && change.clear == 0)
        edited[9] = false
        #expect(PermissionBits.change(from: initial, to: edited).clear == 0o4000)
        #expect((0o4750 & ~change.clear) | change.set == 0o4754)
    }
}

@MainActor
@Test func editWithListsTheTextEditorFirstAndNoAppTwice() {
    let apps = FilePaneView.editors(for: ["notes.txt", "run.sh", "Makefile"])
    #expect(apps.first == NSWorkspace.shared.urlForApplication(toOpen: .plainText))
    #expect(!apps.isEmpty && Set(apps.map(\.lastPathComponent)).count == apps.count)
}

@Test func backAndForwardRetraceAndANewMoveForgetsForward() {
    var history = PathHistory()
    history.moved(from: "/a")           // /a → /b
    history.moved(from: "/b")           // /b → /c
    #expect(history.goBack(from: "/c") == "/b" && history.goBack(from: "/b") == "/a" && history.goBack(from: "/a") == nil)
    #expect(history.goForward(from: "/a") == "/b" && history.forward == ["/c"])
    history.moved(from: "/b")           // /b → /x
    #expect(history.goForward(from: "/x") == nil && history.back == ["/a", "/b"])
}
