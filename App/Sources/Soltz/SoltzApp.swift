// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzWorkspace
import SwiftUI

// shortcut: SDK 27 turns `@State` into a macro whose plugin (SwiftUIMacros) ships only with Xcode; this alias
// reaches the property wrapper directly. Go back to `@State` once builds have Xcode's macro plugins.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct SoltzApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // `--smoke`, `--e2e` and `--snapshot` never touch the user's data directory or login keychain.
    @ViewState private var workspace = Smoke.requested
        ? Workspace(dataDir: Smoke.dataDir, keychain: .memory)
        : E2E.requested ? Workspace(dataDir: E2E.dataDir, keychain: .memory)
        : Snapshot.requested ? Workspace(dataDir: Snapshot.dataDir, keychain: .memory)
        : Workspace(dataDir: .applicationSupportDirectory.appending(path: "Soltz"), keychain: .system)
    @ViewState private var shortcuts = ShortcutStore()

    var body: some Scene {
        // No title bar of its own: the content runs under the transparent toolbar, the traffic lights stay
        // (ContentView sets the toolbar and the window's material).
        Window("Soltz", id: "main") {
            ContentView()
                .environment(workspace)
        }
        .defaultSize(Theme.window) // the mockup's 657 × 410 aspect
        .windowResizability(.contentMinSize) // any size from the content's minimum up
        .windowToolbarStyle(.unifiedCompact) // the mockup's bar capsules are 24 pt tall
        .commands { SoltzCommands(workspace: workspace, shortcuts: shortcuts) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var inputBlock: Any?
    /// The window whose top strip a double click's second press was on: answered at its release.
    private var doubleClicked: NSWindow?
    /// Whether that window filled the screen when the double click began.
    private var wasZoomed = false

    func applicationWillFinishLaunching(_: Notification) {
        DragImages.install()
        // A double click on the main window's top strip. Its second press and release go no further (the system
        // must not answer them too), and it is answered at the release: resizing at the press let the animation
        // take the release, and the window was left as if the mouse were still down on it.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                doubleClicked = event.clickCount == 2 ? Self.titleBar(under: event) : nil
                if event.clickCount == 1 { wasZoomed = event.window?.isZoomed ?? false }
                return doubleClicked == nil ? event : nil
            }
            guard let window = doubleClicked else { return event }
            doubleClicked = nil
            Self.titleBarDoubleClick(window, wasZoomed: wasZoomed)
            return nil
        }
        guard Smoke.requested || E2E.requested || Snapshot.requested else { return }
        // No Dock icon and no activation: a test run never takes keyboard focus from the user.
        NSApp.setActivationPolicy(.accessory)
        // Its window is still on screen: a click or key there (an alert's OK, a host key's Cancel, a pane) would change
        // what the checks read, so a test run drops all user input.
        inputBlock = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]) { _ in nil }
        if Smoke.requested { Smoke.startWatchdog() } else if E2E.requested { E2E.startWatchdog() } else { Snapshot.startWatchdog() }
        // After a test run crashed, the system asks at every later launch whether to reopen its windows: a modal
        // alert, before the window, that nobody can answer here. It is dismissed as soon as it is up (the timer
        // runs only while something is modal; the app's own alerts are sheets).
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }, forMode: .modalPanel)
    }

    /// The window is remembered at its own size, so the app never opens filling the screen.
    func applicationWillTerminate(_: Notification) {
        Self.openAtOwnSize()
    }
}

extension AppDelegate {
    /// The main window, when `event` is on its top strip as on a title bar: on the glass of Home, which runs under
    /// the title bar (the system never sees a double click there), or on the bar of a page, not on a button of it.
    @MainActor static func titleBar(under event: NSEvent) -> NSWindow? {
        guard let window = event.window, let content = window.contentView,
              window.attachedSheet == nil, event.locationInWindow.y > window.contentLayoutRect.maxY,
              let hit = content.superview?.hitTest(event.locationInWindow) else { return nil }
        let under = Array(sequence(first: hit, next: \.superview))
        // Only the main window has the glass. In its content the click must be on that glass itself; in the bar
        // over it, on the bar and not on one of its buttons or titles.
        guard content.firstBackdrop != nil,
              hit.isDescendant(of: content) ? under.contains(where: { $0 is WindowBackdrop.Backdrop })
                  : !under.contains(where: { $0 is NSControl || String(describing: type(of: $0)).contains("Hosting") })
        else { return nil }
        return window
    }

    /// What this Mac does for a double click on a title bar (System Settings, Desktop & Dock): fill the screen, and
    /// from there give the size back; minimize; or nothing.
    /// - Parameter wasZoomed: the window filled the screen when the double click began. One that no longer does
    ///   has its size back already (the system gives it at the first press when that moves the window a little).
    @MainActor static func titleBarDoubleClick(_ window: NSWindow, wasZoomed: Bool) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default:
            if window.isZoomed {
                giveSizeBack(window, animate: true)
            } else if !wasZoomed {
                unfilledFrame = window.frame
                window.zoom(nil)
            }
        }
    }

    /// The main window's frame from before it filled the screen: what a double click there gives back, in this run
    /// and the next. Kept here because the system's own zoom forgets it once the app has quit while filled.
    @MainActor static var unfilledFrame: NSRect? {
        get { UserDefaults.standard.string(forKey: SettingsKey.unfilledFrame).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: SettingsKey.unfilledFrame) }
    }

    /// `window` at the size it had before it filled the screen; with none remembered, or one that is no longer on
    /// this screen, at the app's first size in the middle of the screen.
    @MainActor static func giveSizeBack(_ window: NSWindow, animate: Bool) {
        guard let screen = window.screen?.visibleFrame else { return }
        let first = NSRect(x: screen.midX - Theme.window.width / 2, y: screen.midY - Theme.window.height / 2,
                           width: Theme.window.width, height: Theme.window.height)
        let own = unfilledFrame.flatMap { screen.contains($0) && $0.size != screen.size ? $0 : nil }
        window.setFrame(own ?? first.intersection(screen), display: true, animate: animate)
    }

    /// The main window never opens, and is never remembered, filling the screen: at launch and at quit it goes back
    /// to its own size.
    @MainActor static func openAtOwnSize() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), window.isZoomed else { return }
        giveSizeBack(window, animate: false)
    }
}

private extension NSView {
    /// The window's glass backdrop in this view's tree.
    var firstBackdrop: WindowBackdrop.Backdrop? {
        (self as? WindowBackdrop.Backdrop) ?? subviews.lazy.compactMap(\.firstBackdrop).first
    }
}

struct SoltzCommands: Commands {
    let workspace: Workspace
    let shortcuts: ShortcutStore
    @FocusedValue(\.workspace) private var mainWindowKey

    var body: some Commands {
        let inWorkspace = workspace.shown != nil
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { workspace.checkForUpdates() }
        }
        // Settings is a card in the main window, so it is the same glass.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { workspace.showingSettings = true }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            // With a tab on screen, another on the same host (a local shell for This Mac); with none a local terminal.
            Button("New Tab") {
                if inWorkspace { workspace.duplicate(workspace.activeSession, .tab, files: false) } else { workspace.newLocalTerminal() }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut("new-tab"))
            Button("New Files Tab") { workspace.showFiles(for: workspace.shownSession) }
                .disabled(workspace.shownSession?.args == nil)
            Button("New Local Terminal") { workspace.newLocalTerminal() }
            Button("New Host…") { workspace.newHost = NewHostForm() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W closes a pane in the main window, and any other window (Settings) itself.
            Button("Close") {
                guard mainWindowKey != nil, NSApp.keyWindow?.isSheet != true, inWorkspace, workspace.layout.root != nil else {
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                workspace.closePane()
            }
            .keyboardShortcut(shortcuts.keyboardShortcut("close-tab"))
            Button("Close Tab") { if let tabId = workspace.layout.activeSplitTabId { workspace.closeTab(tabId) } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!inWorkspace || workspace.layout.activeSplitTabId == nil)
        }
        CommandMenu("Shell") {
            Group {
                Button("Split Right") { workspace.split(.right) }
                    .keyboardShortcut("d", modifiers: .command)
                // ⇧⌘D is ShortcutStore's unbound "duplicate-session"; ⌥⌘D belongs to the Dock.
                Button("Split Down") { workspace.split(.below) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(workspace.layout.maximizedPaneId == nil ? "Maximize Pane" : "Restore Pane") { workspace.toggleMaximize() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled((workspace.layout.root?.leaves.count ?? 0) < 2)
                Button("Float Pane") { if let session = workspace.activeSession { workspace.float(session.id) } }
            }
            .disabled(!inWorkspace)
        }
        CommandGroup(before: .windowArrangement) {
            Button("Show Previous Tab") { workspace.selectTab(offset: -1) }
                .keyboardShortcut(shortcuts.keyboardShortcut("prev-tab"))
            Button("Show Next Tab") { workspace.selectTab(offset: 1) }
                .keyboardShortcut(shortcuts.keyboardShortcut("next-tab"))
            Divider()
        }
    }
}
