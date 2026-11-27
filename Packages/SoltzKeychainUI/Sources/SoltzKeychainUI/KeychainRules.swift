// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzModel

/// Upstream `keychainSortMode`; `newest` is its default.
enum KeychainSort: String, CaseIterable, Sendable {
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

/// What keys and identities share, so the list rules are written once. Settable throughout:
/// `Lossless` reaches fields through writable key paths only.
protocol KeychainFields: LosslessFields, Identifiable where ID == String {
    var id: String { get set }
    var name: String? { get set }
    var tags: [String] { get set }
    var createdAt: String { get set }
    var updatedAt: String { get set }
    var deletedAt: String? { get set }
    var folderID: String? { get set }
    var vaultID: String { get set }
    var pinned: Bool { get set }
    var clocks: [String: String] { get set }
    /// Upstream searches keys by name and type, identities by name and username.
    var searchFields: [String] { get }
}

extension SshKeyFields: KeychainFields {
    var searchFields: [String] { [name ?? "", keyType ?? ""] }
}

extension IdentityFields: KeychainFields {
    var searchFields: [String] { [name ?? "", username] }
}

/// One folder level of the keychain.
struct KeychainLevel {
    /// Breadcrumb from the root's first child down to the open folder; empty at the root.
    var path: [Folder]
    var folders: [Folder]
    var pinnedKeys: [SshKey]
    var pinnedIdentities: [Identity]
    var keys: [SshKey]
    var identities: [Identity]

    var isEmpty: Bool {
        folders.isEmpty && pinnedKeys.isEmpty && pinnedIdentities.isEmpty && keys.isEmpty && identities.isEmpty
    }
}

/// The keychain's rules, ported from upstream `KeychainPage.tsx`, `KeyCards.tsx`, `KeyExportPanel.tsx`
/// (`sortByMode`), `utils/folderTree.ts`, `utils/search.ts` and `services/vaultObjectWrites.ts`.
enum KeychainRules {
    static let defaultVaultID = "personal"

    /// Rust `crdt::is_alive`, the filter behind `key_list` and `identity_list`: a tombstone is
    /// live again once a later edit wins over it.
    static func isLive(deletedAt: String?, updatedAt: String) -> Bool {
        deletedAt.map { updatedAt > $0 } ?? true
    }

    static func isLive<F: KeychainFields>(_ item: Lossless<F>) -> Bool { isLive(deletedAt: item.deletedAt, updatedAt: item.updatedAt) }
    static func isLive(_ c: Connection) -> Bool { isLive(deletedAt: c.deletedAt, updatedAt: c.updatedAt) }

    /// Live keychain folders (`object_type: keychain`).
    static func keychainFolders(_ folders: [Folder]) -> [Folder] {
        folders.filter { isLive(deletedAt: $0.deletedAt, updatedAt: $0.updatedAt) && $0.objectType == .keychain }
    }

    // MARK: Display

    static func keyName(_ k: SshKey) -> String { nonEmpty(k.name) ?? "Unnamed Key" }

    /// Upstream `identity.name ?? identity.username`.
    static func identityName(_ i: Identity) -> String { nonEmpty(i.name) ?? i.username }

    /// Upstream `connectionDisplayName`.
    static func hostName(_ c: Connection) -> String {
        if let name = nonEmpty(c.name) { return name }
        switch c.connectionType {
        case .serial: return nonEmpty(c.serialPort) ?? "Serial Device"
        case .web: return "\(c.host):\(c.port)"
        default: return "\(c.username)@\(c.host):\(c.port)"
        }
    }

    /// Upstream default key label: the detected type and today's date.
    static func defaultKeyName(type: String?, date: Date = .now) -> String {
        "\(type ?? "SSH Key") · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Rust writes RFC 3339 with up to nanoseconds, JS with milliseconds; both parse.
    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text.replacing(/\.\d+/, with: ""))
    }

    // MARK: Filtering and sorting

    /// Upstream `searchMatcher` over the item's search fields, plus tags as in SoltzHostsUI.
    /// Case- and accent-insensitive.
    static func matches<F: KeychainFields>(_ item: Lossless<F>, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return (item.fields.searchFields + item.tags).contains { $0.localizedStandardContains(q) }
    }

    /// Upstream `sortByMode`: a missing name sorts as "", dates compare as stored strings.
    static func sorted<F: KeychainFields>(_ items: [Lossless<F>], by sort: KeychainSort) -> [Lossless<F>] {
        items.sorted { a, b in
            switch sort {
            case .nameAscending: (a.name ?? "").localizedStandardCompare(b.name ?? "") == .orderedAscending
            case .nameDescending: (b.name ?? "").localizedStandardCompare(a.name ?? "") == .orderedAscending
            case .newest: a.createdAt > b.createdAt
            case .oldest: a.createdAt < b.createdAt
            }
        }
    }

    /// Every tag on a live key or identity (upstream `availableTags`).
    static func tags(keys: [SshKey], identities: [Identity]) -> [String] {
        Set(keys.filter { isLive($0) }.flatMap(\.tags) + identities.filter { isLive($0) }.flatMap(\.tags)).sorted()
    }

    /// One level of the keychain. Search and the tag filter apply within the open folder; at the
    /// root, items whose folder is gone show up too. Pinned items get their own section unless a
    /// search is running, as in SoltzHostsUI (upstream does this at the root only).
    static func level(keys: [SshKey], identities: [Identity], folders allFolders: [Folder], folderID: String?,
                      query: String, tags: Set<String>, sort: KeychainSort) -> KeychainLevel {
        let folders = keychainFolders(allFolders)
        let byID = index(folders)
        let path = path(to: folderID, in: byID)
        let open = path.last?.id
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        func shown<F: KeychainFields>(_ items: [Lossless<F>]) -> (pinned: [Lossless<F>], rest: [Lossless<F>]) {
            let list = sorted(items.filter { item in
                guard isLive(item), matches(item, query: query), tags.isEmpty || !tags.isDisjoint(with: item.tags) else { return false }
                if let open { return item.folderID == open }
                return item.folderID.map { byID[$0] == nil } ?? true
            }, by: sort)
            return searching ? ([], list) : (list.filter(\.pinned), list.filter { !$0.pinned })
        }

        let k = shown(keys)
        let i = shown(identities)
        return KeychainLevel(path: path, folders: folders.filter { parentID($0, in: byID) == open },
                             pinnedKeys: k.pinned, pinnedIdentities: i.pinned, keys: k.rest, identities: i.rest)
    }

    // MARK: Usage

    /// Live hosts and identities that sign in with key `id` (upstream `LinkedToSection` for a key).
    static func usage(ofKey id: String, connections: [Connection], identities: [Identity]) -> (hosts: [Connection], identities: [Identity]) {
        (connections.filter { isLive($0) && $0.keyID == id }, identities.filter { isLive($0) && $0.keyID == id })
    }

    /// Live hosts that sign in as identity `id`.
    static func hosts(usingIdentity id: String, connections: [Connection]) -> [Connection] {
        connections.filter { isLive($0) && $0.identityID == id }
    }

    /// The delete confirmation for a key or identity, naming what uses it.
    static func deleteMessage(hosts: [Connection], identities: [Identity] = []) -> String {
        var users: [String] = []
        if !hosts.isEmpty { users.append("\(count(hosts.count, "host", "hosts")) (\(names(hosts.map(hostName))))") }
        if !identities.isEmpty {
            users.append("\(count(identities.count, "identity", "identities")) (\(names(identities.map(identityName))))")
        }
        guard !users.isEmpty else { return "This cannot be undone." }
        return "Used by \(users.joined(separator: " and ")), which will no longer sign in with it. This cannot be undone."
    }

    /// Upstream `folderDeleteMessages`: the store deletes everything filed beneath the folder.
    static func folderDeleteMessage(itemCount: Int) -> String {
        itemCount == 0
            ? "This will delete the folder and everything inside it. This cannot be undone."
            : "This will delete the folder, its subfolders, and the \(count(itemCount, "item", "items")) inside. This cannot be undone."
    }

    // MARK: Folders

    static func index(_ folders: [Folder]) -> [String: Folder] {
        Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A parent that is not a known folder reads as the root (upstream `rootedParentId`).
    static func parentID(_ folder: Folder, in byID: [String: Folder]) -> String? {
        folder.parentFolderID.flatMap { byID[$0] == nil ? nil : $0 }
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

    /// `rootID` and every folder beneath it. Tolerates parent cycles (upstream `folderSubtreeIds`).
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

    /// Live keys and identities filed anywhere beneath `folderID` (upstream `folderItemCounter`).
    static func itemCount(in folderID: String, keys: [SshKey], identities: [Identity], folders: [Folder]) -> Int {
        let ids = subtreeIDs(of: folderID, in: keychainFolders(folders))
        return keys.count { isLive($0) && $0.folderID.map(ids.contains) == true }
            + identities.count { isLive($0) && $0.folderID.map(ids.contains) == true }
    }

    /// Folders an item may be filed in: its own vault's, labelled "Parent / Child".
    static func folderChoices(_ folders: [Folder], vaultID: String) -> [(id: String, label: String)] {
        let live = keychainFolders(folders)
        let byID = index(live)
        return live.filter { $0.vaultID == vaultID }
            .map { (id: $0.id, label: path(to: $0.id, in: byID).map(\.name).joined(separator: " / ")) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Where a folder may move: same vault, not into itself or a descendant (upstream `foldersOutsideSubtree`).
    static func parentChoices(for folder: Folder, folders: [Folder]) -> [(id: String, label: String)] {
        let excluded = subtreeIDs(of: folder.id, in: keychainFolders(folders))
        return folderChoices(folders, vaultID: folder.vaultID).filter { !excluded.contains($0.id) }
    }

    // MARK: New records

    /// A new key as Rust `build_key` starts one, filed in `folder` and its vault when given.
    /// Built without `raw`, so it is written with every key. The store stamps `clocks` on save.
    static func newKey(in folder: Folder? = nil, vaultID: String? = nil, id: String = newID(), now: String = timestamp()) -> SshKey {
        Lossless(make(newRecord(id: id, now: now, folder: folder, vaultID: vaultID)).fields)
    }

    /// A new identity as Rust `build_identity` starts one.
    static func newIdentity(in folder: Folder? = nil, id: String = newID(), now: String = timestamp()) -> Identity {
        var json = newRecord(id: id, now: now, folder: folder, vaultID: nil)
        json["username"] = ""
        return Lossless(make(json).fields)
    }

    private static func newRecord(id: String, now: String, folder: Folder?, vaultID: String?) -> JSONObject {
        var json: JSONObject = [
            "id": .string(id), "tags": [], "created_at": .string(now), "updated_at": .string(now), "clocks": [:],
            "vault_id": .string(folder?.vaultID ?? vaultID ?? defaultVaultID), "pinned": false,
        ]
        if let folder { json["folder_id"] = .string(folder.id) }
        return json
    }

    /// Upstream "Duplicate" (`duplicateInPlace`): a "(copy)" beside the original, same vault, folder
    /// and key link, unpinned. The original's unknown fields come along; the store copies its secrets
    /// (`KeySecrets.copyFrom`, `IdentitySecrets.copyFrom`).
    static func duplicate<F: KeychainFields>(_ item: Lossless<F>, id: String = newID(), now: String = timestamp()) -> Lossless<F> {
        var copy = item
        copy.fields.id = id
        copy.name = item.name.map { $0.isEmpty ? $0 : "\($0) (copy)" }
        copy.createdAt = now
        copy.updatedAt = now
        copy.deletedAt = nil
        copy.pinned = false
        copy.clocks = [:]
        return copy
    }

    /// The folder naming prompt's result: `folder` renamed in place, or a new keychain folder inside
    /// `parent` and its vault (upstream `newFolderData`). nil when the trimmed name is empty.
    static func savedFolder(_ folder: Folder?, name: String, parent: Folder?, id: String = newID(), now: String = timestamp()) -> Folder? {
        guard let name = nonEmpty(name) else { return nil }
        if var folder {
            folder.name = name
            return folder
        }
        var json: JSONObject = [
            "id": .string(id), "name": .string(name), "created_at": .string(now), "updated_at": .string(now),
            "object_type": .string(FolderObjectType.keychain.rawValue), "vault_id": .string(parent?.vaultID ?? defaultVaultID),
            "clocks": [:],
        ]
        if let parent { json["parent_folder_id"] = .string(parent.id) }
        return Lossless(make(json).fields)
    }

    // MARK: Helpers

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// RFC 3339 with milliseconds, like JS `toISOString`.
    static func timestamp(_ date: Date = .now) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func nonEmpty(_ text: String?) -> String? {
        text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // shortcut: tags are typed comma-separated, so a tag cannot contain a comma; use a token field if that matters.
    /// Trimmed, non-empty, first occurrence kept (upstream `TagSelector`).
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Up to three names, then how many more.
    static func names(_ list: [String]) -> String {
        let shown = list.prefix(3).joined(separator: ", ")
        return list.count > 3 ? "\(shown) and \(list.count - 3) more" : shown
    }
}

/// A record from JSON this package writes itself, with every required key present, so decoding
/// cannot fail short of a model change, which the tests catch.
func make<F: LosslessFields>(_ json: JSONObject) -> Lossless<F> {
    do { return try Lossless(json: json) } catch { preconditionFailure("\(F.self): \(error)") }
}
