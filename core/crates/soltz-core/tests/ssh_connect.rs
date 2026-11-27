// SPDX-License-Identifier: AGPL-3.0-only
//! `Core::ssh_connect` with upstream's host options, against scripted in-process
//! hosts and proxies on loopback: no real host, no ~/.ssh, no SSH agent.

mod common;

use common::host::{self, key, serve, Host, OSC7_HEAD, PASSWORD, PROBED_CWD, STAGED, USER};
use common::{trusting, wait_for, Recorder};
use serde_json::{json, Value};
use soltz_core::api::{Cancellation, Core, CoreError, ErrorCode, Session};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

fn args(port: u16, extra: Value) -> String {
    let mut args = json!({
        "host": "127.0.0.1",
        "port": port,
        "username": USER,
        "password": PASSWORD,
        "persist": false,
    });
    args.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    args.to_string()
}

async fn connect(
    core: &Arc<Core>,
    sink: &Arc<Recorder>,
    args: String,
) -> Result<Arc<Session>, CoreError> {
    let connect = core.clone().ssh_connect(sink.clone(), args, Cancellation::new());
    trusting(core, sink, connect).await
}

fn steps(sink: &Recorder) -> Vec<(String, String)> {
    sink.events("ssh-step")
        .into_iter()
        .map(|e| {
            (
                e["step"].as_str().unwrap().into(),
                e["detail"].as_str().unwrap().into(),
            )
        })
        .collect()
}

/// The shell answers: what is written comes back.
async fn echoes(session: &Arc<Session>, sink: &Recorder, text: &str) {
    session
        .clone()
        .write(format!("{text}\n").into_bytes())
        .await
        .unwrap();
    wait_for(text, || sink.text().contains(&format!("{text}\n"))).await;
}

#[tokio::test]
async fn a_jump_chain_reaches_the_host_through_two_jump_hosts() {
    let (first, second, target) = (
        serve(key(1)).await,
        serve(key(2)).await,
        serve(key(3)).await,
    );
    let hop = |h: &Host| json!({"host": "127.0.0.1", "port": h.port, "username": USER, "password": PASSWORD});
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let session = connect(
        &core,
        &sink,
        args(
            target.port,
            json!({"jumpHosts": [hop(&first), hop(&second)]}),
        ),
    )
    .await
    .unwrap();

    let at = |h: &Host| vec![("127.0.0.1".to_string(), u32::from(h.port))];
    assert_eq!(first.seen(|s| s.tunnels.clone()), at(&second));
    assert_eq!(second.seen(|s| s.tunnels.clone()), at(&target));
    let details: Vec<String> = steps(&sink).into_iter().map(|(_, d)| d).collect();
    assert!(
        details.iter().any(|d| d.ends_with("(jump 1)")),
        "{details:?}"
    );
    assert!(
        details.iter().any(|d| d.ends_with("(jump 2)")),
        "{details:?}"
    );
    echoes(&session, &sink, "through").await;
    session.close().await.unwrap();
}

/// A SOCKS5 proxy (no auth, RFC 1928) that records each CONNECT target.
async fn socks5(targets: Arc<Mutex<Vec<String>>>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut client, _) = listener.accept().await.unwrap();
            let targets = Arc::clone(&targets);
            tokio::spawn(async move {
                let mut hello = [0u8; 2];
                client.read_exact(&mut hello).await.unwrap();
                let mut methods = vec![0u8; hello[1].into()];
                client.read_exact(&mut methods).await.unwrap();
                client.write_all(&[5, 0]).await.unwrap();
                let mut head = [0u8; 4];
                client.read_exact(&mut head).await.unwrap();
                let host = match head[3] {
                    1 => {
                        let mut ip = [0u8; 4];
                        client.read_exact(&mut ip).await.unwrap();
                        std::net::Ipv4Addr::from(ip).to_string()
                    }
                    3 => {
                        let len = client.read_u8().await.unwrap();
                        let mut name = vec![0u8; len.into()];
                        client.read_exact(&mut name).await.unwrap();
                        String::from_utf8(name).unwrap()
                    }
                    other => panic!("address type {other}"),
                };
                let port = client.read_u16().await.unwrap();
                targets.lock().unwrap().push(format!("{host}:{port}"));
                let mut upstream = TcpStream::connect((host.as_str(), port)).await.unwrap();
                client
                    .write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                    .await
                    .unwrap();
                let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
            });
        }
    });
    port
}

/// An HTTP proxy that answers CONNECT and records each request line.
async fn http_connect(requests: Arc<Mutex<Vec<String>>>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut client, _) = listener.accept().await.unwrap();
            let requests = Arc::clone(&requests);
            tokio::spawn(async move {
                let mut head = Vec::new();
                while !head.ends_with(b"\r\n\r\n") {
                    head.push(client.read_u8().await.unwrap());
                }
                let head = String::from_utf8(head).unwrap();
                let line = head.lines().next().unwrap().to_string();
                let target = line.split(' ').nth(1).unwrap().to_string();
                requests.lock().unwrap().push(line);
                let mut upstream = TcpStream::connect(target).await.unwrap();
                client
                    .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    .await
                    .unwrap();
                let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
            });
        }
    });
    port
}

#[tokio::test]
async fn socks5_and_http_connect_proxies_carry_the_connection() {
    let target = serve(key(1)).await;
    let socks_seen = Arc::new(Mutex::new(Vec::new()));
    let http_seen = Arc::new(Mutex::new(Vec::new()));
    let proxies = [
        ("socks5", socks5(Arc::clone(&socks_seen)).await),
        ("http", http_connect(Arc::clone(&http_seen)).await),
    ];
    let core = Core::new();
    for (kind, port) in proxies {
        let sink = Arc::new(Recorder::default());
        let proxy = json!({"kind": kind, "host": "127.0.0.1", "port": port});
        let session = connect(&core, &sink, args(target.port, json!({"proxy": proxy})))
            .await
            .unwrap();
        let via = format!("via {kind} 127.0.0.1:{port}");
        assert!(
            steps(&sink).iter().any(|(_, d)| d.ends_with(&via)),
            "{:?}",
            steps(&sink)
        );
        echoes(&session, &sink, kind).await;
        session.close().await.unwrap();
    }
    let at = format!("127.0.0.1:{}", target.port);
    assert_eq!(*socks_seen.lock().unwrap(), std::slice::from_ref(&at));
    assert_eq!(
        *http_seen.lock().unwrap(),
        [format!("CONNECT {at} HTTP/1.1")]
    );
}

#[tokio::test]
async fn the_port_knock_reaches_tcp_and_udp_ports_in_order_before_the_connect() {
    let target = serve(key(1)).await;
    let start = Instant::now();
    let (a, c) = (
        TcpListener::bind("127.0.0.1:0").await.unwrap(),
        TcpListener::bind("127.0.0.1:0").await.unwrap(),
    );
    let b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let ports =
        [&a.local_addr(), &b.local_addr(), &c.local_addr()].map(|p| p.as_ref().unwrap().port());
    let accept =
        |l: TcpListener| tokio::spawn(async move { l.accept().await.map(|_| start.elapsed()) });
    let (a, c) = (accept(a), accept(c));
    let b = tokio::spawn(async move { b.recv_from(&mut [0u8; 8]).await.map(|_| start.elapsed()) });

    let knock = json!({
        "steps": [
            {"port": ports[0], "protocol": "tcp"},
            {"port": ports[1], "protocol": "udp"},
            {"port": ports[2], "protocol": "tcp"},
        ],
        "delay_ms": 100,
        "settle_ms": 10,
    });
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let session = connect(&core, &sink, args(target.port, json!({"knock": knock})))
        .await
        .unwrap();

    let arrived = [a.await, b.await, c.await].map(|t| t.unwrap().unwrap());
    assert!(
        arrived[0] < arrived[1] && arrived[1] < arrived[2],
        "{arrived:?}"
    );
    assert_eq!(steps(&sink)[0], ("knocking".into(), "3".into()));
    session.close().await.unwrap();
}

#[tokio::test]
async fn env_vars_pre_and_post_commands_reach_the_host() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let extra = json!({"envVars": [["GREETING", "hello world"]], "preCommand": "echo pre"});
    let session = connect(&core, &sink, args(target.port, extra))
        .await
        .unwrap();

    wait_for("the startup input", || {
        target.shell_input().contains("echo pre\n")
    })
    .await;
    assert_eq!(
        target.seen(|s| String::from_utf8(s.staged.clone()).unwrap()),
        "export GREETING='hello world'\n",
        "the values go through the staging exec, not the PTY"
    );
    assert_eq!(target.shell_input(), format!(" . {STAGED}\necho pre\n"));

    let killed = session
        .disconnect(Some("echo post".into()), false, true, false)
        .await
        .unwrap();
    assert!(!killed);
    wait_for("the post command", || {
        target.shell_input().ends_with("echo post\n")
    })
    .await;
}

#[tokio::test]
async fn keepalive_leaves_an_idle_healthy_session_up() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let extra = json!({"keepaliveIntervalSecs": 1, "keepaliveMax": 2});
    let session = connect(&core, &sink, args(target.port, extra))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(3500)).await;
    assert_eq!(sink.closed(), None);
    echoes(&session, &sink, "still-here").await;
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_legacy_only_host_needs_the_legacy_algorithms_option() {
    use russh::{kex, Preferred};
    let legacy_kex = Preferred {
        kex: std::borrow::Cow::Borrowed(&[kex::DH_G14_SHA1]),
        ..Preferred::default()
    };
    let target = host::serve_with(vec![key(1)], legacy_kex).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    match connect(&core, &sink, args(target.port, json!({}))).await {
        Err(CoreError::Coded { code, message }) => {
            assert_eq!(code, ErrorCode::SshLegacyAlgorithmsRequired, "{message}");
        }
        other => panic!("{:?}", other.map(|_| ())),
    }
    let legacy = json!({"legacyAlgorithms": true});
    connect(&core, &sink, args(target.port, legacy))
        .await
        .unwrap()
        .close()
        .await
        .unwrap();
}

#[tokio::test]
async fn failures_carry_upstreams_code_and_plain_message() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());

    let wrong = connect(&core, &sink, args(target.port, json!({"password": "nope"}))).await;
    let Err(
        err @ CoreError::Coded {
            code: ErrorCode::SshPasswordRejected,
            ..
        },
    ) = wrong
    else {
        panic!("{:?}", wrong.map(|_| ()));
    };
    assert_eq!(
        err.to_string(),
        "Password authentication rejected — check the username and password."
    );

    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = closed.local_addr().unwrap().port();
    drop(closed);
    let refused = connect(&core, &sink, args(port, json!({}))).await;
    assert!(
        matches!(
            refused,
            Err(CoreError::Coded {
                code: ErrorCode::ConnectionRefused,
                ..
            })
        ),
        "{:?}",
        refused.map(|_| ())
    );

    let bad = connect(&core, &sink, "{\"host\":1}".into()).await;
    assert!(matches!(bad, Err(CoreError::Failed { .. })));
    let foreign = connect(
        &core,
        &sink,
        args(target.port, json!({"sessionId": "6f1c"})),
    )
    .await;
    assert!(
        matches!(&foreign, Err(CoreError::Failed { message }) if message.contains("sessionId")),
        "only a Soltz id is reconnected under"
    );
}

#[tokio::test]
async fn a_cancelled_connect_ends_and_leaves_no_connection() {
    // Key 1 on first sight, key 2 after: the second connect waits on the user.
    let target = host::serve_with(vec![key(1), key(2)], Default::default()).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    connect(&core, &sink, args(target.port, json!({})))
        .await
        .unwrap()
        .close()
        .await
        .unwrap();
    wait_for("the first connection to end", || {
        target.seen(|s| s.live) == 0
    })
    .await;

    let sink = Arc::new(Recorder::default());
    let cancel = Cancellation::new();
    let connecting = {
        let (core, sink, cancel) = (core.clone(), sink.clone(), cancel.clone());
        let args = args(target.port, json!({}));
        tokio::spawn(async move { core.ssh_connect(sink, args, cancel).await })
    };
    wait_for("the conflict prompt", || {
        !sink.events("ssh-host-key-conflict").is_empty()
    })
    .await;
    assert_eq!(target.seen(|s| s.live), 1);
    cancel.cancel();
    let cancelled = connecting.await.unwrap();
    assert!(
        matches!(&cancelled, Err(CoreError::Failed { message }) if message == "Connection cancelled"),
        "{:?}",
        cancelled.map(|_| ())
    );
    wait_for("the host to see the connection go", || {
        target.seen(|s| s.live) == 0
    })
    .await;
}

#[tokio::test]
async fn a_plain_session_reports_its_cwd_from_osc7() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let session = connect(&core, &sink, args(target.port, json!({})))
        .await
        .unwrap();
    wait_for("shell integration's wrapper", || {
        target.seen(|s| s.shell_execs.len()) == 1
    })
    .await;
    wait_for("the cut-off OSC 7", || sink.bytes().ends_with(OSC7_HEAD)).await;
    echoes(&session, &sink, "ls").await;
    wait_for("the cwd", || !sink.events("ssh-cwd").is_empty()).await;
    assert_eq!(sink.events("ssh-cwd"), [json!("/home/soltz/my dir")]);
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_cwd_with_control_characters_is_neither_reported_nor_handed_back_to_a_shell() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    // Split's starting directory, as an output stream could have set it: a ^U erases the `cd '` typed
    // before it, and what follows would run as a command.
    let hostile = json!({"initialCwd": "/tmp/a\u{15}touch /tmp/soltz-pwned;echo '"});
    let session = connect(&core, &sink, args(target.port, hostile))
        .await
        .unwrap();
    wait_for("shell integration's wrapper", || {
        target.seen(|s| s.shell_execs.len()) == 1
    })
    .await;
    wait_for("the cut-off OSC 7", || sink.bytes().ends_with(OSC7_HEAD)).await;
    // The host echoes what is typed, so these arrive as output: one cwd with a control character, one clean.
    echoes(&session, &sink, "\x1b]7;file://box/tmp/a%15b\x07").await;
    echoes(&session, &sink, "\x1b]7;file://box/tmp/clean\x07").await;
    wait_for("the clean cwd", || {
        sink.events("ssh-cwd").contains(&json!("/tmp/clean"))
    })
    .await;
    assert!(
        sink.events("ssh-cwd").iter().all(|cwd| !cwd.as_str().unwrap().chars().any(char::is_control)),
        "{:?}",
        sink.events("ssh-cwd")
    );
    let ran = target.seen(|s| s.shell_execs.join("\n")) + &target.shell_input();
    assert!(!ran.contains("soltz-pwned"), "{ran}");
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_persistent_session_runs_tmux_control_mode_and_reattaches_by_id() {
    let target = serve(key(1)).await;
    let core = Core::new();
    let sink = Arc::new(Recorder::default());
    let persist = json!({"persist": true});
    let session = connect(&core, &sink, args(target.port, persist.clone()))
        .await
        .unwrap();
    let id = session.id();
    assert!(id.starts_with("soltz-"), "{id}");
    wait_for("the tmux wrapper", || {
        target.seen(|s| s.shell_execs.len()) == 1
    })
    .await;
    let created = target.seen(|s| s.shell_execs[0].clone());
    assert!(
        created.contains(&format!("new-session -A -s soltz_{id}")),
        "upstream's tmux naming, on a Soltz id"
    );

    wait_for("tmux control mode", || {
        !sink.events("ssh-mux-mode").is_empty()
    })
    .await;
    assert_eq!(
        sink.events("ssh-mux-mode"),
        [json!({"control": true, "tmux": "3.4"})]
    );
    wait_for("the replayed pane", || sink.text().contains("old line")).await;
    wait_for("the polled cwd", || {
        sink.events("ssh-cwd").contains(&json!(PROBED_CWD))
    })
    .await;

    session.clone().write(b"ls\n".to_vec()).await.unwrap();
    wait_for("the keys, as tmux commands", || {
        target
            .shell_input()
            .contains("send-keys -H -t %0 6c 73 0a\n")
    })
    .await;
    wait_for("the pane's output", || sink.text().contains("hi\r\n")).await;
    wait_for("the cwd from OSC 7", || {
        sink.events("ssh-cwd").contains(&json!("/srv/a b"))
    })
    .await;

    // A reconnect: drop the connection, attach the multiplexer session again.
    assert!(!session.disconnect(None, false, true, true).await.unwrap());
    let sink = Arc::new(Recorder::default());
    let attach = json!({"persist": true, "attachOnly": true, "sessionId": id});
    let again = connect(&core, &sink, args(target.port, attach.clone()))
        .await
        .unwrap();
    assert_eq!(again.id(), id);
    assert!(target.seen(|s| s.execs.iter().any(|e| e.contains("SOLTZ_PRESENT"))));
    wait_for("the attach", || target.seen(|s| s.shell_execs.len()) == 2).await;
    let attached = target.seen(|s| s.shell_execs.last().unwrap().clone());
    assert!(attached.contains(&format!("attach-session -t soltz_{id}")));
    wait_for("tmux control mode", || {
        !sink.events("ssh-mux-mode").is_empty()
    })
    .await;

    // Closing for good kills it; attaching then finds it gone.
    assert!(again.disconnect(None, true, true, false).await.unwrap());
    let ended = connect(
        &core,
        &Arc::new(Recorder::default()),
        args(target.port, attach),
    )
    .await;
    assert!(
        matches!(&ended, Err(CoreError::Failed { message }) if message == "SESSION_ENDED"),
        "{:?}",
        ended.map(|_| ())
    );
}
