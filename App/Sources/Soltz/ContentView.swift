// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzFilesUI
import SoltzHostsUI
import SoltzModel
import SoltzTerminal
import SoltzWorkspace
import SwiftUI

/// The main window: the sidebar's hosts card and, beside it, the workspace of the host picked there, over the blurred
/// desktop. Every host's sessions keep running whichever is shown.
struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceSetting.system
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = ""
    @AppStorage(SettingsKey.fontSize) private var fontSize = Theme.terminalSize
    @AppStorage(SettingsKey.lineHeight) private var lineHeight = Theme.terminalLineHeight

    var body: some View {
        @Bindable var workspace = workspace
        HStack(spacing: 0) {
            // In line with the pane cards beside it: their top, and the window's margin on the other edges.
            HomeView()
                .padding(.leading, Theme.paneMargin).padding(.top, Theme.paneGap / 2).padding(.bottom, Theme.paneMargin)
            Group {
                if let key = workspace.shown {
                    WorkspaceView(key: key).transition(Theme.arrival)
                } else {
                    // It steps back while a popup's card is up: it showed through the card's edge.
                    Text("Double-click a host to connect, or drag it here").font(Theme.body).foregroundStyle(.secondary)
                        .opacity(SheetCards.shared.frame == nil ? 1 : 0).transition(.opacity)
                        .animation(Theme.motion, value: SheetCards.shared.frame == nil)
                        // A host dragged here from the sidebar opens its tab.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                        .dropDestination(for: Dragged.self) { drags, _ in drags.first.map(workspace.openTab(for:)) ?? false }
                        // An empty item keeps the bar at a workspace's height: the sidebar stays put when one opens.
                        .toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }.sharedBackgroundVisibility(.hidden) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.motion, value: workspace.shown)
            .overlay(alignment: .bottomTrailing) { FloatingPanes() }
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background { WindowBackdrop().ignoresSafeArea() }
        // One appearance for the whole app, from Settings: set per page or per window, the sidebar, the terminals, the file
        // panes and the popups over them fell out of step with each other.
        .onChange(of: appearance, initial: true) { NSApp.appearance = $1.appearance }
        .sheet(item: $workspace.newHost) { NewHostView(form: $0) }
        .sheet(item: $workspace.connectForm) { QuickConnectView(form: $0).glassSheet() }
        .sheet(item: $workspace.editing) { EditHostSheet(host: $0) }
        .sheet(item: $workspace.naming) { GroupSheet(form: $0) }
        .sheet(isPresented: $workspace.showingSettings) { SettingsSheet() }
        .sheet(isPresented: $workspace.vaultLocked) { UnlockVaultView().glassSheet() }
        .alert(workspace.failure?.title ?? "", isPresented: Binding(
            get: { workspace.failure != nil }, set: { if !$0 { workspace.failure = nil } }
        )) {} message: {
            Text(workspace.failure?.message ?? "")
        }
        .alert(workspace.updateNotice?.title ?? "", isPresented: Binding(
            get: { workspace.updateNotice != nil }, set: { if !$0 { workspace.updateNotice = nil } }
        ), presenting: workspace.updateNotice) { notice in
            if let release = notice.release {
                Button("Download") { workspace.updates.open(release) }
                Button("Later", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
        .background { HostKeyQuestion() }
        // One conflict question for the window, whichever files pane a copy came from.
        .transferConflicts(workspace.transfers)
        .overlay { SheetCard() }
        .focusedSceneValue(\.workspace, workspace)
        .onChange(of: TerminalFont(family: fontFamily, size: fontSize, lineHeight: lineHeight), initial: true) {
            workspace.font = $1
        }
        .task {
            AppDelegate.openAtOwnSize()
            workspace.installKeyMonitor()
            workspace.startNetworkWatch()
            await workspace.openVault()
            await workspace.reload()
            await workspace.updates.checkDaily()
            if Smoke.requested { await Smoke.run(workspace) }
            if E2E.requested { await E2E.run(workspace) }
            if Snapshot.requested { await Snapshot.run(workspace) }
        }
    }
}

/// The window's backdrop: AppKit's Liquid Glass (`NSGlassEffectView`, regular style) filling a
/// non-opaque window, so what is behind shows through, blurred. (`containerBackground(_:for: .window)` with a material
/// left the window opaque, and a behind-window `NSVisualEffectView` read as a flat fill.)
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSGlassEffectView { Backdrop() }

    func updateNSView(_: NSGlassEffectView, context _: Context) {}

    final class Backdrop: NSGlassEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
}

/// The window's one host-key question, for whichever session meets a changed key. A view of its own so that only a
/// conflict redraws it: an alert redrawn along with the window or a pane (whose title changes with every prompt)
/// dismissed the alert on screen, and this one then answered Cancel by itself.
private struct HostKeyQuestion: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let session = workspace.sessions.values.filter { $0.conflict != nil }.min { $0.id < $1.id }
        Color.clear.hostKeyAlert(session, host: session?.args?["host"]?.string ?? "", core: workspace.core)
    }
}

/// Edit host as a card: New host's rows for a saved host, its stored key named where a new host shows the file chosen.
private struct EditHostSheet: View {
    let host: Connection
    @Environment(Workspace.self) private var workspace
    @ViewState private var storedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit host").font(Theme.title).padding(.horizontal, Theme.sheetInset).padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            HostEditor(connection: host, connections: workspace.connections, folders: workspace.folders,
                       identities: workspace.identities, keys: workspace.keys, compactWidth: Theme.sheetWidth,
                       storedKey: storedKey, motion: Theme.motion, actions: { problem, save in
                AnyView(SheetActions(problem: problem, action: "Save", disabled: problem != nil,
                                     cancel: { workspace.editing = nil }, run: save))
            }) { host, secrets in
                workspace.change("Couldn’t Save the Host") { try await workspace.save(host, secrets) }
            }
        }
        .glassSheet()
        .task { storedKey = await workspace.keySummary(of: host) }
    }
}

/// Settings as a card: its title in the card, as on Home, and Done.
private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(Theme.title).padding(.horizontal, Theme.sheetInset).padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            SettingsView()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(Pill(prominent: true, height: Theme.buttonHeight, font: Theme.body.weight(.semibold)))
            }
            .padding(.horizontal, Theme.sheetInset - 6)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
        .glassSheet()
    }
}

// MARK: - Tabs

/// The tab on screen: its panes as cards, the transfers of a files tab, and the strip of every host's tabs below. The
/// host's name is in the top bar (the window toolbar, whose items are Liquid Glass by themselves).
private struct WorkspaceView: View {
    let key: String
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let showsFiles = workspace.layout.root?.sessionIds.contains { workspace.sessions[$0]?.showsFiles == true } == true
        VStack(spacing: 0) {
            PaneTreeView(store: workspace.layout, motion: Theme.motion) { sessionId in
                if let session = workspace.sessions[sessionId] { PaneCard(session: session).transition(Theme.arrival) }
            }
            // Panes glide to their places when one is split off, closed, maximized or its tab changes; dragging a
            // divider is not animated, it follows the pointer.
            .animation(Theme.motion, value: workspace.layout.root?.sessionIds)
            .animation(Theme.motion, value: workspace.layout.maximizedPaneId)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.paneArea = $0 }
            .padding(.horizontal, Theme.paneMargin - Theme.paneGap / 2)
            // Copies to and from the hosts, under the files they are about. (Nothing while there are none.)
            if showsFiles {
                TransferQueueView(queue: workspace.transfers)
                    .padding(.horizontal, Theme.paneMargin).padding(.top, Theme.paneGap / 2).transition(.opacity)
            }
            BottomBar()
        }
        .animation(Theme.motion, value: showsFiles)
        .environment(\.filesStyle, .soltz)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(workspace.name(of: key)).font(Theme.chromeStrong).lineLimit(1).padding(.horizontal, 4)
                    .contentTransition(.opacity)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// The floating panes: each a small card over the corner of the main panel, above the tabs, whatever tab is on
/// screen, its session live in it. It goes back among the panes from its button, or dragged there by its header;
/// minimized, it is a capsule in the same corner, and a click brings its card back.
private struct FloatingPanes: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.paneGap) {
            ForEach(workspace.floating.compactMap { workspace.sessions[$0] }, id: \.id) { session in
                if workspace.minimized.contains(session.id) {
                    Button { workspace.setMinimized(session.id, false) } label: {
                        Label(workspace.label(of: session), systemImage: session.showsFiles ? TerminalSession.filesSymbol : "terminal")
                            .lineLimit(1).frame(maxWidth: Theme.floatingCapsule).fixedSize() // as wide as its name, to a point
                    }
                    .buttonStyle(Pill(font: Theme.chrome))
                    .help("Show \(workspace.label(of: session))")
                    .transition(Theme.arrival)
                } else {
                    PaneCard(session: session, floating: true)
                        .frame(width: Theme.floatingPane.width, height: Theme.floatingPane.height)
                        // Lifted off the panes under it, which are the same glass: the one shadow in the app, in the
                        // scrim's colour.
                        .background {
                            RoundedRectangle(cornerRadius: Theme.paneRadius, style: .continuous)
                                .fill(Color(nsColor: .shadowColor).opacity(Theme.scrim)).blur(radius: 16).offset(y: 6)
                        }
                        .transition(Theme.arrival)
                }
            }
        }
        .padding(.trailing, Theme.paneMargin + Theme.paneGap).padding(.bottom, Theme.bottomBar + Theme.paneGap)
        .animation(Theme.motion, value: workspace.floating)
        .animation(Theme.motion, value: workspace.minimized)
        .environment(\.filesStyle, .soltz)
    }
}

/// One pane: a session's terminal in a card with a header (title, directory, split, maximize, float, close), or its
/// host's files (`FilesPane`, a card of its own), and the connecting or ended state over either. `floating`, it is a
/// floating one's card (`FloatingPanes`): no part of a split.
private struct PaneCard: View {
    let session: TerminalSession
    var floating = false
    @Environment(Workspace.self) private var workspace
    /// Narrower than `Theme.paneNarrow` (the window was made small, or a divider dragged): the header sheds buttons.
    @ViewState private var narrow = false

    var body: some View {
        let layout = workspace.layout
        let isActive = floating || layout.root?.findLeaf(layout.activePaneId)?.sessionId == session.id
        let isSplit = !floating && (layout.root?.leaves.count ?? 0) > 1
        let shape = RoundedRectangle(cornerRadius: Theme.paneRadius, style: .continuous)
        let over = workspace.dropTarget == Workspace.panel + session.id, side = over ? workspace.dropSide : nil
        Group {
            if session.showsFiles {
                // In a hosting view of its own, as the terminal is, so that a click anywhere in it makes the pane the
                // active one (`ClickObserving`). What the pane reads from the environment goes in with it.
                ClickObserving(content: FilesPane(session: session, buttons: AnyView(buttons(isSplit: isSplit)))
                                   .environment(workspace).environment(\.filesStyle, .soltz),
                               onClick: { workspace.activatePane(of: session.id) })
            } else {
                // The same glass as the sidebar's hosts card.
                terminal(isSplit: isSplit).glassEffect(.regular, in: shape)
            }
        }
        // Which pane of a split has the keys: the others step back, and the outline moves to it.
        .opacity(isActive || !isSplit ? 1 : Theme.paneUnfocused)
        .overlay {
            if isActive && isSplit {
                shape.strokeBorder(.primary.opacity(0.35), lineWidth: 1).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(Theme.motion, value: isActive && isSplit)
        .animation(Theme.motion, value: isActive || !isSplit)
        .overlay(alignment: .bottom) {
            if session.ended || !session.isAttached { state.transition(Theme.arrival) }
        }
        .animation(Theme.motion, value: session.ended || !session.isAttached)
        // A host or a session dragged here from the sidebar is new work beside this pane; a tab dragged here from
        // the strip joins it, and so does another pane, dragged by its header (`PaneDrop` takes the drag). The
        // half the new pane would take lights up, and glides as the pointer nears another side; all of it lights
        // up under a pane held over its middle, which changes places with this one.
        .overlay { if !floating { PaneDrop(onDragOver: dragOver, onDrop: drop).allowsHitTesting(false) } }
        .overlay {
            GeometryReader { box in
                if over {
                    let wide = side == .left || side == .right, tall = side == .top || side == .bottom
                    shape.fill(.tint.opacity(Theme.dropFill)).overlay { shape.strokeBorder(.tint, lineWidth: 2) }
                        .frame(width: wide ? box.size.width / 2 : nil, height: tall ? box.size.height / 2 : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.map(Self.edge) ?? .center)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(Theme.motion, value: over ? side?.rawValue ?? "middle" : nil)
        .onGeometryChange(for: Bool.self) { $0.size.width < Theme.paneNarrow } action: { narrow = $0 }
        .padding(floating ? 0 : Theme.paneGap / 2)
    }

    private static func edge(_ side: SplitPosition) -> Alignment {
        switch side {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func terminal(isSplit: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // The pane's handle: dragged onto another pane it moves there, onto the tabs it becomes a tab.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: Theme.paneIcon - 2, weight: .semibold))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(session.title).font(Theme.chromeStrong).lineLimit(1)
                    if let cwd = session.cwd {
                        Text(Self.abbreviated(cwd)).font(Theme.chromeRegular).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            .contentTransition(.opacity).transition(.opacity)
                    }
                    Spacer(minLength: 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .draggable(Dragged(kind: .pane, id: session.id)) { DragChip(title: session.title, systemImage: "terminal") }
                buttons(isSplit: isSplit)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: Theme.paneHeader)
            .clipped() // what does not fit a very narrow pane is cut, not drawn over the pane beside it
            .animation(Theme.motion, value: session.cwd)
            ClickObserving(content: SoltzTerminalView(session.terminal), onClick: { workspace.activatePane(of: session.id) })
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    /// The app's drag is over this pane, there, or left it (neither). False when it cannot land here. Told on every
    /// move of the pointer, so nothing is set that is set already.
    private func dragOver(_ drag: Dragged?, _ zone: PaneDrop.Zone?) -> Bool {
        let mine = Workspace.panel + session.id
        guard let drag, let zone, workspace.lands(drag, on: session.id) else {
            if let drag, workspace.dropTarget != nil { Workspace.drags.notice("a \(drag.kind.rawValue, privacy: .public) cannot land on this pane") }
            if workspace.dropTarget == mine { workspace.dropTarget = nil }
            return false
        }
        if workspace.dropTarget != mine { workspace.dropTarget = mine }
        if workspace.dropSide != side(drag, zone) { workspace.dropSide = side(drag, zone) }
        return true
    }

    /// Where a drop there goes: beside the pane, on its nearest side; none for a pane held over the middle, which
    /// changes places with this one.
    private func side(_ drag: Dragged, _ zone: PaneDrop.Zone) -> SplitPosition? {
        drag.kind == .pane && zone.middle ? nil : zone.side
    }

    private func drop(_ drag: Dragged, _ zone: PaneDrop.Zone) -> Bool {
        let side = side(drag, zone)
        let taken = side.map { workspace.openPane(for: drag, beside: session.id, $0) } ?? workspace.swap(drag, with: session.id)
        Workspace.drags.notice("a \(drag.kind.rawValue, privacy: .public) dropped on a pane, \(side?.rawValue ?? "middle", privacy: .public): \(taken ? "taken" : "refused", privacy: .public)")
        return taken
    }

    /// The pane's own buttons: each acts on this pane.
    private func buttons(isSplit: Bool) -> some View {
        let maximized = workspace.layout.maximizedPaneId != nil
        return HStack(spacing: 2) {
            if floating {
                button("Back Among the Panes", "pip.exit") { workspace.restore(session.id) }
                button("Minimize", "minus") { workspace.setMinimized(session.id, true) }
            } else {
                if !narrow {
                    button("Split Right", "rectangle.split.2x1") { workspace.split(.right) }
                    button("Split Down", "rectangle.split.1x2") { workspace.split(.below) }
                }
                button(maximized ? "Restore Pane" : "Maximize Pane",
                       maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { workspace.toggleMaximize() }
                    .disabled(!isSplit)
                button("Float Pane", "pip.enter") { workspace.float(session.id) }
            }
            button("Close Pane", "xmark") { workspace.close(session.id) }
        }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol) {
            workspace.activatePane(of: session.id)
            action()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(PaneButton())
        .help(title)
    }

    private var state: some View {
        HStack(spacing: 10) {
            if session.ended {
                // An SSH tab whose shell exited has closed; a failed or given-up one offers Reconnect.
                let reconnectable = session.dropped && session.args != nil
                Label(reconnectable ? "Disconnected" : "Session ended", systemImage: "stop.circle")
                if reconnectable { Button("Reconnect") { workspace.reconnect(session) } }
            } else {
                // upstream's overlay while connecting, the automatic reconnect's waits included (ConnectionStatusPanel).
                Label { Text(QuickConnectView.label(for: session.step)) } icon: { ProgressView().controlSize(.small) }
                switch session.reconnectWait {
                case .offline?: Text("You’re offline — reconnecting when the network is back").foregroundStyle(.secondary)
                case .slow?: Text("Host still unreachable — retrying every 30 seconds").foregroundStyle(.secondary)
                case nil: EmptyView()
                }
                if session.autoReconnecting {
                    Button("Reconnect") { workspace.reconnect(session) }
                        .help("Try now; the retries start over from the shortest wait")
                }
                if session.args != nil { Button("Cancel") { session.connectTask?.cancel() } }
            }
        }
        .font(Theme.chrome)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(12)
    }

    /// A home-relative path as shells show it.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingCharacters(in: ["/"])
        let trimmed = path.trimmingCharacters(in: ["/"])
        if trimmed == home { return "~" }
        return trimmed.hasPrefix(home + "/") ? "~/" + trimmed.dropFirst(home.count + 1) : path
    }
}

/// Shows `content` and reports a click anywhere in it. SwiftUI gestures never see a mouse-down that
/// an AppKit view (the terminal) takes, so the hit test of an enclosing view is watched instead.
// shortcut: a nested hosting view per pane only to see clicks; drop it once SoltzTerminal reports focus changes.
private struct ClickObserving<Content: View>: NSViewRepresentable {
    let content: Content
    let onClick: () -> Void

    func makeNSView(context _: Context) -> Host {
        let host = Host(rootView: content)
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: Host, context _: Context) {
        host.rootView = content
        host.onClick = onClick
    }

    final class Host: NSHostingView<Content> {
        var onClick: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onClick() }
            return hit
        }
    }
}

/// Takes the app's own drag (`Dragged`) anywhere over a pane, and says which side of the pane the pointer is nearest.
///
/// It lies over the pane, as an AppKit view that asks for that one type. AppKit offers a drag to the frontmost view
/// that asks for a type it carries, and to no other: under this one the terminal asks for text and files, and the
/// file list for files, which SwiftUI's drag of anything carries a promise of, so the list would be offered the
/// drag and refuse it. (SwiftUI's own drop destination lies behind them all.) Clicks pass through.
private struct PaneDrop: NSViewRepresentable {
    /// Where over the pane the pointer is: the side it is nearest, and whether it is in the middle (the inner two
    /// fifths each way).
    struct Zone {
        let side: SplitPosition
        let middle: Bool
    }

    /// The drag is over the pane, there; neither when it left. False when it cannot land.
    let onDragOver: (Dragged?, Zone?) -> Bool
    /// It was dropped there; false when it cannot land here.
    let onDrop: (Dragged, Zone) -> Bool

    func makeNSView(context _: Context) -> Catcher {
        let view = Catcher()
        view.registerForDraggedTypes([Dragged.pasteboardType])
        return view
    }

    func updateNSView(_ view: Catcher, context _: Context) {
        (view.onDragOver, view.onDrop) = (onDragOver, onDrop)
    }

    final class Catcher: NSView {
        var onDragOver: (Dragged?, Zone?) -> Bool = { _, _ in false }
        var onDrop: (Dragged, Zone) -> Bool = { _, _ in false }

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        /// One of the operations the drag allows; none when it cannot land here.
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let drag = Self.dragged(sender), onDragOver(drag, zone(of: sender)) else {
                left()
                return []
            }
            let allowed = sender.draggingSourceOperationMask
            return [NSDragOperation.copy, .move, .generic].first(where: allowed.contains) ?? .generic
        }

        private static func dragged(_ sender: any NSDraggingInfo) -> Dragged? {
            sender.draggingPasteboard.data(forType: Dragged.pasteboardType).flatMap { try? JSONDecoder().decode(Dragged.self, from: $0) }
        }

        /// Where over the pane the pointer is, each way measured against the pane's own width and height.
        private func zone(of sender: any NSDraggingInfo) -> Zone {
            let point = convert(sender.draggingLocation, from: nil)
            let x = point.x / max(bounds.width, 1), down = (isFlipped ? point.y : bounds.height - point.y) / max(bounds.height, 1)
            let side: SplitPosition = min(x, 1 - x) < min(down, 1 - down) ? (x < 0.5 ? .left : .right) : (down < 0.5 ? .top : .bottom)
            return Zone(side: side, middle: abs(x - 0.5) < 0.2 && abs(down - 0.5) < 0.2)
        }

        private func left() { _ = onDragOver(nil, nil) }
        override func draggingExited(_: (any NSDraggingInfo)?) { left() }
        override func draggingEnded(_: any NSDraggingInfo) { left() }
        override func prepareForDragOperation(_: any NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            left()
            return Self.dragged(sender).map { onDrop($0, zone(of: sender)) } ?? false
        }
    }
}

/// Every host's tabs in one glass capsule, a new tab's "+" beside it, and the active session's state.
private struct BottomBar: View {
    @Environment(Workspace.self) private var workspace
    @Namespace private var selection

    var body: some View {
        let status = workspace.activeSession.flatMap(workspace.status(of:))
        let tabs = workspace.tabs
        let atEnd = workspace.dropTarget == Workspace.stripEnd
        HStack(spacing: 6) {
            // More tabs than fit scroll sideways, inside the capsule.
            ViewThatFits(in: .horizontal) {
                chips(tabs)
                ScrollViewReader { strip in
                    ScrollView(.horizontal) { chips(tabs) }.scrollIndicators(.hidden)
                        // The tab shown stays in view: a new one, or one picked in the sidebar.
                        .onChange(of: workspace.layout.activeSplitTabId, initial: true) { _, tab in
                            withAnimation(Theme.motion) { strip.scrollTo(tab) }
                        }
                }
            }
            .padding(3)
            .frame(height: Theme.tabBar)
            .glassEffect(.regular, in: .capsule)
            // The selection glides to the tab shown; tabs make room for a new one, close the gap of a closed one
            // and change places with a dragged one.
            .animation(Theme.motion, value: workspace.layout.activeSplitTabId)
            .animation(Theme.motion, value: workspace.dropTarget)
            .animation(Theme.motion, value: tabs.map(\.id))
            // "+" asks what to open, the host's terminal or its files. It marks the end of the strip too: a tab
            // dropped on the bar beyond it goes last, a sidebar row opens its tab.
            Menu {
                NewTabItems(terminal: { workspace.duplicate(workspace.activeSession, .tab, files: false) },
                            files: workspace.activeSession?.args == nil ? nil : { workspace.showFiles(for: workspace.activeSession) })
            } label: {
                Image(systemName: "plus").font(Theme.chromeStrong).frame(width: Theme.tabBar, height: Theme.tabBar)
                    .contentShape(.circle).glassEffect(.regular.interactive(), in: .circle)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("New tab on this host, in the current directory: its terminal or its files")
            .accessibilityLabel("New Tab")
            .overlay { if atEnd { Circle().strokeBorder(.tint, lineWidth: 2).allowsHitTesting(false).transition(.opacity) } }
            .animation(Theme.motion, value: atEnd)
            Color.clear.frame(minWidth: 12, maxWidth: .infinity).contentShape(.rect)
                .dropDestination(for: Dragged.self) { drags, _ in
                    workspace.dropTarget = nil
                    return drags.first.map { workspace.dropped($0, before: nil) } ?? false
                } isTargeted: { over in
                    if over { workspace.dropTarget = Workspace.stripEnd } else if atEnd { workspace.dropTarget = nil }
                }
            if let status {
                Text(status).font(Theme.chromeRegular).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity).transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.paneMargin)
        .frame(height: Theme.bottomBar)
        .animation(Theme.motion, value: status) // Connecting… turning into Connected, or another pane's state
    }

    private func chips(_ tabs: [SplitTab]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabChip(tab: tab, number: index + 1, selection: selection).transition(Theme.arrival).id(tab.id)
            }
        }
    }
}

/// What "+" opens on a host: its terminal, or its files. This Mac has terminals only (its files are Finder's).
struct NewTabItems: View {
    let terminal: () -> Void
    let files: (() -> Void)?

    var body: some View {
        Button("Terminal", systemImage: "terminal", action: terminal)
        Button("Files", systemImage: "folder") { files?() }.disabled(files == nil)
    }
}

/// A tab of the strip: click to show, pin and close from the context menu, drag to another place in the strip. The
/// shown tab has the selection pill the sidebar's rows have; a dot tells a live tab from an ended one, and turns into
/// Close under the pointer; a files tab has a folder before its name.
private struct TabChip: View {
    let tab: SplitTab
    let number: Int
    let selection: Namespace.ID
    @Environment(Workspace.self) private var workspace
    @ViewState private var hovering = false

    var body: some View {
        let isActive = workspace.layout.activeSplitTabId == tab.id
        let isPinned = workspace.isPinned(tab)
        let ended = workspace.hasEnded(tab)
        let session = tab.root.findLeaf(tab.activePaneId).flatMap { workspace.sessions[$0.sessionId] }
        let files = session?.showsFiles == true
        let host = workspace.name(of: workspace.key(of: tab))
        // A folder's name says little without its host's: the strip holds every host's tabs.
        let title = files && tab.name == nil ? "\(host) · \(workspace.title(of: tab))" : workspace.title(of: tab)
        let key = Workspace.key(tab.id)
        HStack(spacing: 5) {
            // One slot for the state and Close, so the tab keeps its width under the pointer.
            ZStack {
                if hovering && !isPinned {
                    Button("Close Tab", systemImage: "xmark") { workspace.closeTab(tab.id) }
                        .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size: 8, weight: .bold))
                        .transition(Theme.arrival)
                } else if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).transition(Theme.arrival)
                } else {
                    Circle().fill(ended ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green)).frame(width: 6, height: 6)
                        .transition(Theme.arrival)
                }
            }
            .frame(width: 12, height: 12)
            .animation(Theme.motion, value: isPinned)
            .animation(Theme.motion, value: ended)
            if files { Image(systemName: TerminalSession.filesSymbol).font(.system(size: 9)).accessibilityHidden(true) }
            Text(title).lineLimit(1).frame(maxWidth: 140).fixedSize()
        }
        .font(isActive ? Theme.chromeStrong : Theme.chrome)
        .foregroundStyle(isActive && !ended ? .primary : .secondary)
        .padding(.leading, 7)
        .padding(.trailing, 11)
        .frame(minWidth: 64, minHeight: Theme.tabPill, maxHeight: Theme.tabPill)
        .background {
            if isActive {
                Capsule().fill(Color(nsColor: .controlColor)).matchedGeometryEffect(id: "selection", in: selection)
            } else if hovering {
                Capsule().fill(.fill.quaternary).transition(.opacity)
            }
        }
        .contentShape(.capsule)
        .onTapGesture { workspace.activate(tab.id) }
        .onHover { hovering = $0 }
        .animation(Theme.motion, value: hovering) // the pointer's pill, and the dot turning into Close
        .contextMenu {
            if session?.args != nil, !files { Button("Open Its Files") { workspace.showFiles(for: session) } }
            Button(isPinned ? "Unpin Tab" : "Pin Tab") { workspace.togglePin(tab.id) }
            Button("Close Tab") { workspace.closeTab(tab.id) }
        }
        .draggable(Dragged(kind: .tab, id: tab.id)) { DragChip(title: title, systemImage: files ? TerminalSession.filesSymbol : "terminal") }
        // A tab dropped here takes this place, before this one; a sidebar row opens its tab.
        .dropDestination(for: Dragged.self) { drags, _ in
            workspace.dropTarget = nil
            let taken = drags.first.map { workspace.dropped($0, before: tab.id) } ?? false
            Workspace.drags.notice("a \(drags.first?.kind.rawValue ?? "nothing", privacy: .public) dropped on a tab: \(taken ? "taken" : "refused", privacy: .public)")
            return taken
        } isTargeted: { over in
            guard over else {
                if workspace.dropTarget == key { workspace.dropTarget = nil }
                return
            }
            workspace.dropTarget = key
            // Held over a tab, a drag brings it on screen: the drop can go on to one of its panes.
            Task {
                try? await Task.sleep(for: .milliseconds(Theme.springLoad))
                if workspace.dropTarget == key, workspace.layout.activeSplitTabId != tab.id { workspace.activate(tab.id) }
            }
        }
        // Where the dragged tab would go: before this one.
        .overlay(alignment: .leading) {
            if workspace.dropTarget == key {
                Capsule().fill(.tint).frame(width: 3, height: Theme.tabPill - 2).offset(x: -3).transition(.opacity)
            }
        }
        .help(ended ? "\(host) — \(title) — ended" : "\(host) — \(title)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ended ? "Tab \(number), \(title), ended" : "Tab \(number), \(title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workspace.activate(tab.id) }
        .accessibilityAction(named: "Close Tab") { workspace.closeTab(tab.id) }
    }
}

extension Workspace {
    /// A host's name: its saved host's, This Mac, or the title of a session whose host was deleted since.
    func name(of key: String) -> String {
        if key == Self.thisMac { return "This Mac" }
        if let host = connections.first(where: { $0.id == key }) { return host.name.flatMap { $0.isEmpty ? nil : $0 } ?? host.host }
        return tabs(of: key).first.map(title(of:)) ?? "Host"
    }

    /// The bottom bar's status: the active SSH session's real state, the multiplexer once a persistent one attached.
    func status(of session: TerminalSession) -> String? {
        guard session.args != nil else { return nil }
        if session.ended { return session.dropped ? "Disconnected" : "Ended" }
        if !session.isAttached { return session.autoReconnecting ? "Reconnecting…" : QuickConnectView.label(for: session.step) }
        return session.muxMode.map { "\($0) · attached" } ?? "Connected"
    }
}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    /// Set while the main window is key; menu commands use it to tell it from Settings.
    var workspace: Workspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}
