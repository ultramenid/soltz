// SPDX-License-Identifier: AGPL-3.0-only
//! A scripted SSH host on loopback (russh's server, in process): password auth,
//! jump tunnels, the env-staging exec, an echoing shell or a scripted tmux control
//! mode, the persistent-session probes and, given a root, an SFTP subsystem
//! (`super::sftp`). It records what the client sent, and can drop every connection.

use russh::keys::ssh_key::private::Ed25519Keypair;
use russh::keys::PrivateKey;
use russh::server::{Auth, ChannelOpenHandle, Msg, Session, VerifiedPublicKey};
use russh::{Channel, ChannelId};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub const USER: &str = "soltz";
pub const PASSWORD: &str = "hunter2";
/// What the env-staging exec answers: where it put the exports.
pub const STAGED: &str = "/tmp/soltz-env";
/// What the tmux cwd probe answers.
pub const PROBED_CWD: &str = "/home/soltz";
/// The cwd the shell reports in OSC 7 once input arrives, split across two writes.
pub const OSC7_HEAD: &[u8] = b"\x1b]7;file://box/home/so";
pub const OSC7_TAIL: &[u8] = b"ltz/my%20dir\x1b\\";

pub fn key(seed: u8) -> PrivateKey {
    Ed25519Keypair::from_seed(&[seed; 32]).into()
}

/// What a host saw, across all its connections.
#[derive(Default)]
pub struct Seen {
    pub connections: usize,
    pub live: usize,
    /// One-shot exec commands, in order (not the shell's own).
    pub execs: Vec<String>,
    /// The exec that started the shell (the wrapper, or the tmux/screen one).
    pub shell_execs: Vec<String>,
    pub shell_input: Vec<u8>,
    pub staged: Vec<u8>,
    pub tunnels: Vec<(String, u32)>,
    /// What the client's agent answered to "ping" over a forwarded agent channel.
    pub agent_reply: Option<Vec<u8>>,
    /// Set by the kill command: the tmux session is gone from then on.
    pub killed: bool,
    /// Public keys that authenticate `USER`.
    pub authorized_keys: Vec<russh::keys::PublicKey>,
    /// Where the `sftp` subsystem serves from; none: it is refused.
    pub sftp_root: Option<PathBuf>,
    /// How long each SFTP read and write takes, for the sessions opened from then on.
    pub sftp_delay: Duration,
    /// One-shot execs really run, by this machine's `sh`: for commands that only name a test's temp dirs.
    pub run_execs: bool,
    /// Each connection's TCP relay: aborting one drops that connection.
    relays: Vec<tokio::task::AbortHandle>,
}

#[derive(Clone)]
pub struct Host {
    pub port: u16,
    pub seen: Arc<Mutex<Seen>>,
}

impl Host {
    pub fn seen<T>(&self, f: impl FnOnce(&Seen) -> T) -> T {
        f(&self.seen.lock().unwrap())
    }
    pub fn shell_input(&self) -> String {
        self.seen(|s| String::from_utf8_lossy(&s.shell_input).into_owned())
    }
    /// Cuts every connection so far, as a network failure would.
    pub fn drop_connections(&self) {
        self.seen
            .lock()
            .unwrap()
            .relays
            .drain(..)
            .for_each(|r| r.abort());
    }
}

pub async fn serve(host_key: PrivateKey) -> Host {
    serve_with(vec![host_key], russh::Preferred::default()).await
}

/// The n-th connection presents `host_keys[n]` (the last one repeats).
pub async fn serve_with(host_keys: Vec<PrivateKey>, preferred: russh::Preferred) -> Host {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let host = Host {
        port: listener.local_addr().unwrap().port(),
        seen: Arc::default(),
    };
    let seen = Arc::clone(&host.seen);
    tokio::spawn(async move {
        let last = host_keys.last().unwrap().clone();
        for host_key in host_keys.into_iter().chain(std::iter::repeat(last)) {
            let (mut tcp, _) = listener.accept().await.unwrap();
            let (mut near, stream) = tokio::io::duplex(1 << 16);
            let relay = tokio::spawn(async move {
                let _ = tokio::io::copy_bidirectional(&mut tcp, &mut near).await;
            });
            seen.lock().unwrap().relays.push(relay.abort_handle());
            let config = Arc::new(russh::server::Config {
                keys: vec![host_key],
                preferred: preferred.clone(),
                auth_rejection_time: std::time::Duration::ZERO,
                ..Default::default()
            });
            let seen = Arc::clone(&seen);
            tokio::spawn(async move {
                {
                    let mut s = seen.lock().unwrap();
                    s.connections += 1;
                    s.live += 1;
                }
                let handler = Conn {
                    seen: Arc::clone(&seen),
                    shell: None,
                    control: false,
                    staging: HashSet::new(),
                    first_input: true,
                    channels: HashMap::new(),
                };
                if let Ok(session) = russh::server::run_stream(config, stream, handler).await {
                    let _ = session.await;
                }
                seen.lock().unwrap().live -= 1;
            });
        }
    });
    host
}

struct Conn {
    seen: Arc<Mutex<Seen>>,
    /// The channel that asked for a PTY.
    shell: Option<ChannelId>,
    /// The shell is a scripted tmux in control mode.
    control: bool,
    staging: HashSet<ChannelId>,
    first_input: bool,
    /// Session channels no request has claimed yet: one may ask for `sftp`.
    channels: HashMap<ChannelId, Channel<Msg>>,
}

/// tmux 3.4's answers to the control-mode sync (`ssh::control_mode::sync_command`).
fn sync_reply(line: &str) -> Vec<u8> {
    let mut out = String::new();
    for (i, cmd) in line.trim_end().split(" ; ").enumerate() {
        out.push_str(&format!("%begin 1 {i} 1\r\n"));
        if cmd.starts_with("display -p") {
            out.push_str("%0 3.4 0 0 0 2 0 1 0 0 0 0 0 0 0 0 1 0 0 23 1 24\r\n");
        } else if cmd.contains(" -J ") {
            out.push_str("old line\r\n");
        } else if cmd.starts_with("capture-pane -p -e -t") {
            out.push_str("$ \r\n");
        }
        out.push_str(&format!("%end 1 {i} 1\r\n"));
    }
    out.into_bytes()
}

impl Conn {
    fn seen<T>(&self, f: impl FnOnce(&Seen) -> T) -> T {
        f(&self.seen.lock().unwrap())
    }

    fn reply(
        &self,
        session: &mut Session,
        channel: ChannelId,
        out: &[u8],
    ) -> Result<(), russh::Error> {
        if !out.is_empty() {
            session.data(channel, out.to_vec())?;
        }
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)
    }
}

impl russh::server::Handler for Conn {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(if user == USER && password == PASSWORD {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        key: VerifiedPublicKey<'_>,
    ) -> Result<Auth, Self::Error> {
        let seen = self.seen.lock().unwrap();
        let known =
            (seen.authorized_keys.iter()).any(|k| k.key_data() == key.public_key.key_data());
        Ok(if user == USER && known {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.channels.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let (root, delay) = self.seen(|s| (s.sftp_root.clone(), s.sftp_delay));
        match (name, root, self.channels.remove(&channel)) {
            ("sftp", Some(root), Some(ch)) => {
                session.channel_success(channel)?;
                let fs = super::sftp::Fs::new(&root, delay);
                russh_sftp::server::run(ch.into_stream(), fs).await;
                Ok(())
            }
            _ => session.channel_failure(channel),
        }
    }

    async fn channel_close(
        &mut self,
        channel: ChannelId,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.channels.remove(&channel);
        Ok(())
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host: &str,
        port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.seen.lock().unwrap().tunnels.push((host.into(), port));
        let Ok(mut tcp) = TcpStream::connect((host, port as u16)).await else {
            return Ok(());
        };
        reply.accept().await;
        tokio::spawn(async move {
            let mut stream = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut stream, &mut tcp).await;
        });
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _cols: u32,
        _rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(russh::Pty, u32)],
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.channels.remove(&channel);
        self.shell = Some(channel);
        Ok(())
    }

    async fn agent_request(
        &mut self,
        _channel: ChannelId,
        session: &mut Session,
    ) -> Result<bool, Self::Error> {
        let (handle, seen) = (session.handle(), Arc::clone(&self.seen));
        tokio::spawn(async move {
            let Ok(channel) = handle.channel_open_agent().await else {
                return;
            };
            let mut stream = channel.into_stream();
            let _ = stream.write_all(b"ping").await;
            let mut reply = [0u8; 4];
            if stream.read_exact(&mut reply).await.is_ok() {
                seen.lock().unwrap().agent_reply = Some(reply.to_vec());
            }
        });
        Ok(true)
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        command: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let cmd = String::from_utf8_lossy(command).into_owned();
        self.channels.remove(&channel);
        session.channel_success(channel)?;
        if Some(channel) == self.shell {
            self.seen.lock().unwrap().shell_execs.push(cmd.clone());
            if cmd.contains("new-session") || cmd.contains("attach-session") {
                // tmux 3.2+ in control mode: the marker, then it waits for the sync.
                self.control = true;
                return session.data(channel, b"\x1bP1000p".to_vec());
            }
            let mut out = b"welcome\r\n".to_vec();
            out.extend_from_slice(OSC7_HEAD);
            return session.data(channel, out);
        }
        let mut seen = self.seen.lock().unwrap();
        seen.execs.push(cmd.clone());
        if seen.run_execs {
            drop(seen);
            let ran = std::process::Command::new("sh")
                .args(["-c", &cmd])
                .output()?;
            session.data(channel, ran.stdout)?;
            session.extended_data(channel, 1, ran.stderr)?;
            session.exit_status_request(channel, ran.status.code().unwrap_or(1) as u32)?;
            session.eof(channel)?;
            return session.close(channel);
        }
        if cmd.starts_with("umask 077") {
            // Env staging: its exports come on stdin, the path goes back at EOF.
            self.staging.insert(channel);
            return Ok(());
        }
        let out = if cmd.contains("list-sessions") {
            // One of Soltz's, open on another device, and a name that is not one of its sessions.
            "soltz_soltz-elsewhere 1 1700000000 /srv/my app\nsoltz_$(reboot) 0 1 /\n".into()
        } else if cmd.contains("pane_current_path") {
            format!("{PROBED_CWD}\n")
        } else if cmd.contains("SOLTZ_KILLED") {
            seen.killed = true;
            "SOLTZ_KILLED".into()
        } else if cmd.contains("SOLTZ_PRESENT") && !seen.killed {
            "SOLTZ_PRESENT".into()
        } else {
            String::new()
        };
        drop(seen);
        self.reply(session, channel, out.as_bytes())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.staging.contains(&channel) {
            self.seen.lock().unwrap().staged.extend_from_slice(data);
            return Ok(());
        }
        if Some(channel) != self.shell {
            return Ok(());
        }
        self.seen
            .lock()
            .unwrap()
            .shell_input
            .extend_from_slice(data);
        let first = std::mem::replace(&mut self.first_input, false);
        if self.control {
            let text = String::from_utf8_lossy(data);
            if text.contains("display -p") {
                return session.data(channel, sync_reply(&text));
            }
            if text.starts_with("send-keys") {
                // The shell reports its cwd (OSC 7) and prints, inside tmux.
                let out = "%output %0 \\033]7;file://box/srv/a%20b\\007hi\\015\\012\r\n";
                return session.data(channel, out.as_bytes().to_vec());
            }
            return Ok(());
        }
        if data == b"exit\n" {
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            return session.close(channel);
        }
        if first {
            session.data(channel, OSC7_TAIL.to_vec())?;
        }
        session.data(channel, data.to_vec())
    }

    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.staging.remove(&channel) {
            self.reply(session, channel, format!("{STAGED}\n").as_bytes())?;
        }
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.data(channel, format!("[{cols}x{rows}]").into_bytes())
    }
}
