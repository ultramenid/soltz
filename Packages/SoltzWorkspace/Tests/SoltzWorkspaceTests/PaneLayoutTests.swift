// SPDX-License-Identifier: AGPL-3.0-only
// The geometry PaneTreeView renders from (the view itself needs a window and is not tested).
// Also ports ResizeHandle.test.tsx's double-click reset as the 0.5 the divider sends.
import CoreGraphics
import Testing
@testable import SoltzWorkspace

@Suite struct PaneGeometry {
    let rect = CGRect(x: 0, y: 0, width: 201, height: 100)

    @Test func aHorizontalSplitSitsSideBySideAroundTheGap() {
        let layout = PaneLayout(twoPanes, in: rect, gap: 1)
        #expect(layout.panes.map(\.frame) == [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 101, y: 0, width: 100, height: 100)])
        #expect(layout.dividers.map(\.frame) == [CGRect(x: 100, y: 0, width: 1, height: 100)])
        #expect(layout.dividers.first?.bounds == rect)
        #expect(layout.panes.allSatisfy { !$0.hidden })
    }

    @Test func nestedSplitsDivideTheirOwnSide() {
        let tree = split("outer", leaf("a", "sa"), split("inner", leaf("b", "sb"), leaf("c", "sc"), .v, ratio: 0.25), ratio: 0.5)
        let layout = PaneLayout(tree, in: rect, gap: 1)
        #expect(layout.panes.map(\.leaf.sessionId) == ["sa", "sb", "sc"])
        #expect(layout.panes[1].frame == CGRect(x: 101, y: 0, width: 100, height: 25)) // (100 - 1) * 0.25 rounded
        #expect(layout.panes[2].frame == CGRect(x: 101, y: 26, width: 100, height: 74))
        #expect(layout.dividers.map(\.splitId) == ["outer", "inner"])
        #expect(layout.dividers[1].bounds == CGRect(x: 101, y: 0, width: 100, height: 100))
    }

    @Test func aMaximizedPaneFillsTheContainerAndHidesTheRest() {
        let layout = PaneLayout(twoPanes, in: rect, maximizedPaneId: "p2", gap: 1)
        #expect(layout.panes.map(\.hidden) == [true, false])
        #expect(layout.panes[1].frame == rect)
        #expect(layout.panes[0].frame == CGRect(x: 0, y: 0, width: 100, height: 100), "hidden panes keep their size")
        #expect(layout.dividers.isEmpty)
        #expect(PaneLayout(twoPanes, in: rect, maximizedPaneId: "gone", gap: 1).dividers.count == 1, "a stale id maximizes nothing")
    }

    @Test func draggingPutsTheDividerCentreUnderThePointer() {
        let bounds = CGRect(x: 50, y: 20, width: 201, height: 100)
        #expect(splitRatio(at: CGPoint(x: 50 + 100.5, y: 0), in: bounds, direction: .h, gap: 1) == 0.5)
        #expect(splitRatio(at: CGPoint(x: 0, y: 20 + 50), in: bounds, direction: .v, gap: 1) == 0.5) // (100 - 1) / 2 + 0.5
        #expect(splitRatio(at: CGPoint(x: 0, y: 0), in: .zero, direction: .h, gap: 1) == 0.5, "degenerate bounds")
    }

    @Test func theStoreClampsWhatADragOrDoubleClickSends() throws {
        let store = LayoutStore()
        store.root = split("split", leaf("a", "a"), leaf("b", "b"), ratio: 0.8)
        store.setRatio("split", 0.5) // divider double-click
        guard case .split(let node) = try #require(store.root) else { return }
        #expect(node.ratio == 0.5)
        store.setRatio("split", splitRatio(at: CGPoint(x: -40, y: 0), in: rect, direction: .h))
        guard case .split(let dragged) = try #require(store.root) else { return }
        #expect(dragged.ratio == 0.1)
    }
}
