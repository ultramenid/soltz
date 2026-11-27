// SPDX-License-Identifier: AGPL-3.0-only

// Rust-owned records from `storage/config.rs`. `clocks` everywhere: JSON field name → RFC 3339,
// with `__deleted__` clocking `deleted_at`.

/// `folders.json`. Loaded by Rust without the legacy `vault_ids` migration.
public typealias Folder = Lossless<FolderFields>
/// `identities.json`.
public typealias Identity = Lossless<IdentityFields>
/// `ssh_keys.json`. The key material itself lives in the secret store.
public typealias SshKey = Lossless<SshKeyFields>
/// `known_hosts.json`. Loaded without the legacy migration; not in upstream's sync file list.
public typealias KnownHost = Lossless<KnownHostFields>

public struct FolderFields: LosslessFields, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: String
    public var parentFolderID: String?
    public var objectType: FolderObjectType
    public var vaultID: String
    public var pinned: Bool?
    public var color: String?
    public var icon: String?
    public var updatedAt: String
    public var deletedAt: String?
    public var clocks: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, pinned, color, icon, clocks
        case createdAt = "created_at", parentFolderID = "parent_folder_id", objectType = "object_type"
        case vaultID = "vault_id", updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public static let defaults: JSONObject = ["object_type": "connection", "vault_id": "personal"]
}

public struct IdentityFields: LosslessFields, Identifiable {
    public var id: String
    public var name: String?
    public var username: String
    public var keyID: String?
    public var tags: [String]
    public var createdAt: String
    public var folderID: String?
    public var vaultID: String
    public var pinned: Bool
    public var updatedAt: String
    public var deletedAt: String?
    public var clocks: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, username, tags, pinned, clocks
        case keyID = "key_id", createdAt = "created_at", folderID = "folder_id", vaultID = "vault_id"
        case updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public static let defaults: JSONObject = ["tags": [], "vault_id": "personal", "pinned": false]
    public static func migrate(_ object: inout JSONObject) { migrateLegacyRecord(&object) }
}

public struct SshKeyFields: LosslessFields, Identifiable {
    public var id: String
    public var name: String?
    /// Free string written by the key generator/importer (e.g. "ed25519").
    public var keyType: String?
    public var tags: [String]
    public var createdAt: String
    public var folderID: String?
    public var vaultID: String
    public var pinned: Bool
    public var updatedAt: String
    public var deletedAt: String?
    public var clocks: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, tags, pinned, clocks
        case keyType = "key_type", createdAt = "created_at", folderID = "folder_id", vaultID = "vault_id"
        case updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public static let defaults: JSONObject = ["tags": [], "vault_id": "personal", "pinned": false]
    public static func migrate(_ object: inout JSONObject) { migrateLegacyRecord(&object) }
}

public struct KnownHostFields: LosslessFields, Identifiable {
    public var id: String
    public var host: String
    public var port: UInt16
    public var fingerprint: String
    public var name: String?
    public var vaultID: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
    public var clocks: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, host, port, fingerprint, name, clocks
        case vaultID = "vault_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public static let defaults: JSONObject = ["vault_id": "personal", "clocks": [:]]
}
