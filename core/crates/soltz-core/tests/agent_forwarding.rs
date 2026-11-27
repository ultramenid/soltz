// SPDX-License-Identifier: AGPL-3.0-only
//! Agent forwarding against a fake agent socket in a temp dir. Its own test binary:
//! it points this process's `SSH_AUTH_SOCK` there, never at the user's agent.

mod common;

use common::host::{key, serve, PASSWORD, USER};
use common::{trusting, wait_for, Recorder};
use soltz_core::api::{Cancellation, Core};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

#[tokio::test]
async fn the_host_reaches_the_local_agent_through_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("agent.sock");
    let agent = UnixListener::bind(&socket).unwrap();
    std::env::set_var("SSH_AUTH_SOCK", &socket);
    tokio::spawn(async move {
        let (mut conn, _) = agent.accept().await.unwrap();
        let mut asked = [0u8; 4];
        conn.read_exact(&mut asked).await.unwrap();
        assert_eq!(&asked, b"ping");
        conn.write_all(b"pong").await.unwrap();
    });

    let target = serve(key(1)).await;
    let args = serde_json::json!({
        "host": "127.0.0.1", "port": target.port, "username": USER, "password": PASSWORD,
        "persist": false, "agentForwarding": true,
    });
    let (core, sink) = (Core::new(), Arc::new(Recorder::default()));
    let connect = (core.clone()).ssh_connect(sink.clone(), args.to_string(), Cancellation::new());
    let session = trusting(&core, &sink, connect).await.unwrap();
    wait_for("the agent's answer", || {
        target.seen(|s| s.agent_reply.is_some())
    })
    .await;
    assert_eq!(
        target.seen(|s| s.agent_reply.clone()),
        Some(b"pong".to_vec())
    );
    session.close().await.unwrap();
}
