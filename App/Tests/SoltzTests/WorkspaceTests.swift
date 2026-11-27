// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
@testable import Soltz
import SoltzModel
import SoltzWorkspace
import Testing

/// Layout logic only: session ids here are bare strings with no shell or terminal behind them.
@MainActor struct WorkspaceTests {
    @Test func hostAndUserNamesRefuseOptionsAndInvisibleCharacters() {
        #expect(NewHostForm.isPlain("example.com") && NewHostForm.isPlain("deploy") && NewHostForm.isPlain("müller"))
        #expect(!NewHostForm.isPlain("-oProxyCommand=x"))
        #expect(!NewHostForm.isPlain("exa\u{1B}mple.com") && !NewHostForm.isPlain("pay\u{202E}moc.lap") && !NewHostForm.isPlain("a\u{0}b"))
        var form = NewHostForm()
        form.host = "-x"
        #expect(form.problem != nil)
        (form.host, form.user) = ("example.com", "ro\u{7}ot")
        #expect(form.problem != nil)
    }

    @Test func aStoredKeyIsNamedByItsCommentOrItsFingerprint() {
        // A throwaway key made for this test; only its public half is here.
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICD6punFKt6cOvJT0Cxc5yA1ALAwIijY4Xwvq1LCCriC"
        #expect(Workspace.keySummary(publicKey: line + " deploy@laptop\n") == "ED25519 · deploy@laptop")
        #expect(Workspace.keySummary(publicKey: line) == "ED25519 SHA256:urnwEMydKCLz//uXgXAU/gl9xQycYz1i3hbAGw+/xtc",
                "no comment: the fingerprint ssh-keygen -l prints")
        #expect(Workspace.keySummary(publicKey: "not a key") == nil)
    }

    @Test func aHostKeyQuestionIsAFirstSightOnlyWhenTheCoreSaysNothingWasTrusted() {
        let ask = { (stored: String) in
            TerminalSession.decode(HostKeyConflict.self, #"{"session_id":"s","host":"h","port":22,"new_fingerprint":"SHA256:new"\#(stored)}"#)
        }
        #expect(ask(#","stored_entries":[]"#)?.isFirstSight == true)
        let changed = ask(#","stored_entries":[{"id":"1","host":"h","port":22,"fingerprint":"SHA256:old","vault_id":"personal"}]"#)
        #expect(changed?.isFirstSight == false && changed?.storedEntries?.map(\.fingerprint) == ["SHA256:old"])
        // Without the list it is the stricter question, never the first-sight one.
        #expect(ask("")?.isFirstSight == false)
    }

    @Test func aReleaseIsNewerByItsNumbersNotItsText() {
        #expect(Updates.isNewer("0.10.0", than: "0.9.2"))
        #expect(Updates.isNewer("1.0.0", than: "0.99.99"))
        #expect(!Updates.isNewer("0.1.0", than: "0.1.0"))
        #expect(!Updates.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func tabsCycleAndKeepStripOrderWithPinnedFirst() {
        let workspace = Workspace()
        for id in ["a", "b", "c"] { workspace.place(id, .tab) }
        let ids = workspace.tabs.map(\.id)
        #expect(ids.count == 3 && workspace.layout.activeSplitTabId == ids[2])

        workspace.selectTab(offset: 1)
        #expect(workspace.layout.activeSplitTabId == ids[0], "next wraps to the first tab")
        workspace.selectTab(offset: -1)
        #expect(workspace.layout.activeSplitTabId == ids[2], "previous wraps to the last tab")

        workspace.togglePin(ids[2])
        #expect(workspace.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
        _ = workspace.dropped(Dragged(kind: .tab, id: ids[1]), before: ids[0])
        #expect(workspace.tabs.map(\.id) == [ids[2], ids[1], ids[0]])
    }

    @Test func closingAPaneLeavesTheSurvivorInATabInTheSameSlotWithItsPin() {
        let workspace = Workspace()
        workspace.place("x", .tab)
        workspace.place("a", .tab)
        workspace.place("b", .right)
        #expect(workspace.tabs.map(\.root.sessionIds) == [["x"], ["a", "b"]])

        workspace.closePane() // b, the active pane
        #expect(workspace.tabs.map(\.root.sessionIds) == [["x"], ["a"]])
        #expect(workspace.layout.root?.sessionIds == ["a"], "the survivor's tab is shown")

        workspace.place("c", .below)
        workspace.togglePin(workspace.layout.activeSplitTabId!)
        workspace.closePane() // c
        #expect(workspace.tabs.map(\.root.sessionIds) == [["a"], ["x"]])
        #expect(workspace.isPinned(workspace.tabs[0]))

        workspace.closePane() // a, the last pane of its tab
        #expect(workspace.tabs.map(\.root.sessionIds) == [["x"]])
    }

    @Test func closingASessionsPaneInAnotherTabKeepsTheRest() {
        let workspace = Workspace()
        workspace.place("a", .tab)
        workspace.place("b", .right)
        workspace.place("x", .tab)
        workspace.close("b") // a Reconnect's SESSION_ENDED, in the tab not shown
        #expect(workspace.tabs.map(\.root.sessionIds) == [["a"], ["x"]])
        workspace.close("x")
        workspace.close("missing")
        #expect(workspace.tabs.map(\.root.sessionIds) == [["a"]])
    }

    @Test func eventPayloadsDecode() {
        let conflict = TerminalSession.decode(HostKeyConflict.self, """
            {"session_id":"s1","host":"h","port":22,"stored_entries":[],"new_fingerprint":"SHA256:x"}
            """)
        #expect(conflict == HostKeyConflict(sessionId: "s1", host: "h", port: 22, newFingerprint: "SHA256:x", storedEntries: []))
        #expect(TerminalSession.decode(HostKeyConflict.self, #"{"session_id":"s2"}"#)?.sessionId == "s2")
        #expect(TerminalSession.decode(SshStep.self, #"{"step":"authenticating","detail":""}"#)?.step == "authenticating")
        #expect(TerminalSession.decode(String.self, #""/home/me""#) == "/home/me", "ssh-cwd is a JSON string")
    }

    @Test func showingNoneKeepsTheTabsAndAHostComesBackToItsLastTab() {
        let workspace = Workspace()
        workspace.place("a", .tab)
        workspace.place("b", .tab)
        #expect(workspace.shown == Workspace.thisMac && workspace.tabs(of: Workspace.thisMac).count == 2, "sessions without a host are This Mac's")
        workspace.show(nil)
        #expect(workspace.shown == nil && workspace.tabs.count == 2, "showing none keeps the tabs")
        workspace.show(Workspace.thisMac)
        #expect(workspace.layout.activeSplitTabId == workspace.tabs[1].id, "it comes back to the tab it showed last")
        workspace.closeAll()
        #expect(workspace.shown == nil, "with no tab left none is shown")
        workspace.show("gone")
        #expect(workspace.shown == nil)
    }

    @Test func aDraggedTabTakesItsPlaceInTheStripAndAClosedOnesNeighbourShows() {
        let workspace = Workspace()
        for id in ["a", "b", "c"] { workspace.place(id, .tab) }
        let ids = workspace.tabs.map(\.id)
        #expect(workspace.dropped(Dragged(kind: .tab, id: ids[2]), before: ids[0]) && workspace.tabs.map(\.id) == [ids[2], ids[0], ids[1]],
                "dropped on a tab, it goes before it")
        #expect(workspace.dropped(Dragged(kind: .tab, id: ids[2]), before: nil) && workspace.tabs.map(\.id) == ids,
                "dropped on the strip's end, it goes last")
        #expect(!workspace.dropped(Dragged(kind: .tab, id: "gone"), before: nil) && workspace.tabs.map(\.id) == ids, "a tab closed meanwhile moves nothing")
        #expect(!workspace.openTab(for: Dragged(kind: .session, id: "gone")) && !workspace.openTab(for: Dragged(kind: .host, id: "gone")),
                "a row whose session or host is gone opens nothing")
        #expect(!workspace.openPane(for: Dragged(kind: .host, id: Workspace.thisMac), beside: "gone", .right) && workspace.tabs.map(\.id) == ids,
                "nor does a row dropped on a pane closed meanwhile")
        workspace.activate(ids[1])
        workspace.closeTab(ids[1])
        #expect(workspace.layout.activeSplitTabId == ids[2], "the next tab takes a closed one's place on screen")
        workspace.closeTab(ids[2])
        #expect(workspace.layout.activeSplitTabId == ids[0], "or the one before it, at the strip's end")
    }

    @Test func aTabDroppedOnAPaneJoinsIt() {
        let workspace = Workspace()
        for id in ["a", "b", "c"] { workspace.place(id, .tab) }
        let ids = workspace.tabs.map(\.id)
        #expect(!workspace.openPane(for: Dragged(kind: .tab, id: ids[2]), beside: "c", .right) && workspace.tabs.map(\.id) == ids,
                "the tab on screen, dropped on its own pane, moves nothing")
        #expect(workspace.openPane(for: Dragged(kind: .tab, id: ids[0]), beside: "c", .left) && workspace.tabs.map(\.id) == [ids[1], ids[2]]
                    && workspace.layout.root?.sessionIds == ["a", "c"] && workspace.layout.activeSplitTabId == ids[2],
                "another tab leaves the strip: its pane is beside that one, on the side it was dropped")
    }

    @Test func aPaneMovesByADropAndAFloatingOneStaysOutUntilItComesBack() {
        let workspace = Workspace()
        workspace.place("a", .tab)
        workspace.place("b", .right)
        workspace.place("c", .below)
        let panes = { workspace.layout.root?.sessionIds ?? [] }
        #expect(workspace.openPane(for: Dragged(kind: .pane, id: "c"), beside: "a", .left) && panes() == ["c", "a", "b"], "a pane dropped on another moves beside it")
        #expect(!workspace.openPane(for: Dragged(kind: .pane, id: "a"), beside: "a", .left) && panes() == ["c", "a", "b"], "but not on itself")
        workspace.float("b")
        #expect(workspace.floating == ["b"] && panes() == ["c", "a"] && workspace.tabs.count == 1, "a floating pane leaves its tab")
        workspace.float("c")
        workspace.float("a")
        #expect(workspace.floating == ["b", "c", "a"] && workspace.tabs.isEmpty && workspace.shown == nil, "the last one takes its tab with it")
        workspace.restore("b")
        #expect(workspace.floating == ["c", "a"] && panes() == ["b"] && workspace.shown == Workspace.thisMac, "with no tab on screen it comes back in one of its own")
        #expect(workspace.openPane(for: Dragged(kind: .pane, id: "c"), beside: "b", .right) && panes() == ["b", "c"] && workspace.floating == ["a"],
                "a floating pane dropped on a pane goes beside it")
        #expect(workspace.openTab(for: Dragged(kind: .pane, id: "c")) && workspace.tabs.count == 2 && panes() == ["c"], "a pane dropped on the tabs becomes a tab")
        workspace.restore("a")
        #expect(workspace.floating.isEmpty && panes() == ["c", "a"], "and beside the active pane when a tab is on screen")
        workspace.float("a")
        workspace.setMinimized("a", true)
        workspace.setMinimized("c", true)
        #expect(workspace.minimized == ["a"], "a floating pane minimizes, a pane of a tab does not")
        workspace.setMinimized("a", false)
        workspace.setMinimized("a", true)
        #expect(workspace.minimized == ["a"] && workspace.floating == ["a"], "and comes back, and goes again")
        workspace.close("a")
        #expect(workspace.minimized.isEmpty, "closed, it is no longer minimized either")
        #expect(workspace.floating.isEmpty && panes() == ["c"], "a floating pane closes like any other")
    }

    @Test func aPaneDroppedOnTheMiddleOfAnotherChangesPlacesWithItAndTabsJoinOneAfterAnother() {
        let workspace = Workspace()
        workspace.place("a", .tab)
        workspace.place("b", .right)
        workspace.place("c", .below)
        let panes = { workspace.layout.root?.sessionIds ?? [] }
        #expect(workspace.swap(Dragged(kind: .pane, id: "c"), with: "a") && panes() == ["c", "b", "a"], "two panes of a tab change places")
        #expect(!workspace.swap(Dragged(kind: .pane, id: "a"), with: "a") && !workspace.swap(Dragged(kind: .tab, id: "a"), with: "b") && panes() == ["c", "b", "a"],
                "not a pane with itself, and nothing but a pane")
        workspace.float("b")
        #expect(workspace.swap(Dragged(kind: .pane, id: "b"), with: "c") && panes() == ["b", "a"] && workspace.floating == ["c"],
                "a floating pane takes the pane's place, which floats in its stead")
        workspace.place("d", .tab)
        workspace.place("e", .tab)
        workspace.place("f", .right)
        let tabs = workspace.tabs.map(\.id)
        workspace.activate(tabs[0])
        #expect(workspace.openPane(for: Dragged(kind: .tab, id: tabs[1]), beside: "a", .right) && panes() == ["b", "a", "d"], "a tab joins")
        #expect(workspace.openPane(for: Dragged(kind: .tab, id: tabs[2]), beside: "b", .bottom) && workspace.tabs.map(\.id) == [tabs[0]]
                    && Set(panes()) == ["a", "b", "d", "e", "f"], "and then another, both its panes")
    }

    @Test func aPaneThatWouldLeaveNoRoomOpensInATabOfItsOwn() {
        let workspace = Workspace()
        workspace.paneArea = CGSize(width: 600, height: 400)
        workspace.place("a", .tab)
        workspace.place("b", .right)
        #expect(workspace.tabs.count == 1 && workspace.layout.root?.sessionIds == ["a", "b"], "two columns of 300 have room")
        workspace.place("c", .right)
        #expect(workspace.tabs.count == 2 && workspace.layout.root?.sessionIds == ["c"], "three of 200 have not: the third is a tab")
        workspace.place("d", .below)
        #expect(workspace.layout.root?.sessionIds == ["c", "d"], "and that tab splits as any other")
    }

    @Test func closingAnotherPaneLeavesTheKeysWhereTheyWere() {
        let workspace = Workspace()
        workspace.place("a", .tab)
        workspace.place("b", .right)
        workspace.place("c", .right)
        let active = { workspace.layout.root?.findLeaf(workspace.layout.activePaneId)?.sessionId }
        #expect(active() == "c")
        workspace.close("b")
        #expect(workspace.layout.root?.sessionIds == ["a", "c"] && active() == "c", "the pane that had the keys keeps them")
        workspace.close("c")
        #expect(workspace.tabs.map(\.root.sessionIds) == [["a"]] && active() == "a")
    }

    @Test func newHostFormValidatesItsFieldsAndSpreadsAPastedAddress() throws {
        var form = NewHostForm()
        #expect(form.problem == "Enter the host.")
        form.host = "ops@db.example:2200"
        form.spreadAddress()
        #expect(form.host == "db.example" && form.user == "ops" && form.port == "2200" && form.problem == nil)
        form.port = "70000"
        #expect(form.problem != nil)
        (form.host, form.user, form.port) = ("db.example", "", "22")
        form.spreadAddress()
        let (host, _) = try form.host(id: "h1")
        #expect(host.id == "h1" && host.host == "db.example" && host.port == 22 && host.username == "root" && host.persistSession == true)
    }

    @Test func newHostFormCarriesThePasswordOrTheKeyFileButNotBoth() throws {
        var form = NewHostForm()
        (form.host, form.user) = ("db.example", "ops")
        var (host, secrets) = try form.host()
        #expect(host.authType == .password && secrets.password == nil && secrets.privateKey == nil, "nothing typed: the login prompt asks")
        form.password = "pw"
        (host, secrets) = try form.host()
        #expect(host.authType == .password && secrets.password == "pw" && secrets.privateKey == nil)
        form.useKey = true
        #expect(form.problem == "Choose a key file.")
        // A made-up key in a temp file: never the user's own.
        let file = FileManager.default.temporaryDirectory.appending(path: "soltz-test-key-\(UUID().uuidString)")
        try "not a real key\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        (form.keyFile, form.passphrase) = (file, "phrase")
        (host, secrets) = try form.host()
        #expect(host.authType == .key && secrets.privateKey == "not a real key\n" && secrets.passphrase == "phrase" && secrets.password == nil,
                "a key file is used instead of the password")
        form.keyFile = file.appending(path: "missing")
        #expect(throws: (any Error).self) { try form.host() }
    }

    @Test func savedHostPrefillsQuickConnect() throws {
        let host = try Connection(json: ["id": "1", "host": "example.com", "port": 0, "username": "me", "auth_type": "key",
                                         "tags": [], "created_at": "", "updated_at": "", "clocks": [:]])
        var form = ConnectForm(host)
        #expect(form.host == "example.com" && form.port == 22 && form.username == "me" && form.useKey)
        #expect(!form.isComplete, "key auth needs a key file")
        form.keyFile = URL(filePath: "/dev/null")
        #expect(form.isComplete)
    }
}
