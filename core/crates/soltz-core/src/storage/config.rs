use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

pub const APP_IDENTIFIER: &str = "com.soltz.app";

fn default_folder_object_type() -> String {
    "connection".to_string()
}
fn default_personal() -> String {
    "personal".to_string()
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum AuthType {
    #[default]
    Password,
    Key,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionType {
    #[default]
    Ssh,
    Serial,
    Ftp,
    Webdav,
    /// A web UI (HTTP/HTTPS) opened in a webview instead of a terminal.
    Web,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    Direct,
    System,
    Socks5,
    Http,
    Https,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProxyOverride {
    pub mode: ProxyMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PortKnock {
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delay_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settle_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_secs: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JumpHost {
    pub id: String,
    pub connection_id: String,
    // Snapshot fields, optional. Host/port/username/credentials are resolved
    // dynamically from `connection_id` at use time; these remain only as a
    // fallback for deleted connections or jump hosts imported from external
    // formats that have no managed connection.
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub identity_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvVar {
    pub id: String,
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Folder {
    pub id: String,
    pub name: String,
    pub created_at: String,
    #[serde(default)]
    pub parent_folder_id: Option<String>,
    #[serde(default = "default_folder_object_type")]
    pub object_type: String,
    #[serde(default = "default_personal")]
    pub vault_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    /// Per-field LWW clocks: field_name → RFC3339 timestamp of last write.
    /// "__deleted__" key tracks when the entity was soft-deleted.
    pub clocks: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
pub struct FolderFormData {
    pub name: String,
    #[serde(default)]
    pub parent_folder_id: Option<String>,
    #[serde(default = "default_folder_object_type")]
    pub object_type: String,
    #[serde(default)]
    pub vault_id: Option<String>,
    #[serde(default)]
    pub pinned: Option<bool>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Connection {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub auth_type: AuthType,
    pub tags: Vec<String>,
    pub created_at: String,
    pub last_used_at: Option<String>,
    #[serde(default)]
    pub distro: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub identity_id: Option<String>,
    #[serde(default)]
    pub key_id: Option<String>,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default = "default_personal")]
    pub vault_id: String,
    #[serde(default)]
    pub jump_hosts: Vec<JumpHost>,
    #[serde(default)]
    pub env_vars: Vec<EnvVar>,
    #[serde(default)]
    pub agent_forwarding: bool,
    /// Allow weak legacy SSH algorithms (e.g. legacy Cisco IOS) for this host.
    #[serde(default)]
    pub legacy_algorithms: bool,
    #[serde(default)]
    pub pre_command: Option<String>,
    #[serde(default)]
    pub post_command: Option<String>,
    #[serde(default)]
    pub pre_snippet_id: Option<String>,
    #[serde(default)]
    pub post_snippet_id: Option<String>,
    #[serde(default)]
    pub ask_vars_each_time: bool,
    #[serde(default)]
    pub terminal_encoding: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub ping_disabled: bool,
    /// Per-host shell-integration override. None inherits the global toggle;
    /// Some(true) forces it on, Some(false) off. Mirrors `persist_session`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell_integration: Option<bool>,
    /// Per-host keepalive preset; None inherits the global setting.
    #[serde(default)]
    pub keepalive_preset: Option<String>,
    /// Per-host session persistence override. None inherits the global setting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persist_session: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<ProxyOverride>,
    /// Plain knock settings; the port sequence lives in the secret store.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port_knock: Option<PortKnock>,
    #[serde(default)]
    pub connection_type: ConnectionType,
    #[serde(default)]
    pub serial_port: Option<String>,
    #[serde(default)]
    pub serial_baud: Option<u32>,
    #[serde(default)]
    pub serial_data_bits: Option<u8>,
    #[serde(default)]
    pub serial_parity: Option<String>,
    #[serde(default)]
    pub serial_stop_bits: Option<u8>,
    #[serde(default)]
    pub serial_flow_control: Option<String>,
    pub serial_auto_reconnect: Option<bool>,
    /// FTP only: use explicit FTPS (AUTH TLS) instead of plain FTP.
    #[serde(default)]
    pub ftp_secure: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub webdav_url: Option<String>,
    /// Web only: use HTTPS instead of HTTP.
    #[serde(default)]
    pub web_secure: bool,
    /// Free-form user notes for this host (reminders, maintenance windows, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub clocks: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
pub struct ConnectionFormData {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub auth_type: AuthType,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub identity_id: Option<String>,
    #[serde(default)]
    pub key_id: Option<String>,
    #[serde(default)]
    pub folder_id: Option<String>,
    /// None = keep existing vault on update, defaults to "personal" on create
    #[serde(default)]
    pub vault_id: Option<String>,
    #[serde(default)]
    pub jump_hosts: Vec<JumpHost>,
    #[serde(default)]
    pub env_vars: Vec<EnvVar>,
    #[serde(default)]
    pub agent_forwarding: bool,
    #[serde(default)]
    pub legacy_algorithms: bool,
    #[serde(default)]
    pub pre_command: Option<String>,
    #[serde(default)]
    pub post_command: Option<String>,
    #[serde(default)]
    pub pre_snippet_id: Option<String>,
    #[serde(default)]
    pub post_snippet_id: Option<String>,
    #[serde(default)]
    pub ask_vars_each_time: bool,
    #[serde(default)]
    pub terminal_encoding: Option<String>,
    #[serde(default)]
    pub distro: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub ping_disabled: bool,
    #[serde(default)]
    pub shell_integration: Option<bool>,
    #[serde(default)]
    pub keepalive_preset: Option<String>,
    #[serde(default)]
    pub persist_session: Option<bool>,
    #[serde(default)]
    pub proxy: Option<ProxyOverride>,
    #[serde(default)]
    pub port_knock: Option<PortKnock>,
    #[serde(default)]
    pub connection_type: ConnectionType,
    #[serde(default)]
    pub serial_port: Option<String>,
    #[serde(default)]
    pub serial_baud: Option<u32>,
    #[serde(default)]
    pub serial_data_bits: Option<u8>,
    #[serde(default)]
    pub serial_parity: Option<String>,
    #[serde(default)]
    pub serial_stop_bits: Option<u8>,
    #[serde(default)]
    pub serial_flow_control: Option<String>,
    pub serial_auto_reconnect: Option<bool>,
    #[serde(default)]
    pub ftp_secure: bool,
    #[serde(default)]
    pub webdav_url: Option<String>,
    #[serde(default)]
    pub web_secure: bool,
    #[serde(default)]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Identity {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    pub username: String,
    #[serde(default)]
    pub key_id: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub created_at: String,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default = "default_personal")]
    pub vault_id: String,
    #[serde(default)]
    pub pinned: bool,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub clocks: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
pub struct IdentityFormData {
    #[serde(default)]
    pub name: Option<String>,
    pub username: String,
    #[serde(default)]
    pub key_id: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub vault_id: Option<String>,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshKey {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub key_type: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub created_at: String,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default = "default_personal")]
    pub vault_id: String,
    #[serde(default)]
    pub pinned: bool,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    pub clocks: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
pub struct SshKeyFormData {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub key_type: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub vault_id: Option<String>,
    #[serde(default)]
    pub pinned: bool,
}

// ─── Backward-compat migration ───────────────────────────────────────────────

/// Migrate an entity JSON object from the old `vault_ids: [...]` format
/// to the new `vault_id: "..."` format.  No-op if already migrated.
fn migrate_vault_id(obj: &mut serde_json::Map<String, serde_json::Value>) {
    if obj.contains_key("vault_id") {
        obj.remove("vault_ids");
        return;
    }
    let vault_id = obj
        .remove("vault_ids")
        .and_then(|v| match v {
            serde_json::Value::Array(arr) => arr
                .into_iter()
                .next()
                .and_then(|e| e.as_str().map(str::to_string)),
            serde_json::Value::String(s) => Some(s),
            _ => None,
        })
        .unwrap_or_else(|| "personal".to_string());
    obj.insert("vault_id".to_string(), serde_json::Value::String(vault_id));
}

/// Fold the old disable-only flag into the tri-state `shell_integration`.
/// `shell_integration_disabled: true` means force-off, so it becomes
/// `shell_integration: false`; legacy `false` meant "follow global", which is
/// absence. An existing `shell_integration` always wins, so this is idempotent.
fn migrate_shell_integration(obj: &mut serde_json::Map<String, serde_json::Value>) {
    let legacy = obj.remove("shell_integration_disabled");
    if obj.contains_key("shell_integration") {
        return;
    }
    if legacy == Some(serde_json::Value::Bool(true)) {
        obj.insert(
            "shell_integration".to_string(),
            serde_json::Value::Bool(false),
        );
    }
}

/// Drop legacy/invalid `auth_type`/`connection_type` strings so `#[serde(default)]`
/// supplies a valid enum variant instead of the record failing to deserialize
/// (which would silently drop it). New code only ever writes valid variants.
fn migrate_enum_fields(obj: &mut serde_json::Map<String, serde_json::Value>) {
    drop_unless_valid::<AuthType>(obj, "auth_type");
    drop_unless_valid::<ConnectionType>(obj, "connection_type");
}

fn drop_unless_valid<T: serde::de::DeserializeOwned>(
    obj: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
) {
    if obj
        .get(key)
        .is_some_and(|v| serde_json::from_value::<T>(v.clone()).is_err())
    {
        obj.remove(key);
    }
}

fn parse_with_migration<T: serde::de::DeserializeOwned>(data: &str) -> Result<Vec<T>, String> {
    let raw: Vec<serde_json::Value> = serde_json::from_str(data).map_err(|e| e.to_string())?;
    Ok(raw
        .into_iter()
        .filter_map(|mut v| {
            if let serde_json::Value::Object(ref mut map) = v {
                migrate_vault_id(map);
                migrate_shell_integration(map);
                migrate_enum_fields(map);
            }
            serde_json::from_value(v).ok()
        })
        .collect())
}

// ─── File helpers ────────────────────────────────────────────────────────────

#[cfg(not(test))]
fn default_config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("soltz")
}

// Per test thread: libtest runs each test on its own thread, and the TempDir is removed when it exits.
#[cfg(test)]
fn default_config_dir() -> PathBuf {
    thread_local! {
        static DIR: tempfile::TempDir = tempfile::tempdir().expect("test config dir");
    }
    DIR.with(|d| d.path().to_path_buf())
}

/// `name` if it is a single path component that cannot leave its directory.
pub fn plain_leaf(name: &str) -> Option<&str> {
    let ok = !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\');
    ok.then_some(name)
}

pub fn app_data_dir() -> Result<PathBuf, String> {
    dirs::data_dir()
        .map(|d| d.join(APP_IDENTIFIER))
        .ok_or_else(|| "Failed to get app data dir".to_string())
}

pub fn config_dir_peek() -> PathBuf {
    default_config_dir()
}

pub fn config_dir() -> PathBuf {
    let dir = config_dir_peek();
    fs::create_dir_all(&dir).ok();
    dir
}

fn connections_file() -> PathBuf {
    config_dir().join("connections.json")
}
fn identities_file() -> PathBuf {
    config_dir().join("identities.json")
}
fn keys_file() -> PathBuf {
    config_dir().join("ssh_keys.json")
}
fn folders_file() -> PathBuf {
    config_dir().join("folders.json")
}
pub fn known_hosts_file() -> PathBuf {
    config_dir().join("known_hosts.json")
}

// ─── Generic JSON load/save ──────────────────────────────────────────────────

/// Renames a corrupt file aside so a later save can't overwrite the only copy.
fn side_band_corrupt_file(path: &std::path::Path) {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return;
    };
    let ts = chrono::Utc::now().format("%Y%m%d%H%M%S%3f");
    let corrupt = path.with_file_name(format!("{name}.corrupt-{ts}"));
    let _ = fs::rename(path, corrupt);
}

/// `T::default()` if `path` is absent; `Err` (never a silent empty value) if it
/// exists but can't be read or parsed.
pub(crate) fn load_json<T: serde::de::DeserializeOwned + Default>(
    path: PathBuf,
) -> Result<T, String> {
    if !path.exists() {
        return Ok(T::default());
    }
    let data =
        fs::read_to_string(&path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    serde_json::from_str(&data).map_err(|e| {
        side_band_corrupt_file(&path);
        format!("failed to parse {}: {e}", path.display())
    })
}

/// Like [`load_json`] but applies the `vault_ids` → `vault_id` migration to
/// each record (see [`parse_with_migration`]).
pub(crate) fn load_json_migrated<T: serde::de::DeserializeOwned>(
    path: PathBuf,
) -> Result<Vec<T>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let data =
        fs::read_to_string(&path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    parse_with_migration(&data).map_err(|e| {
        side_band_corrupt_file(&path);
        format!("failed to parse {}: {e}", path.display())
    })
}

/// Pretty-print `value` as JSON and write it to `path`.
pub(crate) fn save_json<T: Serialize + ?Sized>(path: PathBuf, value: &T) -> Result<(), String> {
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    super::secrets::write_atomic(&path, data.as_bytes()).map_err(String::from)
}

pub fn load_connections() -> Result<Vec<Connection>, String> {
    load_json_migrated(connections_file())
}

pub fn save_connections(connections: &[Connection]) -> Result<(), String> {
    save_json(connections_file(), connections)
}

pub fn load_identities() -> Result<Vec<Identity>, String> {
    load_json_migrated(identities_file())
}

pub fn save_identities(identities: &[Identity]) -> Result<(), String> {
    save_json(identities_file(), identities)
}

pub fn load_keys() -> Result<Vec<SshKey>, String> {
    load_json_migrated(keys_file())
}

pub fn save_keys(keys: &[SshKey]) -> Result<(), String> {
    save_json(keys_file(), keys)
}

pub fn load_folders() -> Result<Vec<Folder>, String> {
    load_json(folders_file())
}

pub fn save_folders(folders: &[Folder]) -> Result<(), String> {
    save_json(folders_file(), folders)
}

// ─── Known Hosts ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnownHost {
    pub id: String,
    pub host: String,
    pub port: u16,
    pub fingerprint: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default = "default_personal")]
    pub vault_id: String,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
    #[serde(default)]
    pub clocks: HashMap<String, String>,
}

pub fn load_known_hosts() -> Result<Vec<KnownHost>, String> {
    load_json(known_hosts_file())
}

pub fn save_known_hosts(entries: &[KnownHost]) -> Result<(), String> {
    save_json(known_hosts_file(), entries)
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    use super::*;
    use serde::de::DeserializeOwned;

    /// Asserts that `value` survives a JSON serialize → deserialize → serialize
    /// cycle unchanged. Compares `serde_json::Value`s (not strings) so that
    /// `HashMap` clock ordering does not make the assertion flaky.
    fn assert_json_round_trip<T: Serialize + DeserializeOwned>(value: &T) {
        let v1 = serde_json::to_value(value).expect("serialize");
        let back: T = serde_json::from_value(v1.clone()).expect("deserialize");
        let v2 = serde_json::to_value(&back).expect("re-serialize");
        assert_eq!(v1, v2);
    }

    #[test]
    fn shell_integration_migration_folds_the_legacy_disable_flag() {
        let cases = [
            // legacy force-off -> tri-state off
            (r#"{"shell_integration_disabled":true}"#, Some(false)),
            // legacy false meant "follow global" -> inherit
            (r#"{"shell_integration_disabled":false}"#, None),
            (r#"{}"#, None),
            // already migrated, and the new field wins over a stale legacy one
            (r#"{"shell_integration":true}"#, Some(true)),
            (
                r#"{"shell_integration":true,"shell_integration_disabled":true}"#,
                Some(true),
            ),
        ];
        for (input, want) in cases {
            let mut obj = match serde_json::from_str(input).expect("json") {
                serde_json::Value::Object(m) => m,
                _ => unreachable!(),
            };
            migrate_shell_integration(&mut obj);
            let got = obj.get("shell_integration").and_then(|v| v.as_bool());
            assert_eq!(got, want, "input {input}");
            assert!(
                !obj.contains_key("shell_integration_disabled"),
                "legacy key must not survive: {input}"
            );
        }
    }

    fn clocks() -> HashMap<String, String> {
        let mut c = HashMap::new();
        c.insert("name".to_string(), "2026-01-01T00:00:00Z".to_string());
        c.insert("host".to_string(), "2026-01-02T00:00:00Z".to_string());
        c
    }

    fn sample_connection() -> Connection {
        Connection {
            id: "conn-1".into(),
            name: Some("web".into()),
            host: "example.com".into(),
            port: 22,
            username: "root".into(),
            auth_type: AuthType::Key,
            tags: vec!["prod".into(), "eu".into()],
            created_at: "2026-01-01T00:00:00Z".into(),
            last_used_at: Some("2026-01-05T00:00:00Z".into()),
            distro: Some("ubuntu".into()),
            icon: Some("server".into()),
            identity_id: Some("id-1".into()),
            key_id: Some("key-1".into()),
            folder_id: Some("folder-1".into()),
            vault_id: "team".into(),
            jump_hosts: vec![JumpHost {
                id: "jh-1".into(),
                connection_id: "c-9".into(),
                host: Some("bastion".into()),
                port: Some(2222),
                username: Some("jump".into()),
                identity_id: Some("id-2".into()),
            }],
            env_vars: vec![EnvVar {
                id: "ev-1".into(),
                key: "TERM".into(),
                value: "xterm".into(),
            }],
            agent_forwarding: true,
            legacy_algorithms: false,
            pre_command: Some("echo hi".into()),
            post_command: Some("echo bye".into()),
            pre_snippet_id: None,
            post_snippet_id: None,
            ask_vars_each_time: false,
            terminal_encoding: Some("utf-8".into()),
            pinned: true,
            ping_disabled: false,
            shell_integration: None,
            keepalive_preset: None,
            persist_session: None,
            proxy: None,
            port_knock: None,
            connection_type: ConnectionType::Ssh,
            serial_port: Some("/dev/ttyU0".into()),
            serial_baud: Some(9600),
            serial_data_bits: Some(8),
            serial_parity: Some("none".into()),
            serial_stop_bits: Some(1),
            serial_flow_control: Some("none".into()),
            serial_auto_reconnect: Some(true),
            ftp_secure: false,
            webdav_url: None,
            web_secure: false,
            notes: Some("maintenance window: Sat".into()),
            updated_at: "2026-01-02T00:00:00Z".into(),
            deleted_at: None,
            clocks: clocks(),
        }
    }

    #[test]
    fn connection_row_without_port_knock_loads_as_none() {
        let mut row = serde_json::to_value(sample_connection()).unwrap();
        assert!(row.as_object_mut().unwrap().remove("port_knock").is_none());
        let loaded: Connection = serde_json::from_value(row).unwrap();
        assert_eq!(loaded.port_knock, None);
    }

    fn sample_identity() -> Identity {
        Identity {
            id: "id-1".into(),
            name: Some("admin".into()),
            username: "root".into(),
            key_id: Some("key-1".into()),
            tags: vec!["prod".into()],
            created_at: "2026-01-01T00:00:00Z".into(),
            folder_id: Some("folder-1".into()),
            vault_id: "team".into(),
            pinned: true,
            updated_at: "2026-01-02T00:00:00Z".into(),
            deleted_at: None,
            clocks: clocks(),
        }
    }

    fn sample_folder() -> Folder {
        Folder {
            id: "folder-1".into(),
            name: "Servers".into(),
            created_at: "2026-01-01T00:00:00Z".into(),
            parent_folder_id: Some("root".into()),
            object_type: "connection".into(),
            vault_id: "team".into(),
            pinned: Some(true),
            color: Some("#22c55e".into()),
            icon: Some("lucide:house".into()),
            updated_at: "2026-01-02T00:00:00Z".into(),
            deleted_at: None,
            clocks: clocks(),
        }
    }

    #[test]
    fn connection_serde_round_trip() {
        assert_json_round_trip(&sample_connection());
    }

    #[test]
    fn identity_serde_round_trip() {
        assert_json_round_trip(&sample_identity());
    }

    #[test]
    fn folder_serde_round_trip() {
        assert_json_round_trip(&sample_folder());
    }

    #[test]
    fn deleted_connection_serde_round_trip() {
        let mut c = sample_connection();
        c.deleted_at = Some("2026-02-01T00:00:00Z".into());
        c.clocks
            .insert("__deleted__".into(), "2026-02-01T00:00:00Z".into());
        assert_json_round_trip(&c);
    }

    // ── migrate_vault_id ────────────────────────────────────────────────────
    /// Runs `migrate_vault_id` over `input`'s object and returns the result.
    fn migrate(input: serde_json::Value) -> serde_json::Map<String, serde_json::Value> {
        let mut map = input.as_object().expect("object").clone();
        migrate_vault_id(&mut map);
        map
    }

    #[test]
    fn migrate_keeps_existing_vault_id_and_drops_vault_ids() {
        let out = migrate(serde_json::json!({ "vault_id": "keep", "vault_ids": ["x"] }));
        assert_eq!(out.get("vault_id").unwrap(), "keep");
        assert!(!out.contains_key("vault_ids"));
    }

    #[test]
    fn migrate_takes_first_element_of_vault_ids_array() {
        let out = migrate(serde_json::json!({ "vault_ids": ["team", "other"] }));
        assert_eq!(out.get("vault_id").unwrap(), "team");
        assert!(!out.contains_key("vault_ids"));
    }

    #[test]
    fn migrate_accepts_vault_ids_as_bare_string() {
        let out = migrate(serde_json::json!({ "vault_ids": "solo" }));
        assert_eq!(out.get("vault_id").unwrap(), "solo");
    }

    #[test]
    fn migrate_defaults_to_personal_for_empty_array() {
        let out = migrate(serde_json::json!({ "vault_ids": [] }));
        assert_eq!(out.get("vault_id").unwrap(), "personal");
    }

    #[test]
    fn migrate_defaults_to_personal_when_absent() {
        let out = migrate(serde_json::json!({ "other": 1 }));
        assert_eq!(out.get("vault_id").unwrap(), "personal");
    }

    #[test]
    fn migrate_defaults_to_personal_for_wrong_type() {
        let out = migrate(serde_json::json!({ "vault_ids": 42 }));
        assert_eq!(out.get("vault_id").unwrap(), "personal");
    }

    // ── migrate_enum_fields ─────────────────────────────────────────────────
    fn migrate_enums(input: serde_json::Value) -> serde_json::Map<String, serde_json::Value> {
        let mut map = input.as_object().expect("object").clone();
        migrate_enum_fields(&mut map);
        map
    }

    #[test]
    fn migrate_enum_keeps_valid_values() {
        let out =
            migrate_enums(serde_json::json!({ "auth_type": "key", "connection_type": "serial" }));
        assert_eq!(out.get("auth_type").unwrap(), "key");
        assert_eq!(out.get("connection_type").unwrap(), "serial");

        // FTP is a valid connection_type and must survive a load round-trip.
        let ftp = migrate_enums(serde_json::json!({ "connection_type": "ftp" }));
        assert_eq!(ftp.get("connection_type").unwrap(), "ftp");

        let webdav = migrate_enums(serde_json::json!({ "connection_type": "webdav" }));
        assert_eq!(webdav.get("connection_type").unwrap(), "webdav");
    }

    #[test]
    fn saved_webdav_connection_survives_load() {
        let mut json = serde_json::to_value(sample_connection()).unwrap();
        json["connection_type"] = "webdav".into();
        json["webdav_url"] = "https://h/dav/".into();
        let data = serde_json::to_string(&vec![json]).unwrap();
        let loaded = parse_with_migration::<Connection>(&data).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].connection_type, ConnectionType::Webdav);
        assert_eq!(loaded[0].webdav_url.as_deref(), Some("https://h/dav/"));
    }

    #[test]
    fn migrate_enum_drops_invalid_values_so_defaults_apply() {
        // Legacy empty/unknown strings must be removed, not deserialized — else the
        // whole connection record would be silently dropped on load.
        let out =
            migrate_enums(serde_json::json!({ "auth_type": "", "connection_type": "telnet" }));
        assert!(!out.contains_key("auth_type"));
        assert!(!out.contains_key("connection_type"));
    }

    // ── parse_with_migration ────────────────────────────────────────────────
    #[derive(serde::Deserialize, Debug, PartialEq)]
    struct Mini {
        id: String,
    }

    #[derive(serde::Deserialize, Debug, PartialEq)]
    struct WithVault {
        id: String,
        vault_id: String,
    }

    #[test]
    fn parse_reads_valid_array() {
        let got: Vec<Mini> = parse_with_migration(r#"[{"id":"a"},{"id":"b"}]"#).unwrap();
        assert_eq!(got, vec![Mini { id: "a".into() }, Mini { id: "b".into() }]);
    }

    #[test]
    fn parse_applies_migration_to_each_record() {
        let got: Vec<WithVault> =
            parse_with_migration(r#"[{"id":"a","vault_ids":["team","x"]}]"#).unwrap();
        assert_eq!(
            got,
            vec![WithVault {
                id: "a".into(),
                vault_id: "team".into(),
            }]
        );
    }

    #[test]
    fn parse_errors_on_malformed_json() {
        let got: Result<Vec<Mini>, String> = parse_with_migration("not valid json {");
        assert!(got.is_err());
    }

    #[test]
    fn parse_errors_when_top_level_is_not_an_array() {
        let got: Result<Vec<Mini>, String> = parse_with_migration(r#"{"id":"a"}"#);
        assert!(got.is_err());
    }

    #[test]
    fn parse_silently_drops_records_that_fail_to_deserialize() {
        // Pinned current behavior: a bad record is filtered out, not surfaced.
        let got: Vec<Mini> = parse_with_migration(r#"[{"id":"a"},{"nope":"b"}]"#).unwrap();
        assert_eq!(got, vec![Mini { id: "a".into() }]);
    }

    // ── End-to-end persistence (golden master for the load/save layer) ───────
    #[test]
    fn persistence_round_trip_and_on_disk_migration() {
        // A missing file loads as empty, not an error.
        assert!(load_identities().unwrap().is_empty());

        // save → load preserves the record.
        save_connections(&[sample_connection()]).expect("save");
        let loaded = load_connections().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "conn-1");
        assert_eq!(loaded[0].vault_id, "team");

        // Legacy `vault_ids` on disk is migrated to `vault_id` on load.
        let legacy = r#"[{"id":"c2","tags":[],"created_at":"t","last_used_at":null,
            "updated_at":"t","deleted_at":null,"clocks":{},"vault_ids":["legacy-team","x"]}]"#;
        std::fs::write(config_dir().join("connections.json"), legacy).unwrap();
        let migrated = load_connections().unwrap();
        assert_eq!(migrated.len(), 1);
        assert_eq!(migrated[0].vault_id, "legacy-team");
    }

    // ── #250: a corrupt entity file must error, not silently look empty ──────

    #[test]
    fn load_json_migrated_is_empty_for_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let items: Vec<KnownHost> =
            load_json_migrated(dir.path().join("connections.json")).unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn load_json_migrated_errors_on_a_corrupt_file_instead_of_returning_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("connections.json");
        fs::write(&path, "not json").unwrap();

        let result: Result<Vec<KnownHost>, String> = load_json_migrated(path.clone());
        assert!(result.is_err());

        // The bad file is renamed aside, not left for the next save to overwrite.
        assert!(!path.exists());
        let siblings: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .collect();
        assert_eq!(siblings.len(), 1);
        let corrupt_name = siblings[0].file_name().to_string_lossy().into_owned();
        assert!(
            corrupt_name.starts_with("connections.json.corrupt-"),
            "{corrupt_name}"
        );
        assert_eq!(fs::read_to_string(siblings[0].path()).unwrap(), "not json");
    }

    #[test]
    fn load_json_errors_on_a_corrupt_file_instead_of_returning_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("folders.json");
        fs::write(&path, "not json").unwrap();

        let result: Result<Vec<Folder>, String> = load_json(path.clone());
        assert!(result.is_err());
        assert!(!path.exists());
    }
}
