// SPDX-License-Identifier: AGPL-3.0-only
// Port of the zustand store in core/src/stores/layoutStore.ts. Like the TS, the active split tab
// is mirrored into the flat `root`/`activePaneId`/... fields; every operation keeps both in step.
import Observation

@Observable
public final class LayoutStore {
    public var root: PaneNode?
    public var activePaneId: String?
    public var maximizedPaneId: String?
    public var splitTabActive = false
    public var splitTabs: [SplitTab] = []
    public var activeSplitTabId: String?
    /// Tab strip order of `session:<id>` / `split:<id>` keys.
    public var titlebarOrder: [String] = []
    public var pinnedKeys: [String] = []

    public init() {}

    /// `split:<id>` when a split tab is showing, else `session:<activeSessionId>` (services/tabLock.ts).
    public func activeTabKey(activeSessionId: String?) -> String? {
        if splitTabActive, let activeSplitTabId { return "split:\(activeSplitTabId)" }
        return activeSessionId.map { "session:\($0)" }
    }

    // MARK: - Operations

    public func setPinned(_ key: String, _ pinned: Bool) {
        pinnedKeys = pinnedKeys.filter { $0 != key } + (pinned ? [key] : [])
    }

    public func openSplitTab(_ sessionId: String? = nil) {
        guard let sessionId, !sessionId.isEmpty else { splitTabActive = true; return }
        if let existing = root?.findLeaf(session: sessionId) {
            focus(existing.id)
            return
        }
        guard let root else { appendTab(newLeaf(sessionId)); return }
        let target = root.findLeaf(activePaneId) ?? root.firstLeaf
        insert(newLeaf(sessionId), splitting: target, position: .right, in: root)
    }

    /// Name a split tab. A blank name clears it, so the label derives again.
    public func renameSplitTab(_ tabId: String, _ name: String?) {
        for i in splitTabs.indices where splitTabs[i].id == tabId { splitTabs[i].name = normalizeTabTitle(name) }
    }

    public func setSplitTabActive(_ active: Bool) { splitTabActive = active }

    public func activateSplitTab(_ tabId: String) {
        guard let tab = splitTabs.first(where: { $0.id == tabId }) else { return }
        show(tab)
    }

    public func closeSplitTab(_ tabId: String) {
        let key = "split:\(tabId)"
        splitTabs.removeAll { $0.id == tabId }
        pinnedKeys.removeAll { $0 == key }
        guard activeSplitTabId == tabId else { return }
        titlebarOrder.removeAll { $0 == key }
        show(splitTabs.last)
    }

    public func placeTitlebarItem(_ itemKey: String, _ targetKey: String?, _ placement: TitlebarPlacement) {
        titlebarOrder = SoltzWorkspace.placeTitlebarItem(titlebarOrder, itemKey, targetKey, placement)
    }

    public func syncTitlebarOrder(_ visibleKeys: [String], groupOf: ((String) -> String?)? = nil) {
        let merged = mergeTitlebarItems(titlebarOrder, visibleKeys)
        let next = groupOf.map { gatherGroups(merged, $0) } ?? merged
        if next != titlebarOrder { titlebarOrder = next }
    }

    public func reorderTitlebarItem(_ sourceKeys: [String], _ targetKey: String?, _ placement: TitlebarPlacement) {
        if let targetKey, sourceKeys.contains(targetKey) { return }
        titlebarOrder = placeTitlebarBlock(titlebarOrder, sourceKeys, targetKey, placement)
    }

    public func createSplitTab(_ targetSessionId: String, _ incomingSessionId: String, _ position: SplitPosition) {
        guard targetSessionId != incomingSessionId,
              findSessionPane(splitTabs, targetSessionId) == nil,
              findSessionPane(splitTabs, incomingSessionId) == nil else { return }
        let incoming = LeafNode(id: newPaneId(), sessionId: incomingSessionId)
        let root = splitLeaf(LeafNode(id: newPaneId(), sessionId: targetSessionId), incoming, position)
        let tab = SplitTab(id: newSplitTabId(), root: root, activePaneId: incoming.id)
        let targetPinned = pinnedKeys.contains("session:\(targetSessionId)")
        pinnedKeys = withoutSessionKeys(pinnedKeys, [targetSessionId, incomingSessionId]) + (targetPinned ? ["split:\(tab.id)"] : [])
        splitTabs.append(tab)
        show(tab)
    }

    public func splitPane(_ targetPaneId: String, _ sessionId: String, _ position: SplitPosition) {
        if let existing = root?.findLeaf(session: sessionId) {
            focus(existing.id)
            return
        }
        if findSessionPane(splitTabs, sessionId) != nil { return }
        guard let root else { appendTab(newLeaf(sessionId)); return }
        guard let target = root.findLeaf(targetPaneId) else { return }
        insert(newLeaf(sessionId), splitting: target, position: position, in: root)
        pinnedKeys = withoutSessionKeys(pinnedKeys, [sessionId])
    }

    /// Shows `sessionId` in the pane `paneId` of the active tab and returns the session that was there. A session
    /// with a pane of its own in the tab changes places with it; one in another tab is left where it is.
    @discardableResult
    public func swapSession(in paneId: String, with sessionId: String) -> String? {
        guard let root, let target = root.findLeaf(paneId), target.sessionId != sessionId else { return nil }
        let other = root.findLeaf(session: sessionId)
        if other == nil, findSessionPane(splitTabs, sessionId) != nil { return nil }
        var next = root.replacingLeaf(target.id, with: .leaf(LeafNode(id: target.id, sessionId: sessionId)))
        if let other { next = next.replacingLeaf(other.id, with: .leaf(LeafNode(id: other.id, sessionId: target.sessionId))) }
        updateActiveTab { $0.root = next }
        self.root = next
        focus(target.id)
        return target.sessionId
    }

    public func movePane(_ sourcePaneId: String, _ targetPaneId: String, _ position: SplitPosition) {
        guard let root, sourcePaneId != targetPaneId else { return }
        let (withoutSource, removed) = root.removingLeaf(sourcePaneId)
        guard let removed, let withoutSource else { return }
        guard let target = withoutSource.findLeaf(targetPaneId) else {
            updateActiveTab { $0.root = withoutSource }
            self.root = withoutSource
            return
        }
        insert(removed, splitting: target, position: position, in: withoutSource)
    }

    /// Takes a pane out of the active split tab and returns its session id.
    /// A tab left with one pane closes and hands its strip slot and pin to that pane's session.
    @discardableResult
    public func detachPane(_ paneId: String) -> String? {
        guard let root, let removedLeaf = root.findLeaf(paneId) else { return nil }
        let rest = root.removingLeaf(paneId).root
        guard let rest, !rest.isLeaf else {
            if let tabId = activeSplitTabId {
                splitTabs.removeAll { $0.id == tabId }
                handOverSplitKey("split:\(tabId)", to: rest.map { "session:\($0.firstLeaf.sessionId)" })
            }
            show(splitTabs.last)
            return removedLeaf.sessionId
        }
        let nextActive = (rest.findLeaf(activePaneId) ?? rest.firstLeaf).id
        let maximized = maximizedPaneId == paneId ? nil : maximizedPaneId
        updateActiveTab {
            $0.root = rest
            $0.activePaneId = nextActive
            $0.maximizedPaneId = maximized
        }
        self.root = rest
        activePaneId = nextActive
        maximizedPaneId = maximized
        return removedLeaf.sessionId
    }

    public func removeSession(_ sessionId: String) {
        titlebarOrder.removeAll { $0 == "session:\(sessionId)" }
        pinnedKeys = withoutSessionKeys(pinnedKeys, [sessionId])
        let tabs = splitTabs.compactMap { tab -> SplitTab? in
            if let next = withoutSession(tab, sessionId) { return next }
            let ids = tab.root.sessionIds
            if ids.contains(sessionId), let survivor = ids.first(where: { $0 != sessionId }) {
                handOverSplitKey("split:\(tab.id)", to: "session:\(survivor)")
            }
            return nil
        }
        splitTabs = tabs
        show(tabs.first { $0.id == activeSplitTabId } ?? tabs.last)
    }

    public func setRatio(_ splitNodeId: String, _ ratio: Double) {
        guard let root else { return }
        let next = root.updatingRatio(splitNodeId, ratio)
        updateActiveTab { $0.root = next }
        self.root = next
    }

    public func setActivePane(_ paneId: String) {
        focus(paneId)
    }

    public func setMaximized(_ paneId: String?) {
        updateActiveTab { $0.maximizedPaneId = paneId }
        maximizedPaneId = paneId
    }

    /// One new split tab around the sessions not already in a split; if fewer than two are fresh,
    /// focuses the existing split holding one of them instead.
    public func openSessions(_ sessionIds: [String]) {
        var seen = Set<String>()
        let uniqueIds = sessionIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        let freshIds = uniqueIds.filter { findSessionPane(splitTabs, $0) == nil }
        if freshIds.count < min(2, uniqueIds.count) {
            guard let existing = uniqueIds.lazy.compactMap({ findSessionPane(self.splitTabs, $0) }).first,
                  var tab = splitTabs.first(where: { $0.id == existing.tabId }) else { return }
            tab.activePaneId = existing.paneId
            splitTabs = splitTabs.map { $0.id == tab.id ? tab : $0 }
            show(tab)
            return
        }
        let leaves = freshIds.map { LeafNode(id: newPaneId(), sessionId: $0) }
        guard let root = buildBalancedTree(leaves[...]) else { return }
        let tab = SplitTab(id: newSplitTabId(), root: root, activePaneId: leaves.last?.id)
        splitTabs.append(tab)
        pinnedKeys = withoutSessionKeys(pinnedKeys, freshIds)
        show(tab)
    }

    /// Workspace restore: replaces layout state wholesale. A session that already appeared in an
    /// earlier tab is dropped from later ones (older snapshots could hold it twice).
    public func hydrate(_ saved: SnapshotLayout) {
        var seen = Set<String>()
        let tabs = saved.splitTabs.compactMap { tab -> SplitTab? in
            let next = tab.root.sessionIds.reduce(Optional(tab)) { kept, id in
                guard let kept, seen.contains(id) else { return kept }
                return withoutSession(kept, id)
            }
            next?.root.sessionIds.forEach { seen.insert($0) }
            return next
        }
        let activeTab = tabs.first { $0.id == saved.activeSplitTabId } ?? tabs.last
        splitTabs = tabs
        titlebarOrder = saved.titlebarOrder
        pinnedKeys = saved.pinnedKeys
        show(activeTab)
        splitTabActive = saved.splitTabActive && activeTab != nil
    }

    /// The layout part of a workspace snapshot.
    public var snapshotLayout: SnapshotLayout {
        SnapshotLayout(splitTabs: splitTabs, activeSplitTabId: activeSplitTabId, splitTabActive: splitTabActive,
                       titlebarOrder: titlebarOrder, pinnedKeys: pinnedKeys)
    }

    // MARK: - Helpers

    /// fieldsFromTab: mirror `tab` (or nothing) into the flat active-tab fields.
    private func show(_ tab: SplitTab?) {
        root = tab?.root
        activePaneId = tab?.activePaneId
        maximizedPaneId = tab?.maximizedPaneId
        activeSplitTabId = tab?.id
        splitTabActive = tab != nil
    }

    private func updateActiveTab(_ update: (inout SplitTab) -> Void) {
        guard let activeSplitTabId else { return }
        for i in splitTabs.indices where splitTabs[i].id == activeSplitTabId { update(&splitTabs[i]) }
    }

    private func focus(_ paneId: String) {
        updateActiveTab { $0.activePaneId = paneId }
        activePaneId = paneId
        splitTabActive = true
    }

    private func newLeaf(_ sessionId: String) -> LeafNode { LeafNode(id: newPaneId(), sessionId: sessionId) }

    private func appendTab(_ leaf: LeafNode) {
        let tab = SplitTab(id: newSplitTabId(), root: .leaf(leaf), activePaneId: leaf.id)
        splitTabs.append(tab)
        show(tab)
    }

    /// Replace `target` in `root` with a split of target + `leaf`, focusing `leaf`.
    private func insert(_ leaf: LeafNode, splitting target: LeafNode, position: SplitPosition, in root: PaneNode) {
        let next = root.splitting(target.id, with: leaf, position)
        updateActiveTab {
            $0.root = next
            $0.activePaneId = leaf.id
            $0.maximizedPaneId = nil
        }
        self.root = next
        activePaneId = leaf.id
        maximizedPaneId = nil
        splitTabActive = true
    }

    /// A collapsing split hands its strip slot and pin to the survivor, or drops them.
    private func handOverSplitKey(_ splitKey: String, to survivorKey: String?) {
        let move = { (list: [String]) in survivorKey.map { replaceKey(list, splitKey, $0) } ?? list.filter { $0 != splitKey } }
        titlebarOrder = move(titlebarOrder)
        pinnedKeys = move(pinnedKeys)
    }

    private func withoutSessionKeys(_ keys: [String], _ sessionIds: [String]) -> [String] {
        keys.filter { key in !sessionIds.contains { key == "session:\($0)" } }
    }
}
