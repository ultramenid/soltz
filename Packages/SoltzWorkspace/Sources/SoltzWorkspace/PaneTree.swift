// SPDX-License-Identifier: AGPL-3.0-only
// Port of the pure half of core/src/stores/layoutStore.ts plus utils/titlebarOrder.ts.
// JSON shape matches upstream ({"type":"leaf"|"split", ...}) because split tabs ride in the synced snapshot.
import Foundation

public enum SplitDirection: String, Codable, Sendable { case h, v }
public enum SplitPosition: String, Codable, Sendable { case left, right, top, bottom }
public enum TitlebarPlacement: Sendable { case before, after }

public struct LeafNode: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public init(id: String, sessionId: String) { self.id = id; self.sessionId = sessionId }
}

public struct SplitNode: Codable, Equatable, Sendable {
    public var id: String
    public var direction: SplitDirection
    public var ratio: Double
    public var first: PaneNode
    public var second: PaneNode
    public init(id: String, direction: SplitDirection, ratio: Double, first: PaneNode, second: PaneNode) {
        self.id = id; self.direction = direction; self.ratio = ratio; self.first = first; self.second = second
    }
}

public indirect enum PaneNode: Equatable, Sendable {
    case leaf(LeafNode)
    case split(SplitNode)
}

extension PaneNode: Codable {
    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        switch try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type) {
        case "leaf": self = .leaf(try LeafNode(from: decoder))
        case "split": self = .split(try SplitNode(from: decoder))
        case let other:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown pane type \(other)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .leaf(let leaf): try container.encode("leaf", forKey: .type); try leaf.encode(to: encoder)
        case .split(let split): try container.encode("split", forKey: .type); try split.encode(to: encoder)
        }
    }
}

public struct SplitTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// User-given tab name. Unset keeps deriving the label from the active pane.
    public var name: String?
    public var root: PaneNode
    public var activePaneId: String?
    public var maximizedPaneId: String?
    public init(id: String, name: String? = nil, root: PaneNode, activePaneId: String?, maximizedPaneId: String? = nil) {
        self.id = id; self.name = name; self.root = root
        self.activePaneId = activePaneId; self.maximizedPaneId = maximizedPaneId
    }
}

// MARK: - Tree queries and rewrites

extension PaneNode {
    public var leaves: [LeafNode] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(let split): split.first.leaves + split.second.leaves
        }
    }

    public var sessionIds: [String] { leaves.map(\.sessionId) }

    public var firstLeaf: LeafNode {
        switch self {
        case .leaf(let leaf): leaf
        case .split(let split): split.first.firstLeaf
        }
    }

    public func findLeaf(_ paneId: String?) -> LeafNode? { leaves.first { $0.id == paneId } }
    public func findLeaf(session sessionId: String) -> LeafNode? { leaves.first { $0.sessionId == sessionId } }
    public func contains(pane paneId: String?) -> Bool { findLeaf(paneId) != nil }

    var isLeaf: Bool { if case .leaf = self { true } else { false } }

    func replacingLeaf(_ paneId: String, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let leaf): return leaf.id == paneId ? replacement : self
        case .split(var split):
            split.first = split.first.replacingLeaf(paneId, with: replacement)
            split.second = split.second.replacingLeaf(paneId, with: replacement)
            return .split(split)
        }
    }

    /// The tree without `paneId`, its parent split collapsing into the sibling.
    func removingLeaf(_ paneId: String) -> (root: PaneNode?, removed: LeafNode?) {
        switch self {
        case .leaf(let leaf): return leaf.id == paneId ? (nil, leaf) : (self, nil)
        case .split(var split):
            let first = split.first.removingLeaf(paneId)
            if let removed = first.removed {
                guard let root = first.root else { return (split.second, removed) }
                split.first = root
                return (.split(split), removed)
            }
            let second = split.second.removingLeaf(paneId)
            if let removed = second.removed {
                guard let root = second.root else { return (split.first, removed) }
                split.second = root
                return (.split(split), removed)
            }
            return (self, nil)
        }
    }

    func removingSession(_ sessionId: String) -> PaneNode? {
        switch self {
        case .leaf(let leaf): return leaf.sessionId == sessionId ? nil : self
        case .split(var split):
            let first = split.first.removingSession(sessionId)
            let second = split.second.removingSession(sessionId)
            guard let first else { return second }
            guard let second else { return first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    func updatingRatio(_ splitNodeId: String, _ ratio: Double) -> PaneNode {
        guard case .split(var split) = self else { return self }
        if split.id == splitNodeId {
            split.ratio = max(0.1, min(0.9, ratio))
            return .split(split)
        }
        split.first = split.first.updatingRatio(splitNodeId, ratio)
        split.second = split.second.updatingRatio(splitNodeId, ratio)
        return .split(split)
    }
}

/// Where a split places the incoming leaf: which axis, and which side.
public func splitGeometry(_ position: SplitPosition) -> (direction: SplitDirection, incomingFirst: Bool) {
    (position == .left || position == .right ? .h : .v, position == .left || position == .top)
}

public func findSessionPane(_ splitTabs: [SplitTab], _ sessionId: String) -> (tabId: String, paneId: String)? {
    for tab in splitTabs {
        if let leaf = tab.root.findLeaf(session: sessionId) { return (tab.id, leaf.id) }
    }
    return nil
}

func newPaneId() -> String { "pane-\(UUID().uuidString.lowercased())" }
func newSplitId() -> String { "split-\(UUID().uuidString.lowercased())" }
func newSplitTabId() -> String { "split-tab-\(UUID().uuidString.lowercased())" }

func splitLeaf(_ target: LeafNode, _ leaf: LeafNode, _ position: SplitPosition) -> PaneNode {
    let (direction, incomingFirst) = splitGeometry(position)
    return .split(SplitNode(
        id: newSplitId(), direction: direction, ratio: 0.5,
        first: .leaf(incomingFirst ? leaf : target), second: .leaf(incomingFirst ? target : leaf)
    ))
}

func buildBalancedTree(_ leaves: ArraySlice<LeafNode>) -> PaneNode? {
    guard let only = leaves.first else { return nil }
    if leaves.count == 1 { return .leaf(only) }
    let mid = leaves.startIndex + (leaves.count + 1) / 2
    guard let first = buildBalancedTree(leaves[..<mid]), let second = buildBalancedTree(leaves[mid...]) else { return nil }
    return .split(SplitNode(id: newSplitId(), direction: leaves.count <= 2 ? .h : .v, ratio: 0.5, first: first, second: second))
}

/// A split tab without `sessionId`; nil once fewer than two panes remain.
func withoutSession(_ tab: SplitTab, _ sessionId: String) -> SplitTab? {
    guard let root = tab.root.removingSession(sessionId), !root.isLeaf else { return nil }
    var next = tab
    next.root = root
    next.activePaneId = (root.findLeaf(tab.activePaneId) ?? root.firstLeaf).id
    next.maximizedPaneId = root.findLeaf(tab.maximizedPaneId)?.id
    return next
}

let tabTitleMax = 60

/// Trimmed tab title capped at 60 characters; blank means "no title".
public func normalizeTabTitle(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(tabTitleMax))
}

// MARK: - Titlebar (tab strip) order — utils/titlebarOrder.ts

public func placeTitlebarBlock(_ order: [String], _ keys: [String], _ targetKey: String?, _ placement: TitlebarPlacement) -> [String] {
    let moving = Set(keys)
    let block = order.filter { moving.contains($0) } + keys.filter { !order.contains($0) }
    let next = order.filter { !moving.contains($0) }
    guard let targetKey, let targetIndex = next.firstIndex(of: targetKey) else { return next + block }
    let insertIndex = placement == .before ? targetIndex : targetIndex + 1
    return Array(next[..<insertIndex]) + block + Array(next[insertIndex...])
}

public func placeTitlebarItem(_ order: [String], _ itemKey: String, _ targetKey: String?, _ placement: TitlebarPlacement) -> [String] {
    placeTitlebarBlock(order, [itemKey], targetKey, placement)
}

/// Pulls later members of a group up behind the group's first member.
public func gatherGroups(_ order: [String], _ groupOf: (String) -> String?) -> [String] {
    var byGroup: [String: [String]] = [:]
    for key in order { if let group = groupOf(key) { byGroup[group, default: []].append(key) } }
    var gathered: [String] = []
    var done = Set<String>()
    for key in order {
        guard let group = groupOf(key) else { gathered.append(key); continue }
        if done.insert(group).inserted { gathered += byGroup[group] ?? [] }
    }
    return gathered
}

public func mergeTitlebarItems(_ order: [String], _ visibleKeys: [String]) -> [String] {
    let visible = Set(visibleKeys)
    let ordered = order.filter { visible.contains($0) }
    let orderedSet = Set(ordered)
    return ordered + visibleKeys.filter { !orderedSet.contains($0) }
}

func replaceKey(_ list: [String], _ from: String, _ to: String) -> [String] {
    list.map { $0 == from ? to : $0 }
}
