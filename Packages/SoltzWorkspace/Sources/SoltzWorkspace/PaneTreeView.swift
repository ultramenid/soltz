// SPDX-License-Identifier: AGPL-3.0-only
// Native replacement for components/panes/PaneView.tsx + ResizeHandle.tsx.
// Panes are laid out flat (one ForEach keyed by session id) from computed frames instead of nested
// split views, so splitting, closing or moving a pane never re-creates the other panes' content
// (a terminal's view and scrollback survive any restructure or maximize).
import SwiftUI

/// Gap between panes; the system separator line fills it.
public let paneGap: CGFloat = 1
/// Grab area of a divider, centred on the gap and overlapping the panes beside it.
let dividerHitThickness: CGFloat = 7
private let paneTreeSpace = "SoltzPaneTree"
// shortcut: SDK 27 makes `@State` a macro whose plugin (SwiftUIMacros) ships only with Xcode; this alias reaches the
// property wrapper directly, as SoltzHostsUI does. Go back to `@State` once builds have Xcode.
private typealias ViewState<Value> = SwiftUI.State<Value>

public struct PaneFrame: Equatable, Sendable {
    public let leaf: LeafNode
    public let frame: CGRect
    /// Behind a maximized pane: stays alive at its normal frame but is not shown or hit-tested.
    public let hidden: Bool
}

public struct DividerFrame: Equatable, Sendable {
    public let splitId: String
    public let direction: SplitDirection
    public let ratio: Double
    /// The gap between the split's two sides.
    public let frame: CGRect
    /// The whole split, which a drag position is measured against.
    public let bounds: CGRect
}

/// Frames for every pane and divider of a tree in `rect`. A maximized pane fills `rect`,
/// the rest are hidden and no dividers are shown, like upstream.
public struct PaneLayout: Equatable, Sendable {
    public private(set) var panes: [PaneFrame] = []
    public private(set) var dividers: [DividerFrame] = []

    public init(_ root: PaneNode, in rect: CGRect, maximizedPaneId: String? = nil, gap: CGFloat = paneGap) {
        place(root, in: rect, gap: gap)
        guard let maximizedPaneId, root.contains(pane: maximizedPaneId) else { return }
        panes = panes.map { pane in
            pane.leaf.id == maximizedPaneId
                ? PaneFrame(leaf: pane.leaf, frame: rect, hidden: false)
                : PaneFrame(leaf: pane.leaf, frame: pane.frame, hidden: true)
        }
        dividers = []
    }

    private mutating func place(_ node: PaneNode, in rect: CGRect, gap: CGFloat) {
        switch node {
        case .leaf(let leaf):
            panes.append(PaneFrame(leaf: leaf, frame: rect, hidden: false))
        case .split(let split):
            let edge: CGRectEdge = split.direction == .h ? .minXEdge : .minYEdge
            let length = split.direction == .h ? rect.width : rect.height
            // Whole points keep terminal text on the pixel grid.
            let firstLength = (max(0, length - gap) * split.ratio).rounded()
            let (first, rest) = rect.divided(atDistance: firstLength, from: edge)
            let (gapRect, second) = rest.divided(atDistance: gap, from: edge)
            dividers.append(DividerFrame(splitId: split.id, direction: split.direction, ratio: split.ratio, frame: gapRect, bounds: rect))
            place(split.first, in: first, gap: gap)
            place(split.second, in: second, gap: gap)
        }
    }
}

/// The ratio that puts a divider's centre at `point` (the store clamps it to 0.1...0.9).
public func splitRatio(at point: CGPoint, in bounds: CGRect, direction: SplitDirection, gap: CGFloat = paneGap) -> Double {
    let horizontal = direction == .h
    let length = (horizontal ? bounds.width : bounds.height) - gap
    guard length > 0 else { return 0.5 }
    return ((horizontal ? point.x - bounds.minX : point.y - bounds.minY) - gap / 2) / length
}

/// Renders the active split tab of `store`. `content` builds one pane's view for a session id.
public struct PaneTreeView<Content: View>: View {
    private let store: LayoutStore
    private let motion: Animation?
    private let content: (String) -> Content

    /// `motion` fades a divider's grip in under the pointer; nil shows it at once.
    public init(store: LayoutStore, motion: Animation? = nil, @ViewBuilder content: @escaping (_ sessionId: String) -> Content) {
        self.store = store
        self.motion = motion
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            if let root = store.root {
                let layout = PaneLayout(root, in: CGRect(origin: .zero, size: proxy.size), maximizedPaneId: store.maximizedPaneId)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.panes, id: \.leaf.sessionId) { pane in
                        content(pane.leaf.sessionId)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .opacity(pane.hidden ? 0 : 1)
                            .allowsHitTesting(!pane.hidden)
                            .accessibilityHidden(pane.hidden)
                            .offset(x: pane.frame.minX, y: pane.frame.minY)
                    }
                    ForEach(layout.dividers, id: \.splitId) { divider in
                        PaneDivider(divider: divider, motion: motion) { store.setRatio(divider.splitId, $0) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .coordinateSpace(.named(paneTreeSpace))
            }
        }
    }
}

private struct PaneDivider: View {
    let divider: DividerFrame
    let motion: Animation?
    let setRatio: (Double) -> Void
    @ViewState private var hovering = false
    @GestureState private var dragging = false

    var body: some View {
        let horizontal = divider.direction == .h
        let frame = divider.frame
        // A hit area (the panes draw themselves as cards, so the gap between them is the visible divider), and a
        // grip in the gap while the pointer is over it or drags it.
        Color.clear
        .frame(width: horizontal ? dividerHitThickness : frame.width, height: horizontal ? frame.height : dividerHitThickness)
        .overlay {
            Capsule().fill(.tertiary)
                .frame(width: horizontal ? 3 : 32, height: horizontal ? 32 : 3)
                .opacity(hovering || dragging ? 1 : 0)
                .animation(motion, value: hovering || dragging)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(paneTreeSpace))
                .updating($dragging) { _, dragging, _ in dragging = true }
                .onChanged { drag in
                    setRatio(splitRatio(at: drag.location, in: divider.bounds, direction: divider.direction))
                }
        )
        .onTapGesture(count: 2) { setRatio(0.5) }
        .accessibilityElement()
        .accessibilityLabel("Pane divider")
        .accessibilityValue("\(Int((divider.ratio * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setRatio(divider.ratio + 0.05)
            case .decrement: setRatio(divider.ratio - 0.05)
            default: break
            }
        }
        .offset(x: horizontal ? frame.midX - dividerHitThickness / 2 : frame.minX,
                y: horizontal ? frame.minY : frame.midY - dividerHitThickness / 2)
    }
}
