// SPDX-License-Identifier: AGPL-3.0-only
// Port of core/src/stores/workspaceSnapshotCore.ts and the pure steps of workspaceRestore.ts.
// Decoding *is* parseSnapshot: it validates and sanitizes exactly like the TS, so a snapshot
// written by upstream (or by an older build) decodes the same way on both sides.
import Foundation

public let snapshotVersion = 1

public struct SnapshotSerialConfig: Codable, Equatable, Sendable {
    public var sessionId: String
    public var port: String
    public var baud: Int
    public var dataBits: Int?
    public var parity: String?
    public var stopBits: Int?
    public var flowControl: String?
    public init(sessionId: String, port: String, baud: Int, dataBits: Int? = nil, parity: String? = nil, stopBits: Int? = nil, flowControl: String? = nil) {
        self.sessionId = sessionId; self.port = port; self.baud = baud
        self.dataBits = dataBits; self.parity = parity; self.stopBits = stopBits; self.flowControl = flowControl
    }
}

public enum SnapshotSessionType: String, Codable, Sendable { case ssh, local, serial, web }

public struct SnapshotSession: Codable, Equatable, Sendable {
    /// Original session UUID: the tmux key soltz_<id> derives from it.
    public var id: String
    public var type: SnapshotSessionType
    public var connectionId: String
    public var connectionName: String
    /// User-given tab name, so a rename survives a restart.
    public var title: String?
    /// Whether persistence (tmux/screen) was active when it connected.
    public var persist: Bool
    public var cwd: String?
    public var localShell: String?
    public var serialConfig: SnapshotSerialConfig?
    /// Web tabs only: the page the tab shows.
    public var webUrl: String?
    public var encoding: String?
    /// Lines scrolled up from the live prompt when snapshotted; nil at the bottom.
    public var scrollLinesFromBottom: Int?
    public var locked: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, connectionId, connectionName, title, persist, cwd, localShell, serialConfig, webUrl, encoding, scrollLinesFromBottom, locked
    }

    /// id, type and connection fields are required (the entry is dropped otherwise); the rest is sanitized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(SnapshotSessionType.self, forKey: .type)
        connectionId = try c.decode(String.self, forKey: .connectionId)
        connectionName = try c.decode(String.self, forKey: .connectionName)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        persist = (try? c.decode(Bool.self, forKey: .persist)) == true
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        localShell = try? c.decodeIfPresent(String.self, forKey: .localShell)
        serialConfig = try? c.decodeIfPresent(SnapshotSerialConfig.self, forKey: .serialConfig)
        webUrl = try? c.decodeIfPresent(String.self, forKey: .webUrl)
        encoding = try? c.decodeIfPresent(String.self, forKey: .encoding)
        let scroll = (try? c.decodeIfPresent(Double.self, forKey: .scrollLinesFromBottom)) ?? 0
        scrollLinesFromBottom = scroll > 0 ? Int(scroll.rounded(.down)) : nil
        locked = (try? c.decode(Bool.self, forKey: .locked)) == true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(connectionId, forKey: .connectionId)
        try c.encode(connectionName, forKey: .connectionName)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(persist, forKey: .persist)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(localShell, forKey: .localShell)
        try c.encodeIfPresent(serialConfig, forKey: .serialConfig)
        try c.encodeIfPresent(webUrl, forKey: .webUrl)
        try c.encodeIfPresent(encoding, forKey: .encoding)
        try c.encodeIfPresent(scrollLinesFromBottom, forKey: .scrollLinesFromBottom)
        if locked { try c.encode(true, forKey: .locked) } // upstream writes the key only when locked
    }

    init(_ s: SessionInput, cwd: String?, scrollOffset: Int) {
        id = s.id
        type = SnapshotSessionType(rawValue: s.type)!
        connectionId = s.connectionId
        connectionName = s.connectionName
        title = s.title
        persist = s.persist
        self.cwd = cwd
        localShell = s.localShell
        serialConfig = s.serialConfig
        webUrl = type == .web ? s.webUrl : nil
        encoding = s.encoding
        scrollLinesFromBottom = scrollOffset > 0 ? scrollOffset : nil
        locked = s.locked
    }
}

/// Layout payload: layoutStore's split tabs plus the tab strip order and pins.
public struct SnapshotLayout: Codable, Equatable, Sendable {
    public var splitTabs: [SplitTab]
    public var activeSplitTabId: String?
    public var splitTabActive: Bool
    public var titlebarOrder: [String]
    public var pinnedKeys: [String]
    enum CodingKeys: String, CodingKey { case splitTabs, activeSplitTabId, splitTabActive, titlebarOrder, pinnedKeys }
    public init(splitTabs: [SplitTab] = [], activeSplitTabId: String? = nil, splitTabActive: Bool = false, titlebarOrder: [String] = [], pinnedKeys: [String] = []) {
        self.splitTabs = splitTabs; self.activeSplitTabId = activeSplitTabId; self.splitTabActive = splitTabActive
        self.titlebarOrder = titlebarOrder; self.pinnedKeys = pinnedKeys
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: String
    public var activeSessionId: String?
    public var layout: SnapshotLayout
    public var sessions: [SnapshotSession]

    enum CodingKeys: String, CodingKey { case version, savedAt, activeSessionId, layout, sessions }

    /// parseSnapshot: throws (whole snapshot discarded) on an unknown version or a malformed
    /// sessions/layout structure; silently drops malformed session entries, split tabs, and keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == snapshotVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "unknown snapshot version \(version)")
        }
        sessions = try c.decode([Lossy<SnapshotSession>].self, forKey: .sessions).compactMap(\.value)
        savedAt = (try? c.decode(String.self, forKey: .savedAt)) ?? ""
        activeSessionId = try? c.decodeIfPresent(String.self, forKey: .activeSessionId)

        let l = try c.nestedContainer(keyedBy: SnapshotLayout.CodingKeys.self, forKey: .layout)
        // shortcut: a split tab that fails to decode is dropped (the TS passes it through opaque);
        // its id still counts as known for pins, matching the TS.
        let splitTabs = try l.decode([Lossy<SplitTab>].self, forKey: .splitTabs).compactMap(\.value)
        let tabIds = try l.decode([Lossy<TabId>].self, forKey: .splitTabs).compactMap(\.value?.id)
        let titlebarOrder = try l.decode([Lossy<String>].self, forKey: .titlebarOrder).compactMap(\.value)
        let known = Set(sessions.map { "session:\($0.id)" } + tabIds.map { "split:\($0)" })
        let pins = ((try? l.decode([Lossy<String>].self, forKey: .pinnedKeys)) ?? []).compactMap(\.value)
        layout = SnapshotLayout(
            splitTabs: splitTabs,
            activeSplitTabId: try? l.decodeIfPresent(String.self, forKey: .activeSplitTabId),
            splitTabActive: (try? l.decode(Bool.self, forKey: .splitTabActive)) == true,
            titlebarOrder: titlebarOrder,
            pinnedKeys: pins.filter(known.contains)
        )
    }

    public init(version: Int = snapshotVersion, savedAt: String, activeSessionId: String?, layout: SnapshotLayout, sessions: [SnapshotSession]) {
        self.version = version; self.savedAt = savedAt; self.activeSessionId = activeSessionId
        self.layout = layout; self.sessions = sessions
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

private struct TabId: Decodable { let id: String }

/// Validated read of stored snapshot JSON; nil when absent, version-mismatched, or malformed.
public func parseSnapshot(_ data: Data?) -> WorkspaceSnapshot? {
    data.flatMap { try? JSONDecoder().decode(WorkspaceSnapshot.self, from: $0) }
}

// MARK: - Building

/// The app's session as the snapshot builder sees it. `type` is open-ended ("multiplayer", ...).
public struct SessionInput: Sendable {
    public var id: String
    public var type: String
    public var connectionId: String
    public var connectionName: String
    public var title: String?
    public var persist: Bool
    public var encoding: String?
    public var localShell: String?
    public var serialConfig: SnapshotSerialConfig?
    public var webUrl: String?
    /// A docker/lxc exec tab: its parent session id would be stale after a restart.
    public var containerExec: Bool
    public var locked: Bool
    public init(id: String, type: String, connectionId: String, connectionName: String, title: String? = nil, persist: Bool = false,
                encoding: String? = nil, localShell: String? = nil, serialConfig: SnapshotSerialConfig? = nil, webUrl: String? = nil,
                containerExec: Bool = false, locked: Bool = false) {
        self.id = id; self.type = type; self.connectionId = connectionId; self.connectionName = connectionName
        self.title = title; self.persist = persist; self.encoding = encoding; self.localShell = localShell
        self.serialConfig = serialConfig; self.webUrl = webUrl; self.containerExec = containerExec; self.locked = locked
    }

    /// Restorable: a plain ssh/local/serial/web tab. Multiplayer views, container exec tabs,
    /// web tabs without a page and ephemeral serial tabs without a config are skipped.
    public var isSnapshotable: Bool {
        guard let kind = SnapshotSessionType(rawValue: type), !containerExec else { return false }
        if kind == .web && webUrl == nil { return false }
        if kind == .serial && serialConfig == nil { return false }
        return true
    }
}

public func buildSnapshot(
    sessions: [SessionInput],
    cwds: [String: String],
    scrollOffsets: [String: Int] = [:],
    layout: SnapshotLayout,
    activeSessionId: String?,
    now: Date = Date(),
    isTeamConnection: (String) -> Bool = { _ in false }
) -> WorkspaceSnapshot {
    let kept = sessions
        .filter { $0.isSnapshotable && !isTeamConnection($0.connectionId) }
        .map { SnapshotSession($0, cwd: cwds[$0.id], scrollOffset: scrollOffsets[$0.id] ?? 0) }
    return WorkspaceSnapshot(
        savedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now),
        activeSessionId: kept.contains { $0.id == activeSessionId } ? activeSessionId : nil,
        layout: layout,
        sessions: kept
    )
}

// MARK: - Restore (pure steps of workspaceRestore.ts)

extension WorkspaceSnapshot {
    /// The snapshot a launch should restore: nil when restore is off (the app then clears the
    /// stored snapshot), when it is missing or empty, or when tabs are already open.
    public static func toRestore(_ snapshot: WorkspaceSnapshot?, enabled: Bool, hasOpenSessions: Bool) -> WorkspaceSnapshot? {
        guard enabled, let snapshot, !snapshot.sessions.isEmpty, !hasOpenSessions else { return nil }
        return snapshot
    }
}

public enum RestoreStep: Equatable, Sendable {
    /// Web tab: nothing to connect, its page loads when shown.
    case none
    /// ssh/serial: reconnect (attach to tmux when `restore`), then hand to the reconnect loop.
    case reconnect(restore: Bool)
    /// Local shell: respawn in its last directory.
    case spawnLocal(shell: String?, cwd: String?)
}

extension SnapshotSession {
    public var restoreStep: RestoreStep {
        switch type {
        case .web: .none
        case .ssh, .serial: .reconnect(restore: persist)
        case .local: .spawnLocal(shell: localShell, cwd: cwd)
        }
    }
}

extension LayoutStore {
    /// Hydrate from a snapshot, then prune panes whose sessions were not restored
    /// (e.g. a multiplayer pane inside a split).
    public func restore(from snapshot: WorkspaceSnapshot) {
        hydrate(snapshot.layout)
        let restored = Set(snapshot.sessions.map(\.id))
        for id in splitTabs.flatMap(\.root.sessionIds) where !restored.contains(id) {
            removeSession(id)
        }
    }
}
