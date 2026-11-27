// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzFilesUI
import SwiftUI

/// File rows drag out of the list's AppKit table, which shows a picture of every dragged row. This gives a file drag
/// the chip a host or a tab has (`DragChip`): the file's name, or how many items, in one capsule at the pointer.
@MainActor
enum DragImages {
    /// For `--snapshot`: the last chip drawn and what it was drawn for, and whether drags carry nothing (a staged
    /// drag follows the real pointer, so it must not be able to drop a file anywhere).
    static var last: NSImage?
    static var note = ""
    static var staged = false

    static func install() {
        // shortcut: wraps AppKit's `beginDraggingSession` because a SwiftUI List takes no drag preview; if a macOS
        // update stops starting list drags through it, file drags go back to the system's row pictures.
        let selector = #selector(NSView.beginDraggingSession(with:event:source:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        typealias Begin = @convention(c) (NSView, Selector, NSArray, NSEvent, AnyObject) -> NSDraggingSession
        let original = unsafeBitCast(method_getImplementation(method), to: Begin.self)
        let wrapped: @convention(block) (NSView, NSArray, NSEvent, AnyObject) -> NSDraggingSession = { view, items, event, source in
            guard Thread.isMainThread else { return original(view, selector, items, event, source) }
            nonisolated(unsafe) var shown: NSArray? // AppKit starts drags on the main thread
            MainActor.assumeIsolated { shown = chip(items as? [NSDraggingItem] ?? [], in: view, at: event).map { $0 as NSArray } }
            return original(view, selector, shown ?? items, event, source)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapped))
    }

    /// Puts the chip on a file drag's first item and nothing on the rest. Returns the items to drag instead, if any.
    private static func chip(_ items: [NSDraggingItem], in view: NSView, at event: NSEvent) -> [NSDraggingItem]? {
        let entries = PaneDrag.starting
        PaneDrag.starting = []
        if staged { note = "drag began from \(type(of: view)) with \(items.count) item(s), \(entries.count) file(s) noted" }
        guard view is NSTableView, let first = entries.first, !items.isEmpty else { return nil }
        let title = items.count == 1 ? first.name : "\(items.count) items"
        let symbol = items.count > 1 ? "doc.on.doc" : first.isDir ? "folder" : "doc"
        var image: NSImage?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let renderer = ImageRenderer(content: DragChip(title: title, systemImage: symbol).environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = view.window?.backingScaleFactor ?? 2
            image = renderer.nsImage
        }
        guard let image else { return nil }
        (last, note) = (image, "\(items.count) item(s) from \(type(of: view)), “\(title)”")
        // The chip starts at the pointer and is centred on it.
        let at = view.convert(event.locationInWindow, from: nil)
        let frame = CGRect(x: at.x - 8, y: at.y - image.size.height / 2, width: image.size.width, height: image.size.height)
        for (index, item) in items.enumerated() { item.setDraggingFrame(frame, contents: index == 0 ? image : nil) }
        guard staged else { return nil }
        let nothing = NSPasteboardItem()
        nothing.setString("", forType: NSPasteboard.PasteboardType("app.soltz.snapshot.nothing"))
        let item = NSDraggingItem(pasteboardWriter: nothing)
        item.setDraggingFrame(frame, contents: image)
        return [item]
    }
}
