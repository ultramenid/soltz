// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Network
import Observation
import os
import SoltzCore
import SoltzFilesUI
import SoltzModel
import SoltzWorkspace
import SwiftUI
import UniformTypeIdentifiers

/// What is dragged inside the window: a sidebar host or session, or a tab. A type of its own, never text: a terminal
/// takes dropped text as a paste, and would type the id into its shell.
struct Dragged: Codable, Transferable {
    /// A host or a session from the sidebar, a tab from the strip, a pane by its header (its session's id).
    enum Kind: String, Codable { case host, session, tab, pane }

    let kind: Kind
    let id: String

    static let pasteboardType = NSPasteboard.PasteboardType("app.soltz.drag")
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType.rawValue))
    }
}

/// Where a new session goes: its own tab, or a new pane on one side of the active one.
enum Placement: Equatable {
    case tab, beside(SplitPosition)
    static let right = beside(.right), below = beside(.bottom)
}

/// The main window's state: open sessions, their tabs and panes, and the saved hosts (Storage.swift).
///
/// Every session lives in a `LayoutStore` split tab, one leaf or more; a tab's strip key is `split:<id>`.
/// The tabs of every host share the one strip under the panes; a tab is on its sessions' saved host, or on This Mac
/// (`thisMac`). A session shows its terminal, or its host's files (`TerminalSession.showsFiles`).
@MainActor @Observable
final class Workspace {
    static let thisMac = "this-mac"
    /// `dropTarget` over a pane of the main panel (its session follows), and over the end of the tab strip.
    static let panel = "panel:", stripEnd = "strip-end"
    let core: Core
    let layout = LayoutStore()
    private(set) var sessions: [String: TerminalSession] = [:]
    /// Sessions floated out of their tabs: each is in a small card over the main panel, whatever tab is on screen,
    /// and goes on running.
    private(set) var floating: [String] = []
    /// The floating ones minimized: each is a capsule in the corner until it is clicked.
    private(set) var minimized: Set<String> = []
    /// The host of the tab on screen, a saved host's id or `thisMac`; nil shows none.
    private(set) var shown: String?
    /// Each host's tab shown last, to come back to from another host's.
    @ObservationIgnored private var lastTab: [String: String] = [:]
    var showingSettings = false
    /// What a dragged host, session or tab is over: a sidebar group's id ("" for no group), a tab's key, or the
    /// pane (`panel`, then the pane's session).
    var dropTarget: String?
    /// Over a pane: the side of it the new pane would take; none is the whole of it, to change places with.
    var dropSide: SplitPosition?
    /// The size the panes of a tab share on screen, for `place` to tell whether one more has room; zero until laid out.
    @ObservationIgnored var paneArea = CGSize.zero
    /// What the app's own drags did, for when one does nothing: kinds and outcomes, no names
    /// (`log show --predicate 'subsystem == "app.soltz"'`).
    static let drags = Logger(subsystem: "app.soltz", category: "drag")
    var newHost: NewHostForm?
    /// The group being named in its card.
    var naming: GroupNaming?
    /// The saved host open in the full editor.
    var editing: Connection?
    /// A saved host's login prompt (it had none stored).
    var connectForm: ConnectForm?
    var failure: Failure?
    let updates = Updates()
    /// What "Check for Updates…" found.
    var updateNotice: UpdateNotice?
    /// A master-password vault waiting for its password; the unlock sheet shows meanwhile.
    var vaultLocked = false
    var font = TerminalFont() {
        didSet { if font != oldValue { sessions.values.forEach { $0.setFont(font) } } }
    }
    private(set) var connections: [Connection] = []
    private(set) var folders: [Folder] = []
    private(set) var identities: [Identity] = []
    private(set) var keys: [SshKey] = []
    /// Every copy between panes, app-wide, as upstream's `transferQueueStore`.
    let transfers = TransferQueue()
    let localFiles = LocalFileProvider()
    /// SSH sessions' files by `TerminalSession.id`, opened when first shown and closed with their session.
    @ObservationIgnored var fileProviders: [String: SftpFileProvider] = [:]
    @ObservationIgnored private var keyMonitor: Any?
    /// Whether the system has a usable network path; nil until it first says (Reconnect.swift).
    @ObservationIgnored var networkUp: Bool?
    @ObservationIgnored var pathMonitor: NWPathMonitor?
    @ObservationIgnored var lastWakeAll: ContinuousClock.Instant?

    /// A core keeping hosts, known hosts and the vault in `dataDir`, the vault's key in `keychain`.
    /// Without `dataDir` it runs sessions only and every storage call fails (tests).
    init(dataDir: URL? = nil, keychain: Keychain = .memory) {
        do {
            core = try dataDir.map { try Core.withDataDir(dataDir: $0.path(percentEncoded: false), keychain: keychain) } ?? Core()
        } catch {
            core = Core()
            failure = Failure(title: "Couldn’t Open Soltz’s Data", message: describe(error))
        }
    }

    static func key(_ tabId: String) -> String { "split:\(tabId)" }

    var activeSession: TerminalSession? {
        layout.root?.findLeaf(layout.activePaneId).flatMap { sessions[$0.sessionId] }
    }

    /// The active session while a tab is on screen.
    var shownSession: TerminalSession? { shown != nil ? activeSession : nil }

    // MARK: - Hosts

    /// The host a session is on: its saved host's id, else This Mac.
    func key(ofSession id: String) -> String { sessions[id]?.hostID ?? Self.thisMac }

    /// The host `tab` is on: its sessions' saved host, else This Mac.
    func key(of tab: SplitTab) -> String {
        tab.root.sessionIds.lazy.compactMap { self.sessions[$0]?.hostID }.first ?? Self.thisMac
    }

    /// A host's tabs, in strip order.
    /// A tab is every host's that has a pane in it.
    func tabs(of key: String) -> [SplitTab] { tabs.filter { $0.root.sessionIds.contains { self.key(ofSession: $0) == key } } }

    /// A host's sessions, in tab then pane order, then the floating ones: what the sidebar lists under it.
    func sessions(of key: String) -> [TerminalSession] {
        (tabs.flatMap(\.root.sessionIds) + floating).compactMap { sessions[$0] }.filter { self.key(ofSession: $0.id) == key }
    }

    /// Shows a host's tab, the one it showed last; nil, or a host without tabs, shows none. Sessions keep running
    /// either way.
    func show(_ key: String?) {
        let mine = key.map(tabs(of:)) ?? []
        guard let key, let tab = mine.first(where: { $0.id == lastTab[key] }) ?? mine.first else {
            shown = nil
            return
        }
        layout.activateSplitTab(tab.id)
        follow()
        focusActive()
    }

    /// The tab now on screen says which host is shown, and is the one that host comes back to; with no tab, none is.
    private func follow() {
        let tab = layout.splitTabs.first { $0.id == layout.activeSplitTabId }
        shown = tab.map(key(of:))
        if let tab, let shown { lastTab[shown] = tab.id }
    }

    /// Shows a session picked in the sidebar: its tab and its pane. A floating one comes back among the panes, a
    /// minimized one to its card.
    func reveal(_ sessionId: String) {
        if minimized.contains(sessionId) { return setMinimized(sessionId, false) }
        if floating.contains(sessionId) { return restore(sessionId) }
        guard let tab = layout.splitTabs.first(where: { $0.root.sessionIds.contains(sessionId) }),
              let leaf = tab.root.findLeaf(session: sessionId) else { return }
        layout.activateSplitTab(tab.id)
        layout.setActivePane(leaf.id)
        if let maximized = layout.maximizedPaneId, maximized != leaf.id { layout.setMaximized(nil) } // it would be behind it
        follow()
        focusActive()
    }

    /// Dropped on the tabs, or on the panel while it is empty. A sidebar row is new work on that host, in a new tab;
    /// a pane, open already, becomes a tab of its own.
    @discardableResult
    func openTab(for drag: Dragged) -> Bool {
        guard drag.kind == .pane else { return start(drag, .tab) }
        guard lift(drag.id) else { return false }
        place(drag.id, .tab)
        focusActive()
        return true
    }

    /// Whether a drop on the pane showing `sessionId` does anything: not the tab on screen's, which is there already,
    /// nor a pane's on itself.
    func lands(_ drag: Dragged, on sessionId: String) -> Bool {
        switch drag.kind {
        case .host, .session: true
        case .tab: drag.id != layout.activeSplitTabId && layout.splitTabs.contains { $0.id == drag.id }
        case .pane: drag.id != sessionId && (floating.contains(drag.id) || layout.splitTabs.contains { $0.root.sessionIds.contains(drag.id) })
        }
    }

    /// Dropped on a pane, on the side of it the drop was nearest. A sidebar row is the same new work as on the tabs,
    /// in a new pane there. What is open already moves there: a pane dragged by its header, and a tab from the
    /// strip, whose panes move in, each beside the last, as it leaves the strip. So a tab can have panes of several
    /// hosts.
    @discardableResult
    func openPane(for drag: Dragged, beside sessionId: String, _ side: SplitPosition) -> Bool {
        guard layout.root?.findLeaf(session: sessionId) != nil, lands(drag, on: sessionId) else { return false }
        let moving: [String]
        switch drag.kind {
        case .host, .session:
            activatePane(of: sessionId)
            return start(drag, .beside(side))
        case .pane:
            guard lift(drag.id) else { return false }
            moving = [drag.id]
        case .tab:
            moving = layout.splitTabs.first { $0.id == drag.id }?.root.sessionIds ?? []
            layout.closeSplitTab(drag.id)
        }
        activatePane(of: sessionId)
        for id in moving { place(id, .beside(side)) }
        focusActive()
        return true
    }

    /// A pane dropped on the middle of another: the two change places. A floating one takes the pane's place, and
    /// that pane floats in its stead.
    @discardableResult
    func swap(_ drag: Dragged, with sessionId: String) -> Bool {
        guard drag.kind == .pane, lands(drag, on: sessionId), let target = layout.root?.findLeaf(session: sessionId),
              layout.swapSession(in: target.id, with: drag.id) != nil else { return false }
        if let index = floating.firstIndex(of: drag.id) { floating[index] = sessionId }
        focusActive()
        return true
    }

    /// A session's drop opens another like it (the same host and directory, terminal or files); a host's is its Open.
    private func start(_ drag: Dragged, _ placement: Placement) -> Bool {
        switch drag.kind {
        case .session:
            guard let session = sessions[drag.id] else { return false }
            duplicate(session, placement)
        case .host:
            if drag.id == Self.thisMac { newLocalTerminal(placement) }
            else if let host = connections.first(where: { $0.id == drag.id }) { connect(to: host, placement) }
            else if let left = sessions(of: drag.id).first { duplicate(left, placement) } // its host was deleted since
            else { return false }
        case .tab, .pane: return false
        }
        return true
    }

    /// After a tab closed: the tab now on screen is followed, unless none was shown.
    private func settle() {
        if shown != nil { follow() }
    }

    // MARK: - Tabs

    /// Strip order: pinned tabs first, then the user's order (`titlebarOrder`).
    var tabs: [SplitTab] {
        let keys = layout.splitTabs.map { Self.key($0.id) }
        let ordered = mergeTitlebarItems(layout.titlebarOrder, keys).compactMap { key in
            layout.splitTabs.first { Self.key($0.id) == key }
        }
        return ordered.filter(isPinned) + ordered.filter { !isPinned($0) }
    }

    func isPinned(_ tab: SplitTab) -> Bool { layout.pinnedKeys.contains(Self.key(tab.id)) }

    func title(of tab: SplitTab) -> String {
        tab.name ?? tab.root.findLeaf(tab.activePaneId).flatMap { sessions[$0.sessionId] }.map(label(of:)) ?? "Terminal"
    }

    /// What a session is called in the sidebar and on its tab: a terminal's title, a files pane's folder.
    func label(of session: TerminalSession) -> String {
        guard session.showsFiles else { return session.title }
        return session.filesPath.isEmpty ? "Files" : session.filesPath.split(separator: "/").last.map(String.init) ?? "/"
    }

    func hasEnded(_ tab: SplitTab) -> Bool {
        tab.root.sessionIds.allSatisfy { sessions[$0]?.ended ?? true }
    }

    func activate(_ tabId: String) {
        layout.activateSplitTab(tabId)
        follow()
        focusActive()
    }

    /// The next or previous tab of the strip.
    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == layout.activeSplitTabId } ?? 0
        activate(tabs[((index + offset) % tabs.count + tabs.count) % tabs.count].id)
    }

    func togglePin(_ tabId: String) {
        let key = Self.key(tabId)
        layout.setPinned(key, !layout.pinnedKeys.contains(key))
    }

    /// A drag dropped on the tab strip, on the tab `tabId` or at its end: a tab moves there (before that tab, or
    /// last), a sidebar row opens its tab.
    func dropped(_ drag: Dragged, before tabId: String?) -> Bool {
        guard drag.kind == .tab else { return openTab(for: drag) }
        guard layout.splitTabs.contains(where: { $0.id == drag.id }) else { return false }
        layout.syncTitlebarOrder(tabs.map { Self.key($0.id) }) // every tab has its place in the order before one moves
        layout.reorderTitlebarItem([Self.key(drag.id)], tabId.map(Self.key), .before)
        return true
    }

    /// `ending` false leaves its sessions open: they are on their way somewhere else (`lift`).
    func closeTab(_ tabId: String, ending: Bool = true) {
        guard let tab = layout.splitTabs.first(where: { $0.id == tabId }) else { return }
        // The tab beside it in the strip takes its place on screen: the next one, else the one before.
        let strip = tabs
        let beside = layout.activeSplitTabId != tabId ? nil : strip.firstIndex { $0.id == tabId }.flatMap { index in
            (strip.dropFirst(index + 1).first ?? strip.prefix(index).last)?.id
        }
        layout.closeSplitTab(tabId)
        if ending { tab.root.sessionIds.forEach(end) }
        if let beside { layout.activateSplitTab(beside) }
        settle()
        if beside != nil { focusActive() }
    }

    func closeAll() {
        layout.splitTabs.map(\.id).forEach { closeTab($0) }
        floating.forEach(close)
    }

    // MARK: - Panes

    func closePane() {
        if let id = layout.root?.findLeaf(layout.activePaneId)?.sessionId { close(id) }
    }

    /// Takes the active pane out of its tab, which has others, and returns its session, still open.
    @discardableResult
    private func detachActivePane() -> String? {
        guard let tabId = layout.activeSplitTabId, let root = layout.root, let pane = layout.activePaneId,
              let detached = layout.detachPane(pane) else { return nil }
        // LayoutStore turns a split left with one pane into a bare `session:` tab. Soltz keeps every
        // session in a split tab, so the survivor gets a new one in the same strip slot, with the pin.
        guard !layout.splitTabs.contains(where: { $0.id == tabId }),
              let survivor = root.sessionIds.first(where: { $0 != detached }) else { return detached }
        let bare = "session:\(survivor)"
        let pinned = layout.pinnedKeys.contains(bare)
        layout.openSessions([survivor])
        guard let newId = layout.activeSplitTabId else { return detached }
        layout.titlebarOrder = layout.titlebarOrder.map { $0 == bare ? Self.key(newId) : $0 }
        layout.setPinned(Self.key(newId), pinned)
        return detached
    }

    /// Closes the pane showing `sessionId`, floating or in whichever tab; the tab and the pane shown before stay shown.
    func close(_ sessionId: String) {
        guard lift(sessionId) else { return }
        end(sessionId)
        focusActive()
    }

    /// Takes `sessionId` out of where it shows, still open: from the floating ones, or out of its tab, which closes
    /// if it was alone in it. The tab shown before stays shown, and the pane that had the keys keeps them.
    private func lift(_ sessionId: String) -> Bool {
        if let index = floating.firstIndex(of: sessionId) {
            floating.remove(at: index)
            minimized.remove(sessionId)
            return true
        }
        guard let tab = layout.splitTabs.first(where: { $0.root.sessionIds.contains(sessionId) }),
              let leaf = tab.root.findLeaf(session: sessionId) else { return false }
        guard tab.root.leaves.count > 1 else {
            closeTab(tab.id, ending: false)
            return true
        }
        let before = layout.activeSplitTabId, active = layout.activePaneId
        layout.activateSplitTab(tab.id)
        layout.setActivePane(leaf.id)
        detachActivePane()
        if let before, before != tab.id, layout.splitTabs.contains(where: { $0.id == before }) { layout.activateSplitTab(before) }
        if let active, active != leaf.id, layout.root?.findLeaf(active) != nil { layout.setActivePane(active) }
        settle()
        return true
    }

    /// Floats a pane: out of its tab, into a small card over the main panel.
    func float(_ sessionId: String) {
        guard !floating.contains(sessionId), lift(sessionId) else { return }
        floating.append(sessionId)
        focusActive()
    }

    /// A floating pane's card shrinks to a capsule in the corner, or comes back from it.
    func setMinimized(_ sessionId: String, _ on: Bool) {
        if on, floating.contains(sessionId) { minimized.insert(sessionId) } else { minimized.remove(sessionId) }
        if on { focusActive() } else { sessions[sessionId]?.terminal.focus() }
    }

    /// A floating pane back among the panes: beside the active one of the tab on screen, or in a tab of its own.
    func restore(_ sessionId: String) {
        guard floating.contains(sessionId), lift(sessionId) else { return }
        place(sessionId, shown == nil ? .tab : .right)
        focusActive()
    }

    func toggleMaximize() {
        layout.setMaximized(layout.maximizedPaneId == nil ? layout.activePaneId : nil)
    }

    /// A click in a pane makes it active; the click itself focuses its terminal.
    func activatePane(of sessionId: String) {
        guard let leaf = layout.root?.findLeaf(session: sessionId), leaf.id != layout.activePaneId else { return }
        layout.setActivePane(leaf.id)
    }

    func focusActive() {
        activeSession?.terminal.focus()
    }

    // MARK: - Sessions

    func newLocalTerminal(_ placement: Placement = .tab) {
        let session = TerminalSession(title: "Local", font: font)
        add(session, placement)
        Task {
            do {
                session.attach(try await core.openLocalShell(sink: session.sink, cols: 80, rows: 24))
            } catch {
                session.end()
                failure = Failure(title: "Couldn’t Open a Terminal", message: describe(error))
            }
        }
    }

    /// Shows an opened (or opening) session and routes its keystrokes.
    func add(_ session: TerminalSession, _ placement: Placement = .tab) {
        sessions[session.id] = session
        session.onClosed = { [weak self, weak session] cleanExit in
            if let self, let session { sessionClosed(session, cleanExit: cleanExit) }
        }
        Task { [weak self] in
            for await data in session.input { self?.route(data, from: session.id) }
        }
        place(session.id, placement)
        focusActive()
    }

    /// A pane that would leave any pane of the tab under the least size (`Theme.paneLeast`) opens in a tab of its
    /// own instead.
    func place(_ sessionId: String, _ placement: Placement) {
        if case .beside(let side) = placement, let pane = layout.activePaneId, let root = layout.root,
           hasRoom(root.splitting(pane, with: LeafNode(id: "", sessionId: sessionId), side)) {
            layout.splitPane(pane, sessionId, side)
        } else {
            layout.openSessions([sessionId])
            layout.syncTitlebarOrder(layout.splitTabs.map { Self.key($0.id) })
        }
        follow()
    }

    private func hasRoom(_ panes: PaneNode) -> Bool {
        paneArea == .zero || PaneLayout(panes, in: CGRect(origin: .zero, size: paneArea)).panes.allSatisfy {
            $0.frame.width >= Theme.paneLeast.width && $0.frame.height >= Theme.paneLeast.height
        }
    }

    /// Keystrokes from one terminal, to its own session.
    func route(_ data: Data, from sessionId: String) { sessions[sessionId]?.send(data) }

    /// Closing a pane or tab: as upstream `closeSession` (src/services/closeSession.ts:14), a live SSH session gets its
    /// host's post-command and is disconnected, its tmux session killed; a connect in flight is cancelled.
    private func end(_ sessionId: String) {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        fileProviders.removeValue(forKey: sessionId)?.close() // upstream panelSftpStore `closeSession`
        session.answer(.abort, via: core) // a connect still asking about its host key gives up
        let live = session.isAttached && !session.ended && !session.showsFiles // a files pane ran no pre-command either
        session.close(postCommand: connections.first { live && $0.id == session.hostID }.flatMap { inlineCommand($0, post: true) })
    }

    // MARK: - Hosts

    /// Re-reads every list from the core: at launch, after unlocking and after each change.
    func reload() async {
        do {
            connections = await withEnv(try await list(.connections))
            folders = try await list(.folders)
            identities = try await list(.identities)
            keys = try await list(.sshKeys)
        } catch {
            failure = Failure(title: "Couldn’t Load Saved Hosts", message: describe(error))
        }
    }

    /// The live rows of `kind`.
    func list<Fields: LosslessFields>(_ kind: EntityKind) async throws -> [Lossless<Fields>] {
        try JSONDecoder().decode([Lossless<Fields>].self, from: Data(try await core.entityList(kind: kind).utf8))
    }

    // MARK: - Keys

    // shortcut: Ghostty's built-in keybinds (⌘T, ⌘W, ⌘D, ⌘K, ⌃Tab, ⇧⌘P…) take those chords while a terminal has focus,
    // so the menu bar gets first pick of every ⌘/⌃ chord here. Drop once SoltzTerminal clears Ghostty's keybinds.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true } ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        !event.modifierFlags.isDisjoint(with: [.command, .control]) && NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }
}

/// What the main window's alert says went wrong.
struct Failure {
    let title: String
    let message: String
}

/// What the Quick Connect sheet asks for.
struct ConnectForm: Identifiable {
    let id = UUID()
    /// The saved host it was opened for (it had no stored login), whose options the connect uses.
    var connection: Connection?
    /// The tab opens on the host's files, not its terminal.
    var files = false
    /// Save what was typed to `connection` (upstream "Connect & Save").
    var save = false
    var host = ""
    var port = 22
    var username = ""
    var useKey = false
    var password = ""
    var keyFile: URL?
    var passphrase = ""

    init() {}

    init(_ connection: Connection) {
        self.connection = connection
        host = connection.host
        port = connection.port == 0 ? 22 : Int(connection.port)
        username = connection.username
        useKey = connection.authType == .key
    }

    /// The host to connect: the saved one with the address typed over it, or a new unsaved one, as upstream's
    /// ephemeral quick-connect host.
    func target() throws -> Connection {
        var target = try connection ?? Connection(json: ["id": .string(UUID().uuidString.lowercased()), "tags": [],
                                                         "created_at": "", "updated_at": "", "clocks": [:]])
        target.host = host.trimmingCharacters(in: .whitespaces)
        target.port = UInt16(clamping: port)
        target.username = username
        return target
    }

    /// What was typed, in place of the host's stored login.
    func login(key: String?) -> Login {
        Login(username: username, password: useKey || password.isEmpty ? nil : password, privateKey: useKey ? key : nil,
              passphrase: useKey && !passphrase.isEmpty ? passphrase : nil)
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && (1...65535).contains(port)
            && (useKey ? keyFile != nil : true) && NewHostForm.isPlain(host) && NewHostForm.isPlain(username)
    }
}
