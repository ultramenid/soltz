// SPDX-License-Identifier: AGPL-3.0-only
//! What Swift sees: a [`Core`] that opens local shells and SSH sessions, each a
//! [`Session`] whose output and events go to the caller's [`SessionSink`]. With a
//! data directory it also keeps entities ([`crate::entities`]), known hosts and a
//! secrets vault ([`crate::vault`]).

use crate::async_runtime;
pub use crate::commands::files::TransferSink;
use crate::error::AppError;
pub use crate::error::ErrorCode;
use crate::knock::KnockSpec;
use crate::known_hosts::{ConflictAction, KnownHostsStore, PendingConflicts};
use crate::local::session::LocalSessionManager;
use crate::proxy::ProxySpec;
pub use crate::shell_integration::LiveSession;
use crate::sftp::SftpManager;
use crate::ssh::client::{self, HopRoute, JumpHostConnect};
use crate::ssh::control_mode::TerminalColors;
use crate::ssh::session::SessionManager;
use crate::storage::secrets::{SecretsStore, SECRETS_FILE};
use crate::terminal_output::{OutputSink, SessionApp, TerminalOutputs};
use crate::vault::VaultKeys;
use std::future::Future;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;

/// Receives one session's output and events, on background threads.
#[uniffi::export(with_foreign)]
pub trait SessionSink: Send + Sync {
    /// Raw terminal bytes, coalesced in 8 ms windows of at most 256 KiB.
    fn output(&self, data: Vec<u8>);
    /// The last call. `clean_exit` is false when the transport dropped rather
    /// than the shell exiting, i.e. when a reconnect makes sense.
    fn closed(&self, clean_exit: bool);
    /// An event with the payload the upstream frontend gets, as JSON. SSH sessions:
    /// `ssh-step` (connect progress), `ssh-host-key-conflict` (answer it with
    /// [`Core::resolve_host_key`]), `ssh-cwd` (the remote working directory, a JSON
    /// string) and, for a persistent session, `ssh-mux-mode` (`{control, tmux}`).
    fn event(&self, name: String, payload_json: String);
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
// Swift's `localizedDescription` is then the message, not the case.
#[uniffi::export(Display)]
pub enum CoreError {
    #[error("{message}")]
    Failed { message: String },
    /// A failure upstream names with a stable code, beside its English message.
    #[error("{message}")]
    Coded { code: ErrorCode, message: String },
}

pub(crate) fn failed(e: impl std::fmt::Display) -> CoreError {
    CoreError::Failed {
        message: e.to_string(),
    }
}

impl From<AppError> for CoreError {
    fn from(e: AppError) -> Self {
        let message = e.to_string();
        match e.code() {
            Some(code) => Self::Coded { code, message },
            None => Self::Failed { message },
        }
    }
}

/// Stops the call it is handed to. Swift's `sshConnect(sink:argsJson:)` fires it
/// when the calling task is cancelled.
#[derive(Default, uniffi::Object)]
pub struct Cancellation(CancellationToken);

#[uniffi::export]
impl Cancellation {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::default()
    }

    pub fn cancel(&self) {
        self.0.cancel();
    }
}

const CANCELLED: &str = "Connection cancelled";

/// Ids this core gives sessions. A persistent session's tmux/screen session is
/// named after its id (`soltz_soltz-…` on tmux's `soltz` socket), so it
/// can never be an upstream session, whose ids are bare UUIDs.
const SESSION_ID_PREFIX: &str = "soltz-";

fn new_session_id() -> String {
    format!("{SESSION_ID_PREFIX}{}", uuid::Uuid::new_v4())
}

/// Upstream's `ssh_connect` arguments (commands/ssh.rs) in the JSON
/// its frontend sends (src/services/ssh.ts `sshConnect`); absent ones take
/// `ssh_connect`'s defaults.
#[derive(Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SshConnectArgs {
    /// An earlier session's [`Session::id`], to reconnect under; a new id when absent.
    session_id: Option<String>,
    host: String,
    port: u16,
    username: String,
    password: Option<String>,
    private_key: Option<String>,
    passphrase: Option<String>,
    jump_hosts: Option<Vec<JumpHostConnect>>,
    env_vars: Option<Vec<(String, String)>>,
    #[serde(default)]
    agent_forwarding: bool,
    pre_command: Option<String>,
    shell_integration: Option<bool>,
    keepalive_interval_secs: Option<u64>,
    keepalive_max: Option<usize>,
    persist: Option<bool>,
    restore: Option<bool>,
    attach_only: Option<bool>,
    cols: Option<u32>,
    rows: Option<u32>,
    legacy_algorithms: Option<bool>,
    initial_cwd: Option<String>,
    proxy: Option<ProxySpec>,
    terminal_colors: Option<TerminalColors>,
    knock: Option<KnockSpec>,
    detached_ttl_secs: Option<u64>,
}

/// Answer to a changed host key (`ssh-host-key-conflict`).
#[derive(uniffi::Enum)]
pub enum HostKeyAction {
    /// Trust the new key alongside the stored ones.
    AddNew,
    /// Trust the new key instead of the stored ones.
    Replace,
    Abort,
}

/// Where a data directory's vault keeps its key material: the vault mode, the
/// master-password salt, or the key itself in OS-keychain mode.
#[derive(uniffi::Enum)]
pub enum Keychain {
    /// The login keychain: one item, service `soltz`, or `soltz-<ns>` when the
    /// `SOLTZ_KEYCHAIN_NS` environment variable holds `ns`.
    System,
    /// This process's memory, shared by the `Core`s of one data directory as the
    /// login keychain is by every launch. For tests.
    Memory,
}

#[derive(uniffi::Object)]
pub struct Core {
    outputs: Arc<TerminalOutputs>,
    local: LocalSessionManager,
    pub(crate) ssh: SessionManager,
    pub(crate) sftp: SftpManager,
    pub(crate) known_hosts: Arc<KnownHostsStore>,
    conflicts: Arc<PendingConflicts>,
    data: Option<Data>,
}

/// What [`Core::with_data_dir`] adds: the directory every file lives in, and its vault.
/// Locks `dir` against other processes until this one exits. Two apps on one folder would each rewrite
/// the whole vault file with what it holds, dropping what the other saved.
fn hold(dir: &std::path::Path) -> Result<(), CoreError> {
    static HELD: std::sync::LazyLock<Mutex<std::collections::HashMap<PathBuf, std::fs::File>>> =
        std::sync::LazyLock::new(Default::default);
    let mut held = HELD.lock().unwrap();
    if !held.contains_key(dir) {
        let lock = std::fs::File::create(dir.join(".lock")).map_err(failed)?;
        if lock.try_lock().is_err() {
            return Err(failed("Soltz is already open with this data"));
        }
        held.insert(dir.to_path_buf(), lock);
    }
    Ok(())
}

pub(crate) struct Data {
    pub(crate) dir: PathBuf,
    pub(crate) keys: VaultKeys,
    pub(crate) secrets: SecretsStore,
    /// One entity-file change at a time: each is a whole-file read, modify, write.
    pub(crate) entity_write: Mutex<()>,
}

impl Data {
    pub(crate) fn secrets_path(&self) -> PathBuf {
        self.dir.join(SECRETS_FILE)
    }
}

/// Upstream code reports through this the way the app's `AppHandle` does.
#[derive(Clone)]
struct App {
    outputs: Arc<TerminalOutputs>,
    sink: Arc<dyn SessionSink>,
    session_id: String,
}

impl SessionApp for App {
    fn terminal_outputs(&self) -> &TerminalOutputs {
        &self.outputs
    }

    fn emit<S: serde::Serialize + Clone>(&self, event: &str, payload: S) {
        let payload = serde_json::to_string(&payload).unwrap_or_default();
        let name = event_name(event, &self.session_id);
        self.sink.event(name.to_string(), payload);
    }
}

/// Upstream names a session's or transfer's events `<name>-<id>`; a sink is per
/// session or transfer, so it gets `<name>`.
pub(crate) fn event_name<'a>(event: &'a str, id: &str) -> &'a str {
    event
        .strip_suffix(id)
        .and_then(|e| e.strip_suffix('-'))
        .unwrap_or(event)
}

struct Output {
    sink: Arc<dyn SessionSink>,
    /// SSH sessions only: Ghostty takes OSC 7 from local shells alone.
    cwd: Option<Mutex<Osc7>>,
}

impl OutputSink for Output {
    // Never detached by id: closing a session removes its stream.
    fn id(&self) -> u32 {
        0
    }
    fn output(&self, data: Vec<u8>) {
        let cwds = self.cwd.as_ref().map(|c| c.lock().unwrap().feed(&data));
        self.sink.output(data);
        for cwd in cwds.into_iter().flatten() {
            let payload = serde_json::to_string(&cwd).unwrap_or_default();
            self.sink.event("ssh-cwd".into(), payload);
        }
    }
    fn closed(&self, clean_exit: bool) {
        self.sink.closed(clean_exit);
    }
}

const OSC7: &[u8] = b"\x1b]7;";
/// Longer than any path a shell reports; an unterminated sequence is dropped past it.
const MAX_OSC7: usize = 8192;

/// The working directory a shell reports in its output (`ESC ] 7 ; file://host/path`,
/// ended by BEL or ST), read as the upstream terminal reads it (src/hooks/useTerminal.ts).
/// Upstream polls it only for persistent sessions, until the first OSC 7 arrives.
#[derive(Default)]
struct Osc7 {
    /// The start of a sequence the last chunk cut off.
    held: Vec<u8>,
    last: Option<String>,
}

impl Osc7 {
    /// The new working directories `data` reports, in order.
    fn feed(&mut self, data: &[u8]) -> Vec<String> {
        let mut buf = std::mem::take(&mut self.held);
        buf.extend_from_slice(data);
        let mut found = Vec::new();
        let mut rest = &buf[..];
        while let Some(start) = rest.windows(OSC7.len()).position(|w| w == OSC7) {
            let body = &rest[start + OSC7.len()..];
            let end = body.iter().enumerate().find_map(|(i, &b)| match b {
                0x07 => Some((i, 1)),
                0x1b if body.get(i + 1) == Some(&b'\\') => Some((i, 2)),
                _ => None,
            });
            let Some((end, terminator)) = end else {
                if body.len() < MAX_OSC7 {
                    self.held = rest[start..].to_vec();
                }
                return found;
            };
            if let Some(path) = osc7_path(&body[..end]) {
                if self.last.as_ref() != Some(&path) {
                    self.last = Some(path.clone());
                    found.push(path);
                }
            }
            rest = &body[end + terminator..];
        }
        // A sequence whose introducer itself was cut off.
        let partial = (1..OSC7.len())
            .rev()
            .find(|&k| rest.ends_with(&OSC7[..k]))
            .unwrap_or(0);
        self.held = rest[rest.len() - partial..].to_vec();
        found
    }
}

/// `file://host/path` → `/path`, percent-decoded unless that fails (then as is).
fn osc7_path(uri: &[u8]) -> Option<String> {
    let uri = String::from_utf8_lossy(uri);
    let rest = uri.strip_prefix("file://")?;
    let raw = &rest[rest.find('/')?..];
    let path = percent_decode(raw).unwrap_or_else(|| raw.to_string());
    // The output stream chose this; a path with control characters is not one to hand back to a shell.
    (!path.chars().any(char::is_control)).then_some(path)
}

fn percent_decode(s: &str) -> Option<String> {
    let (bytes, mut out, mut i) = (s.as_bytes(), Vec::with_capacity(s.len()), 0);
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s
                .get(i + 1..i + 3)
                .filter(|h| h.bytes().all(|b| b.is_ascii_hexdigit()))?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Runs `future` on the core's tokio runtime, whatever executor awaits the result.
pub(crate) async fn on_runtime<T: Send + 'static>(
    future: impl Future<Output = T> + Send + 'static,
) -> T {
    async_runtime::spawn(future)
        .await
        .unwrap_or_else(|e| std::panic::resume_unwind(e.into_panic()))
}

/// Runs `job` (file I/O, the keychain, a key derivation) on the runtime's blocking pool.
pub(crate) async fn blocking<T: Send + 'static>(job: impl FnOnce() -> T + Send + 'static) -> T {
    async_runtime::spawn_blocking(job)
        .await
        .unwrap_or_else(|e| std::panic::resume_unwind(e.into_panic()))
}

#[uniffi::export]
impl Core {
    /// Sessions only: host keys are trusted for this process alone, and the
    /// entity and vault calls fail. [`Core::with_data_dir`] keeps them on disk.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Self::build(Arc::new(KnownHostsStore::new()), None)
    }

    /// A core whose entity files, known hosts (`known_hosts.json`) and vault
    /// (`secrets.enc`) live in `data_dir`, an absolute path it creates if needed.
    /// The vault's key material goes to `keychain`.
    #[uniffi::constructor]
    pub fn with_data_dir(data_dir: String, keychain: Keychain) -> Result<Arc<Self>, CoreError> {
        let dir = PathBuf::from(data_dir);
        if !dir.is_absolute() {
            return Err(failed("The data directory must be an absolute path"));
        }
        std::fs::create_dir_all(&dir).map_err(failed)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).map_err(failed)?;
        }
        hold(&dir)?;
        let data = Data {
            keys: VaultKeys::new(keychain, &dir).map_err(failed)?,
            secrets: SecretsStore::new(),
            entity_write: Mutex::new(()),
            dir,
        };
        let known_hosts = KnownHostsStore::open(data.dir.join("known_hosts.json"));
        Ok(Self::build(known_hosts, Some(data)))
    }

    /// Starts the user's login shell (`$SHELL`) in a PTY.
    pub async fn open_local_shell(
        self: Arc<Self>,
        sink: Arc<dyn SessionSink>,
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Session>, CoreError> {
        let app = self.attach(sink, new_session_id(), false);
        on_runtime(async move {
            let id = app.session_id.clone();
            // Same defaults as the app's `local_connect`.
            let spawned = self
                .local
                .spawn(app.clone(), id.clone(), cols, rows, None, None, true)
                .await;
            self.finish_open(app, spawned, Kind::Local)
        })
        .await
        .map_err(failed)
    }

    /// Connects, authenticates (private key first when both are given, then
    /// password or keyboard-interactive) and opens a shell. A host key that
    /// differs from the trusted one raises `ssh-host-key-conflict` on `sink`
    /// and waits for [`Core::resolve_host_key`]. [`Core::ssh_connect`] takes
    /// every option upstream has.
    pub async fn connect_ssh(
        self: Arc<Self>,
        sink: Arc<dyn SessionSink>,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key: Option<String>,
        passphrase: Option<String>,
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Session>, CoreError> {
        let args = SshConnectArgs {
            host,
            port,
            username,
            password,
            private_key,
            passphrase,
            persist: Some(false),
            cols: Some(cols.into()),
            rows: Some(rows.into()),
            ..SshConnectArgs::default()
        };
        self.open_ssh(sink, new_session_id(), args, CancellationToken::new())
            .await
            .map_err(failed)
    }

    /// Upstream's `ssh_connect` (commands/ssh.rs): connects a host the
    /// way upstream connects a saved one. `args_json` is the object its frontend
    /// invokes `ssh_connect` with (src/services/ssh.ts `sshConnect`), camelCase:
    /// `host`, `port`, `username` and optionally `sessionId`, `password`,
    /// `privateKey`, `passphrase`, `jumpHosts`, `envVars` (`[[key, value]]`),
    /// `agentForwarding`, `preCommand`, `shellIntegration`, `keepaliveIntervalSecs`,
    /// `keepaliveMax`, `persist` (default true), `restore`, `attachOnly`, `cols`,
    /// `rows`, `legacyAlgorithms`, `initialCwd`, `proxy`, `terminalColors`, `knock`,
    /// `detachedTtlSecs`. Any other key (`connectionId`, `autoForward`…) is ignored.
    ///
    /// A reconnect passes the dropped session's [`Session::id`] as `sessionId`,
    /// after [`Session::disconnect`] with `reconnecting`, and `attachOnly` for a
    /// persistent one: if its multiplexer session is gone, this fails with
    /// `SESSION_ENDED`, as upstream.
    /// `cancel` abandons the connect: the call fails and leaves no session.
    pub async fn ssh_connect(
        self: Arc<Self>,
        sink: Arc<dyn SessionSink>,
        args_json: String,
        cancel: Arc<Cancellation>,
    ) -> Result<Arc<Session>, CoreError> {
        let mut args: SshConnectArgs = serde_json::from_str(&args_json).map_err(failed)?;
        let id = match args.session_id.take() {
            Some(id) if !id.starts_with(SESSION_ID_PREFIX) => {
                return Err(failed("sessionId must be a Soltz session's id"))
            }
            Some(id) => id,
            None => new_session_id(),
        };
        Ok(self.open_ssh(sink, id, args, cancel.0.clone()).await?)
    }

    /// Answers the `ssh-host-key-conflict` event of the session being connected: `fingerprint` is the
    /// event's `new_fingerprint`, so an answer only ever applies to the key the user was shown.
    pub async fn resolve_host_key(&self, session_id: String, fingerprint: String, action: HostKeyAction) {
        let action = match action {
            HostKeyAction::AddNew => ConflictAction::AddNew,
            HostKeyAction::Replace => ConflictAction::Replace,
            HostKeyAction::Abort => ConflictAction::Abort,
        };
        self.conflicts.resolve(&session_id, &fingerprint, action).await;
    }
}

impl Core {
    fn build(known_hosts: Arc<KnownHostsStore>, data: Option<Data>) -> Arc<Self> {
        Arc::new(Self {
            outputs: Arc::default(),
            local: LocalSessionManager::new(),
            ssh: SessionManager::new(),
            sftp: SftpManager::new(),
            known_hosts,
            conflicts: Arc::new(PendingConflicts::new()),
            data,
        })
    }

    pub(crate) fn data(&self) -> Result<&Data, String> {
        self.data
            .as_ref()
            .ok_or_else(|| "This Core has no data directory: create it with withDataDir".into())
    }

    /// `sink` receiving the output of `session_id`, live (not gated like the app's
    /// local shells, which wait for the terminal to subscribe).
    fn attach(&self, sink: Arc<dyn SessionSink>, session_id: String, ssh: bool) -> App {
        let output = Output {
            sink: Arc::clone(&sink),
            cwd: ssh.then(Mutex::default),
        };
        self.outputs.attach(&session_id, false, Box::new(output));
        App {
            outputs: Arc::clone(&self.outputs),
            sink,
            session_id,
        }
    }

    /// `ssh_connect`'s body.
    async fn open_ssh(
        self: Arc<Self>,
        sink: Arc<dyn SessionSink>,
        session_id: String,
        a: SshConnectArgs,
        cancel: CancellationToken,
    ) -> Result<Arc<Session>, AppError> {
        let app = self.attach(sink, session_id, true);
        on_runtime(async move {
            let id = app.session_id.clone();
            let connecting = client::connect(
                app.clone(),
                id.clone(),
                &a.host,
                a.port,
                &a.username,
                a.password.as_deref(),
                a.private_key.as_deref(),
                a.passphrase.as_deref(),
                a.jump_hosts.unwrap_or_default(),
                a.env_vars.unwrap_or_default(),
                a.agent_forwarding,
                a.pre_command,
                a.shell_integration.unwrap_or(true),
                Arc::clone(&self.known_hosts),
                Arc::clone(&self.conflicts),
                a.keepalive_interval_secs.unwrap_or(3),
                a.keepalive_max.unwrap_or(3),
                a.persist.unwrap_or(true),
                a.restore.unwrap_or(false),
                a.attach_only.unwrap_or(false),
                a.cols.filter(|c| *c > 0).unwrap_or(80),
                a.rows.filter(|r| *r > 0).unwrap_or(24),
                a.legacy_algorithms.unwrap_or(false),
                a.initial_cwd,
                HopRoute {
                    proxy: a.proxy,
                    knock: a.knock,
                },
                a.terminal_colors,
                a.detached_ttl_secs,
            );
            let opened = tokio::select! {
                connected = connecting => match connected {
                    Ok(session) => {
                        self.ssh.add(id.clone(), session).await;
                        Ok(())
                    }
                    Err(e) => Err(e),
                },
                () = cancel.cancelled() => {
                    // Drops a host-key prompt the connect was waiting on.
                    self.conflicts.abort(&id).await;
                    Err(CANCELLED.into())
                }
            };
            self.finish_open(app, opened, Kind::Ssh)
        })
        .await
    }

    fn finish_open<E>(
        self: Arc<Self>,
        app: App,
        opened: Result<(), E>,
        kind: Kind,
    ) -> Result<Arc<Session>, E> {
        if let Err(e) = opened {
            self.outputs.remove(&app.session_id);
            return Err(e);
        }
        Ok(Arc::new(Session {
            core: self,
            app,
            kind,
        }))
    }
}

enum Kind {
    Local,
    Ssh,
}

/// An open local shell or SSH shell.
#[derive(uniffi::Object)]
pub struct Session {
    core: Arc<Core>,
    app: App,
    kind: Kind,
}

#[uniffi::export]
impl Session {
    pub async fn write(self: Arc<Self>, data: Vec<u8>) -> Result<(), CoreError> {
        on_runtime(async move {
            let id = &self.app.session_id;
            match self.kind {
                Kind::Local => self.core.local.send_data(id, data).await,
                Kind::Ssh => self.core.ssh.send_data(id, &data).await,
            }
        })
        .await
        .map_err(failed)
    }

    pub async fn resize(self: Arc<Self>, cols: u16, rows: u16) -> Result<(), CoreError> {
        on_runtime(async move {
            let id = &self.app.session_id;
            match self.kind {
                Kind::Local => self.core.local.resize(id, cols, rows).await,
                Kind::Ssh => self.core.ssh.resize(id, cols.into(), rows.into()).await,
            }
        })
        .await
        .map_err(failed)
    }

    /// Ends the session. Its sink gets no `closed` for it. A persistent SSH
    /// session's tmux/screen session stays on the host, detached: see
    /// [`Session::disconnect`].
    pub async fn close(self: Arc<Self>) -> Result<(), CoreError> {
        match self.kind {
            Kind::Local => on_runtime(async move {
                let id = &self.app.session_id;
                self.core.local.disconnect(&self.app, id).await
            })
            .await
            .map_err(failed),
            Kind::Ssh => self.disconnect(None, false, true, false).await.map(drop),
        }
    }

    /// What [`Core::ssh_connect`] reconnects under.
    pub fn id(&self) -> String {
        self.app.session_id.clone()
    }

    /// Upstream's `ssh_disconnect`: ends an SSH session after typing `post_command`.
    /// With `kill_persistent` it also ends the session's tmux/screen session on the
    /// host, unless another client is attached to it (`attached`: this session's
    /// own channel still is), and returns whether it did. Its sink gets no `closed`.
    ///
    /// `reconnecting` has no effect; it stays for callers.
    #[uniffi::method(default(reconnecting = false))]
    pub async fn disconnect(
        self: Arc<Self>,
        post_command: Option<String>,
        kill_persistent: bool,
        attached: bool,
        reconnecting: bool,
    ) -> Result<bool, CoreError> {
        if matches!(self.kind, Kind::Local) {
            return Err(failed("Not an SSH session"));
        }
        let _ = reconnecting;
        on_runtime(async move {
            let id = &self.app.session_id;
            // First, so the channel's own close as it goes down is not reported.
            self.core.outputs.remove(id);
            let ssh = &self.core.ssh;
            ssh.disconnect(id, post_command, kill_persistent, attached)
                .await
        })
        .await
        .map_err(failed)
    }

    /// The persistent sessions on this session's host, its own among them: what
    /// another device, or this one before it quit, left running there. Each is
    /// joined with [`Core::ssh_connect`], its `sessionId` and `attachOnly`.
    pub async fn live_sessions(self: Arc<Self>) -> Result<Vec<LiveSession>, CoreError> {
        on_runtime(async move { self.core.ssh.live_sessions(&self.app.session_id).await })
            .await
            .map_err(failed)
    }

    /// Ends one of [`Session::live_sessions`], `session_id`, on the host, whoever
    /// has it open. Whether the host confirmed it.
    pub async fn end_live_session(self: Arc<Self>, session_id: String) -> Result<bool, CoreError> {
        on_runtime(async move {
            let ssh = &self.core.ssh;
            ssh.end_live(&self.app.session_id, &session_id).await
        })
        .await
        .map_err(failed)
    }

    /// Upstream's `ssh_detect_distro`: `ubuntu`, `debian`, `proxmox`, `pbs`…, `linux`
    /// when unknown, or `windows`/`routeros` from the SSH banner.
    pub async fn detect_distro(self: Arc<Self>) -> Result<String, CoreError> {
        on_runtime(async move { self.core.ssh.detect_distro(&self.app.session_id).await })
            .await
            .map_err(failed)
    }

    /// Upstream's `ssh_get_system_info`, as JSON: `pretty_name`, `version_id`,
    /// `kernel`, `arch` (empty when the host does not say).
    pub async fn system_info(self: Arc<Self>) -> Result<String, CoreError> {
        on_runtime(async move { self.core.ssh.get_system_info(&self.app.session_id).await })
            .await
            .and_then(|info| serde_json::to_string(&info).map_err(|e| e.to_string()))
            .map_err(failed)
    }
}
