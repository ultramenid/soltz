// SPDX-License-Identifier: AGPL-3.0-only
// Ports of layoutStore.test.ts, layoutStore.pinned.test.ts, layoutStore.titlebarBlock.test.ts
// and utils/titlebarOrder.test.ts. Each test gets a fresh store instead of zustand setState.
import Testing
@testable import SoltzWorkspace

func leaf(_ id: String, _ sessionId: String) -> PaneNode { .leaf(LeafNode(id: id, sessionId: sessionId)) }
func split(_ id: String, _ first: PaneNode, _ second: PaneNode, _ direction: SplitDirection = .h, ratio: Double = 0.5) -> PaneNode {
    .split(SplitNode(id: id, direction: direction, ratio: ratio, first: first, second: second))
}

let twoPanes = split("sp1", leaf("p1", "s1"), leaf("p2", "s2"))

@Suite struct RenameSplitTab {
    let store: LayoutStore = {
        let store = LayoutStore()
        store.splitTabs = [SplitTab(id: "t1", root: twoPanes, activePaneId: "p1"), SplitTab(id: "t2", root: twoPanes, activePaneId: "p1")]
        store.activeSplitTabId = "t1"
        return store
    }()
    var names: [String?] { store.splitTabs.map(\.name) }

    @Test func namesTheTabItIsGivenNotTheActiveOne() {
        store.renameSplitTab("t2", "prod")
        #expect(names == [nil, "prod"])
    }

    @Test func storesWhatTheUserTypedTrimmed() {
        store.renameSplitTab("t1", "  prod  ")
        #expect(names[0] == "prod")
    }

    @Test func aBlankNameReturnsTheTabToDerivingFromItsActivePane() {
        store.renameSplitTab("t1", "prod")
        store.renameSplitTab("t1", "")
        #expect(names[0] == nil)
    }
}

@Suite struct OneSplitTabPerSession {
    func splitSessionIds(_ store: LayoutStore) -> [String] { store.splitTabs.flatMap(\.root.sessionIds) }

    @Test func openSessionsBuildsNoTabAroundASessionAlreadyInASplitAndFocusesItInstead() throws {
        let store = LayoutStore()
        store.createSplitTab("a1", "a2", .right)
        let t1 = try #require(store.splitTabs.first)
        store.createSplitTab("c1", "c2", .right)

        store.openSessions(["a1", "b1"])
        #expect(store.splitTabs.count == 2)
        #expect(store.activeSplitTabId == t1.id)
        #expect(splitSessionIds(store).filter { $0 == "a1" }.count == 1)

        store.openSessions(["a1", "b1", "b2"])
        #expect(store.root?.sessionIds == ["b1", "b2"])
        #expect(Set(splitSessionIds(store)).count == splitSessionIds(store).count)
    }

    @Test func hydrateDropsASessionsSecondPaneFromAnOlderCorruptedSnapshot() {
        func tab(_ id: String, _ a: String, _ b: String) -> SplitTab {
            SplitTab(id: id, root: split("\(id)-sp", leaf("\(id)-p1", a), leaf("\(id)-p2", b)), activePaneId: "\(id)-p2")
        }
        var three = tab("t3", "c1", "a2")
        three.root = split("t3-sp", tab("t3", "c1", "a2").root, leaf("t3-p3", "c2"))
        let store = LayoutStore()
        store.hydrate(SnapshotLayout(
            splitTabs: [tab("t1", "a1", "a2"), tab("t2", "b1", "a1"), three],
            activeSplitTabId: "t2", splitTabActive: true, titlebarOrder: ["split:t1", "split:t2", "split:t3"]
        ))

        #expect(store.splitTabs.map(\.id) == ["t1", "t3"])
        #expect(store.splitTabs[1].root.sessionIds == ["c1", "c2"])
        #expect(store.splitTabs[1].activePaneId == "t3-p1")
        #expect(Set(splitSessionIds(store)).count == splitSessionIds(store).count)
        #expect(store.activeSplitTabId == "t3")
    }
}

@Suite struct PinnedTitlebarKeys {
    let splitT = SplitTab(id: "T", root: split("sp", leaf("p1", "s1"), leaf("p2", "s2")), activePaneId: "p2")

    func withPinnedSplit() -> LayoutStore {
        let store = LayoutStore()
        store.hydrate(SnapshotLayout(splitTabs: [splitT], activeSplitTabId: "T", splitTabActive: true,
                                     titlebarOrder: ["session:a", "split:T", "session:b"], pinnedKeys: ["split:T"]))
        return store
    }

    @Test func setPinnedAddsOnceAndRemoves() {
        let store = LayoutStore()
        store.setPinned("session:s1", true)
        store.setPinned("session:s1", true)
        #expect(store.pinnedKeys == ["session:s1"])
        store.setPinned("session:s1", false)
        #expect(store.pinnedKeys == [])
    }

    @Test func aSplitCreatedFromAPinnedTabIsPinned() {
        let store = LayoutStore()
        store.setPinned("session:s1", true)
        store.createSplitTab("s1", "s2", .right)
        #expect(store.pinnedKeys.contains("split:\(store.splitTabs[0].id)"))
    }

    @Test func aSplitCollapsingOnRemoveSessionHandsItsPlaceAndPinToTheSurvivor() {
        let store = withPinnedSplit()
        store.removeSession("s2")
        #expect(store.titlebarOrder == ["session:a", "session:s1", "session:b"])
        #expect(store.pinnedKeys == ["session:s1"])
    }

    @Test func aSplitCollapsingOnDetachPaneHandsItsPlaceAndPinToTheRemainingPaneOnly() {
        let store = withPinnedSplit()
        let detached = store.detachPane("p2")
        #expect(detached == "s2")
        #expect(store.titlebarOrder == ["session:a", "session:s1", "session:b"])
        #expect(store.pinnedKeys == ["session:s1"])
    }

    @Test func closingASplitTabOrRemovingASessionDropsItsPin() {
        let store = withPinnedSplit()
        store.setPinned("session:x", true)
        store.closeSplitTab("T")
        #expect(store.pinnedKeys == ["session:x"])
        store.removeSession("x")
        #expect(store.pinnedKeys == [])
    }

    @Test func sessionsGatheredIntoANewSplitByOpenSessionsLoseTheirStandalonePin() {
        let store = LayoutStore()
        store.setPinned("session:a", true)
        store.openSessions(["a", "b"])
        #expect(store.pinnedKeys == [])
    }
}

@Suite struct TitlebarBlocks {
    let groupOf: (String) -> String? = { $0.hasPrefix("session:w") ? "web" : nil }

    @Test func gathersAHostsKeysBehindItsFirstKeyWhenAGroupFunctionIsGiven() {
        let store = LayoutStore()
        store.syncTitlebarOrder(["session:w1", "session:d1", "session:w2"], groupOf: groupOf)
        #expect(store.titlebarOrder == ["session:w1", "session:w2", "session:d1"])
    }

    @Test func keepsTheFlatMergeWhenNoGroupFunctionIsGiven() {
        let store = LayoutStore()
        store.syncTitlebarOrder(["session:w1", "session:d1", "session:w2"])
        #expect(store.titlebarOrder == ["session:w1", "session:d1", "session:w2"])
    }

    @Test func movesSeveralKeysAsOneBlock() {
        let store = LayoutStore()
        store.titlebarOrder = ["session:d1", "session:w1", "session:w2", "session:x"]
        store.reorderTitlebarItem(["session:w1", "session:w2"], "session:d1", .before)
        #expect(store.titlebarOrder == ["session:w1", "session:w2", "session:d1", "session:x"])
    }

    @Test func ignoresADropOntoOneOfTheMovingKeys() {
        let store = LayoutStore()
        store.titlebarOrder = ["session:w1", "session:w2"]
        store.reorderTitlebarItem(["session:w1", "session:w2"], "session:w2", .after)
        #expect(store.titlebarOrder == ["session:w1", "session:w2"])
    }
}

@Suite struct TitlebarOrder {
    let order = ["a", "b", "c", "d", "e"]

    @Test func movesSeveralKeysAsOneBlockBeforeTheTargetKeepingTheirOrder() {
        #expect(placeTitlebarBlock(order, ["d", "b"], "a", .before) == ["b", "d", "a", "c", "e"])
    }

    @Test func movesABlockAfterTheTarget() {
        #expect(placeTitlebarBlock(order, ["a", "b"], "d", .after) == ["c", "d", "a", "b", "e"])
    }

    @Test func appendsWhenThereIsNoTarget() {
        #expect(placeTitlebarBlock(order, ["b"], nil, .after) == ["a", "c", "d", "e", "b"])
    }

    @Test func appendsKeysThatWereNotInTheOrderYet() {
        #expect(placeTitlebarBlock(order, ["x"], "c", .before) == ["a", "b", "x", "c", "d", "e"])
    }

    @Test func placeTitlebarItemIsTheOneKeyCase() {
        #expect(placeTitlebarItem(order, "e", "a", .before) == placeTitlebarBlock(order, ["e"], "a", .before))
    }

    let groups = ["a1": "A", "a2": "A", "a3": "A", "b1": "B"]

    @Test func pullsLaterMembersOfAGroupUpBehindItsFirstMember() {
        #expect(gatherGroups(["a1", "b1", "x", "a2", "a3"], { groups[$0] }) == ["a1", "a2", "a3", "b1", "x"])
    }

    @Test func isStableWhenGroupsAreAlreadyContiguous() {
        let order = ["x", "a1", "a2", "b1"]
        #expect(gatherGroups(order, { groups[$0] }) == order)
    }

    @Test func leavesUngroupedKeysWhereTheyAre() {
        #expect(gatherGroups(["x", "y"], { groups[$0] }) == ["x", "y"])
    }
}

/// Not in the TS suite: the tree operations the ported tests only touch indirectly.
@Suite struct PaneOperations {
    @Test func splitPaneSplitsTheTargetAndFocusesTheNewPane() throws {
        let store = LayoutStore()
        store.createSplitTab("s1", "s2", .right)
        let target = try #require(store.root?.findLeaf(session: "s1"))
        store.setMaximized(target.id)
        store.splitPane(target.id, "s3", .bottom)
        let root = try #require(store.root)
        #expect(root.sessionIds == ["s1", "s3", "s2"])
        #expect(store.activePaneId == root.findLeaf(session: "s3")?.id)
        #expect(store.maximizedPaneId == nil)
        #expect(store.splitTabs[0].root == root)
    }

    @Test func movePaneReattachesTheSameLeafBesideTheTarget() throws {
        let store = LayoutStore()
        store.openSessions(["a", "b", "c"])
        let root = try #require(store.root)
        let a = try #require(root.findLeaf(session: "a")), c = try #require(root.findLeaf(session: "c"))
        store.movePane(a.id, c.id, .left)
        #expect(store.root?.sessionIds == ["b", "a", "c"])
        #expect(store.root?.findLeaf(session: "a") == a)
        #expect(store.activePaneId == a.id)
    }

    @Test func setRatioClampsAndUpdatesTheActiveTab() throws {
        let store = LayoutStore()
        store.createSplitTab("s1", "s2", .right)
        guard case .split(let node) = try #require(store.root) else { Issue.record("expected a split"); return }
        store.setRatio(node.id, 0.95)
        guard case .split(let updated) = try #require(store.splitTabs.first?.root) else { return }
        #expect(updated.ratio == 0.9)
        #expect(store.root == store.splitTabs.first?.root)
    }

    @Test func openSessionsBuildsABalancedTree() throws {
        let store = LayoutStore()
        store.openSessions(["a", "b", "c", "", "a"])
        guard case .split(let top) = try #require(store.root) else { Issue.record("expected a split"); return }
        #expect(top.direction == .v)
        #expect(top.first.sessionIds == ["a", "b"])
        #expect(top.second.sessionIds == ["c"])
        #expect(store.activePaneId == store.root?.findLeaf(session: "c")?.id)
    }
}
