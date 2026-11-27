// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import SoltzCore
import SoltzFilesUI
import SoltzHostsUI
import SoltzKeychainUI
import SoltzModel

// Test harness: compiled only into SoltzTest.app (SOLTZ_HARNESS, scripts/bundle-app.sh). See Harness.swift.
#if SOLTZ_HARNESS

/// `--smoke`: drives the real window and Rust core, prints one `[PASS]`/`[FAIL]` line per check
/// and exits 0 (all passed) or 1, within 10 seconds.
@MainActor
enum Smoke {
    static let requested = CommandLine.arguments.contains("--smoke")
    /// The smoke run's data directory, used with the in-memory keychain; removed when it exits.
    static let dataDir = FileManager.default.temporaryDirectory.appending(path: "soltz-smoke-\(UUID().uuidString)")

    nonisolated static func startWatchdog() {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 15) // the window checks animate a resize three times
            print("[FAIL] watchdog: smoke run did not finish within 15 s")
            exit(1)
        }
    }

    static func run(_ workspace: Workspace) async -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }
        // A login /bin/sh reads no zsh or bash rc files, so a slow or chatty user shell setup cannot fail the run.
        setenv("SHELL", "/bin/sh", 1)
        check("main window open", NSApp.windows.contains(where: \.isVisible))

        workspace.newLocalTerminal()
        guard let first = workspace.activeSession else {
            check("local terminal tab opened", false)
            exit(1)
        }
        check("local shell opened through the Rust core, terminal on screen",
              await wait { first.isAttached && first.terminal.readScreenText() != nil })
        workspace.route(Data("echo soltz-app-ok\n".utf8), from: first.id)
        check("echo soltz-app-ok printed by the shell", await wait { first.screenLines.contains("soltz-app-ok") },
              first.screenLines.suffix(3).joined(separator: " | "))

        workspace.newLocalTerminal(.right)
        let second = workspace.activeSession
        check("split right: two leaves in one tab",
              workspace.layout.root?.leaves.count == 2 && workspace.layout.splitTabs.count == 1 && second !== first)
        check("second shell opened, its pane on screen",
              await wait { second?.isAttached == true && second?.terminal.readScreenText() != nil })

        workspace.closePane()
        check("close pane: one leaf left, still in a tab", workspace.layout.root?.leaves.count == 1 && workspace.layout.splitTabs.count == 1)
        workspace.closePane()
        check("close pane: no tabs or sessions left", workspace.layout.splitTabs.isEmpty && workspace.sessions.isEmpty)

        // Upstream `handleSessionClosed` for local shells: `exit` (status 0) closes the tab, a failing exit keeps it.
        for (command, clean) in [("exit", true), ("exit 3", false)] {
            workspace.newLocalTerminal()
            guard let shell = workspace.activeSession else { continue }
            let up = await wait { shell.isAttached && shell.terminal.readScreenText() != nil }
            workspace.route(Data("\(command)\n".utf8), from: shell.id)
            let gone = await wait { clean ? workspace.sessions[shell.id] == nil : shell.ended }
            check(clean ? "`exit` in a local shell closes its tab (upstream: a clean local exit ends the session)"
                        : "`exit 3` in a local shell keeps its tab, Session ended, so the failure can be read",
                  up && gone && (clean ? workspace.layout.splitTabs.isEmpty : workspace.sessions[shell.id] != nil), "")
            workspace.closeAll()
        }

        await storage(workspace, check)
        await home(workspace, check)
        await keychain(workspace, check)
        await files(workspace, check)
        await titleBar(check)
        await strayClick(workspace, check)

        try? await Task.sleep(for: .milliseconds(300)) // lets both closes reach the core before exit
        try? FileManager.default.removeItem(at: dataDir)
        exit(failures == 0 ? 0 : 1)
    }

    /// A double click on the window's top strip (the content runs under the title bar there, so the app answers it
    /// itself): the screen filled, then the size given back; a traffic light's own double click is not answered.
    /// The handler is called as the app's event monitor calls it: a test run's own monitor drops mouse events, at
    /// times before that one sees them.
    private static func titleBar(_ check: (String, Bool, String) -> Void) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else {
            return check("a double click on the window's top strip", false, "no window")
        }
        /// A double click's second press at `x` of the strip (the middle for nil): answered, when it is on the bar.
        func doubleClick(x: CGFloat?) -> Bool {
            let press = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x ?? window.frame.width / 2, y: window.frame.height - 14),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
            guard let bar = AppDelegate.titleBar(under: press) else { return false }
            AppDelegate.titleBarDoubleClick(bar, wasZoomed: bar.isZoomed)
            return true
        }
        let size = window.frame.size
        let onButton = doubleClick(x: 60)
        let first = doubleClick(x: nil)
        let filled = await wait { window.isZoomed && window.frame.size != size }
        let second = doubleClick(x: nil)
        let back = await wait { !window.isZoomed && window.frame.size == size }
        // The system gave the size back at the first press: the double click must not fill the screen again.
        AppDelegate.titleBarDoubleClick(window, wasZoomed: true)
        let left = !window.isZoomed
        check("a double click on the window's top strip fills the screen and a second gives the size back; not on a traffic light",
              first && filled && second && back && left && !onButton,
              "answered \(first) \(second), filled \(filled), back \(back), left alone \(left), on a button \(onButton)")

        // The app quit while it filled the screen, as the window is then found at the next launch: filled, with
        // nothing to go back to. It opens at the app's first size, and from filled a double click gives that size.
        // (Set to the screen's frame at once: every animated resize counts against the run's time.)
        guard let screen = window.screen?.visibleFrame else { return check("a window left filling the screen", false, "no screen") }
        let own = window.frame
        window.setFrame(screen, display: true)
        AppDelegate.unfilledFrame = nil
        let foundFilled = window.isZoomed
        AppDelegate.openAtOwnSize()
        let opened = !window.isZoomed && window.frame.size == Theme.window
        window.setFrame(screen, display: true)
        _ = doubleClick(x: nil)
        let given = await wait { !window.isZoomed && window.frame.size == Theme.window }
        window.setFrame(own, display: true)
        AppDelegate.unfilledFrame = nil
        check("a window left filling the screen opens at its own size, and a double click on a filled one always gives a size back",
              foundFilled && opened && given, "found filled \(foundFilled), opened \(opened), given \(given)")
    }

    /// Hosts and secrets through the same calls the hosts page makes, against `dataDir` set up by the launch path.
    private static func storage(_ workspace: Workspace, _ check: (String, Bool, String) -> Void) async {
        let core = workspace.core
        let error = { workspace.failure?.message ?? "" }
        func newID() -> String { UUID().uuidString.lowercased() }
        check("vault initialised at launch, unlocked in keychain mode",
              (try? await core.vaultStatus()) == .unlocked(mode: .keychain), "")

        let id = newID()
        guard let new = try? Connection(json: ["id": .string(id), "host": "smoke.invalid", "port": 22, "username": "root",
                                               "tags": [], "created_at": "", "updated_at": "", "clocks": [:]]),
              await workspace.perform("save", { try await workspace.save(new, HostSecrets(password: "smoke-pw")) }),
              let saved = workspace.connections.first(where: { $0.id == id })
        else { return check("new host saved and listed back", false, error()) }
        let stamp = saved.createdAt
        check("new host stamped as upstream connection_save: 40 clocks, created_at, updated_at at one chrono RFC 3339 time",
              saved.updatedAt == stamp && saved.deletedAt == nil
                  && saved.clocks == Dictionary(uniqueKeysWithValues: Workspace.connectionClocks.map { ($0, stamp) })
                  && stamp.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{3}|\.\d{6}|\.\d{9})?\+00:00/) != nil, stamp)
        check("password stored under password:<id>", (try? core.secretGet(key: "password:\(id)")) == "smoke-pw", "")

        try? await Task.sleep(for: .milliseconds(5)) // the edit's clock must read later than the create's
        var edit = saved
        edit.host = "edited.smoke.invalid"
        await workspace.perform("edit") { try await workspace.save(edit, HostSecrets()) }
        let edited = workspace.connections.first { $0.id == id }
        let clock = edited?.clocks["host"] ?? ""
        check("edit stamps only the edited field's clock; updated_at follows it, created_at stays",
              clock > stamp && edited?.updatedAt == clock && edited?.createdAt == stamp && edited?.clocks.count == 40
                  && edited?.clocks.filter { $0.key != "host" }.values.allSatisfy { $0 == stamp } == true, clock)
        check("connect resolves the stored login", (try? edited.map(workspace.login(for:))) == Login(username: "root", password: "smoke-pw"), "")

        var copy = edited ?? saved
        copy.id = newID()
        copy.clocks = [:]
        await workspace.perform("duplicate") { try await workspace.save(copy, HostSecrets(copyFrom: id)) }
        check("duplicate is a new host and copies the original's password (copyFrom)",
              (workspace.connections.first { $0.id == copy.id }?.createdAt ?? "") > clock
                  && (try? core.secretGet(key: "password:\(copy.id)")) == "smoke-pw", error())

        await workspace.perform("delete") { try await workspace.delete(edited ?? saved) }
        check("deleted host gone from the list, its copy kept",
              !workspace.connections.contains { $0.id == id } && workspace.connections.contains { $0.id == copy.id }, error())

        func folder(_ name: String, in parent: String?) -> Folder? {
            try? Folder(json: ["id": .string(newID()), "name": .string(name), "created_at": "", "updated_at": "",
                               "clocks": [:], "parent_folder_id": parent.map(JSONValue.string) ?? .null])
        }
        guard let outer = folder("Outer", in: nil), let inner = folder("Inner", in: outer.id) else {
            return check("folder delete cascades to its subfolder and the hosts filed in them", false, "")
        }
        var filed = workspace.connections.first { $0.id == copy.id } ?? copy
        filed.folderID = inner.id
        await workspace.perform("file") {
            try await workspace.save(outer)
            try await workspace.save(inner)
            try await workspace.save(filed, HostSecrets())
        }
        let wasFiled = workspace.folders.count == 2 && workspace.connections.first?.folderID == inner.id
        await workspace.perform("delete folder") { try await workspace.delete(outer) }
        check("folder delete cascades to its subfolder and the hosts filed in them",
              wasFiled && workspace.folders.isEmpty && workspace.connections.isEmpty, error())
        check("known hosts listed (none yet)", (try? await core.entityList(kind: .knownHosts)) == "[]", "")
    }

    /// Home and the workspaces: the hosts card's rows, a row's Open into a workspace and back with the session alive (a
    /// local shell standing in for the host's SSH session), and the New host sheet's Connect.
    private static func home(_ workspace: Workspace, _ check: (String, Bool, String) -> Void) async {
        let core = workspace.core
        let error = { workspace.failure?.message ?? "" }
        func newID() -> String { UUID().uuidString.lowercased() }
        let folderID = newID(), webID = newID(), dbID = newID()
        guard let folder = try? Folder(json: ["id": .string(folderID), "name": "Prod", "created_at": "", "updated_at": "", "clocks": [:]]),
              let web = try? Connection(json: ["id": .string(webID), "name": "prod-web-01", "host": "10.0.4.11", "port": 22, "username": "deploy",
                                               "tags": [], "created_at": "", "updated_at": "", "clocks": [:]]),
              let db = try? Connection(json: ["id": .string(dbID), "host": "db.smoke.invalid", "port": 2222, "username": "pg",
                                              "folder_id": .string(folderID), "tags": [], "created_at": "", "updated_at": "", "clocks": [:]]),
              await workspace.perform("save hosts", {
                  try await workspace.save(folder)
                  try await workspace.save(web, HostSecrets())
                  try await workspace.save(db, HostSecrets())
              })
        else { return check("Home: hosts saved", false, error()) }
        let groups = workspace.homeGroups()
        let listed = groups.map { "\($0.title ?? "-"): \($0.rows.map { "\($0.name) \($0.detail)" }.joined(separator: ", "))" }
        check("Home lists the saved hosts by folder (name and address), This Mac's local terminal last of the unfiled ones; typing filters them",
              workspace.shown == nil && listed == ["-: prod-web-01 10.0.4.11, Local terminal This Mac", "Prod: db.smoke.invalid:2222 pg"]
                  && workspace.homeGroups(matching: "web").flatMap(\.rows).map(\.id) == [webID],
              listed.joined(separator: " | "))
        await workspace.perform("group") {
            if let web = workspace.connections.first(where: { $0.id == webID }) { try await workspace.newGroup("Edge", with: web) }
        }
        let edge = workspace.homeGroups().first { $0.title == "Edge" }
        await workspace.perform("ungroup") { if let folder = edge?.folder { try await workspace.deleteGroup(folder) } }
        check("Home's groups: a host moves into a new group; deleting the group keeps the host, in no group",
              edge?.rows.map(\.id) == [webID] && !workspace.folders.contains { $0.name == "Edge" && $0.deletedAt == nil }
                  && workspace.homeGroups().first { $0.title == nil }?.rows.contains { $0.id == webID } == true
                  && workspace.connections.contains { $0.id == webID },
              error())

        // The update check, against a release written to a temp file: a newer one is offered, the same one is not.
        let feed = dataDir.appending(path: "latest.json")
        let page = "https://github.com/soltz/soltz/releases/tag/v9.4.0"
        try? Data(#"{"tag_name":"v9.4.0","html_url":"\#(page)","body":"notes"}"#.utf8).write(to: feed)
        let newer = await workspace.updates.check(repo: "soltz/soltz", feed: feed, current: "9.3.12")
        let offered = workspace.updates.available?.version == "9.4.0"
        let same = await workspace.updates.check(repo: "soltz/soltz", feed: feed, current: "9.4.0")
        // A feed pointing anywhere but the repository's own pages is not offered.
        let elsewhere = await workspace.updates.check(repo: "other/app", feed: feed, current: "9.3.12")
        check("an update check offers a newer release and its page, nothing when this build is the newest, and never a page outside the repository",
              newer == .newer(.init(tagName: "v9.4.0", htmlUrl: URL(string: page)!)) && offered
                  && same == .current && elsewhere == .failed("The release has no download page.") && workspace.updates.available == nil,
              "\(newer) \(same) \(elsewhere)")

        // A row's Open: This Mac's starts a local shell in its workspace; a host with a live session returns to it.
        workspace.open(Workspace.thisMac)
        guard let local = workspace.activeSession else { return check("opening This Mac enters its workspace", false, "") }
        let opened = workspace.shown == Workspace.thisMac && local.args == nil
        workspace.newLocalTerminal()
        guard let stand = workspace.activeSession, await wait(until: { stand.isAttached && local.isAttached }) else {
            return check("opening a host enters its workspace", false, "no shell")
        }
        // A program in the terminal setting the clipboard (OSC 52): asked about, Don't Allow the default, and refused
        // it leaves the clipboard as it was. (Were it ever obeyed here, the clipboard is put back.)
        let board = NSPasteboard.general
        let (before, held) = (board.changeCount, board.string(forType: .string))
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let sheet = { NSApp.windows.compactMap(\.attachedSheet).first }
        stand.terminal.feed(Data("\u{1B}]52;c;\(Data("soltz-smoke-clipboard".utf8).base64EncodedString())\u{07}".utf8))
        // The alert is up once it has its default button. That is asked of the panel, not read from the buttons' keys:
        // a default button has Return only while its panel is the key window, which a test run's never needs to be.
        let askedClipboard = await wait { sheet()?.defaultButtonCell != nil }
        let choices: [NSButton] = (sheet()?.contentView).map(buttons) ?? []
        let refusing = [sheet()?.defaultButtonCell?.title].compactMap { $0 }
        if let panel = sheet() { panel.sheetParent?.endSheet(panel, returnCode: .alertFirstButtonReturn) }
        let closed = await wait { sheet() == nil }
        check("a terminal program's clipboard write (OSC 52) is asked about, Don’t Allow the default; refused, the clipboard is untouched",
              askedClipboard && refusing == ["Don’t Allow"] && choices.contains { $0.title == "Allow" } && closed && board.changeCount == before,
              "asked \(askedClipboard), buttons \(choices.map(\.title)), default \(refusing), clipboard \(board.changeCount == before ? "untouched" : "CHANGED")")
        if board.changeCount != before {
            board.clearContents()
            if let held { board.setString(held, forType: .string) }
        }
        stand.hostID = webID
        workspace.show(nil)
        workspace.open(webID)
        let entered = workspace.shown == webID && workspace.activeSession === stand && workspace.tabs(of: webID).count == 1
            && workspace.tabs.count == 2
        workspace.show(Workspace.thisMac)
        let switched = workspace.shown == Workspace.thisMac && workspace.activeSession === local
            && workspace.tabs(of: webID).count == 1 && workspace.tabs(of: Workspace.thisMac).count == 1
        workspace.show(nil)
        check("opening a row shows its host's tab: This Mac's starts a local shell; a host with a live session returns to it; every host's tabs are in the one strip",
              opened && entered && workspace.liveState(webID) == true && workspace.liveState(dbID) == nil, "")
        check("another host's tab shows with both hosts' sessions still alive",
              switched && workspace.shown == nil && workspace.sessions[stand.id]?.isAttached == true && workspace.sessions[local.id] != nil
                  && !stand.ended && workspace.homeGroups().flatMap(\.rows).count == 3, "")
        // A session dragged from the sidebar onto the main panel: the drop is sent to the window as AppKit would send
        // it, at the middle of the pane's terminal (which takes dropped text for itself).
        workspace.show(Workspace.thisMac)
        try? await Task.sleep(for: .milliseconds(300))
        func terminals(_ view: NSView) -> [NSView] {
            (view.registeredDraggedTypes.contains(.string) ? [view] : []) + view.subviews.flatMap(terminals)
        }
        let dragBoard = NSPasteboard.withUniqueName()
        dragBoard.clearContents()
        dragBoard.setData((try? JSONEncoder().encode(Dragged(kind: .session, id: local.id))) ?? Data(), forType: Dragged.pasteboardType)
        var dropped = (taker: "no terminal", taken: false)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
           let terminal = window.contentView.map(terminals)?.first {
            dropped = StagedDrop.send(dragBoard, at: terminal.convert(CGPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil), in: window)
        }
        let landed = await wait(2) { workspace.tabs.count == 3 }
        dragBoard.releaseGlobally()
        check("a sidebar session dropped on a terminal pane is taken by the pane, not by the terminal as text, and opens a new tab on its host",
              dropped.taken && landed && !dropped.taker.contains("Terminal") && workspace.tabs(of: Workspace.thisMac).count == 2
                  && workspace.shown == Workspace.thisMac && workspace.activeSession !== local,
              "taken by \(dropped.taker): \(dropped.taken), tabs \(workspace.tabs.count)")
        let strip = workspace.tabs.map(\.id)
        let first = strip.count == 3 && workspace.dropped(Dragged(kind: .tab, id: strip[2]), before: strip[0])
            && workspace.tabs.map(\.id) == [strip[2], strip[0], strip[1]]
        check("a tab dragged onto another takes its place in the strip, hosts mixed; dropped at the strip's end it goes last",
              first && workspace.dropped(Dragged(kind: .tab, id: strip[2]), before: nil) && workspace.tabs.map(\.id) == strip, "")
        workspace.closeAll()

        // The New host card's Connect: saved as the full editor saves a host, then connected (no login typed: the prompt).
        var form = NewHostForm()
        form.host = "ops@new.smoke.invalid:2200" // pasted whole: spread over the three fields
        form.spreadAddress()
        form.label = " New smoke "
        let saved = await workspace.create(form)
        check("New host's Connect stores the host (its label trimmed, a pasted address spread to host, user and port; persistent), then asks for its login",
              saved.map { $0.name == "New smoke" && $0.host == "new.smoke.invalid" && $0.port == 2200 && $0.username == "ops" && $0.persistSession == true
                  && $0.clocks.count == Workspace.connectionClocks.count } == true
                  && workspace.connectForm?.connection?.id == saved?.id && workspace.connectForm?.save == true,
              error())
        workspace.connectForm = nil
        await workspace.perform("delete hosts") {
            for row in workspace.connections where [webID, dbID, saved?.id].contains(row.id) { try await workspace.delete(row) }
            try await workspace.delete(folder)
        }
    }

    /// Keys, identities and connect arguments through the calls the keychain and hosts pages make.
    /// Secrets are compared, never printed.
    private static func keychain(_ workspace: Workspace, _ check: (String, Bool, String) -> Void) async {
        let core = workspace.core
        let error = { workspace.failure?.message ?? "" }
        func newID() -> String { UUID().uuidString.lowercased() }
        func row(_ fields: JSONObject) -> JSONObject {
            fields.merging(["id": .string(newID()), "created_at": "", "updated_at": "", "clocks": [:]]) { given, _ in given }
        }

        // Keychain: generate, save, derive, identity.
        let keyID = newID()
        guard let pair = try? await workspace.keyOperations.generate(KeyGenOptions(keyType: "ed25519")),
              let key = try? SshKey(json: row(["id": .string(keyID), "name": "Smoke key", "key_type": "ED25519"])),
              await workspace.perform("save key", { try await workspace.save(key, KeySecrets(privateKey: pair.privateKey, publicKey: pair.publicKey)) }),
              let savedKey = workspace.keys.first(where: { $0.id == keyID })
        else { return check("ed25519 key generated by the core and saved", false, error()) }
        check("ed25519 key generated by the core, saved as upstream key_save stamps it (5 clocks), both halves in key:<id>:…",
              savedKey.clocks.keys.sorted() == Workspace.keyClocks.sorted() && Set(savedKey.clocks.values) == [savedKey.createdAt]
                  && pair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY")
                  && (try? core.secretGet(key: "key:\(keyID):private")) == pair.privateKey
                  && (try? core.secretGet(key: "key:\(keyID):public")) == pair.publicKey,
              "public key type \(pair.publicKey.split(separator: " ").first ?? "?")")

        await workspace.perform("clear public half") { try await workspace.save(savedKey, KeySecrets(publicKey: "")) }
        let cleared = (try? core.secretGet(key: "key:\(keyID):public")) == nil
        let derived = try? await workspace.keyOperations.publicKey(savedKey)
        check("public key derived from the stored private half by the core (ensurePublicKey) and stored again",
              cleared && derived?.split(separator: " ").prefix(2) == pair.publicKey.split(separator: " ").prefix(2)
                  && (try? core.secretGet(key: "key:\(keyID):public")) == derived, "")

        let identityID = newID()
        guard let identity = try? Identity(json: row(["id": .string(identityID), "name": "Smoke identity", "username": "deploy",
                                                      "key_id": .string(keyID), "tags": []])),
              await workspace.perform("save identity", { try await workspace.save(identity, IdentitySecrets(password: "smoke-identity-pw")) }),
              let savedIdentity = workspace.identities.first(where: { $0.id == identityID })
        else { return check("identity using the key saved", false, error()) }
        check("identity using the key saved as upstream identity_save stamps it (6 clocks), password in identity:<id>:password",
              savedIdentity.clocks.keys.sorted() == Workspace.identityClocks.sorted() && savedIdentity.keyID == keyID
                  && (try? core.secretGet(key: "identity:\(identityID):password")) == "smoke-identity-pw", "")

        // Connect arguments for a host behind a jump host and a SOCKS5 proxy, logging in with the identity.
        let jumpID = newID(), hostID = newID(), envID = newID()
        guard let jump = try? Connection(json: row(["id": .string(jumpID), "host": "jump.smoke.invalid", "port": 2222,
                                                     "username": "hop", "tags": []])),
              let host = try? Connection(json: row([
                  "id": .string(hostID), "host": "target.smoke.invalid", "port": 22, "username": "ignored", "tags": [],
                  "identity_id": .string(identityID), "jump_hosts": [["id": .string(newID()), "connection_id": .string(jumpID)]],
                  "proxy": ["mode": "socks5", "host": "proxy.smoke.invalid", "username": "proxyuser"], "keepalive_preset": "fast",
                  "env_vars": [["id": .string(envID), "key": "LANG", "value": "smoke-env-value"]], "pre_command": " echo hi ",
              ])),
              await workspace.perform("save hosts", {
                  try await workspace.save(jump, HostSecrets(password: "smoke-jump-pw"))
                  try await workspace.save(host, HostSecrets(proxyPassword: "smoke-proxy-pw"))
              }),
              let saved = workspace.connections.first(where: { $0.id == hostID }),
              let args = try? workspace.connectArgs(for: saved, login: workspace.login(for: saved))
        else { return check("connect arguments resolved for a host with a jump host and a proxy", false, error()) }
        let soltzKeys: Set = [
            "sessionId", "host", "port", "username", "password", "privateKey", "passphrase", "connectionId", "jumpHosts", "envVars",
            "agentForwarding", "legacyAlgorithms", "preCommand", "autoForward", "shellIntegration", "keepaliveIntervalSecs",
            "keepaliveMax", "persist", "detachedTtlSecs", "restore", "attachOnly", "cols", "rows", "initialCwd", "proxy", "knock",
            "terminalColors",
        ]
        let hop = args["jumpHosts"]?.array?.first, proxy = args["proxy"]
        func keys(_ value: JSONValue?) -> [String] { if case .object(let o)? = value { o.keys.sorted() } else { [] } }
        // The variable's value is in the vault, not in the host's row on disk; the row in memory has it.
        let onDisk = (try? String(contentsOf: dataDir.appending(path: "connections.json"), encoding: .utf8)) ?? "?"
        check("a host's environment variable value and its pre-command are kept in the vault, not in connections.json",
              !onDisk.contains("smoke-env-value") && onDisk.contains("LANG") && !onDisk.contains("echo hi")
                  && (try? core.secretGet(key: Workspace.envKey(hostID, envID))) == "smoke-env-value"
                  && (try? core.secretGet(key: "command:\(hostID):pre"))?.contains("echo hi") == true && saved.preCommand?.contains("echo hi") == true, "")
        check("connect arguments: upstream's 27 ssh_connect keys, soltz- session id, the identity's login (its key alone, never the password beside it), keepalive fast 2/2, persist, 24 h TTL",
              Set(args.keys) == soltzKeys && args["sessionId"]?.string?.hasPrefix("soltz-") == true
                  && args["username"] == "deploy" && args["privateKey"]?.string == pair.privateKey
                  && args["password"] == .null && args["passphrase"] == .null
                  && args["keepaliveIntervalSecs"] == 2 && args["keepaliveMax"] == 2 && args["persist"] == true
                  && args["shellIntegration"] == true && args["detachedTtlSecs"] == 86400 && args["attachOnly"] == .null
                  && args["envVars"] == [["LANG", "smoke-env-value"]] && args["preCommand"] == "echo hi" && args["knock"] == .null
                  && args["autoForward"] == false,
              "keys \(Set(args.keys).symmetricDifference(soltzKeys).sorted())")
        check("jump host resolved from its saved connection: {host, port, username, password} and its own legacyAlgorithms",
              keys(hop) == ["host", "legacyAlgorithms", "password", "port", "username"] && hop?["legacyAlgorithms"] == false
                  && hop?["host"] == "jump.smoke.invalid" && hop?["port"] == 2222
                  && hop?["username"] == "hop" && hop?["password"]?.string == "smoke-jump-pw", "\(keys(hop))")
        check("proxy resolved as upstream resolveProxy: socks5, default port 1080, username, proxy_password:<id>",
              keys(proxy) == ["host", "kind", "password", "port", "username"] && proxy?["kind"] == "socks5"
                  && proxy?["port"] == 1080 && proxy?["password"]?.string == "smoke-proxy-pw", "\(keys(proxy))")

        // A coded core error shows upstream's en text: connection refused by this machine's port 1 (no server involved).
        var refused = ConnectForm()
        (refused.host, refused.port, refused.username, refused.password) = ("127.0.0.1", 1, "smoke", "x")
        let probe = TerminalSession(title: "probe", font: workspace.font)
        do {
            try await workspace.connectSsh(probe, workspace.connectArgs(for: refused.target(), login: refused.login(key: nil)))
            check("refused connect shows upstream's connection-refused text", false, "it connected")
        } catch {
            check("refused connect shows upstream's connection-refused text", describe(error) == ErrorCode.connectionRefused.text, describe(error))
        }
        probe.close()

        await workspace.perform("delete key") { try await workspace.delete(savedKey) }
        check("deleted key is a tombstone; its secrets stay, as in upstream",
              !workspace.keys.contains { $0.id == keyID } && (try? core.secretGet(key: "key:\(keyID):private")) == pair.privateKey, error())
    }

    /// The Files page local ↔ local on two temp folders, copies through the app's queue, a conflict answered Skip then
    /// Replace, and a delete through the pane's provider into the Trash (that one item is removed again).
    private static func files(_ workspace: Workspace, _ check: (String, Bool, String) -> Void) async {
        print("[INFO] no SSH server is available to the smoke run: no remote (SFTP) file operation runs here")
        let fm = FileManager.default
        let root = dataDir.appending(path: "files").path(percentEncoded: false)
        let left = root + "/left", right = root + "/right"
        func put(_ path: String, _ data: Data) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(filePath: path))
        }
        func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        do {
            try put(left + "/hello.txt", Data("hello".utf8))
            try put(left + "/tree/sub/deep.txt", Data("deep".utf8))
            try put(left + "/tree/data.bin", Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
            try fm.createDirectory(atPath: right, withIntermediateDirectories: true)
        } catch {
            return check("Files: temp folders set up", false, "\(error)")
        }

        // A files pane on This Mac stands in for a host's (the app opens them on hosts only): a local session has
        // This Mac's files for its own.
        workspace.newLocalTerminal()
        defer { workspace.closeAll() }
        if let pane = workspace.activeSession {
            pane.filesPath = left
            pane.showsFiles = true
        }
        check("a files pane lists its folder's 2 items, in a tab like a terminal's",
              await wait { tables().contains { $0.numberOfRows == 2 } } && workspace.shown == Workspace.thisMac
                  && workspace.activeSession.map(workspace.label(of:)) == "left",
              tables().map { "\($0.numberOfRows) rows" }.joined(separator: ", "))

        // A sidebar row dropped on the files pane's list (an AppKit table, which takes dropped files for itself)
        // opens a new tab as it does over a terminal; the files tab is shown again for what follows.
        let filesPane = workspace.activeSession, tabCount = workspace.tabs.count
        let rowBoard = NSPasteboard.withUniqueName()
        rowBoard.clearContents()
        rowBoard.setData((try? JSONEncoder().encode(Dragged(kind: .host, id: Workspace.thisMac))) ?? Data(), forType: Dragged.pasteboardType)
        var onList = (taker: "no list", taken: false)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), let table = tables().first(where: { $0.numberOfRows == 2 }) {
            onList = StagedDrop.send(rowBoard, at: table.convert(CGPoint(x: table.bounds.midX, y: table.bounds.midY), to: nil), in: window)
        }
        let newTab = await wait(2) { workspace.tabs.count == tabCount + 1 }
        rowBoard.releaseGlobally()
        check("a sidebar row dropped on a files pane's list is taken by the pane and opens a new tab",
              onList.taken && newTab && workspace.activeSession !== filesPane, "taken by \(onList.taker): \(onList.taken)")
        if let filesPane { workspace.reveal(filesPane.id) }

        let queue = workspace.transfers, local = workspace.fileProvider(for: nil)
        guard let listed = try? await local.list(left), let file = listed.first(where: { $0.name == "hello.txt" }),
              let tree = listed.first(where: { $0.name == "tree" })
        else { return check("left folder listed by the pane's provider", false, "") }
        queue.enqueue([file, tree], from: local, to: local, into: right)
        let rows = { queue.transfers.filter { $0.label == "hello.txt" || $0.label == "tree" } }
        let copied = await wait { rows().count == 2 && rows().allSatisfy(\.settled) }
        check("a file and a folder tree copied through the app's queue: both rows done, contents equal",
              copied && rows().allSatisfy { $0.status == .done }
                  && fm.contentsEqual(atPath: left + "/hello.txt", andPath: right + "/hello.txt")
                  && fm.contentsEqual(atPath: left + "/tree", andPath: right + "/tree"),
              rows().map { "\($0.label) \($0.status)" }.joined(separator: ", "))

        try? Data("hello v2".utf8).write(to: URL(filePath: left + "/hello.txt"))
        queue.enqueue([file], from: local, to: local, into: right)
        check("copying onto an existing file asks first, the conflict sheet on screen",
              await wait { queue.conflicts.count == 1 && NSApp.windows.contains { $0.attachedSheet != nil } }, "")
        if let pending = queue.conflicts.first { queue.resolveConflict(pending.id, .skip) }
        check("Skip leaves the existing file alone and drops the row",
              await wait { queue.conflicts.isEmpty && rows().count == 2 } && text(right + "/hello.txt") == "hello",
              text(right + "/hello.txt") ?? "missing")

        queue.enqueue([file], from: local, to: local, into: right)
        _ = await wait { queue.conflicts.count == 1 }
        if let pending = queue.conflicts.first { queue.resolveConflict(pending.id, .overwrite) }
        check("Replace copies over it: row done, new content",
              await wait { queue.transfers.first?.status == .done } && text(right + "/hello.txt") == "hello v2",
              "\(queue.transfers.first.map { "\($0.status)" } ?? "no row")")

        let name = "soltz-smoke-trash-\(UUID().uuidString).txt"
        let doomed = left + "/" + name
        let trashed = fm.homeDirectoryForCurrentUser.appending(path: ".Trash/\(name)").path(percentEncoded: false)
        try? Data("trash me".utf8).write(to: URL(filePath: doomed))
        let deleted: Bool
        do {
            try await local.delete(doomed) // what the pane's Move to Trash runs
            deleted = true
        } catch {
            deleted = false
        }
        let inTrash = text(trashed) == "trash me"
        try? fm.removeItem(atPath: trashed)
        check("Move to Trash through the pane's provider: gone from its folder, in the Trash; that Trash item removed",
              deleted && !fm.fileExists(atPath: doomed) && inTrash && !fm.fileExists(atPath: trashed), trashed)
    }

    /// A user's click on the window during a test run, as one dismissed an e2e alert mid-check: a click on the alert's
    /// button, through the app's event queue, is dropped and the alert stays.
    private static func strayClick(_ workspace: Workspace, _ check: (String, Bool, String) -> Void) async {
        workspace.failure = Failure(title: "Smoke", message: "stray click")
        defer { workspace.failure = nil }
        func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        guard await wait(until: { NSApp.windows.contains { $0.attachedSheet != nil } }),
              let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first,
              let button = sheet.contentView.flatMap({ buttons($0).first })
        else { return check("a stray click on an alert during a test run is dropped", false, "no alert on screen") }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                .map { NSApp.postEvent($0, atStart: false) }
        }
        // A click is handled within a frame or two; half a second without the alert going is the answer.
        let dismissed = await wait(0.5) { workspace.failure == nil || sheet.sheetParent == nil }
        check("a stray click on an alert's button during a test run is dropped: the alert and its error stay",
              !dismissed, "button “\(button.title)”")
    }

    /// Every table in the app's windows (the panes are SwiftUI `Table`s).
    private static func tables() -> [NSTableView] {
        func walk(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
        return NSApp.windows.compactMap(\.contentView).flatMap(walk)
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

/// A drop without a drag: a real drag follows the user's pointer, so a test run cannot make one.
@MainActor
private final class StagedDrop: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(_ pasteboard: NSPasteboard, at point: NSPoint, in window: NSWindow) {
        (draggingPasteboard, draggingLocation, draggingDestinationWindow) = (pasteboard, point, window)
    }

    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination _: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions, for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
                                using _: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    /// Sends the drop where AppKit would: to the view under `point`, or the nearest one above it, that takes one of
    /// the pasteboard's types. Returns that view's class and whether it took the drop.
    static func send(_ pasteboard: NSPasteboard, at point: NSPoint, in window: NSWindow) -> (taker: String, taken: Bool) {
        let types = Set(pasteboard.types ?? [])
        var view = window.contentView?.superview?.hitTest(point)
        while let candidate = view, types.isDisjoint(with: candidate.registeredDraggedTypes) { view = candidate.superview }
        guard let view else { return ("no view", false) }
        let info = StagedDrop(pasteboard, at: point, in: window)
        guard !view.draggingEntered(info).isEmpty else { return ("\(type(of: view))", false) }
        _ = view.draggingUpdated(info)
        let taken = view.prepareForDragOperation(info) && view.performDragOperation(info)
        view.concludeDragOperation(info)
        return ("\(type(of: view))", taken)
    }
}
#endif
