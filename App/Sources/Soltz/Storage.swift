// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import SoltzCore
import SoltzHostsUI
import SoltzKeychainUI
import SoltzModel

/// Saved hosts, keys, identities and their folders in the core's data directory, and the vault holding their secrets. The core
/// stores rows exactly as given, so they are stamped here as upstream's Rust commands stamp them.
extension Workspace {
    /// Upstream's personal vault, the only one Soltz has.
    nonisolated static let personalVault = "personal"

    // MARK: - Vault

    /// At launch: a new vault keeps its key in the keychain (upstream's default tier); a master-password
    /// vault waits for the unlock sheet.
    func openVault() async {
        do {
            switch try await core.vaultStatus() {
            case .uninitialised: try await core.vaultInitialise(masterPassword: nil)
            case .locked(mode: .keychain): try await core.vaultUnlock(masterPassword: nil)
            case .locked(mode: .masterPassword): vaultLocked = true
            case .unlocked: break
            }
        } catch {
            failure = Failure(title: "Couldn’t Open the Vault", message: describe(error))
        }
    }

    // MARK: - Changes

    /// Runs one change, shows its error under `title`, then reloads every list. Returns whether it succeeded.
    @discardableResult
    func perform(_ title: String, _ change: () async throws -> Void) async -> Bool {
        var succeeded = true
        do {
            try await change()
        } catch {
            failure = Failure(title: title, message: describe(error))
            succeeded = false
        }
        await reload()
        return succeeded
    }

    /// `perform`, for a sheet or menu that does not wait for it.
    func change(_ title: String, _ change: @escaping @MainActor () async throws -> Void) {
        Task { await perform(title, change) }
    }

    /// upstream "Duplicate": a "(copy)" beside the original, same folder, vault and links, with its secrets.
    func duplicate(_ host: Connection) async throws {
        var copy = host
        copy.id = UUID().uuidString.lowercased()
        copy.name = host.name.map { $0.isEmpty ? $0 : "\($0) (copy)" }
        copy.lastUsedAt = nil
        copy.clocks = [:]
        try await save(copy, HostSecrets(copyFrom: host.id))
    }

    /// The host editor's Save, Duplicate, Pin and Move (`HostsView.onSave`): the row as upstream
    /// `connection_save` (new) or `connection_update` stamps it, then its secrets as `saveHostFromForm` writes
    /// them (nil unchanged, "" cleared), then on a duplicate the original's, as `copyObjectSecrets` does.
    func save(_ host: Connection, _ secrets: HostSecrets) async throws {
        let isNew = try await saveStamped(try sealingEnv(host), as: .connections, seeded: Self.connectionClocks, tracked: Self.connectionClocks)
        let keys = Self.secretKeys(of: host.id)
        try writeSecrets(zip(keys, [secrets.password, secrets.privateKey, secrets.passphrase, secrets.proxyPassword, secrets.knockSequence]), isNew: isNew)
        // No secrets for a serial copy; no inline key (`key:<id>`, `passphrase:<id>`) for one using a keychain key.
        guard let original = secrets.copyFrom, host.connectionType != .serial else { return }
        for (from, to) in zip(Self.secretKeys(of: original), keys)
        where host.keyID == nil || !(from.hasPrefix("key:") || from.hasPrefix("passphrase:")) {
            if let value = try core.secretGet(key: from), !value.isEmpty { try core.secretSet(key: to, value: value) }
        }
    }

    /// What tells the key stored with `host` from another, for Edit host: its type and comment ("ED25519 ·
    /// deploy@laptop"), or its fingerprint when it has no comment. nil when the host has no key of its own, or the key
    /// cannot be read (its passphrase is not the stored one). Only the public half leaves here.
    func keySummary(of host: Connection) async -> String? {
        guard host.keyID == nil, let key = (try? secret("key:\(host.id)")) ?? nil,
              let line = try? await core.sshPublicKeyFromPrivate(privateKey: key, passphrase: (try? secret("passphrase:\(host.id)")) ?? nil)
        else { return nil }
        return Self.keySummary(publicKey: line)
    }

    /// An OpenSSH public line ("ssh-ed25519 AAAA… comment") as `keySummary(of:)` shows it; the fingerprint is the one
    /// `ssh-keygen -l` prints.
    nonisolated static func keySummary(publicKey line: String) -> String? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let blob = Data(base64Encoded: parts[1]) else { return nil }
        let type = parts[0].replacingOccurrences(of: "ssh-", with: "").replacingOccurrences(of: "ecdsa-sha2-", with: "ecdsa ").uppercased()
        let comment = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !comment.isEmpty { return "\(type) · \(comment)" }
        return "\(type) SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: ["="])
    }

    // MARK: What a host's row does not carry on disk

    /// A host's environment variables, notes and pre/post commands are where tokens and passwords get put, so they
    /// are kept in the vault (`env:<host id>:<variable id>`, `note:<host id>`, `command:<host id>:pre|post`) and the
    /// row on disk carries none of them. Upstream writes them to connections.json as they are. The rows in memory
    /// (`connections`) have them, filled in by `withEnv`.
    static func envKey(_ host: String, _ variable: String) -> String { "env:\(host):\(variable)" }

    /// The host's free-text fields kept in the vault, and each one's key there.
    static let sealedText: [(field: WritableKeyPath<ConnectionFields, String?>, key: @Sendable (String) -> String)] = [
        (\.notes, { "note:\($0)" }), (\.preCommand, { "command:\($0):pre" }), (\.postCommand, { "command:\($0):post" }),
    ]

    private func seal(_ key: String, _ value: String) throws {
        if value.isEmpty { try core.secretDelete(key: key) } else { try core.secretSet(key: key, value: value) }
    }

    /// `host` as it goes to disk: its variables' values, notes and commands moved to the vault, and the values of
    /// variables it no longer has removed from it.
    private func sealingEnv(_ host: Connection) throws -> Connection {
        var row = host
        let had = connections.first { $0.id == host.id }?.envVars.map(\.id) ?? []
        for id in had where !host.envVars.contains(where: { $0.id == id }) { try core.secretDelete(key: Self.envKey(host.id, id)) }
        for index in row.envVars.indices {
            try seal(Self.envKey(host.id, row.envVars[index].id), row.envVars[index].value)
            row.envVars[index].value = ""
        }
        for (field, key) in Self.sealedText {
            try seal(key(host.id), row[dynamicMember: field] ?? "")
            row[dynamicMember: field] = nil
        }
        return row
    }

    /// `hosts` as read from disk, with what the vault holds for them filled in. A host that still has any of it on
    /// disk (saved before it moved) keeps that and is saved again, which moves it.
    func withEnv(_ hosts: [Connection]) async -> [Connection] {
        var filled = hosts
        let stored = { (key: String) in (try? self.core.secretGet(key: key)).flatMap { $0 } }
        for h in filled.indices {
            let id = filled[h].id
            var onDisk = filled[h].envVars.contains { !$0.value.isEmpty }
            for v in filled[h].envVars.indices where filled[h].envVars[v].value.isEmpty {
                filled[h].envVars[v].value = stored(Self.envKey(id, filled[h].envVars[v].id)) ?? ""
            }
            for (field, key) in Self.sealedText {
                if filled[h][dynamicMember: field]?.isEmpty == false { onDisk = true } else { filled[h][dynamicMember: field] = stored(key(id)) }
            }
            if onDisk { try? await save(filled[h], HostSecrets()) }
        }
        return filled
    }

    /// Upstream `connection_delete`: a tombstone. Its secrets stay, as upstream leaves them.
    func delete(_ host: Connection) async throws {
        try await core.entityDelete(kind: .connections, id: host.id)
    }

    /// Upstream `folder_save` (new) or `folder_update`.
    func save(_ folder: Folder) async throws {
        try await saveStamped(folder, as: .folders, seeded: Self.folderCreateClocks, tracked: Self.folderUpdateClocks)
    }

    /// Upstream `folder_delete` with its default cascade: the folder, its live subfolders, and every host, identity
    /// and key filed in them. The core deletes one row per call, so the cascade is walked here.
    // shortcut: each tombstone gets its own core `now` (upstream stamps one) and a failure midway leaves a partial
    // cascade; move it into the core once `entityDelete` cascades folders.
    func delete(_ folder: Folder) async throws {
        let all: [Folder] = try await list(.folders)
        let doomed = Self.subtree(folder.id, all.map { ($0.id, $0.parentFolderID) })
        for kind in [EntityKind.connections, .identities, .sshKeys] {
            let rows = try JSONDecoder().decode([JSONObject].self, from: Data(try await core.entityList(kind: kind).utf8))
            for row in rows {
                if let id = row["id"]?.string, let folderID = row["folder_id"]?.string, doomed.contains(folderID) {
                    try await core.entityDelete(kind: kind, id: id)
                }
            }
        }
        for id in doomed { try await core.entityDelete(kind: .folders, id: id) }
    }

    // MARK: - Keychain

    /// Upstream `key_save` (new) or `key_update` (commands/keys.rs), then its slots as `saveKeyFromForm`
    /// (src/services/keychainForm.ts:11) writes them; a duplicate first gets every slot of the original (`copyObjectSecrets`).
    func save(_ key: SshKey, _ secrets: KeySecrets) async throws {
        let isNew = try await saveStamped(key, as: .sshKeys, seeded: Self.keyClocks, tracked: Self.keyClocks)
        let slots = Self.keySecretKeys(of: key.id)
        if let original = secrets.copyFrom { try copySecrets(Self.keySecretKeys(of: original), to: slots) }
        try writeSecrets(zip(slots, [secrets.privateKey, secrets.publicKey, secrets.passphrase]), isNew: isNew)
    }

    /// Upstream `identity_save` (new) or `identity_update` (commands/identities.rs), then `identity:<id>:password` as
    /// `saveIdentityFromForm` (src/services/keychainForm.ts:32) writes it.
    func save(_ identity: Identity, _ secrets: IdentitySecrets) async throws {
        let isNew = try await saveStamped(identity, as: .identities, seeded: Self.identityClocks, tracked: Self.identityClocks)
        let slot = "identity:\(identity.id):password"
        if let original = secrets.copyFrom { try copySecrets(["identity:\(original):password"], to: [slot]) }
        try writeSecrets([(slot, secrets.password)], isNew: isNew)
    }

    /// Upstream `key_delete`: a tombstone. Nothing referring to it changes and its secrets stay, as in upstream.
    func delete(_ key: SshKey) async throws {
        try await core.entityDelete(kind: .sshKeys, id: key.id)
    }

    /// Upstream `identity_delete`: a tombstone, like a key's.
    func delete(_ identity: Identity) async throws {
        try await core.entityDelete(kind: .identities, id: identity.id)
    }

    /// The keychain page's key work: generation in the core (upstream `generate_ssh_keypair`, its options as
    /// src/services/keys.ts:19 sends them, absent ones null), and the halves from the vault.
    var keyOperations: KeyOperations {
        let core = core
        return KeyOperations(
            generate: { options in
                let json: JSONObject = [
                    "keyType": .string(options.keyType), "curve": nullable(options.curve),
                    "bits": options.bits.map { .int(Int64($0)) } ?? .null, "passphrase": nullable(options.passphrase),
                    "cipher": nullable(options.cipher), "rounds": options.rounds.map { .int(Int64($0)) } ?? .null,
                ]
                let pair = try JSONDecoder().decode([String: String].self, from: Data(try await core.generateSshKeypair(optionsJson: jsonString(json)).utf8))
                return GeneratedKey(privateKey: pair["private_key"] ?? "", publicKey: pair["public_key"] ?? "")
            },
            publicKey: { key in try await Self.publicKey(of: key.id, core) },
            privateKey: { key in try core.secretGet(key: "key:\(key.id):private").flatMap { $0.isEmpty ? nil : $0 } }
        )
    }

    /// Upstream `ensurePublicKey`: the stored `key:<id>:public`, else derived from the stored private half and
    /// passphrase (`ssh_public_key_from_private`) and stored. nil when neither is stored.
    // shortcut: upstream also checks a stored public half with `isValidSshPublicKey`; add if bad ones turn up.
    nonisolated static func publicKey(of id: String, _ core: Core) async throws -> String? {
        if let stored = try core.secretGet(key: "key:\(id):public"), !stored.isEmpty { return stored }
        guard let privateKey = try core.secretGet(key: "key:\(id):private"), !privateKey.isEmpty else { return nil }
        let passphrase = try core.secretGet(key: "key:\(id):passphrase").flatMap { $0.isEmpty ? nil : $0 }
        let derived = try await core.sshPublicKeyFromPrivate(privateKey: privateKey, passphrase: passphrase)
        try core.secretSet(key: "key:\(id):public", value: derived)
        return derived
    }

    /// Upstream `key:<id>:private`, `key:<id>:public`, `key:<id>:passphrase`, in `KeySecrets` order.
    static func keySecretKeys(of id: String) -> [String] {
        ["key:\(id):private", "key:\(id):public", "key:\(id):passphrase"]
    }

    // MARK: - Helpers

    /// Upstream `applyEdits` (src/services/vaultObjectSecrets.ts:89): nil leaves a slot as it is, "" clears it (on an
    /// update only: upstream clears nothing on create), anything else is stored.
    private func writeSecrets(_ edits: some Sequence<(String, String?)>, isNew: Bool) throws {
        for (key, value) in edits {
            guard let value else { continue }
            if !value.isEmpty {
                try core.secretSet(key: key, value: value)
            } else if !isNew {
                try core.secretDelete(key: key)
            }
        }
    }

    /// Upstream `copyObjectSecrets`: each stored slot of `from` under the matching key of `to`.
    private func copySecrets(_ from: [String], to: [String]) throws {
        for (from, to) in zip(from, to) {
            if let value = try core.secretGet(key: from), !value.isEmpty { try core.secretSet(key: to, value: value) }
        }
    }

    /// `root` and every folder under it.
    static func subtree(_ root: String, _ parents: [(id: String, parent: String?)]) -> Set<String> {
        var doomed: Set = [root]
        var size = 0
        while doomed.count != size {
            size = doomed.count
            doomed.formUnion(parents.filter { $0.parent.map(doomed.contains) == true }.map(\.id))
        }
        return doomed
    }

    /// Stamps `row` against its stored version and saves it. Returns whether it is new.
    @discardableResult
    private func saveStamped<Fields: LosslessFields & Identifiable>(
        _ row: Lossless<Fields>, as kind: EntityKind, seeded: [String], tracked: [String]
    ) async throws -> Bool {
        let stored: [Lossless<Fields>] = try await list(kind)
        let old = stored.first { $0.id == row.id }
        let stamped = try Self.stamped(row, over: old, seeded: seeded, tracked: tracked, at: Self.timestamp())
        try await core.entitySave(kind: kind, row: String(decoding: JSONEncoder().encode(stamped), as: UTF8.self))
        return old == nil
    }

    /// Upstream `CONNECTION_SECRET_KEYS` order: password, pasted key, its passphrase, proxy password, knock sequence.
    static func secretKeys(of id: String) -> [String] {
        ["password:\(id)", "key:\(id)", "passphrase:\(id)", "proxy_password:\(id)", "knock_sequence:\(id)"]
    }

    // MARK: - Stamps

    /// Upstream `connection_clocks!` (commands/connections.rs): seeded on create, stamped on change.
    /// `pinned` is device-local and `last_used_at` has its own command, so neither is listed.
    static let connectionClocks = [
        "name", "host", "port", "username", "auth_type", "tags", "identity_id", "key_id", "folder_id", "vault_id",
        "agent_forwarding", "legacy_algorithms", "pre_command", "post_command", "pre_snippet_id", "post_snippet_id",
        "ask_vars_each_time", "terminal_encoding", "distro", "icon", "ping_disabled", "shell_integration",
        "keepalive_preset", "persist_session", "proxy", "port_knock", "connection_type", "serial_port", "serial_baud",
        "serial_data_bits", "serial_parity", "serial_stop_bits", "serial_flow_control", "serial_auto_reconnect",
        "ftp_secure", "webdav_url", "web_secure", "notes", "jump_hosts", "env_vars",
    ]
    /// Upstream commands/folders.rs: `folder_save` seeds these clocks …
    static let folderCreateClocks = ["name", "parent_folder_id", "object_type", "vault_id", "color", "icon"]
    /// … and `folder_update` stamps these: `pinned` too, never `object_type`.
    static let folderUpdateClocks = ["vault_id", "name", "parent_folder_id", "pinned", "color", "icon"]
    /// Upstream commands/keys.rs `CLOCK_FIELDS`: seeded on create and, with `vault_id` only when it moves, stamped on update.
    static let keyClocks = ["name", "key_type", "tags", "folder_id", "vault_id"]
    /// Upstream commands/identities.rs, the same way.
    static let identityClocks = ["name", "username", "key_id", "tags", "folder_id", "vault_id"]
    /// Collections clocked by their entries' ids only: an edit inside an entry does not stamp the parent.
    private static let clockedByID: Set = ["jump_hosts", "env_vars"]

    /// Upstream's Rust stamping. New: `created_at`, `updated_at` and each `seeded` clock at `now`. Existing: the
    /// stored clocks plus `now` for each `tracked` field whose value changed, the stored `created_at`, revived,
    /// and `updated_at` the newest clock, so a save that changes nothing leaves it alone.
    static func stamped<Fields: LosslessFields>(
        _ row: Lossless<Fields>, over stored: Lossless<Fields>?, seeded: [String], tracked: [String], at now: String
    ) throws -> Lossless<Fields> {
        func typed(_ fields: Fields) throws -> JSONObject {
            try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(fields))
        }
        var json = try row.json()
        var clocks: JSONObject = [:]
        if let stored {
            let before = try typed(stored.fields), after = try typed(row.fields)
            if case .object(let old)? = before["clocks"] { clocks = old }
            for field in tracked {
                let (a, b) = (before[field] ?? .null, after[field] ?? .null)
                let changed = clockedByID.contains(field) ? a.array?.map { $0["id"] } != b.array?.map { $0["id"] } : a != b
                if changed { clocks[field] = .string(now) }
            }
            json["created_at"] = before["created_at"]
            json["updated_at"] = .string(clocks.values.compactMap(\.string).max() ?? now)
        } else {
            for field in seeded { clocks[field] = .string(now) }
            json["created_at"] = .string(now)
            json["updated_at"] = .string(now)
        }
        json["clocks"] = .object(clocks)
        json["deleted_at"] = .null
        return try Lossless(json: json)
    }

    /// `chrono::Utc::now().to_rfc3339()`, what upstream's Rust commands stamp: UTC written `+00:00`, the fraction
    /// in 0, 3, 6 or 9 digits, the fewest that keep every non-zero one (`SecondsFormat::AutoSi`). Clocks compare
    /// as plain strings across clients, so this must match exactly (JS `toISOString`'s `…000Z` would not).
    static func timestamp() -> String {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return timestamp(seconds: now.tv_sec, nanoseconds: now.tv_nsec)
    }

    static func timestamp(seconds: Int, nanoseconds n: Int) -> String {
        var time = seconds
        var t = tm()
        gmtime_r(&time, &t)
        let fraction = n == 0 ? ""
            : n % 1_000_000 == 0 ? String(format: ".%03ld", n / 1_000_000)
            : n % 1000 == 0 ? String(format: ".%06ld", n / 1000)
            : String(format: ".%09ld", n)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec)
            + fraction + "+00:00"
    }
}
