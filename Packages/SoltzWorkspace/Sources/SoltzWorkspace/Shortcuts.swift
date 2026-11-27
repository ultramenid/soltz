// SPDX-License-Identifier: AGPL-3.0-only
// Port of core/src/stores/shortcutStore.ts + utils/primaryModifier.ts (macOS branch only),
// plus the conflict check from components/settings/sections/ShortcutsSection.tsx.
// `ctrl` is upstream's "primary modifier": ⌘ on macOS, except for chords macOS itself owns.
import Foundation
import Observation
import SwiftUI

public struct ShortcutAlias: Codable, Hashable, Sendable {
    public var key: String
    public var ctrl: Bool
    public var shift: Bool
    public var alt: Bool
    public init(key: String, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) {
        self.key = key; self.ctrl = ctrl; self.shift = shift; self.alt = alt
    }
}

/// Persisted entry, same fields as upstream's `soltz-shortcuts` store.
public struct Shortcut: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// i18n key of the display label (upstream `settings.shortcuts.items.*`).
    public let labelKey: String
    public let descriptionKey: String
    public let defaultKey: String
    /// Current, possibly rebound, key.
    public var key: String
    public var ctrl: Bool
    public var shift: Bool
    public var alt: Bool

    public var binding: ShortcutAlias { ShortcutAlias(key: key, ctrl: ctrl, shift: shift, alt: alt) }
}

/// zustand persist envelope: `{"state":{"shortcuts":[...],"shortcutsUpdatedAt":"..."},"version":9}`.
public struct PersistedShortcuts: Codable, Equatable, Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var shortcuts: [Shortcut]
        public var shortcutsUpdatedAt: String
    }
    public var state: State
    public var version: Int
}

@Observable
public final class ShortcutStore {
    public static let persistVersion = 9

    /// The rebindable shortcuts with their default bindings: upstream's 23 minus the two theme
    /// actions, "themes" (⌘,) and "panel-themes" (⌘⇧T). Soltz has no theme system.
    public static let defaults: [Shortcut] = [
        entry("omni", "omni", "k", ctrl: true),
        entry("shortcuts", "shortcuts", " ", ctrl: true),
        entry("new-tab", "newTab", "t", ctrl: true),
        entry("duplicate-session", "duplicateSession", "d", ctrl: true, shift: true),
        entry("duplicate-session-split", "duplicateSessionSplit", "d", ctrl: true, alt: true),
        entry("close-tab", "closeTab", "w", ctrl: true),
        entry("next-tab", "nextTab", "Tab", ctrl: true),
        entry("prev-tab", "prevTab", "Tab", ctrl: true, shift: true),
        entry("sidebar", "sidebar", "b", ctrl: true),
        entry("delete", "delete", "Delete"),
        entry("rename", "rename", "F2"),
        entry("undo", "undo", "z", ctrl: true),
        entry("redo", "redo", "z", ctrl: true, shift: true),
        entry("filter", "filter", "f", ctrl: true),
        entry("terminal-search", "terminalSearch", "f", ctrl: true),
        entry("history", "history", "h", ctrl: true, shift: true),
        entry("snippets", "snippets", "s", ctrl: true, shift: true),
        entry("panel-notes", "panelNotes", "n", ctrl: true, shift: true),
        entry("copy", "copy", "c", ctrl: true),
        entry("cut", "cut", "x", ctrl: true),
        entry("paste", "paste", "v", ctrl: true),
    ]

    /// Extra, fixed bindings that always fire too. Not persisted, not rebindable.
    public static let aliases: [String: [ShortcutAlias]] = [
        "omni": [ShortcutAlias(key: "P", ctrl: true, shift: true), ShortcutAlias(key: "F1")],
        "redo": [ShortcutAlias(key: "y", ctrl: true)],
    ]

    static let knownIds = Set(defaults.map(\.id))

    /// Every persisted entry in saved order, including actions this build does not know
    /// (upstream-only ones): those are written back untouched and never bind or conflict.
    private var entries: [Shortcut]
    public private(set) var shortcutsUpdatedAt: String

    /// The actions Soltz knows, with their current bindings.
    public var shortcuts: [Shortcut] { entries.filter { Self.knownIds.contains($0.id) } }

    /// Loads a persisted set. Like upstream's migrate step, shortcuts added since the set was
    /// saved are appended with their defaults (persisting replaces the array, it never merges).
    /// shortcut: the v<5 label→labelKey migration is not ported; such a state fails to decode.
    public init(persisted: PersistedShortcuts? = nil) {
        let saved = persisted?.state.shortcuts ?? []
        let present = Set(saved.map(\.id))
        entries = saved + Self.defaults.filter { !present.contains($0.id) }
        shortcutsUpdatedAt = persisted?.state.shortcutsUpdatedAt ?? stamp(Date(timeIntervalSince1970: 0))
    }

    public var persisted: PersistedShortcuts {
        PersistedShortcuts(state: .init(shortcuts: entries, shortcutsUpdatedAt: shortcutsUpdatedAt), version: Self.persistVersion)
    }

    public func setKey(_ id: String, _ binding: ShortcutAlias) {
        update(id) { sc in sc.key = binding.key; sc.ctrl = binding.ctrl; sc.shift = binding.shift; sc.alt = binding.alt }
    }

    public func reset(_ id: String) {
        guard let def = Self.defaults.first(where: { $0.id == id }) else { return }
        setKey(id, def.binding)
    }

    public func resetAll() {
        entries = entries.map { entry in Self.defaults.first { $0.id == entry.id } ?? entry }
        shortcutsUpdatedAt = stamp(Date())
    }

    public func shortcut(_ id: String) -> Shortcut? { shortcuts.first { $0.id == id } }

    /// The other shortcut (by id) already using `binding`, directly or through an alias.
    /// Recording `binding` for `id` should be refused while this is non-nil.
    public func conflict(for id: String, _ binding: ShortcutAlias) -> String? {
        shortcuts.first { $0.id != id && ($0.binding == binding || Self.aliases[$0.id]?.contains(binding) == true) }?.id
    }

    /// The current binding as a menu-command shortcut; nil for a key SwiftUI cannot express.
    public func keyboardShortcut(_ id: String) -> KeyboardShortcut? { shortcut(id)?.binding.keyboardShortcut }

    /// getShortcutHint: the current binding as display text ("Cmd+K").
    public func hint(_ id: String) -> String? { shortcut(id)?.binding.formatted }

    private func update(_ id: String, _ change: (inout Shortcut) -> Void) {
        guard Self.knownIds.contains(id) else { return }
        for i in entries.indices where entries[i].id == id { change(&entries[i]) }
        shortcutsUpdatedAt = stamp(Date())
    }

    private static func entry(_ id: String, _ i18n: String, _ key: String, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) -> Shortcut {
        Shortcut(id: id, labelKey: "settings.shortcuts.items.\(i18n).label", descriptionKey: "settings.shortcuts.items.\(i18n).desc",
                 defaultKey: key, key: key, ctrl: ctrl, shift: shift, alt: alt)
    }
}

private func stamp(_ date: Date) -> String { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date) }

// MARK: - macOS modifier mapping

/// macOS owns ⌘Tab, ⌘Space and ⌘⌥D (Dock), so those chords keep Ctrl; everything else uses ⌘.
func usesCommand(_ key: String, alt: Bool) -> Bool {
    let k = key.lowercased()
    return !(k == "tab" || k == " " || (alt && k == "d"))
}

private let namedKeys: [String: KeyEquivalent] = [
    " ": .space, "Tab": .tab, "Enter": .return, "Escape": .escape,
    "Backspace": .delete, "Delete": .deleteForward, "Clear": .clear,
    "ArrowUp": .upArrow, "ArrowDown": .downArrow, "ArrowLeft": .leftArrow, "ArrowRight": .rightArrow,
    "Home": .home, "End": .end, "PageUp": .pageUp, "PageDown": .pageDown,
]

extension ShortcutAlias {
    /// SwiftUI form for menu commands. `key` uses browser KeyboardEvent.key names ("Tab", "F2", "k").
    public var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        if let named = namedKeys[key] {
            equivalent = named
        } else if key.count > 1, key.first == "F", let n = Int(key.dropFirst()), (1...35).contains(n),
                  let scalar = Unicode.Scalar(0xF703 + n) {
            equivalent = KeyEquivalent(Character(scalar)) // NSF1FunctionKey = 0xF704
        } else if key.count == 1, let char = key.lowercased().first {
            equivalent = KeyEquivalent(char)
        } else {
            return nil
        }
        var modifiers: EventModifiers = []
        if ctrl { modifiers.insert(usesCommand(key, alt: alt) ? .command : .control) }
        if shift { modifiers.insert(.shift) }
        if alt { modifiers.insert(.option) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// formatShortcut: "Cmd+K", "Ctrl+Tab", "Ctrl+Alt+D".
    public var formatted: String {
        var parts: [String] = []
        if ctrl { parts.append(usesCommand(key, alt: alt) ? "Cmd" : "Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key == " " ? "Space" : key.count == 1 ? key.uppercased() : key)
        return parts.joined(separator: "+")
    }
}
