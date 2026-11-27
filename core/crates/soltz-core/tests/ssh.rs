// SPDX-License-Identifier: AGPL-3.0-only
//! The SSH path end to end, against an in-process russh server on loopback:
//! no real host, no keys from disk.

mod common;

use common::{trusting, wait_for, Recorder};
use russh::keys::ssh_key::private::Ed25519Keypair;
use russh::keys::ssh_key::LineEnding;
use russh::keys::PrivateKey;
use russh::server::{Auth, ChannelOpenHandle, Msg, Session, VerifiedPublicKey};
use russh::{Channel, ChannelId};
use soltz_core::api::{Core, CoreError, HostKeyAction, Keychain};
use soltz_core::entities::{write_as_upstream, EntityKind};
use std::sync::Arc;
use tokio::net::TcpListener;

const USER: &str = "soltz";
const PASSWORD: &str = "hunter2";

fn key(seed: u8) -> PrivateKey {
    Ed25519Keypair::from_seed(&[seed; 32]).into()
}

/// Password or `client_key` auth; a shell that echoes input, reports resizes and
/// exits cleanly on `exit`.
struct Server {
    client_key: PrivateKey,
}

impl russh::server::Handler for Server {
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
        let ours = self.client_key.public_key().key_data();
        Ok(if user == USER && key.public_key.key_data() == ours {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    // With shell integration on, the client execs its wrapper instead of asking for a shell.
    async fn exec_request(
        &mut self,
        channel: ChannelId,
        _command: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.data(channel, &b"welcome\r\n"[..])
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if data == b"exit\n" {
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            return session.close(channel);
        }
        session.data(channel, data.to_vec())
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

/// Serves loopback connections, the n-th with `host_keys[n]` (the last one repeats).
async fn serve(host_keys: Vec<PrivateKey>, client_key: PrivateKey) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let last = host_keys.last().unwrap().clone();
        for host_key in host_keys.into_iter().chain(std::iter::repeat(last)) {
            let (stream, _) = listener.accept().await.unwrap();
            let config = Arc::new(russh::server::Config {
                keys: vec![host_key],
                auth_rejection_time: std::time::Duration::ZERO,
                ..Default::default()
            });
            let server = Server {
                client_key: client_key.clone(),
            };
            tokio::spawn(async move {
                if let Ok(session) = russh::server::run_stream(config, stream, server).await {
                    let _ = session.await;
                }
            });
        }
    });
    port
}

async fn connect(
    core: &Arc<Core>,
    sink: &Arc<Recorder>,
    port: u16,
    password: Option<&str>,
    private_key: Option<String>,
) -> Result<Arc<soltz_core::api::Session>, CoreError> {
    let connect = core.clone().connect_ssh(
        sink.clone(),
        "127.0.0.1".into(),
        port,
        USER.into(),
        password.map(Into::into),
        private_key,
        None,
        80,
        24,
    );
    trusting(core, sink, connect).await
}

#[tokio::test]
async fn a_password_session_echoes_resizes_and_reports_a_clean_exit() {
    let port = serve(vec![key(1)], key(9)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let session = connect(&core, &sink, port, Some(PASSWORD), None)
        .await
        .unwrap();

    let steps: Vec<_> = sink
        .events("ssh-step")
        .into_iter()
        .map(|e| e["step"].clone())
        .collect();
    assert_eq!(
        steps,
        [
            "tcp_connected",
            "handshake",
            "authenticating",
            "opening_shell"
        ],
        "the upstream connect steps, in order"
    );

    session.clone().write(b"hello\n".to_vec()).await.unwrap();
    wait_for("the echo", || sink.text().contains("welcome\r\nhello\n")).await;

    session.clone().resize(100, 30).await.unwrap();
    wait_for("the resize", || sink.text().contains("[100x30]")).await;

    session.clone().write(b"exit\n".to_vec()).await.unwrap();
    wait_for("the close", || sink.closed().is_some()).await;
    assert_eq!(
        sink.closed(),
        Some(true),
        "an exit status means a clean exit"
    );
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_private_key_authenticates_and_a_wrong_password_does_not() {
    let client_key = key(9);
    let port = serve(vec![key(1)], client_key.clone()).await;
    let core = Core::new();

    let pem = client_key.to_openssh(LineEnding::LF).unwrap().to_string();
    let sink = Arc::new(Recorder::default());
    let session = connect(&core, &sink, port, None, Some(pem)).await.unwrap();
    session.close().await.unwrap();

    let sink = Arc::new(Recorder::default());
    let Err(CoreError::Failed { message }) = connect(&core, &sink, port, Some("nope"), None).await
    else {
        panic!("a wrong password connected");
    };
    assert!(
        message.contains("Password authentication rejected"),
        "{message}"
    );
}

#[tokio::test]
async fn a_host_seen_for_the_first_time_is_asked_about_before_anything_is_sent() {
    let port = serve(vec![key(1)], key(9)).await;
    let core = Core::new();
    // Refused, then trusted: a refusal stores nothing, so the second connection asks again.
    for (answer, accepted) in [(HostKeyAction::Abort, false), (HostKeyAction::AddNew, true)] {
        let sink = Arc::new(Recorder::default());
        let connecting = tokio::spawn(core.clone().connect_ssh(
            sink.clone(),
            "127.0.0.1".into(),
            port,
            USER.into(),
            Some(PASSWORD.into()),
            None,
            None,
            80,
            24,
        ));
        wait_for("the first-sight prompt", || {
            !sink.events("ssh-host-key-conflict").is_empty()
        })
        .await;
        let asked = &sink.events("ssh-host-key-conflict")[0];
        assert_eq!(asked["port"], port);
        assert!(asked["stored_entries"].as_array().unwrap().is_empty());
        assert!(!connecting.is_finished(), "it went on without an answer");
        let text = |field: &str| asked[field].as_str().unwrap().to_string();
        core.resolve_host_key(text("session_id"), text("new_fingerprint"), answer)
            .await;
        let connected = connecting.await.unwrap();
        assert_eq!(connected.is_ok(), accepted);
        if let Ok(session) = connected {
            session.close().await.unwrap();
        }
    }
    // Trusted now: no question.
    let sink = Arc::new(Recorder::default());
    connect(&core, &sink, port, Some(PASSWORD), None)
        .await
        .unwrap()
        .close()
        .await
        .unwrap();
    assert!(sink.events("ssh-host-key-conflict").is_empty());
}

#[tokio::test]
async fn a_changed_host_key_waits_for_the_users_answer() {
    // First sight of key 1 is trusted; key 2 on the same host:port is a change.
    let port = serve(vec![key(1), key(2)], key(9)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    connect(&core, &sink, port, Some(PASSWORD), None)
        .await
        .unwrap()
        .close()
        .await
        .unwrap();

    for (answer, accepted) in [(HostKeyAction::Abort, false), (HostKeyAction::AddNew, true)] {
        let sink = Arc::new(Recorder::default());
        let connecting = {
            let (core, sink) = (core.clone(), sink.clone());
            tokio::spawn(async move { connect(&core, &sink, port, Some(PASSWORD), None).await })
        };
        wait_for("the conflict prompt", || {
            !sink.events("ssh-host-key-conflict").is_empty()
        })
        .await;
        let conflict = &sink.events("ssh-host-key-conflict")[0];
        assert_eq!(conflict["port"], port);
        assert_eq!(conflict["stored_entries"].as_array().unwrap().len(), 1);
        let session_id = conflict["session_id"].as_str().unwrap().to_string();
        let shown = conflict["new_fingerprint"].as_str().unwrap().to_string();
        // An answer to a key the user was not shown is dropped: the prompt keeps waiting.
        core.resolve_host_key(session_id.clone(), "SHA256:other".into(), HostKeyAction::AddNew)
            .await;
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(!connecting.is_finished());
        core.resolve_host_key(session_id, shown, answer).await;

        let connected = connecting.await.unwrap();
        assert_eq!(connected.is_ok(), accepted);
        if let Ok(session) = connected {
            session.close().await.unwrap();
        }
    }
}

#[tokio::test]
async fn trusted_host_keys_outlive_the_core_in_its_data_directory() {
    // Key 1 on first sight, key 2 from then on.
    let port = serve(vec![key(1), key(2)], key(9)).await;
    let dir = tempfile::tempdir().unwrap();
    let open =
        || Core::with_data_dir(dir.path().to_str().unwrap().into(), Keychain::Memory).unwrap();
    let hosts = |core: Arc<Core>| async move {
        let json = core.entity_list(EntityKind::KnownHosts).await.unwrap();
        (
            serde_json::from_str::<Vec<serde_json::Value>>(&json).unwrap(),
            json,
        )
    };

    let sink = Arc::new(Recorder::default());
    let first = open();
    connect(&first, &sink, port, Some(PASSWORD), None)
        .await
        .unwrap()
        .close()
        .await
        .unwrap();

    let second = open();
    let (trusted, json) = hosts(second.clone()).await;
    assert_eq!(trusted.len(), 1);
    assert_eq!(
        (trusted[0]["host"].clone(), trusted[0]["port"].clone()),
        ("127.0.0.1".into(), port.into())
    );
    let upstream = dir.path().join("upstream.json");
    write_as_upstream(EntityKind::KnownHosts, &json, &upstream).unwrap();
    assert_eq!(
        std::fs::read_to_string(dir.path().join("known_hosts.json")).unwrap(),
        std::fs::read_to_string(upstream).unwrap()
    );

    // The new core trusts key 1, so key 2 is a change it asks about.
    let sink = Arc::new(Recorder::default());
    let connecting = {
        let (core, sink) = (second.clone(), sink.clone());
        tokio::spawn(async move { connect(&core, &sink, port, Some(PASSWORD), None).await })
    };
    wait_for("the conflict prompt", || {
        !sink.events("ssh-host-key-conflict").is_empty()
    })
    .await;
    let asked = &sink.events("ssh-host-key-conflict")[0];
    let text = |field: &str| asked[field].as_str().unwrap().to_string();
    second
        .resolve_host_key(text("session_id"), text("new_fingerprint"), HostKeyAction::Abort)
        .await;
    assert!(connecting.await.unwrap().is_err());

    let id = trusted[0]["id"].as_str().unwrap().to_string();
    second
        .clone()
        .entity_delete(EntityKind::KnownHosts, id)
        .await
        .unwrap();
    let third = open();
    assert!(
        hosts(third.clone()).await.0.is_empty(),
        "the delete is on disk"
    );
    let sink = Arc::new(Recorder::default());
    connect(&third, &sink, port, Some(PASSWORD), None)
        .await
        .expect("a forgotten host is a first sight again")
        .close()
        .await
        .unwrap();
}
