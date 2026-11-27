// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzModel

/// Upstream `homeSortMode`; `newest` is its default.
public enum HostSort: String, CaseIterable, Sendable {
    case nameAscending, nameDescending, newest, oldest

    var title: String {
        switch self {
        case .nameAscending: "Name (A to Z)"
        case .nameDescending: "Name (Z to A)"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        }
    }
}

public enum HostLayout: String, Sendable {
    case grid, list
}

/// What one folder level of the browser shows.
struct HostsLevel {
    /// Breadcrumb from the root's first child down to the open folder; empty at the root.
    var path: [Folder]
    var folders: [Folder]
    var pinned: [Connection]
    var hosts: [Connection]

    var isEmpty: Bool { folders.isEmpty && pinned.isEmpty && hosts.isEmpty }
}

/// The browser's rules, ported from upstream `HostsPage.tsx`, `connectionFilter.ts`,
/// `useFolderNavigation.ts` and `folderTree.ts`.
enum HostRules {
    static let defaultVaultID = "personal"

    /// Live (not tombstoned) host folders.
    static func hostFolders(_ folders: [Folder]) -> [Folder] {
        folders.filter { $0.deletedAt == nil && $0.objectType == .connection }
    }

    /// Upstream `connectionDisplayName`.
    static func displayName(_ c: Connection) -> String {
        if let name = c.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch c.connectionType {
        case .serial: return c.serialPort.flatMap { $0.isEmpty ? nil : $0 } ?? "Serial Device"
        case .web: return "\(c.host):\(c.port)"
        default: return "\(c.username)@\(c.host):\(c.port)"
        }
    }

    static func subtitle(_ c: Connection) -> String {
        switch c.connectionType {
        case .serial: "Serial · \(c.serialBaud ?? 115_200) baud"
        case .web: "\(c.webSecure ? "https" : "http")://\(c.host):\(c.port)"
        default: c.username.isEmpty ? "\(c.host):\(c.port)" : "\(c.username)@\(c.host):\(c.port)"
        }
    }

    /// SF Symbol per connection type; the stored distro/icon fields are left alone.
    static func symbol(_ type: ConnectionType) -> String {
        switch type {
        case .ssh: "terminal"
        case .serial: "cable.connector"
        case .ftp: "folder.badge.gearshape"
        case .webdav: "externaldrive.connected.to.line.below"
        case .web: "globe"
        default: "server.rack"
        }
    }

    /// Upstream `matchesSearch` (name, host, username) plus tags; case- and accent-insensitive.
    static func matches(_ c: Connection, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return ([c.name ?? "", c.host, c.username] + c.tags).contains { $0.localizedStandardContains(q) }
    }

    /// Upstream `compareConnections`: names fall back to the host; dates compare as stored strings.
    static func sorted(_ connections: [Connection], by sort: HostSort) -> [Connection] {
        connections.sorted { a, b in
            switch sort {
            case .nameAscending: (a.name ?? a.host).localizedStandardCompare(b.name ?? b.host) == .orderedAscending
            case .nameDescending: (b.name ?? b.host).localizedStandardCompare(a.name ?? a.host) == .orderedAscending
            case .newest: a.createdAt > b.createdAt
            case .oldest: a.createdAt < b.createdAt
            }
        }
    }

    static func tags(_ connections: [Connection]) -> [String] {
        Set(connections.filter { $0.deletedAt == nil }.flatMap(\.tags)).sorted()
    }

    /// A parent that is not a known folder reads as the root (upstream `rootedParentId`).
    static func parentID(_ folder: Folder, in byID: [String: Folder]) -> String? {
        folder.parentFolderID.flatMap { byID[$0] == nil ? nil : $0 }
    }

    static func index(_ folders: [Folder]) -> [String: Folder] {
        Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Root-first path to `id`; an unknown id is the root. Stops on a parent cycle.
    static func path(to id: String?, in byID: [String: Folder]) -> [Folder] {
        var path: [Folder] = []
        var at = id
        while let current = at, let folder = byID[current], !path.contains(where: { $0.id == current }) {
            path.insert(folder, at: 0)
            at = parentID(folder, in: byID)
        }
        return path
    }

    /// "Parent / Child", for pickers.
    static func pathLabel(_ folder: Folder, in byID: [String: Folder]) -> String {
        path(to: folder.id, in: byID).map(\.name).joined(separator: " / ")
    }

    /// One level of the browser. Like upstream, search and the tag filter apply within the open
    /// folder; at the root, hosts whose folder is gone show up too. Pinned hosts get their own
    /// section unless a search is running (upstream does this at the root only).
    static func level(connections: [Connection], folders allFolders: [Folder], folderID: String?,
                      query: String, tags: Set<String>, sort: HostSort) -> HostsLevel {
        let folders = hostFolders(allFolders)
        let byID = index(folders)
        let path = path(to: folderID, in: byID)
        let open = path.last?.id
        let hosts = sorted(connections.filter { c in
            guard c.deletedAt == nil, matches(c, query: query), tags.isEmpty || !tags.isDisjoint(with: c.tags) else { return false }
            if let open { return c.folderID == open }
            return c.folderID.map { byID[$0] == nil } ?? true
        }, by: sort)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HostsLevel(
            path: path,
            folders: folders.filter { parentID($0, in: byID) == open },
            pinned: searching ? [] : hosts.filter(\.pinned),
            hosts: searching ? hosts : hosts.filter { !$0.pinned }
        )
    }

    /// `rootID` and every folder beneath it. Tolerates parent cycles.
    static func subtreeIDs(of rootID: String, in folders: [Folder]) -> Set<String> {
        var ids: Set<String> = [rootID]
        var grew = true
        while grew {
            grew = false
            for f in folders where !ids.contains(f.id) {
                if let parent = f.parentFolderID, ids.contains(parent) {
                    ids.insert(f.id)
                    grew = true
                }
            }
        }
        return ids
    }

    /// Live hosts filed anywhere beneath `folderID`: the folder card count and the delete warning.
    static func hostCount(in folderID: String, connections: [Connection], folders: [Folder]) -> Int {
        let ids = subtreeIDs(of: folderID, in: hostFolders(folders))
        return connections.count { c in c.deletedAt == nil && c.folderID.map(ids.contains) == true }
    }

    /// Folders a host may be filed in: its own vault's (upstream `folderOptions`).
    static func folderChoices(_ folders: [Folder], vaultID: String) -> [(id: String, label: String)] {
        let live = hostFolders(folders)
        let byID = index(live)
        return live.filter { $0.vaultID == vaultID }
            .map { (id: $0.id, label: pathLabel($0, in: byID)) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Where a folder may move: same vault, not into itself or a descendant (upstream `foldersOutsideSubtree`).
    static func parentChoices(for folder: Folder?, vaultID: String, folders: [Folder]) -> [(id: String, label: String)] {
        let excluded = folder.map { subtreeIDs(of: $0.id, in: hostFolders(folders)) } ?? []
        return folderChoices(folders, vaultID: vaultID).filter { !excluded.contains($0.id) }
    }

    static func defaultPort(_ type: ConnectionType) -> UInt16 {
        switch type {
        case .ssh: 22
        case .ftp: 21
        case .web: 443
        default: 0
        }
    }

    static func defaultUsername(_ type: ConnectionType) -> String { type == .ssh ? "root" : "" }

    /// A new host as the upstream forms start one, filed in `folder` and its vault when given.
    /// Built without `raw`, so it is written with every key like Rust's `build_connection`.
    /// `clocks` is left empty: the store stamps clocks and `updated_at` on save.
    static func newConnection(type: ConnectionType = .ssh, in folder: Folder? = nil,
                              id: String = newID(), now: String = timestamp()) -> Connection {
        var json: JSONObject = [
            "id": .string(id), "host": "", "port": .int(Int64(defaultPort(type))),
            "username": .string(defaultUsername(type)), "tags": [], "created_at": .string(now),
            "updated_at": .string(now), "clocks": [:], "connection_type": .string(type.rawValue),
            "vault_id": .string(folder?.vaultID ?? defaultVaultID), "web_secure": true,
        ]
        if let folder { json["folder_id"] = .string(folder.id) }
        let decoded: Connection = make(json)
        return Connection(decoded.fields)
    }

    /// Upstream "Duplicate": a "(copy)" beside the original, same folder, vault and links. The
    /// original's unknown fields come along. Its stored secrets are the store's to copy
    /// (`HostSecrets.copyFrom`).
    static func duplicate(_ c: Connection, id: String = newID(), now: String = timestamp()) -> Connection {
        var copy = c
        copy.id = id
        copy.name = c.name.map { $0.isEmpty ? $0 : "\($0) (copy)" }
        copy.createdAt = now
        copy.updatedAt = now
        copy.lastUsedAt = nil
        copy.deletedAt = nil
        copy.clocks = [:]
        return copy
    }

    /// The folder editor's result: `folder` renamed and moved in place, or a new host folder.
    /// nil when the trimmed name is empty (upstream `canSave`).
    static func savedFolder(_ folder: Folder?, name: String, parentID: String?, vaultID: String,
                            id: String = newID(), now: String = timestamp()) -> Folder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if var folder {
            folder.name = name
            folder.parentFolderID = parentID
            return folder
        }
        var json: JSONObject = [
            "id": .string(id), "name": .string(name), "created_at": .string(now), "updated_at": .string(now),
            "object_type": .string(FolderObjectType.connection.rawValue), "vault_id": .string(vaultID), "clocks": [:],
        ]
        if let parentID { json["parent_folder_id"] = .string(parentID) }
        let decoded: Folder = make(json)
        return Folder(decoded.fields)
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// RFC 3339 with milliseconds, like JS `toISOString`.
    static func timestamp(_ date: Date = .now) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// A record from JSON this package writes itself, with every required key present, so
/// decoding cannot fail short of a model change, which the tests catch.
func make<F: LosslessFields>(_ json: JSONObject) -> Lossless<F> {
    do { return try Lossless(json: json) } catch { preconditionFailure("\(F.self): \(error)") }
}
