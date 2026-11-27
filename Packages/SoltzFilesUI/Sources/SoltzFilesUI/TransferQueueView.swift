// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// The Transfers card: one row per item with its route, state, progress and the one action that state has
/// (Stop or Retry), plus Stop All and Clear in the title row (upstream TransferQueue.tsx). It draws nothing
/// while the queue is empty. Pair it with `.transferConflicts(queue)` somewhere visible.
public struct TransferQueueView: View {
    private let queue: TransferQueue
    @Environment(\.filesStyle) private var style

    public init(queue: TransferQueue) {
        self.queue = queue
    }

    public var body: some View {
        if !queue.transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Transfers").font(style.title)
                    Spacer()
                    if queue.transfers.count(where: { $0.status == .running || $0.status == .queued }) > 1 {
                        Button("Stop All") { queue.cancelAll() }.help("Stop every running and queued transfer").transition(.opacity)
                    }
                    if queue.transfers.contains(where: \.settled) {
                        Button("Clear") { queue.clearCompleted() }.help("Clear finished transfers").transition(.opacity)
                    }
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(queue.transfers) { row in TransferRow(row: row, queue: queue).transition(.opacity) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Hugs its rows up to about five, then scrolls.
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Rows arrive and leave, and a row's bar and button change with its state, in the app's one motion.
            .animation(style.motion, value: queue.transfers.map(\.id))
            .animation(style.motion, value: queue.transfers.map(\.status))
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(12)
            .glassEffect(.regular, in: style.cardShape)
        }
    }
}

private struct TransferRow: View {
    let row: TransferQueue.Transfer
    let queue: TransferQueue
    @Environment(\.filesStyle) private var style

    var body: some View {
        let line = FileRules.transferLine(row)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(row.label).font(style.row.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text(line).font(style.detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.middle).help(line)
                // A fixed slot, so every row's text ends at the same place whether it has an action or not.
                ZStack(alignment: .trailing) {
                    if queue.canRetry(row.id) {
                        Button("Retry") { queue.retry(row.id) }.help("Retry, keeping what already arrived")
                    } else if row.status == .running || row.status == .queued {
                        Button("Stop") { queue.cancel(row.id) }.help("Stop this transfer")
                    }
                }
                .frame(width: 56, alignment: .trailing)
            }
            if row.status == .running {
                Group {
                    if row.total > 0 {
                        ProgressView(value: Double(min(row.transferred, row.total)), total: Double(row.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .tint(Color.primary)
                .controlSize(.mini)
                .accessibilityLabel("Progress")
                .transition(.opacity)
            }
            if !row.skipped.isEmpty {
                DisclosureGroup("\(row.skipped.count) \(row.skipped.count == 1 ? "item" : "items") skipped") {
                    ForEach(row.skipped, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows the queue's conflict prompts one at a time: Finder's replace sheet with Stop, Skip and Replace
    /// (Merge for a folder onto a folder) and "Apply to All" while more of the same batch waits.
    public func transferConflicts(_ queue: TransferQueue) -> some View {
        // Dismissal only ever comes from the sheet's buttons, which answer the prompt themselves.
        sheet(item: Binding(get: { queue.conflicts.first }, set: { _ in })) { pending in
            ConflictSheet(pending: pending) { queue.resolveConflict(pending.id, $0) }
        }
    }
}

private struct ConflictSheet: View {
    let pending: TransferQueue.PendingConflict
    let resolve: (ConflictResolution) -> Void
    @ViewState private var applyToAll = false

    var body: some View {
        let conflict = pending.conflict
        let merge = conflict.source.isDir && conflict.destinationIsDir
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: conflict.source.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text("An item named “\(conflict.source.name)” already exists in this location.").font(.headline)
                    Text(merge ? "Merging keeps what is there and replaces files with the same names."
                               : "Do you want to replace it with the one you’re copying?")
                        .foregroundStyle(.secondary)
                }
            }
            if pending.hasMore {
                Toggle("Apply to All", isOn: $applyToAll)
            }
            HStack {
                Button("Stop", role: .cancel) { resolve(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(merge ? "Merge" : "Replace") { resolve(applyToAll ? .overwriteAll : .overwrite) }
                // The default: Return never replaces a file.
                Button("Skip") { resolve(applyToAll ? .skipAll : .skip) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}
