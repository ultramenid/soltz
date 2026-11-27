// SPDX-License-Identifier: AGPL-3.0-only
// Ports of workspaceSnapshot.test.ts, workspaceSnapshot.lockPin.test.ts and the pure parts of
// workspaceRestore.test.ts. parseSnapshot takes JSON bytes, so the TS `{...snap, x}` variants are
// built by editing the encoded JSON object.
import Foundation
import Testing
@testable import SoltzWorkspace

private func object(_ snap: WorkspaceSnapshot) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as? [String: Any])
}

private func parse(_ value: Any) -> WorkspaceSnapshot? {
    parseSnapshot(try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
}

/// `{...snap, sessions: [{...snap.sessions[0], key: value}]}`
private func withFirstSession(_ snap: WorkspaceSnapshot, _ key: String, _ value: Any) throws -> [String: Any] {
    var raw = try object(snap)
    var first = try #require((raw["sessions"] as? [[String: Any]])?.first)
    first[key] = value
    raw["sessions"] = [first]
    return raw
}

@Suite struct WorkspaceSnapshotCore {
    let layout = SnapshotLayout(titlebarOrder: ["session:s1", "session:s3"])
    let sessions = [
        SessionInput(id: "s1", type: "ssh", connectionId: "c1", connectionName: "web-01", persist: true, encoding: "utf-8"),
        SessionInput(id: "s2", type: "multiplayer", connectionId: "c2", connectionName: "shared"),
        SessionInput(id: "s3", type: "local", connectionId: "local", connectionName: "zsh", localShell: "/bin/zsh"),
        SessionInput(id: "s4", type: "serial", connectionId: "serial-ephemeral", connectionName: "Serial"),
        SessionInput(id: "s5", type: "serial", connectionId: "c5", connectionName: "UART",
                     serialConfig: SnapshotSerialConfig(sessionId: "s5", port: "/dev/ttyUSB0", baud: 115200)),
        SessionInput(id: "s6", type: "ssh", connectionId: "c6", connectionName: "docker", containerExec: true),
    ]
    var snap: WorkspaceSnapshot {
        buildSnapshot(sessions: sessions, cwds: ["s1": "/var/www", "s3": "/home/me"], layout: layout, activeSessionId: "s1",
                      now: ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!)
    }
    var snapScroll: WorkspaceSnapshot {
        buildSnapshot(sessions: sessions, cwds: [:], scrollOffsets: ["s1": 120, "s3": 0], layout: layout, activeSessionId: "s1")
    }

    @Test func builds() {
        let snap = snap
        #expect(snap.version == snapshotVersion, "snapshot carries current version")
        #expect(snap.savedAt == "2026-06-10T12:00:00.000Z", "savedAt is the injected clock")
        #expect(snap.sessions.map(\.id) == ["s1", "s3", "s5"], "filters out multiplayer, unconfigured ephemeral serial, and container-exec sessions")
        #expect(snap.sessions[0].cwd == "/var/www", "cwd attaches from the cwd map")
        #expect(snap.sessions[0].persist, "persist survives")
        #expect(snap.sessions[0].encoding == "utf-8", "encoding survives")
        #expect(!snap.sessions[1].persist, "persist defaults to false")
        #expect(snap.sessions[1].localShell == "/bin/zsh", "localShell survives")
        #expect(snap.sessions[2].serialConfig?.port == "/dev/ttyUSB0", "serial config survives")
        #expect(snap.activeSessionId == "s1", "active session kept when restorable")
        #expect(buildSnapshot(sessions: sessions, cwds: [:], layout: layout, activeSessionId: "s2").activeSessionId == nil,
                "active session nulled when it was filtered out")
    }

    @Test func scrollOffset() {
        #expect(snapScroll.sessions[0].scrollLinesFromBottom == 120, "scroll offset attaches from the offsets map")
        #expect(snapScroll.sessions[1].scrollLinesFromBottom == nil, "zero scroll offset is omitted")
        #expect(buildSnapshot(sessions: sessions, cwds: [:], layout: layout, activeSessionId: "s1").sessions[0].scrollLinesFromBottom == nil,
                "scroll offset omitted when no offsets map provided")
    }

    @Test func parses() throws {
        let snap = snap
        let roundTrip = parse(try object(snap))
        #expect(roundTrip?.sessions.count == 3, "JSON round trip preserves sessions")
        #expect(roundTrip?.layout.titlebarOrder == ["session:s1", "session:s3"], "layout round trips")
        #expect(roundTrip == snap, "a built snapshot survives encode + parse unchanged")
        #expect(parse(NSNull()) == nil, "null discarded")
        #expect(parse("junk") == nil, "non-object discarded")

        var raw = try object(snap)
        raw["version"] = 99
        #expect(parse(raw) == nil, "unknown version discarded")
        raw = try object(snap)
        raw["sessions"] = "nope"
        #expect(parse(raw) == nil, "malformed sessions discarded")
        raw = try object(snap)
        raw["layout"] = ["splitTabs": "x"]
        #expect(parse(raw) == nil, "malformed layout discarded")
        raw = try object(snap)
        raw["sessions"] = (raw["sessions"] as! [Any]) + [["id": 42]]
        #expect(parse(raw)?.sessions.count == 3, "individual malformed session entries dropped")

        #expect(parse(try withFirstSession(snap, "persist", "yes"))?.sessions[0].persist == false, "non-boolean persist sanitized to false")
        #expect(parse(try object(snapScroll))?.sessions[0].scrollLinesFromBottom == 120, "scroll offset round trips")
        #expect(parse(try withFirstSession(snap, "scrollLinesFromBottom", -5))?.sessions[0].scrollLinesFromBottom == nil, "negative scroll offset sanitized away")
        #expect(parse(try withFirstSession(snap, "scrollLinesFromBottom", 42.7))?.sessions[0].scrollLinesFromBottom == 42, "fractional scroll offset floored")
    }

    @Test func snapshotLayoutIsDecoupledFromCallerMutation() {
        var mutLayout = SnapshotLayout()
        let mutSnap = buildSnapshot(sessions: sessions, cwds: [:], layout: mutLayout, activeSessionId: nil)
        mutLayout.splitTabs.append(SplitTab(id: "x", root: leaf("p", "s"), activePaneId: nil))
        mutLayout.titlebarOrder.append("session:x")
        #expect(mutSnap.layout.splitTabs.isEmpty)
        #expect(mutSnap.layout.titlebarOrder.isEmpty)
    }

    @Test func tabTitles() throws {
        var named = sessions[0]
        named.title = "deploy"
        let titled = buildSnapshot(sessions: [named], cwds: [:], layout: layout, activeSessionId: "s1")
        #expect(titled.sessions[0].title == "deploy", "a renamed tab is snapshotted")
        #expect(parse(try object(titled))?.sessions[0].title == "deploy", "a tab name round trips")
        #expect(buildSnapshot(sessions: [sessions[0]], cwds: [:], layout: layout, activeSessionId: "s1").sessions[0].title == nil,
                "an unnamed tab carries no title")
        #expect(parse(try withFirstSession(titled, "title", 7))?.sessions[0].title == nil, "non-string title sanitized away")
    }

    @Test func webTabs() throws {
        let web = buildSnapshot(sessions: [
            SessionInput(id: "w1", type: "web", connectionId: "c9", connectionName: "proxmox", webUrl: "https://192.168.1.3:8006/"),
            SessionInput(id: "w2", type: "web", connectionId: "c10", connectionName: "no page"),
        ], cwds: [:], layout: layout, activeSessionId: "w1")
        #expect(web.sessions.map(\.id) == ["w1"], "a web tab is kept only with its page")
        #expect(web.sessions[0].webUrl == "https://192.168.1.3:8006/", "web tab keeps its page")
        #expect(parse(try object(web))?.sessions[0].webUrl == "https://192.168.1.3:8006/", "web tab survives a round trip")
    }

    @Test func splitTabsKeepUpstreamJSONShape() throws {
        let tab = SplitTab(id: "T", root: split("sp", leaf("p1", "s1"), leaf("p2", "s2"), .v, ratio: 0.3), activePaneId: "p2")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        let root = try #require(encoded["root"] as? [String: Any])
        #expect(root["type"] as? String == "split")
        #expect(root["direction"] as? String == "v")
        #expect(root["ratio"] as? Double == 0.3)
        #expect((root["first"] as? [String: Any])?["type"] as? String == "leaf")
        #expect((root["second"] as? [String: Any])?["sessionId"] as? String == "s2")
        #expect(try JSONDecoder().decode(SplitTab.self, from: JSONEncoder().encode(tab)) == tab)
    }
}

@Suite struct LockAndPinInTheWorkspaceSnapshot {
    @Test func surviveABuildAndParseRoundTrip() throws {
        let layout = SnapshotLayout(splitTabs: [SplitTab(id: "T", root: split("sp", leaf("p1", "b"), leaf("p2", "c")), activePaneId: nil)],
                                    titlebarOrder: ["session:a", "split:T"], pinnedKeys: ["session:a", "split:T"])
        let snap = buildSnapshot(sessions: [SessionInput(id: "a", type: "local", connectionId: "local", connectionName: "zsh", locked: true)],
                                 cwds: [:], layout: layout, activeSessionId: "a")
        let parsed = try #require(parse(try object(snap)))
        #expect(parsed.sessions[0].locked)
        #expect(parsed.layout.pinnedKeys == ["session:a", "split:T"])
    }

    @Test func anOlderSnapshotWithoutThemRestoresWithNothingLockedOrPinned() throws {
        let old: [String: Any] = [
            "version": 1, "savedAt": "", "activeSessionId": NSNull(),
            "layout": ["splitTabs": [], "activeSplitTabId": NSNull(), "splitTabActive": false, "titlebarOrder": ["session:a"]],
            "sessions": [["id": "a", "type": "local", "connectionId": "local", "connectionName": "zsh", "persist": false]],
        ]
        let parsed = try #require(parse(old))
        #expect(!parsed.sessions[0].locked)
        #expect(parsed.layout.pinnedKeys == [])
    }

    @Test func pinsThatNameAMissingTabOrAreNotStringsAreDropped() throws {
        let raw: [String: Any] = [
            "version": 1, "savedAt": "", "activeSessionId": NSNull(),
            "layout": ["splitTabs": [["id": "T"]], "activeSplitTabId": NSNull(), "splitTabActive": false, "titlebarOrder": [],
                       "pinnedKeys": ["session:gone", 3, "split:T", "split:X"]],
            "sessions": [["id": "a", "type": "local", "connectionId": "local", "connectionName": "zsh"]],
        ]
        #expect(try #require(parse(raw)).layout.pinnedKeys == ["split:T"])
    }
}

@Suite struct WorkspaceRestore {
    let snapshot = WorkspaceSnapshot(
        savedAt: "", activeSessionId: "s1",
        layout: SnapshotLayout(),
        sessions: [try! JSONDecoder().decode(SnapshotSession.self, from: Data(#"""
            {"id":"s1","connectionId":"c1","connectionName":"host","title":"deploy","type":"ssh","persist":true}
            """#.utf8))]
    )

    @Test func aRestoredTabComesBackUnderTheNameTheUserGaveIt() {
        let restored = WorkspaceSnapshot.toRestore(snapshot, enabled: true, hasOpenSessions: false)
        #expect(restored?.sessions.first?.title == "deploy")
        #expect(restored?.activeSessionId == "s1")
    }

    @Test func aRestoredPersistentSshTabReconnectsAttachingToItsMultiplexer() {
        #expect(snapshot.sessions[0].restoreStep == .reconnect(restore: true))
    }

    @Test func localAndWebTabsRestoreWithoutAReconnect() throws {
        let decode = { (json: String) in try JSONDecoder().decode(SnapshotSession.self, from: Data(json.utf8)) }
        let local = try decode(#"{"id":"l","type":"local","connectionId":"local","connectionName":"zsh","localShell":"/bin/zsh","cwd":"/tmp"}"#)
        let web = try decode(#"{"id":"w","type":"web","connectionId":"c","connectionName":"pve","webUrl":"https://x/"}"#)
        #expect(local.restoreStep == .spawnLocal(shell: "/bin/zsh", cwd: "/tmp"))
        #expect(web.restoreStep == RestoreStep.none)
    }

    @Test func nothingIsRestoredWhenOffEmptyOrTabsAreAlreadyOpen() {
        #expect(WorkspaceSnapshot.toRestore(snapshot, enabled: false, hasOpenSessions: false) == nil)
        #expect(WorkspaceSnapshot.toRestore(snapshot, enabled: true, hasOpenSessions: true) == nil)
        #expect(WorkspaceSnapshot.toRestore(nil, enabled: true, hasOpenSessions: false) == nil)
        var empty = snapshot
        empty.sessions = []
        #expect(WorkspaceSnapshot.toRestore(empty, enabled: true, hasOpenSessions: false) == nil)
    }

    @Test func layoutRestorePrunesPanesWhoseSessionsWereNotRestored() {
        var snap = snapshot
        let s1 = snap.sessions[0]
        var s2 = s1
        s2.id = "s2"
        snap.sessions = [s1, s2]
        snap.layout = SnapshotLayout(
            splitTabs: [SplitTab(id: "T", root: split("sp", leaf("p1", "s1"), split("sp2", leaf("p2", "s2"), leaf("p3", "mp"))), activePaneId: "p3")],
            activeSplitTabId: "T", splitTabActive: true, titlebarOrder: ["split:T"]
        )
        let store = LayoutStore()
        store.restore(from: snap)
        #expect(store.root?.sessionIds == ["s1", "s2"])
        #expect(store.activePaneId == "p1")
        #expect(store.splitTabActive)
    }
}
