// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import SoltzHostsUI
import SoltzModel
import SwiftUI

// Test harness: compiled only into SoltzTest.app (SOLTZ_HARNESS, scripts/bundle-app.sh). See Harness.swift.
#if SOLTZ_HARNESS

/// `--snapshot <dir>`: renders each screen of the real window to `<dir>/<screen>.png` from a temp data directory with
/// sample data (local shells stand in for remote panes), then exits.
/// The window is made key for each capture, so they show the active state.
@MainActor
enum Snapshot {
    static let requested = CommandLine.arguments.contains("--snapshot")
    static let output: URL = {
        let args = CommandLine.arguments
        let dir = args.firstIndex(of: "--snapshot").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "snapshots"
        return URL(filePath: dir, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath))
    }()
    /// Removed when it exits.
    static let dataDir = FileManager.default.temporaryDirectory.appending(path: "soltz-snapshot-\(UUID().uuidString)")

    nonisolated static func startWatchdog() {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 90)
            print("[FAIL] watchdog: snapshot run did not finish within 90 s")
            exit(1)
        }
    }

    static func run(_ workspace: Workspace) async -> Never {
        setenv("SHELL", "/bin/sh", 1)
        let fm = FileManager.default
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet == nil && $0.contentView != nil }) else {
            print("[FAIL] no window to render")
            exit(1)
        }
        window.setContentSize(Theme.window)
        // The stand-in draws once before the first capture needs it.
        behind.setFrame(window.frame, display: true)
        behind.order(.below, relativeTo: window.windowNumber)
        try? await Task.sleep(for: .milliseconds(500))
        behind.orderOut(nil)

        func host(_ name: String, _ address: String) -> Connection? {
            try? Connection(json: ["id": .string(UUID().uuidString.lowercased()), "name": .string(name), "host": .string(address),
                                   "port": 22, "username": "deploy", "tags": [], "created_at": "", "updated_at": "", "clocks": [:]])
        }
        let hosts = [host("prod-web-01", "10.0.4.11"), host("prod-db-01", "10.0.4.20"), host("nas", "nas.local")].compactMap { $0 }
        await workspace.perform("seed") {
            for host in hosts { try await workspace.save(host, HostSecrets()) }
            for host in hosts.reversed() { try await workspace.markUsed(host.id) } // the mockup's order: last used first
        }
        let web = hosts[0].id
        await workspace.perform("seed") { try await workspace.newGroup("Production", with: hosts[0]) }
        if let group = workspace.folders.first(where: { $0.name == "Production" }) {
            await workspace.perform("seed") { try await workspace.move(hosts[1], toGroup: group.id) }
        }

        // 1. Home, light and dark.
        NSApp.appearance = NSAppearance(named: .aqua)
        await save("home-light", window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await save("home-dark", window)
        // An update on offer in Home's footer.
        let feed = dataDir.appending(path: "latest.json")
        try? Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/soltz/soltz/releases/tag/v0.2.0"}"#.utf8).write(to: feed)
        await workspace.updates.check(repo: "soltz/soltz", feed: feed, current: "0.1.0")
        await save("home-update", window)
        await workspace.updates.check(repo: "soltz/soltz", feed: feed, current: "0.2.0")
        // A host dragged over the group, and the chip that follows the pointer (a drag itself cannot be staged).
        workspace.dropTarget = workspace.folders.first { $0.name == "Production" }?.id
        await save("home-drop", window)
        workspace.dropTarget = nil
        let chip = ImageRenderer(content: DragChip(title: "prod-web-01", systemImage: "server.rack").environment(\.colorScheme, .dark))
        chip.scale = 2
        if let image = chip.cgImage { write("drag-chip", image) }

        // 2. New host, with a bastion to jump through.
        if let bastion = host("bastion", "bastion.example.net") {
            await workspace.perform("seed") { try await workspace.save(bastion, HostSecrets()) }
            var form = NewHostForm()
            (form.host, form.user) = ("10.0.4.11", "deploy")
            await film("new-host-opening", window) { workspace.newHost = form }
            await save("new-host", window, wait: 1.2)
            await film("new-host-closing", window) { workspace.newHost = nil }
            try? await Task.sleep(for: .milliseconds(600))
            workspace.editing = workspace.connections.first { $0.id == web } ?? hosts[0]
            await save("host-editor", window, wait: 1.2)
            workspace.editing = nil
            try? await Task.sleep(for: .milliseconds(600))
            // Both cards with the switch on Key: the same rows, a new host's file to choose, a stored one to replace.
            form.useKey = true
            workspace.newHost = form
            await save("new-host-key", window, wait: 1.2)
            workspace.newHost = nil
            try? await Task.sleep(for: .milliseconds(600))
            // A host with a key of its own (made here by the core, never a real one): Edit names it.
            var keyHost = workspace.connections.first { $0.id == web } ?? hosts[0] // as filed in its group
            keyHost.authType = .key
            if let made = try? await workspace.core.generateSshKeypair(
                optionsJson: #"{"keyType":"ed25519","curve":null,"bits":null,"passphrase":null,"cipher":null,"rounds":null}"#),
               let key = (try? JSONDecoder().decode([String: String].self, from: Data(made.utf8)))?["private_key"] {
                await workspace.perform("seed") { try await workspace.save(keyHost, HostSecrets(privateKey: key)) }
            }
            workspace.editing = workspace.connections.first { $0.id == keyHost.id } ?? keyHost
            await save("host-editor-key", window, wait: 1.2)
            workspace.editing = nil
            try? await Task.sleep(for: .milliseconds(600))
            workspace.naming = GroupNaming(host: hosts[2])
            await save("new-group", window, wait: 1.2)
            NSApp.appearance = NSAppearance(named: .aqua)
            await save("new-group-light", window)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            workspace.naming = nil
            try? await Task.sleep(for: .milliseconds(600))
            workspace.showingSettings = true
            await save("settings", window, wait: 1.2)
            workspace.showingSettings = false
            await workspace.perform("seed") { try await workspace.delete(bastion) }
            try? await Task.sleep(for: .milliseconds(600))
        }

        // 3. The workspace: two panes stacked on the left, one tall on the right, a second tab; local shells stand in.
        var stands: [TerminalSession] = []
        func stand(_ title: String, _ cwd: String, _ text: String, _ placement: Placement) async {
            workspace.newLocalTerminal(placement)
            guard let session = workspace.activeSession else { return }
            stands.append(session)
            session.hostID = web
            session.title = title
            session.sink.event(name: "ssh-cwd", payloadJson: "\"\(cwd)\"")
            _ = await wait { session.isAttached }
            session.send(Data("PS1=''; clear; printf '\(text)'\n".utf8))
        }
        await stand("Logs", "/var/log/nginx", "deploy@prod-web-01 $ tail -f error.log\\n10:43:40 ERROR connect() failed while connecting to upstream\\n10:43:44 [info] upstream app-2:3000 healthy\\n", .tab)
        let logs = stands.first
        await stand("Docker", "~/app", "deploy@prod-web-01 $ docker ps\\napp-1   Up 3 days\\nredis   Up 41 days\\n", .right)
        if let logs { workspace.activatePane(of: logs.id) }
        await stand("Shell", "~", "deploy@prod-web-01 $ uptime\\n10:44 up 41 days, load average: 0.42\\n", .below)
        let first = workspace.layout.activeSplitTabId
        await stand("shell", "~", "deploy@prod-web-01 $ \\n", .tab)
        if let first { workspace.layout.renameSplitTab(first, "deploy") }
        // The active pane reads as a connected persistent session in the bottom bar.
        if let logs {
            logs.args = ["sessionId": "snapshot-logs", "connectionId": .string(web), "persist": true]
            logs.sink.event(name: "ssh-mux-mode", payloadJson: #"{"control":true,"tmux":true}"#)
            workspace.show(nil)
            workspace.show(web)
            if let first { workspace.activate(first) }
            workspace.activatePane(of: logs.id)
        }
        await save("workspace", window, wait: 1.5)
        // The same in light: the terminals' palette and the cards follow the app's appearance together.
        NSApp.appearance = NSAppearance(named: .aqua)
        await save("workspace-light", window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Selected text: the system's selection colour, the text still in its own.
        logs?.terminal.selectAll()
        await save("selection", window)
        // A click in that pane drops the selection again (sent in-process, as `stageFileDrag` does).
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: 300, y: window.frame.height - 200), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1).map(window.sendEvent)
        }
        workspace.dropTarget = workspace.tabs.last.map { Workspace.key($0.id) }
        await save("tab-drop", window)
        workspace.dropTarget = nil
        // The two host-key questions, staged on a stand-in session: a host seen for the first time, then a changed key.
        if let logs {
            let fingerprint = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
            for (name, stored) in [("host-key-first", [HostKeyConflict.Stored]()),
                                   ("host-key-changed", [.init(fingerprint: "SHA256:jAyTmXIo9Ew0jUu3GJbGyXqQIrQyGgZBbNdQ4SoYZ7c")])] {
                logs.conflict = HostKeyConflict(sessionId: "snapshot", host: "10.0.4.11", port: 22, newFingerprint: fingerprint, storedEntries: stored)
                await save(name, window, wait: 1.2)
                // The window server gives an app no picture of a system alert, so what it says is read from it instead.
                if let alert = window.attachedSheet, let content = alert.contentView {
                    func all<V: NSView>(_ type: V.Type, in view: NSView) -> [V] { (view as? V).map { [$0] } ?? view.subviews.flatMap { all(type, in: $0) } }
                    let texts = all(NSTextField.self, in: content).map(\.stringValue).filter { !$0.isEmpty }
                    let buttons = all(NSButton.self, in: content)
                    print("[INFO] \(name): alert says \(texts)")
                    print("[INFO] \(name): buttons \(buttons.map(\.title)), Return presses \(buttons.filter { $0.keyEquivalent == "\r" }.map(\.title))")
                } else { print("[FAIL] \(name): the alert is not shown") }
                logs.conflict = nil
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        // A saved host's login prompt: its address is shown, not editable.
        workspace.connectForm = ConnectForm(hosts[2])
        await save("login", window, wait: 1.2)
        workspace.connectForm = nil
        try? await Task.sleep(for: .milliseconds(600))
        await film("pane-maximizing", window) { workspace.toggleMaximize() }
        workspace.toggleMaximize()

        // 4. A files tab: a host's files in a pane. A local session on a temp folder shaped like the mockup's stands
        // in for the host's.
        let root = dataDir.appending(path: "files")
        let www = root.appending(path: "var/www")
        for dir in ["releases", "shared"] { try? fm.createDirectory(at: www.appending(path: dir), withIntermediateDirectories: true) }
        sparse(www.appending(path: "db-dump-1123.sql.gz"), gigabytes: 2.6)
        try? Data(repeating: 46, count: 148_000).write(to: www.appending(path: "deploy.log"))
        workspace.newLocalTerminal()
        let filesTab = workspace.layout.activeSplitTabId
        if let pane = workspace.activeSession, await wait(until: { pane.isAttached }) {
            stands.append(pane)
            pane.hostID = web
            pane.filesPath = www.path(percentEncoded: false)
            pane.showsFiles = true
        }
        if let first, let filesTab {
            workspace.activate(first)
            try? await Task.sleep(for: .milliseconds(500))
            await film("tab-to-files", window) { workspace.activate(filesTab) }
        }
        // A copy under way, for the Transfers card (cancelled once captured; the temp folder goes at exit).
        let incoming = root.appending(path: "incoming")
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        if let dump = try? await workspace.localFiles.list(www.path(percentEncoded: false)).first(where: { $0.name.hasPrefix("db-dump") }) {
            workspace.transfers.enqueue([dump], from: workspace.localFiles, to: workspace.localFiles, into: incoming.path(percentEncoded: false))
        }
        await save("files", window, wait: 1.5)
        NSApp.appearance = NSAppearance(named: .aqua)
        await save("files-light", window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        workspace.transfers.cancelAll()
        stageFileDrag(window)
        try? await Task.sleep(for: .milliseconds(300))

        // 5. A sidebar row dragged onto the main panel: the panel is where it lands, and it opens a new tab (This
        // Mac's here, among prod-web-01's).
        if let first {
            workspace.activate(first)
            workspace.dropTarget = Workspace.panel
            await save("panel-drop", window)
            workspace.dropTarget = nil
            try? await Task.sleep(for: .milliseconds(400))
            await film("drop-to-tab", window) { workspace.openTab(for: Dragged(kind: .host, id: Workspace.thisMac)) }
            if let guest = workspace.activeSession, await wait(until: { guest.isAttached }) {
                guest.send(Data("PS1=''; clear; printf 'me@this-mac ~ $ uname\\nDarwin\\n'\n".utf8))
            }
            await save("tabs-of-hosts", window)
        }

        stands.forEach { $0.args = nil } // they close as the local shells they are
        workspace.closeAll()
        try? await Task.sleep(for: .milliseconds(300))
        try? fm.removeItem(at: dataDir)
        print("[INFO] snapshots in \(output.standardizedFileURL.path(percentEncoded: false))")
        exit(0)
    }

    /// Starts a drag of the first two file rows with in-process mouse events (the test run's input block only stops
    /// events from the queue's front door) and saves the chip it is given. The drag carries nothing: `staged`.
    private static func stageFileDrag(_ window: NSWindow) {
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        guard let table = window.contentView.map(tables)?.first(where: { $0.numberOfRows > 1 }) else {
            return print("[FAIL] file-drag: no file list in the window")
        }
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        let row = table.rect(ofRow: 0)
        let start = table.convert(CGPoint(x: row.minX + 60, y: row.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        DragImages.staged = true
        defer { DragImages.staged = false }
        // The table's own tracking loop reads the queued events once the mouse is "down": through the window, or
        // straight to the table if a row's own view keeps the click.
        for send in [window.sendEvent, table.mouseDown(with:)] where DragImages.last == nil {
            for dx in stride(from: 6.0, through: 36, by: 6) { mouse(.leftMouseDragged, dx).map { NSApp.postEvent($0, atStart: false) } }
            mouse(.leftMouseUp, 36).map { NSApp.postEvent($0, atStart: false) }
            mouse(.leftMouseDown, 0).map(send)
        }
        guard let image = DragImages.last?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return print("[FAIL] file-drag: no chip; \(DragImages.note.isEmpty ? "no drag began" : DragImages.note); list is \(type(of: table)), "
                + "click lands on \(window.contentView?.hitTest(start).map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        write("file-drag-chip", image)
        print("[INFO] file-drag: \(DragImages.note)")
    }

    /// Captures the window (and its sheet) once SwiftUI has settled, as the window server composites it, active: alone
    /// to `<output>/<name>.png`, and over the busy stand-in to `<output>/<name>-live.png`, which shows how much the
    /// backdrop blurs. An app may capture its own windows without Screen Recording permission.
    private static func save(_ name: String, _ window: NSWindow, wait seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
        await focus(window)
        try? await Task.sleep(for: .milliseconds(300))
        capture(name, window, over: nil)
        capture("\(name)-live", window, over: behind)
        describe(name, window)
    }

    /// The window (or its sheet) key, so captures show the active state. Cooperative `activate()` is refused while the
    /// user works in another app; this developer mode insists.
    private static func focus(_ window: NSWindow) async {
        let front = window.attachedSheet ?? window
        // The first activation request may only bring the app forward; the window turns key on a later one.
        for _ in 0..<(cannotFocus ? 1 : 3) where !front.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            front.makeKeyAndOrderFront(nil)
            _ = await wait(cannotFocus ? 0.3 : 3) { front.isKeyWindow }
        }
        guard !front.isKeyWindow else { return }
        // A locked screen never gives it: said once, and not waited for again, so the run still ends in time.
        if !cannotFocus { print("[INFO] the window does not turn key (is the screen locked?); captures show it inactive") }
        cannotFocus = true
    }

    private static var cannotFocus = false

    /// The stand-in for the desktop behind the window: a borderless window of colourful stripes and text, ordered
    /// directly behind it. (A capture of one's own windows cannot include anyone else's.)
    private static let behind: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = Stripes()
        return window
    }()

    private final class Stripes: NSView {
        override func draw(_: NSRect) {
            // shortcut: fixed colours, for this test pattern only; the app itself uses semantic styles.
            let colours: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]
            for (i, x) in stride(from: -bounds.height, to: bounds.width, by: 70).enumerated() {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: x, y: 0))
                stripe.line(to: NSPoint(x: x + 70, y: 0))
                stripe.line(to: NSPoint(x: x + 70 + bounds.height, y: bounds.height))
                stripe.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
                colours[i % colours.count].setFill()
                stripe.fill()
            }
            let text = NSAttributedString(string: "Behind the window — Soltz 0123456789", attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: NSColor.black])
            for y in stride(from: 20.0, to: bounds.height, by: 90) { text.draw(at: NSPoint(x: 30 + y.truncatingRemainder(dividingBy: 180), y: y)) }
        }
    }

    /// What the window's backdrop and appearance really are, as evidence beside the pictures.
    private static func describe(_ name: String, _ window: NSWindow) {
        func effects(_ view: NSView) -> [String] {
            let own: [String] = if let effect = view as? NSVisualEffectView {
                ["NSVisualEffectView \(effect.blendingMode == .behindWindow ? "behind-window" : "within-window") material \(effect.material.rawValue)"]
            } else if let glass = view as? NSGlassEffectView {
                ["NSGlassEffectView style \(glass.style == .clear ? "clear" : "regular")"]
            } else { [] }
            return own + view.subviews.flatMap(effects)
        }
        // Whether the window server gives the window its own edges and empty glass (a see-through window can let
        // clicks fall through there, and then it cannot be resized or dragged).
        let f = window.frame
        let points = ["left": NSPoint(x: f.minX + 2, y: f.midY), "right": NSPoint(x: f.maxX - 2, y: f.midY), "bottom": NSPoint(x: f.midX, y: f.minY + 2),
                      "top": NSPoint(x: f.midX, y: f.maxY - 2), "inside": NSPoint(x: f.minX + 40, y: f.minY + 40)]
        let hits = points.sorted { $0.key < $1.key }.map { "\($0.key) \(NSWindow.windowNumber(at: $0.value, belowWindowWithWindowNumber: 0) == window.windowNumber)" }
        print("[INFO] \(name): takes clicks at " + hits.joined(separator: ", "))
        print("[INFO] \(name): resizable \(window.styleMask.contains(.resizable)), size \(Int(window.frame.width))x\(Int(window.frame.height)), min \(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height)), max \(window.contentMaxSize.width)x\(window.contentMaxSize.height)")
        print("[INFO] \(name): window opaque \(window.isOpaque), key \((window.attachedSheet ?? window).isKeyWindow), appearance \(window.appearance?.name.rawValue ?? "inherited") "
            + "(effective \(window.effectiveAppearance.name.rawValue)); " + (window.contentView?.superview.map(effects) ?? []).prefix(3).joined(separator: ", "))
    }

    // shortcut: `CGWindowListCreateImageFromArray` is obsoleted in the macOS 15+ SDK (ScreenCaptureKit replaces it, but
    // needs the permission even for one's own windows), so this developer-only mode looks the C symbol up at run time.
    private static func capture(_ name: String, _ window: NSWindow, over stand: NSWindow?) {
        if let stand {
            stand.setFrame(window.frame, display: true)
            stand.order(.below, relativeTo: window.windowNumber)
        }
        defer { stand?.orderOut(nil) }
        guard let image = shot(window, over: stand) else { return print("[FAIL] \(name): the window server returned no image") }
        write(name, image)
    }

    /// The window, its sheet and the stand-in as the window server composites them now.
    private static func shot(_ window: NSWindow, over stand: NSWindow?) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        // Front to back: the sheet (attached, or still opening), its window, the stand-in.
        // An alert's panel too: it is a sheet of another class.
        var sheets = NSApp.windows.filter { $0.isVisible && $0.className.contains("SheetPresentationWindow") }
        if let alert = window.attachedSheet, !sheets.contains(alert) { sheets.insert(alert, at: 0) }
        let windows = sheets + [window] + (stand.map { [$0] } ?? [])
        let ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        guard let array = ids.withUnsafeBufferPointer({ CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil) })
        else { return nil }
        // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        let image = unsafeBitCast(symbol, to: Capture.self)(.null, array, 1 << 0 | 1 << 3)?.takeRetainedValue()
        return image.flatMap { $0.width > 1 ? $0 : nil }
    }

    /// `<name>.png`: the frames of the window right after `change` (a popup opening or closing), side by side, to see
    /// a transition a still capture cannot show.
    private static func film(_ name: String, _ window: NSWindow, frames: Int = 12, change: () -> Void) async {
        behind.setFrame(window.frame, display: true)
        behind.order(.below, relativeTo: window.windowNumber)
        try? await Task.sleep(for: .milliseconds(300))
        change()
        var shots: [CGImage] = []
        for _ in 0..<frames {
            if let image = shot(window, over: behind) { shots.append(image) }
            try? await Task.sleep(for: .milliseconds(15))
        }
        behind.orderOut(nil)
        guard let first = shots.first else { return print("[FAIL] \(name): no frames") }
        let columns = 4, width = first.width / 3, height = first.height / 3
        let rows = (shots.count + columns - 1) / columns
        guard let context = CGContext(data: nil, width: width * columns, height: height * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.systemPurple.cgColor) // a flat colour behind, so glass and grey read apart
        context.fill(CGRect(x: 0, y: 0, width: width * columns, height: height * rows))
        for (i, image) in shots.enumerated() {
            context.draw(image, in: CGRect(x: (i % columns) * width, y: (rows - 1 - i / columns) * height, width: width, height: height))
        }
        if let sheet = context.makeImage() { write(name, sheet) }
    }

    private static func write(_ name: String, _ image: CGImage) {
        let url = output.appending(path: "\(name).png")
        do {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print("[INFO] wrote \(url.standardizedFileURL.path(percentEncoded: false))")
        } catch {
            print("[FAIL] \(name): \(error.localizedDescription)")
        }
    }

    private static func sparse(_ url: URL, gigabytes: Double) {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: UInt64(gigabytes * 1_073_741_824))
        try? handle.close()
    }

    private static func wait(_ seconds: Double = 4, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
#endif
