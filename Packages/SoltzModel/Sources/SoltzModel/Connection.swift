// SPDX-License-Identifier: AGPL-3.0-only

/// A host in `connections.json`. Mirrors Rust `storage::config::Connection`.
public typealias Connection = Lossless<ConnectionFields>
public typealias JumpHost = Lossless<JumpHostFields>
public typealias EnvVar = Lossless<EnvVarFields>
public typealias ProxyOverride = Lossless<ProxyOverrideFields>
public typealias PortKnock = Lossless<PortKnockFields>

public struct ConnectionFields: LosslessFields, Identifiable {
    public var id: String
    public var name: String?
    public var host: String
    public var port: UInt16
    public var username: String
    public var authType: AuthType
    public var tags: [String]
    public var createdAt: String
    public var lastUsedAt: String?
    public var distro: String?
    public var icon: String?
    public var identityID: String?
    public var keyID: String?
    public var folderID: String?
    public var vaultID: String
    public var jumpHosts: [JumpHost]
    public var envVars: [EnvVar]
    public var agentForwarding: Bool
    public var legacyAlgorithms: Bool
    public var preCommand: String?
    public var postCommand: String?
    public var preSnippetID: String?
    public var postSnippetID: String?
    public var askVarsEachTime: Bool
    public var terminalEncoding: String?
    public var pinned: Bool
    public var pingDisabled: Bool
    /// nil inherits the global toggle.
    public var shellIntegration: Bool?
    /// nil inherits the global setting.
    public var keepalivePreset: KeepalivePreset?
    /// nil inherits the global setting.
    public var persistSession: Bool?
    public var proxy: ProxyOverride?
    /// The knock port sequence itself is a secret, not stored here.
    public var portKnock: PortKnock?
    public var connectionType: ConnectionType
    // Serial settings are flat keys on disk, so they stay flat here.
    public var serialPort: String?
    public var serialBaud: UInt32?
    public var serialDataBits: UInt8?
    public var serialParity: SerialParity?
    public var serialStopBits: UInt8?
    public var serialFlowControl: SerialFlowControl?
    public var serialAutoReconnect: Bool?
    /// FTP only: explicit FTPS.
    public var ftpSecure: Bool
    public var webdavURL: String?
    /// Web only: HTTPS instead of HTTP.
    public var webSecure: Bool
    public var notes: String?
    public var updatedAt: String
    public var deletedAt: String?
    /// Per-field LWW clocks: JSON field name → RFC 3339; `__deleted__` clocks `deleted_at`.
    public var clocks: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, tags, distro, icon, pinned, proxy, notes, clocks
        case authType = "auth_type", createdAt = "created_at", lastUsedAt = "last_used_at"
        case identityID = "identity_id", keyID = "key_id", folderID = "folder_id", vaultID = "vault_id"
        case jumpHosts = "jump_hosts", envVars = "env_vars", agentForwarding = "agent_forwarding"
        case legacyAlgorithms = "legacy_algorithms", preCommand = "pre_command", postCommand = "post_command"
        case preSnippetID = "pre_snippet_id", postSnippetID = "post_snippet_id"
        case askVarsEachTime = "ask_vars_each_time", terminalEncoding = "terminal_encoding"
        case pingDisabled = "ping_disabled", shellIntegration = "shell_integration"
        case keepalivePreset = "keepalive_preset", persistSession = "persist_session", portKnock = "port_knock"
        case connectionType = "connection_type", serialPort = "serial_port", serialBaud = "serial_baud"
        case serialDataBits = "serial_data_bits", serialParity = "serial_parity"
        case serialStopBits = "serial_stop_bits", serialFlowControl = "serial_flow_control"
        case serialAutoReconnect = "serial_auto_reconnect", ftpSecure = "ftp_secure"
        case webdavURL = "webdav_url", webSecure = "web_secure"
        case updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public static let defaults: JSONObject = [
        "host": "", "port": 0, "username": "", "auth_type": "password", "vault_id": "personal",
        "jump_hosts": [], "env_vars": [], "agent_forwarding": false, "legacy_algorithms": false,
        "ask_vars_each_time": false, "pinned": false, "ping_disabled": false, "connection_type": "ssh",
        "ftp_secure": false, "web_secure": false,
    ]

    public static func migrate(_ object: inout JSONObject) { migrateLegacyRecord(&object) }
}

/// `connection_id` is live; the other fields are a fallback snapshot for a deleted or imported host.
public struct JumpHostFields: LosslessFields, Identifiable {
    public var id: String
    public var connectionID: String
    public var host: String?
    public var port: UInt16?
    public var username: String?
    public var identityID: String?

    enum CodingKeys: String, CodingKey {
        case id, host, port, username
        case connectionID = "connection_id", identityID = "identity_id"
    }
}

public struct EnvVarFields: LosslessFields, Identifiable {
    public var id: String
    public var key: String
    public var value: String
}

public struct ProxyOverrideFields: LosslessFields {
    public var mode: ProxyMode
    public var host: String?
    public var port: UInt16?
    public var username: String?
}

public struct PortKnockFields: LosslessFields {
    public var enabled: Bool
    public var delayMs: UInt64?
    public var settleMs: UInt64?
    public var windowSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case enabled, delayMs = "delay_ms", settleMs = "settle_ms", windowSecs = "window_secs"
    }
}
