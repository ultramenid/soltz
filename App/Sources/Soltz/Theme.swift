// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// The type scale and spacing, measured from the mockup: each mockup screen is one 657 × 410 px window, taken as the
/// default 1180 × 736 pt window, so 1 mockup px = 1.796 pt. Text sizes come from the widths of known strings (SF Pro at
/// the weight shown), spacing from distances between edges. Every page and sheet uses these.
enum Theme {
    static let window = CGSize(width: 1180, height: 736)

    // MARK: Type

    /// "Hosts", "New host" (15.1 pt measured at 1100 pt → 16.2; the titles' captures read 6% narrow at 16 → 17).
    static let title = Font.system(size: 17, weight: .bold)
    /// Host rows, form labels and values, the Home footer (10.0–10.4 → 11).
    static let body = Font.system(size: 11)
    static let bodyStrong = Font.system(size: 11, weight: .semibold)
    /// Bar labels, segments, pane headers, bottom buttons, file rows (8.9–9.6 → 10).
    static let chrome = Font.system(size: 10, weight: .medium)
    static let chromeStrong = Font.system(size: 10, weight: .semibold)
    static let chromeRegular = Font.system(size: 10)
    /// Column titles (8.4 → 9).
    static let caption = Font.system(size: 9)
    /// The terminal's default font size (SF Mono advance 3.61 px → 10.5) and line height (10 px pitch = 18 pt, against
    /// 14.5 pt at 11 pt and 1.0).
    static let terminalSize = 11.0
    static let terminalLineHeight = 1.25

    // MARK: Motion

    /// The app's one motion: a spring that settles quickly without bouncing, for panes, pages, cards and selection.
    /// Off with the system's Reduce Motion, and in the test runs, which read state right after changing it.
    @MainActor static var motion: Animation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Smoke.requested || E2E.requested { return nil }
        return .snappy(duration: 0.3)
    }
    /// How a card or pane arrives and leaves: fading, from just under its size.
    @MainActor static var arrival: AnyTransition { .opacity.combined(with: .scale(scale: 0.97)) }

    // MARK: Sidebar's hosts card

    static let sidebarWidth: CGFloat = 264
    static let treeRow: CGFloat = 28            // a group's or a host's row
    static let sessionRow: CGFloat = 24         // a session's, under its host
    static let treeIndent: CGFloat = 16         // one level in: a group's hosts, a host's sessions
    static let treeSlot: CGFloat = 14           // a row's chevron
    static let treeIcon: CGFloat = 18           // and its icon
    static let stackMost = 2                    // the cards that show under a row's icon, at most
    static let stackRise: CGFloat = 2.5         // how far each is above, and narrower than, the one over it
    static let stackLine: CGFloat = 1.2         // and how thick its edge is drawn: the symbol's own stroke
    static let cardRadius: CGFloat = 22         // 12.5 px
    static let cardInset: CGFloat = 23          // text from the card edge, 13 px
    static let rowInset: CGFloat = 11           // selection pill from the card edge, 6.3 px
    static let rowHeight: CGFloat = 38          // row pitch, 21.4 px
    static let rowPill: CGFloat = 32            // selection pill height, 17.7 px
    static let headerHeight: CGFloat = 58       // card top to the first row, 32 px
    static let footerHeight: CGFloat = 44       // separator to card bottom, 23 px
    static let addButton: CGFloat = 27          // "+" diameter, 15 px
    static let searchField: CGFloat = 28

    // MARK: Workspace

    static let capsuleHeight: CGFloat = 24      // top and bottom bar capsules, 13.3 px
    static let barInset: CGFloat = 6            // a top bar button's label from its capsule's border
    static let paneMargin: CGFloat = 8          // window edge to pane card, 4.3 px
    static let paneGap: CGFloat = 8             // between pane cards, 4.7 px (half on each card)
    static let paneRadius: CGFloat = 16         // between the window corner and Home's card
    static let paneHeader: CGFloat = 30         // card top to the first terminal line, 22.7 px − half a line
    static let paneIcon: CGFloat = 11           // header icons, 6 px
    static let paneButton: CGFloat = 20         // a header icon's hover circle
    static let paneUnfocused = 0.7              // a split's panes that do not have the keys (Ghostty's own default)
    static let bottomBar: CGFloat = 44
    static let floatingPane = CGSize(width: 400, height: 250) // a floating pane's card
    static let paneLeast = CGSize(width: 260, height: 150) // no split leaves a pane smaller: it opens in a tab instead
    static let paneNarrow: CGFloat = 340        // under it a pane's header keeps only Maximize, Float and Close
    static let floatingCapsule: CGFloat = 140   // a minimized one's name, at most
    static let springLoad = 600                 // ms a drag is held over a tab before it comes on screen
    static let tabBar: CGFloat = 28             // the tabs' capsule, and the "+" beside it
    static let tabPill: CGFloat = 22            // a tab inside it

    // MARK: Sheets

    static let sheetWidth: CGFloat = 360        // 200 px
    static let sheetInset: CGFloat = 22         // 12 px
    static let sheetRowHeight: CGFloat = 41     // 23 px
    static let fieldWidth: CGFloat = 154        // 86 px
    static let buttonHeight: CGFloat = 26       // 14.3 px
    static let scrim = 0.32                     // the window behind a popup's card
    static let dropFill = 0.16                  // the half of a pane a dropped row's pane would take
}

/// What follows the pointer while a host or a tab is dragged: its icon and name in a capsule, not a picture of the
/// whole row. A drag image is a still picture, so it cannot be live glass: it takes the window's own colour.
struct DragChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(Theme.bodyStrong)
            .lineLimit(1)
            .frame(maxWidth: 180)
            .fixedSize()
            .padding(.horizontal, Theme.buttonHeight / 2)
            .frame(height: Theme.buttonHeight)
            .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
            .overlay { Capsule().strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .padding(8) // room for the shadow in the image
    }
}

/// Where a drag would land: the outline the file panes draw around themselves.
extension View {
    func dropOutline(_ shown: Bool, radius: CGFloat) -> some View {
        overlay {
            if shown {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                    .allowsHitTesting(false).transition(.opacity)
            }
        }
    }
}

/// A glass capsule (or circle) button; `prominent`, the mockup's inverted pill ("+", "Connect"): glass
/// tinted with the primary colour, its label drawn in the opposite appearance, so it inverts with the appearance and
/// stays legible in both.
struct Pill: ButtonStyle {
    var prominent = false
    var circle = false
    var height = Theme.capsuleHeight
    var font = Theme.chromeStrong
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Disabled, the main action keeps a faint fill under its dimmed label: plain, it read as the lesser button
        // beside Cancel.
        let inverted = prominent && isEnabled
        let glass: Glass = prominent ? .regular.tint(.primary.opacity(isEnabled ? 1 : 0.25)).interactive() : .regular.interactive()
        let label = configuration.label
            .font(font)
            .inverted(inverted)
            .opacity(isEnabled ? 1 : 0.45)
        Group {
            if circle {
                label.frame(width: height, height: height).contentShape(.circle).glassEffect(glass, in: .circle)
            } else {
                label.padding(.horizontal, height / 2).frame(height: height).contentShape(.capsule).glassEffect(glass, in: .capsule)
            }
        }
        .opacity(configuration.isPressed ? 0.75 : 1)
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
        .animation(Theme.motion, value: configuration.isPressed)
    }
}

/// A pane header's icon button: a quiet circle under the pointer, and the press `Pill` has.
struct PaneButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: Configuration
        @ViewState private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: Theme.paneIcon))
                .contentTransition(.symbolEffect(.replace)) // Maximize turning into Restore
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .opacity(isEnabled ? 1 : 0.45)
                .frame(width: Theme.paneButton, height: Theme.paneButton)
                .background { if hovering && isEnabled { Circle().fill(.fill.tertiary).transition(Theme.arrival) } }
                .contentShape(.circle)
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.motion, value: hovering)
                .animation(Theme.motion, value: configuration.isPressed)
        }
    }
}

/// A card's last row: why the main action is unavailable, Cancel, and the one main action.
struct SheetActions: View {
    var problem: String?
    let action: String
    var disabled = false
    let cancel: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let problem { Text(problem).font(Theme.chromeRegular).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(Pill(height: Theme.buttonHeight, font: Theme.body.weight(.medium)))
            Button(action, action: run)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(Pill(prominent: true, height: Theme.buttonHeight, font: Theme.body.weight(.semibold)))
                .disabled(disabled)
        }
        .padding(.horizontal, Theme.sheetInset - 6)
        .padding(.bottom, 16)
    }
}

extension View {
    /// A sheet's content in the theme: the body size and small controls, its lists and forms clear over the card
    /// (`SheetCard`) the window draws under it.
    func glassSheet() -> some View {
        font(Theme.body)
            .controlSize(.small)
            .scrollContentBackground(.hidden)
            .containerBackground(.clear, for: .window)
            .presentationBackground(.clear)
    }
}

/// Where the open sheet is, so the window can draw its card. Glass inside a sheet's own window does not see the window
/// under it and came out a flat grey panel, so every SwiftUI sheet (the packages' own too) is made clear, and the main
/// window draws Home's glass card beneath it. Alerts keep the system's look.
///
/// Timing matters: the system's grey panel and its dimming must never reach the screen, not even for a frame. So a
/// sheet starts invisible, everything is put right before each frame is committed, and the sheet is shown only once
/// its card has been drawn.
@MainActor @Observable
final class SheetCards {
    static let shared = SheetCards()
    /// The top sheet's frame in the main window, from its top left.
    private(set) var frame: CGRect?
    @ObservationIgnored private var dirty = false

    private init() {
        // shortcut: wraps AppKit's `beginSheet` so a sheet is put right in the same call that opens it; anything later
        // (a notification, a run loop observer) let one frame of the system's grey panel and dimming through. If this
        // stops holding on a macOS update, present the cards inside the window instead of as sheets.
        let selector = #selector(NSWindow.beginSheet(_:completionHandler:))
        if let method = class_getInstanceMethod(NSWindow.self, selector) {
            typealias Begin = @convention(c) (NSWindow, Selector, NSWindow, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Begin.self)
            let wrapped: @convention(block) (NSWindow, NSWindow, AnyObject?) -> Void = { parent, sheet, handler in
                // AppKit is main-thread only, but a caller that broke that must not bring the app down here.
                guard Thread.isMainThread else { return original(parent, selector, sheet, handler) }
                MainActor.assumeIsolated { SheetCards.shared.opening(sheet) }
                original(parent, selector, sheet, handler)
                MainActor.assumeIsolated { SheetCards.shared.opened(sheet) }
            }
            method_setImplementation(method, imp_implementationWithBlock(wrapped))
        }
        // Two system views are created and drawn inside `beginSheet` itself, so they are hidden as they join the
        // window: the dimming over a sheet's parent (it would dim the card, which is drawn in the parent; alerts lose
        // their dimming too), and the opaque panel under a sheet's content.
        if let dimming = NSClassFromString("NSSheetEffectDimmingView") { Self.hideOnArrival(dimming) { _ in true } }
        Self.hideOnArrival(NSVisualEffectView.self) { view in
            guard let window = view.window, Self.isSheet(window) else { return false }
            return view.superview === window.contentView?.superview
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { SheetCards.shared.dirty = true }
        }
        // The last thing before Core Animation commits the frame (its observer's order is 2 000 000): SwiftUI opens a
        // sheet while it updates its views, late in the run loop's turn, and the system's dimming is in place only then.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999) { _, _ in
            MainActor.assumeIsolated { SheetCards.shared.tick() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // shortcut: SwiftUI's sheet window, the system's panel under its content and the dimming over its parent are
    // found by class; if a macOS update renames them, sheets fall back to the system's grey panel. Then present
    // the cards inside the window instead.
    private static func isSheet(_ window: NSWindow) -> Bool { window.className.contains("SheetPresentationWindow") }

    /// Hides `type`'s views as they join a window, when `matches`.
    private static func hideOnArrival(_ type: AnyClass, when matches: @escaping @MainActor (NSView) -> Bool) {
        let moved = #selector(NSView.viewDidMoveToWindow)
        guard let inherited = class_getMethodImplementation(type, moved) else { return }
        typealias Moved = @convention(c) (NSView, Selector) -> Void
        let hide: @convention(block) (NSView) -> Void = { view in
            unsafeBitCast(inherited, to: Moved.self)(view, moved)
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { if matches(view) { view.isHidden = true } }
        }
        class_replaceMethod(type, moved, imp_implementationWithBlock(hide), "v@:")
    }

    private func clear(_ sheet: NSWindow) {
        sheet.isOpaque = false
        sheet.backgroundColor = .clear
        sheet.hasShadow = false
        sheet.contentView?.superview?.subviews.forEach { if $0 is NSVisualEffectView { $0.isHidden = true } }
    }

    /// A sheet is about to open: clear, and its content hidden until its card is drawn.
    private func opening(_ sheet: NSWindow) {
        guard Self.isSheet(sheet) else { return }
        clear(sheet)
        sheet.contentView?.alphaValue = 0
    }

    /// The sheet is attached and placed, the dimming over its parent just added.
    private func opened(_ sheet: NSWindow) {
        guard Self.isSheet(sheet) else { return }
        dirty = true
        tick()
    }

    /// Before each frame while a sheet is opening, open or closing.
    private func tick() {
        guard dirty || frame != nil else { return }
        dirty = false
        var chain: [NSWindow] = []
        if let main = NSApp.windows.first(where: { $0.attachedSheet != nil && $0.sheetParent == nil }) {
            chain = [main]
            while let sheet = chain[chain.count - 1].attachedSheet { chain.append(sheet) }
        }
        let sheets = chain.dropFirst().filter(Self.isSheet)
        for sheet in sheets {
            clear(sheet)
            sheet.sheetParent?.contentView?.superview?.subviews.forEach { if $0.className.contains("SheetEffectDimming") { $0.isHidden = true } }
        }
        // Only the top one shows (a sheet under it would show through the clear sheet above), and only while it is
        // on screen: a closing sheet takes its card with it.
        guard let main = chain.first, let top = sheets.last, top.isVisible else {
            dirty = !sheets.isEmpty
            sheets.forEach { $0.contentView?.alphaValue = 0 }
            return set(nil)
        }
        let new = CGRect(x: top.frame.minX - main.frame.minX, y: main.frame.maxY - top.frame.maxY, width: top.frame.width, height: top.frame.height)
        for sheet in sheets where sheet !== top { sheet.contentView?.alphaValue = 0 }
        if frame == new {
            // Its card is drawn in this frame, and arrives fading: so does the content.
            if top.contentView?.alphaValue == 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.motion == nil ? 0 : 0.2
                    top.contentView?.animator().alphaValue = 1
                }
            }
        } else {
            // Not shown before its card: the content alone, with no card under it, would be a flicker too.
            top.contentView?.alphaValue = 0
            set(new)
            dirty = true
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func set(_ new: CGRect?) { if frame != new { frame = new } }
}

/// The open sheet's card: the same glass as Home's hosts card, in the main window, under the clear sheet.
struct SheetCard: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let frame = SheetCards.shared.frame {
                // The window steps back behind a popup, so its card reads as the one thing to answer: without it the
                // card was glass on glass, and hard to tell from the panes. It comes and goes with the card (the
                // system's own dimming stays hidden: it arrives a frame early and cannot fade).
                Rectangle().fill(Color(nsColor: .shadowColor).opacity(Theme.scrim)).transition(.opacity)
                Color.clear.frame(width: frame.width, height: frame.height)
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
                    .offset(x: frame.minX, y: frame.minY)
                    // It arrives fading, with its content. A closing sheet's content is gone at once, so the card
                    // goes with it: left to fade, it was an empty box, darker than the scrim lifting around it.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(Theme.motion, value: SheetCards.shared.frame != nil)
    }
}

extension View {
    /// Content on an inverted (primary-tinted) pill: the opposite appearance's primary colour.
    func inverted(_ on: Bool = true) -> some View { modifier(Inverted(on: on)) }
}

private struct Inverted: ViewModifier {
    let on: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .environment(\.colorScheme, on ? (scheme == .dark ? .light : .dark) : scheme)
    }
}
