// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Two pane cards side by side, each on the provider the caller picks (host ↔ local, host ↔ host), with
/// drag and drop between the panes and the Transfers card docked below (a hint about dragging while it is empty). It
/// paints nothing outside its glass cards, so the caller's backdrop shows through.
public struct DualPaneView: View {
    private let left: any FileProvider
    private let right: any FileProvider
    private let queue: TransferQueue
    @Environment(\.filesStyle) private var style
    private let leftSource: AnyView?
    private let rightSource: AnyView?

    @ViewState private var leftPath: String
    @ViewState private var rightPath: String
    @ViewState private var leftReload = 0
    @ViewState private var rightReload = 0
    /// The left pane's share of the width; the gap between the panes drags it.
    @ViewState private var split = 0.5
    private static let minPane: CGFloat = 320

    /// - Parameters:
    ///   - queue: usually one for the whole app, as upstream's queue is global.
    ///   - leftPath, rightPath: where each pane opens; empty is the provider's home.
    ///   - leftSource, rightSource: shown first in each pane's header, e.g. a source popup; nil shows the provider's name.
    public init(left: any FileProvider, right: any FileProvider, queue: TransferQueue,
                leftPath: String = "", rightPath: String = "",
                leftSource: AnyView? = nil, rightSource: AnyView? = nil) {
        self.left = left
        self.right = right
        self.queue = queue
        self.leftSource = leftSource
        self.rightSource = rightSource
        _leftPath = ViewState(initialValue: leftPath)
        _rightPath = ViewState(initialValue: rightPath)
    }

    public var body: some View {
        // Spacing below the gaps between cards: neighbouring cards share one glass pass but never melt together.
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: style.gap) {
                GeometryReader { geometry in
                    let width = max(0, geometry.size.width - style.gap)
                    let left = min(max(width * split, Self.minPane), max(Self.minPane, width - Self.minPane))
                    HStack(spacing: 0) {
                        pane(.left).frame(width: left)
                        // Only a hit area: the gap between the cards is the visible divider.
                        Color.clear.frame(width: style.gap).contentShape(.rect)
                            .pointerStyle(.columnResize)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("files-split")).onChanged { drag in
                                guard width > 0 else { return }
                                split = min(max((drag.location.x - style.gap / 2) / width, 0.1), 0.9)
                            })
                            .onTapGesture(count: 2) { split = 0.5 }
                            .accessibilityElement()
                            .accessibilityLabel("Pane divider")
                            .accessibilityValue("\(Int((split * 100).rounded())) percent")
                            .accessibilityAdjustableAction { split = min(max(split + ($0 == .increment ? 0.05 : -0.05), 0.1), 0.9) }
                        pane(.right)
                    }
                    .coordinateSpace(.named("files-split"))
                }
                .frame(minWidth: Self.minPane * 2 + style.gap, minHeight: 200)
                TransferQueueView(queue: queue).transition(.move(edge: .bottom).combined(with: .opacity))
                if queue.transfers.isEmpty {
                    // Copying is by dragging; this line is where to learn it.
                    Text("Drag files from one side to the other to copy them")
                        .font(style.detail).foregroundStyle(.secondary).transition(.opacity)
                }
            }
            .animation(style.motion, value: queue.transfers.isEmpty)
        }
        .transferConflicts(queue)
    }

    private enum Side { case left, right }

    private func pane(_ side: Side) -> some View {
        FilePaneView(provider: provider(side),
                     path: side == .left ? $leftPath : $rightPath,
                     reloadID: side == .left ? leftReload : rightReload,
                     source: side == .left ? leftSource : rightSource,
                     onTransfer: { send($0, from: side) },
                     onEdit: { items, app in
                         for item in items { queue.edit(item, on: provider(side)) { FilePaneView.open($0, with: app) } }
                     },
                     onReceive: { items, source, folder in
                         queue.enqueue(items, from: source, to: provider(side), into: folder) { reload(side) }
                     })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func provider(_ side: Side) -> any FileProvider { side == .left ? left : right }

    private func send(_ items: [FileEntry], from side: Side) {
        let to: Side = side == .left ? .right : .left
        let folder = to == .left ? leftPath : rightPath
        guard !folder.isEmpty else { return }
        queue.enqueue(items, from: provider(side), to: provider(to), into: folder) { reload(to) }
    }

    private func reload(_ side: Side) {
        if side == .left { leftReload += 1 } else { rightReload += 1 }
    }
}
