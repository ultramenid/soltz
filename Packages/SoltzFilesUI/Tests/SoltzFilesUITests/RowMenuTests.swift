// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import SoltzFilesUI

/// The rows' context menus, read from the list's table as a right click builds them. Needs a window server, so it
/// runs with the snapshots: `SOLTZ_SNAPSHOTS=1 swift test --filter RowMenus`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOLTZ_SNAPSHOTS"] != nil))
struct RowMenus {
    /// The Permissions sheet for a host's folder (user, group and "everything inside" shown), as a PNG beside the others.
    @Test func permissionsSheetOfAHostsFolder() async throws {
        try FileManager.default.createDirectory(at: Snapshots.out, withIntermediateDirectories: true)
        let sheet = PermissionsSheet(entries: [FileEntry(name: "releases", path: "/var/www/releases", isDir: true, permissions: 0o755)],
                                     ownership: true) { _, _, _, _, _ in }
        try await Snapshots.render(sheet, size: CGSize(width: 420, height: 420), dark: true, selectFirstRows: false,
                                   to: Snapshots.out.appending(path: "permissions-dark.png"))
    }

    @Test func aFileOffersItsAppsOnEitherSideAndAFolderDoesNot() async throws {
        try await withTempDir { dir in
            _ = try Snapshots.folder(dir + "/left/var/www", [("releases", nil, 0, 10, 42), ("deploy.log", 148_000, 0, 10, 44)])
            _ = try Snapshots.folder(dir + "/right/Users/you/Backups", [("README.txt", 1_000, -53, 12, 0)])
            let web = MappedProvider(name: "prod-web-01", isLocal: false, root: dir + "/left", home: "/home/deploy")
            let mac = MappedProvider(name: "This Mac", isLocal: true, root: dir + "/right", home: "/Users/you")
            let screen = DualPaneView(left: web, right: mac, queue: TransferQueue(), leftPath: "/var/www", rightPath: "/Users/you/Backups")
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let size = CGSize(width: 1180, height: 640)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: screen.padding(16).frame(width: size.width, height: size.height))
            defer { window.close() }
            try await Snapshots.spin()

            // Each row's menu as title → apps in its submenu (-1 without one), left pane's rows then the right's.
            let menus: [[String: Int]] = Snapshots.tables(in: window.contentView!).flatMap { table in
                (0..<table.numberOfRows).map { row in
                    let rect = table.rect(ofRow: row)
                    let click = NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1)!
                    let items = table.menu(for: click)?.items ?? []
                    // A submenu counts only the apps that carry their icon.
                    return Dictionary(items.map { ($0.title, $0.submenu?.items.filter { $0.image != nil }.count ?? -1) },
                                      uniquingKeysWith: { first, _ in first })
                }
            }
            try #require(menus.count == 3)
            let (folder, hostFile, macFile) = (menus[0], menus[1], menus[2])
            #expect(folder["Open"] != nil && folder["Edit With"] == nil && folder["Open With"] == nil)
            #expect(hostFile["Edit on This Mac"] != nil && (hostFile["Edit With"] ?? 0) > 0)
            #expect(macFile["Open"] != nil && (macFile["Open With"] ?? 0) > 0)
        }
    }
}
