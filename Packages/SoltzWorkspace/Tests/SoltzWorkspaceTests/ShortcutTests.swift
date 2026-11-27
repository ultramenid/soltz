// SPDX-License-Identifier: AGPL-3.0-only
// Ports of shortcutStore.macModifier.test.ts and shortcutStore.clipboard.test.ts. Upstream tests
// matchShortcut against DOM KeyboardEvents; here the same macOS rules are checked on the
// KeyboardShortcut each binding becomes (AppKit does the event matching for menu commands).
import Foundation
import SwiftUI
import Testing
@testable import SoltzWorkspace

private func menuShortcut(_ id: String) throws -> KeyboardShortcut {
    try #require(ShortcutStore().keyboardShortcut(id))
}

@Suite struct AppShortcutsOnMacOS {
    @Test(arguments: ["omni", "copy", "paste", "close-tab", "new-tab", "sidebar", "terminal-search", "undo"])
    func bindCommandAndLeaveCtrlChordsToTheTerminal(id: String) throws {
        let shortcut = try menuShortcut(id)
        #expect(shortcut.modifiers == .command, "\(id) on ⌘ only")
        #expect(shortcut.key == KeyEquivalent(Character(ShortcutStore.defaults.first { $0.id == id }!.defaultKey)))
    }

    @Test func keepCtrlWhereMacOSOwnsTheCommandChord() throws {
        #expect(try menuShortcut("next-tab").modifiers == .control)
        #expect(try menuShortcut("next-tab").key == .tab)
        #expect(try menuShortcut("prev-tab").modifiers == [.control, .shift])
        #expect(try menuShortcut("shortcuts").modifiers == .control)
        #expect(try menuShortcut("shortcuts").key == .space)
    }

    @Test func neverRequireAModifierForAnUnmodifiedShortcut() throws {
        #expect(try menuShortcut("delete").modifiers == [])
        #expect(try menuShortcut("delete").key == .deleteForward)
        #expect(try menuShortcut("rename").key == KeyEquivalent(Character(Unicode.Scalar(0xF705)!))) // NSF2FunctionKey
    }

    @Test func displayAsCmd() {
        #expect(ShortcutAlias(key: "k", ctrl: true).formatted == "Cmd+K")
        #expect(ShortcutAlias(key: "Tab", ctrl: true).formatted == "Ctrl+Tab")
        #expect(ShortcutAlias(key: " ", ctrl: true).formatted == "Ctrl+Space")
    }

    @Test func duplicateIntoSplitStaysOnCtrlOptionDBecauseMacOSOwnsCmdOptionD() throws {
        let shortcut = try menuShortcut("duplicate-session-split")
        #expect(shortcut.modifiers == [.control, .option])
        #expect(shortcut.key == "d")
        #expect(ShortcutAlias(key: "d", ctrl: true, alt: true).formatted == "Ctrl+Alt+D")
    }

    @Test func aliasesConvertToo() {
        let omni = ShortcutStore.aliases["omni"]!.compactMap(\.keyboardShortcut)
        #expect(omni.map(\.modifiers) == [[.command, .shift], []])
        #expect(omni.map(\.key) == ["p", KeyEquivalent(Character(Unicode.Scalar(0xF704)!))])
    }
}

@Suite struct ClipboardShortcuts {
    @Test func copyCutAndPasteShipAsRebindableShortcuts() throws {
        for id in ["copy", "cut", "paste"] {
            let def = try #require(ShortcutStore.defaults.first { $0.id == id }, "\(id) must exist in defaults")
            #expect(!def.labelKey.isEmpty)
            #expect(!def.descriptionKey.isEmpty)
        }
    }

    @Test func defaultsAreCmdCXV() throws {
        for (id, key) in [("copy", "c"), ("cut", "x"), ("paste", "v")] {
            let shortcut = try menuShortcut(id)
            #expect(shortcut.key == KeyEquivalent(Character(key)))
            #expect(shortcut.modifiers == .command)
        }
    }

    static let oldState = PersistedShortcuts(state: .init(shortcuts: [
        Shortcut(id: "omni", labelKey: "x", descriptionKey: "y", defaultKey: "k", key: "k", ctrl: true, shift: false, alt: false),
    ], shortcutsUpdatedAt: "2026-01-01T00:00:00.000Z"), version: 5)

    @Test(arguments: [5, 7, 8])
    func anOlderPersistedStateGainsTheNewShortcuts(version: Int) throws {
        var old = Self.oldState
        old.version = version
        let store = ShortcutStore(persisted: old)
        let ids = store.shortcuts.map(\.id)
        for id in ["copy", "cut", "paste", "omni", "panel-notes"] { #expect(ids.contains(id)) }
        let rename = try #require(store.shortcut("rename"))
        #expect(rename.key == "F2")
        #expect(!rename.ctrl)
        #expect(store.shortcut("omni")?.labelKey == "x", "persisted entries are kept as saved")
    }
}

@Suite struct ShortcutRebinding {
    @Test func setKeyResetAndResetAll() {
        let store = ShortcutStore()
        #expect(ShortcutStore.defaults.count == 21)
        #expect(store.shortcut("themes") == nil && store.shortcut("panel-themes") == nil, "no theme actions in Soltz")
        store.setKey("omni", ShortcutAlias(key: "j", ctrl: true, shift: true))
        #expect(store.hint("omni") == "Cmd+Shift+J")
        #expect(store.shortcutsUpdatedAt != "1970-01-01T00:00:00.000Z")
        store.reset("omni")
        #expect(store.shortcut("omni")?.binding == ShortcutAlias(key: "k", ctrl: true))
        store.setKey("undo", ShortcutAlias(key: "u", ctrl: true))
        store.resetAll()
        #expect(store.shortcuts == ShortcutStore.defaults)
    }

    @Test func conflictNamesTheOtherShortcutOrAlias() {
        let store = ShortcutStore()
        #expect(store.conflict(for: "omni", ShortcutAlias(key: "t", ctrl: true)) == "new-tab")
        #expect(store.conflict(for: "new-tab", ShortcutAlias(key: "t", ctrl: true)) == nil, "its own binding is no conflict")
        #expect(store.conflict(for: "undo", ShortcutAlias(key: "y", ctrl: true)) == "redo", "aliases count")
        #expect(store.conflict(for: "omni", ShortcutAlias(key: "q", ctrl: true)) == nil)
        #expect(store.conflict(for: "omni", ShortcutAlias(key: ",", ctrl: true)) == nil, "⌘, is free (was themes)")
        #expect(store.conflict(for: "omni", ShortcutAlias(key: "t", ctrl: true, shift: true)) == nil, "⌘⇧T is free (was panel-themes)")
    }

    @Test func unknownPersistedEntriesRoundTripUntouchedAndStayInert() throws {
        let json = #"""
        {"state":{"shortcuts":[
          {"id":"panel-themes","labelKey":"settings.shortcuts.items.panelThemes.label","descriptionKey":"settings.shortcuts.items.panelThemes.desc","defaultKey":"t","key":"t","ctrl":true,"shift":true,"alt":false},
          {"id":"omni","labelKey":"settings.shortcuts.items.omni.label","descriptionKey":"settings.shortcuts.items.omni.desc","defaultKey":"k","key":"j","ctrl":true,"shift":false,"alt":false},
          {"id":"themes","labelKey":"settings.shortcuts.items.themes.label","descriptionKey":"settings.shortcuts.items.themes.desc","defaultKey":",","key":",","ctrl":true,"shift":false,"alt":false}
        ],"shortcutsUpdatedAt":"2026-01-01T00:00:00.000Z"},"version":9}
        """#
        let saved = try JSONDecoder().decode(PersistedShortcuts.self, from: Data(json.utf8))
        let store = ShortcutStore(persisted: saved)
        #expect(store.shortcut("panel-themes") == nil && store.keyboardShortcut("themes") == nil)
        #expect(store.conflict(for: "new-tab", ShortcutAlias(key: "t", ctrl: true, shift: true)) == nil)
        store.setKey("panel-themes", ShortcutAlias(key: "x"))
        store.resetAll()

        let written = store.persisted.state.shortcuts
        #expect(Array(written.prefix(3)) == [saved.state.shortcuts[0], ShortcutStore.defaults[0], saved.state.shortcuts[2]],
                "unknown entries keep their place and content; known ones reset")
        #expect(written.count == 2 + ShortcutStore.defaults.count)
        let reread = ShortcutStore(persisted: try JSONDecoder().decode(PersistedShortcuts.self, from: JSONEncoder().encode(store.persisted)))
        #expect(reread.persisted.state.shortcuts == written)
    }

    @Test func persistenceKeepsUpstreamShape() throws {
        let store = ShortcutStore()
        store.setKey("omni", ShortcutAlias(key: "j", ctrl: true))
        let data = try JSONEncoder().encode(store.persisted)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["version"] as? Int == 9)
        let state = try #require(raw["state"] as? [String: Any])
        let first = try #require((state["shortcuts"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["id", "labelKey", "descriptionKey", "defaultKey", "key", "ctrl", "shift", "alt"])
        #expect(first["labelKey"] as? String == "settings.shortcuts.items.omni.label")
        #expect(state["shortcutsUpdatedAt"] is String)
        let reloaded = ShortcutStore(persisted: try JSONDecoder().decode(PersistedShortcuts.self, from: data))
        #expect(reloaded.shortcuts == store.shortcuts)
        #expect(reloaded.shortcutsUpdatedAt == store.shortcutsUpdatedAt)
    }
}
