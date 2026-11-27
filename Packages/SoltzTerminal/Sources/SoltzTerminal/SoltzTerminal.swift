// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine
import Foundation
import GhosttyKit
import GhosttyTerminal
import SwiftUI

/// Grid size reported when the terminal view is laid out or resized.
public struct SoltzTerminalSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var widthPixels: Int
    public var heightPixels: Int

    public init(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

/// One terminal surface. The terminal never runs a process: bytes come in through `feed`,
/// keystrokes and protocol replies go out through `onInput`.
@MainActor
public final class SoltzTerminalModel {
    let state: TerminalViewState
    nonisolated let session: InMemoryTerminalSession
    private var subscriptions: Set<AnyCancellable> = []
    /// The user allowed this terminal's programs to set the clipboard until it closes.
    private var allowsClipboardWrites = false

    /// Window title set by the remote side (OSC 0/2).
    public var onTitleChange: ((String) -> Void)?
    /// Working directory reported by the remote shell (OSC 7), as Ghostty decodes it.
    public var onWorkingDirectoryChange: ((String) -> Void)?

    /// Colours follow the system appearance: the library's built-in light (Alabaster) and dark
    /// (Afterglow) palettes, picked from the view's effective appearance.
    /// - Parameters:
    ///   - fontFamily: `nil` for Ghostty's built-in font.
    ///   - lineHeight: multiplier; 1.2 makes each cell 20% taller.
    ///   - onInput: bytes to send to the remote side. Called on a Ghostty I/O thread.
    ///   - onResize: new grid size. Called on any thread.
    public init(
        fontFamily: String? = nil,
        fontSize: Double = 13,
        lineHeight: Double = 1,
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (SoltzTerminalSize) -> Void
    ) {
        session = InMemoryTerminalSession(write: onInput) { v in
            onResize(SoltzTerminalSize(
                columns: Int(v.columns), rows: Int(v.rows),
                widthPixels: Int(v.widthPixels), heightPixels: Int(v.heightPixels)
            ))
        }
        // shortcut: one Ghostty app (config + font caches) per terminal, upgrade to a shared
        // TerminalController when many tabs are open and per-tab memory matters.
        state = TerminalViewState(controller: TerminalController(
            configSource: .generated(TerminalConfiguration.default.rendered),
            theme: Self.theme(),
            terminalConfiguration: Self.configuration(fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
        ))
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        // The surface (screen + scrollback) lives as long as its NSView. Owning the view here instead
        // of letting SwiftUI make a new one per mount keeps the terminal across tab switches.
        let view = TerminalView(frame: .zero)
        state.makePlatformView = { view }
        // A program in the terminal setting the clipboard (OSC 52), or a paste Ghostty flags as able to run commands,
        // is the user's call: asked about here, never decided silently. Reading the clipboard is refused.
        state.onClipboardConfirmationRequest = { [weak self, weak view] request in
            guard let self, let window = view?.window else { return request.respond(allow: false) }
            self.confirm(request, in: window)
        }
        state.$title.dropFirst().removeDuplicates()
            .sink { [weak self] in self?.onTitleChange?($0) }
            .store(in: &subscriptions)
        state.$workingDirectory.compactMap(\.self).removeDuplicates()
            .sink { [weak self] in self?.onWorkingDirectoryChange?($0) }
            .store(in: &subscriptions)
        // The selection takes the user's accent colour, so it follows a change of it in System Settings.
        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { _ = self?.state.controller.setTheme(Self.theme()) } }
            .store(in: &subscriptions)
    }

    /// The library's palettes with the system's own selection: its selected-text colours, the accent's shade behind
    /// white text in dark and black text in light. The palettes' own selection drew text in the background colour on
    /// a dark grey block, which could not be read on glass; text left in its own colours was faint where a program
    /// had dimmed it.
    static func theme() -> TerminalTheme {
        func selecting(_ palette: TerminalConfiguration, _ appearance: NSAppearance.Name) -> TerminalConfiguration {
            var colours: [String] = []
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                for colour in [NSColor.selectedTextBackgroundColor, .selectedTextColor] {
                    guard let rgb = colour.usingColorSpace(.sRGB) else { continue }
                    let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
                    colours.append(String(format: "%02X%02X%02X", parts[0], parts[1], parts[2]))
                }
            }
            return TerminalConfiguration(startingFrom: palette) { c in
                // Both or neither: one of them alone could land on a colour too close to the other's.
                guard colours.count == 2 else { return c.withSelectionForeground("cell-foreground") }
                c.withSelectionBackground(colours[0])
                c.withSelectionForeground(colours[1])
            }
        }
        return TerminalTheme(light: selecting(.alabaster, .aqua), dark: selecting(.afterglow, .darkAqua))
    }

    /// Selects everything in the terminal, scrollback included (Ghostty's `select_all`).
    @discardableResult
    public func selectAll() -> Bool {
        state.performBindingAction("select_all")
    }

    /// Output from the remote side. Thread-safe and non-blocking; bytes fed before the view
    /// appears are buffered (oldest dropped past 1 MiB).
    // shortcut: once the view is attached the parse queue is unbounded; expose the session's
    // setOutputBacklogHandler when the Rust core needs backpressure for fast streams.
    public nonisolated func feed(_ data: Data) {
        session.receive(data)
    }

    /// `false` when Ghostty rejected the resulting config; the previous font then stays.
    @discardableResult
    public func setFont(family: String?, size: Double, lineHeight: Double) -> Bool {
        state.controller.setTerminalConfiguration(Self.configuration(fontFamily: family, fontSize: size, lineHeight: lineHeight))
    }

    private func confirm(_ request: TerminalClipboardConfirmationRequest, in window: NSWindow) {
        switch request.kind {
        case .osc52Read: return request.respond(allow: false)
        case .osc52Write where allowsClipboardWrites: return request.respond(allow: true)
        default: break
        }
        let write = request.kind == .osc52Write
        let alert = NSAlert()
        alert.messageText = write ? "Let This Terminal Change the Clipboard?" : "Paste This Text?"
        let shown = request.contents.count > 300 ? request.contents.prefix(300) + "…" : request.contents
        alert.informativeText = (write ? "A program in the terminal wants to copy:" : "It could run commands as soon as it is pasted:")
            + "\n\n\(shown)"
        // The first button is the default: Return never allows.
        alert.addButton(withTitle: write ? "Don’t Allow" : "Cancel")
        alert.addButton(withTitle: write ? "Allow" : "Paste")
        if write {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Allow until this terminal closes"
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let allowed = response == .alertSecondButtonReturn
            if allowed, write, alert.suppressionButton?.state == .on { self?.allowsClipboardWrites = true }
            request.respond(allow: allowed)
        }
    }

    /// Settings can arrive from synced data, so the family is stripped of control characters:
    /// a newline would otherwise inject arbitrary config keys.
    nonisolated static func configuration(fontFamily: String?, fontSize: Double, lineHeight: Double) -> TerminalConfiguration {
        TerminalConfiguration { c in
            // The default background is left fully transparent, so whatever the host puts behind the
            // view shows through: the system window background, or glass/material. The palette's own
            // background still drives reverse video and OSC 11 replies.
            c.withBackgroundOpacity(0)
            // Ghostty's default lets any output set the Mac's clipboard; here it asks first (see `confirm`).
            c.withCustom("clipboard-write", "ask")
            let family = String((fontFamily ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            if !family.isEmpty { c.withFontFamily(family) }
            if fontSize.isFinite, fontSize > 0 { c.withFontSize(Float(fontSize)) }
            if lineHeight.isFinite, lineHeight > 0, lineHeight != 1 {
                c.withCustom("adjust-cell-height", "\(Int(((lineHeight - 1) * 100).rounded()))%")
            }
        }
    }

    /// Makes the terminal the first responder (it then receives keys and Edit menu copy/paste).
    public func focus() {
        state.requestFocus()
    }

    /// Scrollback plus screen as text, soft-wrapped rows joined. `nil` until the view has appeared.
    /// Reflects output parsed so far; `feed` is asynchronous.
    public func readScreenText() -> String? {
        // shortcut: GhosttyTerminal keeps the raw surface internal, so it is reached by reflection;
        // upgrade to a wrapper API before shipping. A renamed field returns nil, which --smoke catches.
        guard let surface = state.surface,
              let raw = Mirror(reflecting: surface).descendant("surface") as? ghostty_surface_t
        else { return nil }
        let everything = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(raw, everything, &text) else { return nil }
        defer { ghostty_surface_free_text(raw, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }
}

/// The terminal surface for SwiftUI. Its background is transparent outside the drawn cells, so it
/// can sit directly on window glass. Show at most one view per model at a time (one NSView backs both).
public struct SoltzTerminalView: View {
    let model: SoltzTerminalModel

    public init(_ model: SoltzTerminalModel) {
        self.model = model
    }

    public var body: some View {
        TerminalSurfaceView(context: model.state)
    }
}
