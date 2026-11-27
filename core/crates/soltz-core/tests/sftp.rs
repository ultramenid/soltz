// SPDX-License-Identifier: AGPL-3.0-only
//! The SFTP layer end to end: SSH sessions to loopback hosts whose `sftp`
//! subsystem serves a temp dir (common/sftp.rs), and local files in temp dirs.

mod common;

use common::host::{key, serve, Host, PASSWORD, USER};
use common::{trusting, wait_for, Recorder};
use serde_json::{json, Value};
use soltz_core::api::{Core, CoreError, Session, TransferSink};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tempfile::TempDir;

/// A host serving `root` over SFTP, and an SFTP session on an SSH session to it.
struct Remote {
    host: Host,
    root: TempDir,
    core: Arc<Core>,
    session: Arc<Session>,
    sftp: String,
}

impl Remote {
    async fn new(delay: Duration) -> Self {
        Self::on(Core::new(), delay).await
    }

    async fn on(core: Arc<Core>, delay: Duration) -> Self {
        let host = serve(key(1)).await;
        let root = tempfile::tempdir().unwrap();
        host.seen.lock().unwrap().sftp_root = Some(root.path().into());
        host.seen.lock().unwrap().sftp_delay = delay;
        let sink = Arc::new(Recorder::default());
        let connect =
            (core.clone()).ssh_connect(sink.clone(), args(&host, None), Default::default());
        let session = trusting(&core, &sink, connect).await.unwrap();
        let sftp = core.clone().sftp_open(session.id()).await.unwrap();
        Self {
            host,
            root,
            core,
            session,
            sftp,
        }
    }

    /// The host's own view of `path` (absolute, as the client names it).
    fn disk(&self, path: &str) -> PathBuf {
        self.root.path().join(path.trim_start_matches('/'))
    }

    fn names(&self, dir: &str) -> Vec<String> {
        names(&self.disk(dir))
    }
}

fn args(host: &Host, session_id: Option<String>) -> String {
    json!({ "sessionId": session_id, "host": "127.0.0.1", "port": host.port,
            "username": USER, "password": PASSWORD, "persist": false })
    .to_string()
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn message(e: CoreError) -> String {
    match e {
        CoreError::Failed { message } | CoreError::Coded { message, .. } => message,
    }
}

/// `n` bytes that differ from one 64 KiB block to the next.
fn content(n: usize) -> Vec<u8> {
    (0..n)
        .map(|i| ((i * 31 + i / 65_536) % 251) as u8)
        .collect()
}

/// A transfer's events, as the sink got them.
#[derive(Default)]
struct Events(Mutex<Vec<(String, Value)>>);

impl TransferSink for Events {
    fn event(&self, name: String, payload_json: String) {
        let payload = serde_json::from_str(&payload_json).unwrap();
        self.0.lock().unwrap().push((name, payload));
    }
}

impl Events {
    fn of(&self, name: &str) -> Vec<Value> {
        let events = self.0.lock().unwrap();
        (events.iter())
            .filter(|(n, _)| n == name)
            .map(|(_, p)| p.clone())
            .collect()
    }

    /// Progress came in order and ended at the total, which is `size`.
    fn assert_progress_ended_at(&self, size: u64) {
        let progress = self.of("sftp-progress");
        let done: Vec<u64> = (progress.iter())
            .map(|p| p["transferred"].as_u64().unwrap())
            .collect();
        assert!(done.windows(2).all(|w| w[0] <= w[1]), "in order: {done:?}");
        let last = progress.last().expect("progress events");
        assert_eq!(
            (last["transferred"].as_u64(), last["total"].as_u64()),
            (Some(size), Some(size))
        );
    }

    fn transferred(&self) -> u64 {
        let progress = self.of("sftp-progress");
        progress
            .last()
            .map_or(0, |p| p["transferred"].as_u64().unwrap())
    }
}

#[tokio::test]
async fn the_browser_lists_changes_and_deletes_remote_files() {
    let r = Remote::new(Duration::ZERO).await;
    let (core, id) = (r.core.clone(), r.sftp.clone());

    core.clone()
        .sftp_mkdir(id.clone(), "/docs".into())
        .await
        .unwrap();
    core.clone()
        .sftp_write_file(id.clone(), "/docs/a.txt".into(), "hello".into())
        .await
        .unwrap();
    core.clone()
        .sftp_touch(id.clone(), "/docs/empty".into())
        .await
        .unwrap();
    let stat = |path: &str| core.clone().sftp_stat(id.clone(), path.into());
    assert_eq!(stat("/docs").await.unwrap(), Some(true));
    assert_eq!(stat("/docs/a.txt").await.unwrap(), Some(false));
    assert_eq!(stat("/nothing").await.unwrap(), None);

    let canonical = |path: &str| core.clone().sftp_canonicalize(id.clone(), path.into());
    assert_eq!(canonical(".").await.unwrap(), "/");
    assert_eq!(canonical("/docs/../docs/.").await.unwrap(), "/docs");

    core.clone()
        .sftp_rename(id.clone(), "/docs/a.txt".into(), "/b.txt".into())
        .await
        .unwrap();
    assert_eq!(r.names("/docs"), ["empty"]);
    assert_eq!(std::fs::read_to_string(r.disk("/b.txt")).unwrap(), "hello");

    // chmod: owner may execute, others may not read.
    std::fs::set_permissions(r.disk("/b.txt"), std::fs::Permissions::from_mode(0o644)).unwrap();
    let change = json!({ "paths": ["/b.txt"], "set": 0o100, "clear": 0o004 });
    core.clone()
        .sftp_set_attrs(id.clone(), change.to_string())
        .await
        .unwrap();
    let mode = r.disk("/b.txt").metadata().unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o740);

    // Symlinks: listed as such, with their target's kind.
    std::os::unix::fs::symlink(r.disk("/docs"), r.disk("/to-docs")).unwrap();
    std::os::unix::fs::symlink(r.disk("/b.txt"), r.disk("/to-b")).unwrap();
    let listing: Vec<Value> = serde_json::from_str(
        &core
            .clone()
            .sftp_list_dir(id.clone(), "/".into())
            .await
            .unwrap(),
    )
    .unwrap();
    let summary: Vec<_> = (listing.iter())
        .map(|f| {
            let flags = (
                f["is_dir"].as_bool().unwrap(),
                f["is_symlink"].as_bool().unwrap(),
            );
            (
                f["name"].as_str().unwrap(),
                f["path"].as_str().unwrap(),
                flags,
            )
        })
        .collect();
    assert_eq!(
        summary,
        [
            ("docs", "/docs", (true, false)),
            ("to-docs", "/to-docs", (true, true)),
            ("b.txt", "/b.txt", (false, false)),
            ("to-b", "/to-b", (false, true)),
        ],
        "folders first, then by name"
    );
    let b = &listing[2];
    assert_eq!(
        (
            b["size"].as_u64(),
            b["permissions"].as_u64().map(|p| p & 0o777)
        ),
        (Some(5), Some(0o740))
    );
    assert!(b["modified"].as_u64().is_some());

    // Deleting a link to a folder removes the link, not the folder's contents.
    core.clone()
        .sftp_delete(id.clone(), "/to-docs".into())
        .await
        .unwrap();
    assert_eq!(r.names("/docs"), ["empty"]);
    // A folder goes with everything under it.
    for dir in ["/tree", "/tree/sub", "/tree/sub/deeper"] {
        core.clone()
            .sftp_mkdir(id.clone(), dir.into())
            .await
            .unwrap();
    }
    for file in ["/tree/x", "/tree/sub/y", "/tree/sub/deeper/z"] {
        core.clone()
            .sftp_write_file(id.clone(), file.into(), file.into())
            .await
            .unwrap();
    }
    core.clone()
        .sftp_delete(id.clone(), "/tree".into())
        .await
        .unwrap();
    assert_eq!(r.names("/"), ["b.txt", "docs", "to-b"]);

    // Failures come back as errors, with upstream's message.
    let e = core
        .clone()
        .sftp_mkdir(id.clone(), "/docs".into())
        .await
        .unwrap_err();
    assert!(message(e).starts_with("mkdir failed"));
    let e = core
        .clone()
        .sftp_list_dir(id.clone(), "/missing".into())
        .await
        .unwrap_err();
    assert!(message(e).contains("No such file"));
    let e = core
        .clone()
        .sftp_list_dir("nope".into(), "/".into())
        .await
        .unwrap_err();
    assert_eq!(message(e), "SFTP session 'nope' not found");
    let e = core
        .clone()
        .sftp_open("soltz-unknown".into())
        .await
        .unwrap_err();
    assert_eq!(message(e), "Session not found");

    core.clone().sftp_close(id.clone()).await;
    let e = core
        .clone()
        .sftp_stat(id.clone(), "/".into())
        .await
        .unwrap_err();
    assert_eq!(message(e), format!("SFTP session '{id}' not found"));
    r.session.clone().close().await.unwrap();
}

#[tokio::test]
async fn the_editor_reads_small_text_files_and_refuses_the_rest() {
    let r = Remote::new(Duration::ZERO).await;
    let read = |path: &str, max: u64| {
        r.core
            .clone()
            .sftp_read_file(r.sftp.clone(), path.into(), max)
    };
    std::fs::write(r.disk("/notes.txt"), "line one\nline two\n").unwrap();
    std::fs::write(r.disk("/blob"), b"\0\x01\x02binary").unwrap();

    let file: Value = serde_json::from_str(&read("/notes.txt", 1024).await.unwrap()).unwrap();
    assert_eq!(
        file,
        json!({ "content": "line one\nline two\n", "size": 18 })
    );

    let refused = |e: CoreError| serde_json::from_str::<Value>(&message(e)).unwrap();
    let too_large = refused(read("/notes.txt", 4).await.unwrap_err());
    assert_eq!(
        too_large,
        json!({ "kind": "too_large", "size": 18, "limit": 4 })
    );
    assert_eq!(
        refused(read("/blob", 1024).await.unwrap_err())["kind"],
        "binary"
    );
    assert_eq!(
        refused(read("/missing", 1024).await.unwrap_err())["kind"],
        "io"
    );

    r.core
        .clone()
        .sftp_write_file(r.sftp.clone(), "/notes.txt".into(), "replaced".into())
        .await
        .unwrap();
    assert_eq!(
        std::fs::read_to_string(r.disk("/notes.txt")).unwrap(),
        "replaced"
    );
}

#[tokio::test]
async fn files_and_trees_go_up_down_and_across_with_progress() {
    let a = Remote::new(Duration::ZERO).await;
    let local = tempfile::tempdir().unwrap();
    let at = |rel: &str| local.path().join(rel).to_string_lossy().into_owned();
    let big = content(3 * 1024 * 1024 + 17);
    std::fs::write(at("big.bin"), &big).unwrap();

    let events = Arc::new(Events::default());
    (a.core.clone())
        .sftp_upload(
            a.sftp.clone(),
            at("big.bin"),
            "/big.bin".into(),
            "up".into(),
            events.clone(),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read(a.disk("/big.bin")).unwrap(), big);
    events.assert_progress_ended_at(big.len() as u64);
    assert_eq!(a.names("/"), ["big.bin"], "no temp file left beside it");

    let events = Arc::new(Events::default());
    (a.core.clone())
        .sftp_download(
            a.sftp.clone(),
            "/big.bin".into(),
            at("down.bin"),
            "down".into(),
            events.clone(),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read(at("down.bin")).unwrap(), big);
    events.assert_progress_ended_at(big.len() as u64);

    // A tree, with an empty folder, up and back down.
    let tree = [
        ("a.txt", b"a".to_vec()),
        ("sub/b.bin", content(70_000)),
        ("sub/deeper/c.txt", b"c".to_vec()),
    ];
    for (rel, bytes) in &tree {
        std::fs::create_dir_all(Path::new(&at(rel)).parent().unwrap()).unwrap();
        std::fs::write(at(rel), bytes).unwrap();
    }
    std::fs::create_dir_all(at("sub/empty")).unwrap();
    let local_tree = local.path().join("sub");
    let events = Arc::new(Events::default());
    (a.core.clone())
        .sftp_upload_dir(
            a.sftp.clone(),
            at("sub"),
            "/tree".into(),
            "up-dir".into(),
            events.clone(),
        )
        .await
        .unwrap();
    events.assert_progress_ended_at(70_001);
    let events = Arc::new(Events::default());
    (a.core.clone())
        .sftp_download_dir(
            a.sftp.clone(),
            "/tree".into(),
            at("back"),
            "down-dir".into(),
            events.clone(),
        )
        .await
        .unwrap();
    events.assert_progress_ended_at(70_001);
    for root in [a.disk("/tree"), local.path().join("back")] {
        assert_eq!(names(&root), names(&local_tree));
        assert_eq!(std::fs::read(root.join("b.bin")).unwrap(), tree[1].1);
        assert_eq!(std::fs::read(root.join("deeper/c.txt")).unwrap(), b"c");
        assert!(names(&root.join("empty")).is_empty());
    }

    // Host to host, through the same engine.
    let b = Remote::on(a.core.clone(), Duration::ZERO).await;
    let events = Arc::new(Events::default());
    (a.core.clone())
        .sftp_transfer(
            a.sftp.clone(),
            "/big.bin".into(),
            b.sftp.clone(),
            "/copy.bin".into(),
            "x".into(),
            events.clone(),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read(b.disk("/copy.bin")).unwrap(), big);
    events.assert_progress_ended_at(big.len() as u64);
    (a.core.clone())
        .sftp_transfer_dir(
            a.sftp.clone(),
            "/tree".into(),
            b.sftp.clone(),
            "/tree".into(),
            "x-dir".into(),
            Arc::new(Events::default()),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read(b.disk("/tree/b.bin")).unwrap(), tree[1].1);

    // Local paths are the caller's, and only absolute ones.
    let e = (a.core.clone())
        .sftp_download(
            a.sftp.clone(),
            "/big.bin".into(),
            "relative.bin".into(),
            "rel".into(),
            Arc::new(Events::default()),
        )
        .await
        .unwrap_err();
    assert_eq!(message(e), "Local paths must be absolute");
}

#[tokio::test]
async fn a_cancelled_transfer_leaves_no_partial_file() {
    let r = Remote::new(Duration::from_millis(40)).await;
    let local = tempfile::tempdir().unwrap();
    let source = local.path().join("big.bin");
    std::fs::write(&source, content(4 * 1024 * 1024)).unwrap();
    std::fs::write(r.disk("/big.bin"), content(4 * 1024 * 1024)).unwrap();
    let dst = tempfile::tempdir().unwrap();

    for upload in [true, false] {
        let events = Arc::new(Events::default());
        let tid = format!("cancel-{upload}");
        let transfer = {
            let (core, id, events, tid) =
                (r.core.clone(), r.sftp.clone(), events.clone(), tid.clone());
            let (source, dst) = (
                source.to_string_lossy().into_owned(),
                dst.path().join("big.bin"),
            );
            tokio::spawn(async move {
                match upload {
                    true => {
                        core.sftp_upload(id, source, "/up.bin".into(), tid, events)
                            .await
                    }
                    false => {
                        core.sftp_download(
                            id,
                            "/big.bin".into(),
                            dst.to_string_lossy().into(),
                            tid,
                            events,
                        )
                        .await
                    }
                }
            })
        };
        wait_for("bytes to flow", || events.transferred() > 0).await;
        r.core.clone().sftp_cancel_transfer(tid).await;
        let e = transfer.await.unwrap().unwrap_err();
        assert_eq!(message(e), "Transfer cancelled");
        assert!(
            events.transferred() < 4 * 1024 * 1024,
            "cancelled mid-transfer"
        );
    }
    assert_eq!(
        r.names("/"),
        ["big.bin"],
        "no partial upload, final or temp"
    );
    assert!(
        names(dst.path()).is_empty(),
        "no partial download, final or temp"
    );
}

#[tokio::test]
async fn a_transfer_cut_by_a_dropped_connection_resumes_where_it_stopped() {
    let r = Remote::new(Duration::from_millis(25)).await;
    let local = tempfile::tempdir().unwrap();
    let big = content(6 * 1024 * 1024);
    let source = local.path().join("big.bin");
    std::fs::write(&source, &big).unwrap();

    let events = Arc::new(Events::default());
    let transfer = {
        let (core, id, events) = (r.core.clone(), r.sftp.clone(), events.clone());
        let source = source.to_string_lossy().into_owned();
        tokio::spawn(async move {
            core.sftp_upload(id, source, "/big.bin".into(), "cut".into(), events)
                .await
        })
    };
    wait_for("a quarter of the file", || {
        events.transferred() > big.len() as u64 / 4
    })
    .await;
    r.host.drop_connections();
    wait_for("the transfer to wait for the link", || {
        !events.of("sftp-waiting").is_empty()
    })
    .await;

    // The user reconnects the terminal; the SFTP session rides it again.
    let _ = r.session.clone().disconnect(None, false, false, true).await;
    let sink = Arc::new(Recorder::default());
    let again = (r.core.clone())
        .ssh_connect(
            sink,
            args(&r.host, Some(r.session.id())),
            Default::default(),
        )
        .await
        .unwrap();
    assert_eq!(again.id(), r.session.id());

    transfer.await.unwrap().unwrap();
    assert_eq!(
        events.of("sftp-waiting"),
        [json!({ "waiting": true }), json!({ "waiting": false })]
    );
    let resumed = events.of("sftp-resumed");
    let offset = resumed.first().expect("a resume")["offset"]
        .as_u64()
        .unwrap();
    assert!(
        offset > 0 && offset < big.len() as u64,
        "picked up at {offset}"
    );
    assert!(
        std::fs::read(r.disk("/big.bin")).unwrap() == big,
        "identical content"
    );
    assert_eq!(r.names("/"), ["big.bin"], "no temp file left");
    events.assert_progress_ended_at(big.len() as u64);
}

/// Upstream asks before a transfer, not during one: the queue stats each target
/// (`sftp_stat`) and the conflict dialog's answer decides whether it is sent.
#[tokio::test]
async fn a_conflict_is_answered_before_the_transfer_overwrite_or_skip() {
    let r = Remote::new(Duration::ZERO).await;
    let local = tempfile::tempdir().unwrap();
    let source = local.path().join("a.txt").to_string_lossy().into_owned();
    std::fs::write(&source, "new").unwrap();
    std::fs::write(r.disk("/a.txt"), "old").unwrap();

    for (answer, expected) in [("skip", "old"), ("overwrite", "new")] {
        let exists = r
            .core
            .clone()
            .sftp_stat(r.sftp.clone(), "/a.txt".into())
            .await
            .unwrap();
        assert_eq!(exists, Some(false), "a file is in the way");
        if answer == "overwrite" {
            (r.core.clone())
                .sftp_upload(
                    r.sftp.clone(),
                    source.clone(),
                    "/a.txt".into(),
                    answer.into(),
                    Arc::new(Events::default()),
                )
                .await
                .unwrap();
        }
        assert_eq!(std::fs::read_to_string(r.disk("/a.txt")).unwrap(), expected);
    }
    assert_eq!(
        r.names("/"),
        ["a.txt"],
        "the old copy and the temp are gone"
    );
}

/// `top/-dash.txt`, `top/sub/@at.txt` and `top/link` (to `sub`): names tar and zip could misread.
fn tricky_tree(dir: &Path) -> PathBuf {
    let top = dir.join("top");
    std::fs::create_dir_all(top.join("sub")).unwrap();
    std::fs::write(top.join("-dash.txt"), "dash").unwrap();
    std::fs::write(top.join("sub/@at.txt"), "at").unwrap();
    std::os::unix::fs::symlink("sub", top.join("link")).unwrap();
    top
}

/// A tar member with any name and, for a link, target: the `tar` crate's builder refuses `..`.
fn tar_member(out: &mut Vec<u8>, name: &str, link: Option<&str>, data: &[u8]) {
    let mut header = tar::Header::new_ustar();
    header.as_mut_bytes()[..name.len()].copy_from_slice(name.as_bytes());
    if let Some(target) = link {
        header.set_entry_type(tar::EntryType::Symlink);
        header.as_mut_bytes()[157..157 + target.len()].copy_from_slice(target.as_bytes());
    }
    header.set_mode(0o644);
    header.set_size(data.len() as u64);
    header.set_cksum();
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(data);
    out.resize(out.len().next_multiple_of(512), 0);
}

/// The host's own `cp`, `tar`, `zip`, `unzip` and `chmod`, run by this machine's `sh` on the temp dir.
#[tokio::test]
async fn the_host_copies_packs_and_unpacks_by_itself_and_writes_over_nothing() {
    let r = Remote::new(Duration::ZERO).await;
    r.host.seen.lock().unwrap().run_execs = true;
    let (core, id) = (r.core.clone(), r.sftp.clone());
    // The scripts get real paths: exec, unlike the SFTP subsystem, has no root of its own.
    let dir = r.root.path().canonicalize().unwrap();
    let s = |p: &Path| p.to_string_lossy().into_owned();
    let read = |p: &Path| std::fs::read_to_string(p).unwrap();
    let copy = |from: &Path, to: &Path| core.clone().sftp_copy(id.clone(), s(from), s(to));
    let compress = |paths: &[&Path], archive: &Path| {
        let paths = paths.iter().map(|p| s(p)).collect();
        core.clone().sftp_compress(id.clone(), paths, s(archive))
    };
    let extract = |archive: &Path, into: &Path| {
        std::fs::create_dir_all(into).unwrap();
        core.clone().sftp_extract(id.clone(), s(archive), s(into))
    };

    let top = tricky_tree(&dir);
    let solo = dir.join("-solo");
    std::fs::write(&solo, "solo").unwrap();

    // Copy: the tree with its link; never onto a file, into a folder or through a link to nothing.
    let twin = dir.join("top copy");
    copy(&top, &twin).await.unwrap();
    assert_eq!(read(&twin.join("sub/@at.txt")), "at");
    assert_eq!(read(&twin.join("-dash.txt")), "dash");
    assert!(twin.join("link").is_symlink());
    let dangling = dir.join("dangling");
    std::os::unix::fs::symlink(dir.join("nowhere"), &dangling).unwrap();
    for taken in [twin.join("-dash.txt"), twin.clone(), dangling] {
        let e = message(copy(&solo, &taken).await.unwrap_err());
        assert_eq!(e, format!("Copy failed: {} already exists", s(&taken)));
    }
    assert_eq!(read(&twin.join("-dash.txt")), "dash");
    assert!(!twin.join("-solo").exists() && !dir.join("nowhere").exists());

    // Compress and extract: names of the folder, not paths; an archive that is there stays as it is.
    for ending in ["tar.gz", "tar", "zip"] {
        let archive = dir.join(format!("pack.{ending}"));
        compress(&[&top, &solo], &archive).await.unwrap();
        let before = std::fs::read(&archive).unwrap();
        let e = message(compress(&[&solo], &archive).await.unwrap_err());
        assert_eq!(
            e,
            format!("Compress failed: {} already exists", s(&archive))
        );
        assert_eq!(std::fs::read(&archive).unwrap(), before);

        let out = dir.join(format!("out {ending}"));
        extract(&archive, &out).await.unwrap();
        assert_eq!(names(&out), ["-solo", "top"], "{ending}");
        assert_eq!(read(&out.join("top/sub/@at.txt")), "at");
        assert_eq!(read(&out.join("top/-dash.txt")), "dash");
        assert_eq!(read(&out.join("-solo")), "solo");
        assert!(out.join("top/link").is_symlink());
    }
    // A failed compress leaves no half-made archive.
    let failed = dir.join("failed.tar.gz");
    assert!(compress(&[&dir.join("missing")], &failed).await.is_err());
    assert!(!failed.exists());

    // What never reaches the host's shell.
    let before = r.host.seen.lock().unwrap().execs.len();
    let refused = [
        message(copy(Path::new("relative"), &twin).await.unwrap_err()),
        message(copy(&top, Path::new("-rf")).await.unwrap_err()),
        message(
            compress(&[&top, &twin.join("sub")], &failed)
                .await
                .unwrap_err(),
        ),
        message(compress(&[&dir.join("..")], &failed).await.unwrap_err()),
        message(compress(&[], &failed).await.unwrap_err()),
        message(compress(&[&top], &dir.join("pack.rar")).await.unwrap_err()),
        message(
            extract(&dir.join("pack.gz"), &dir.join("x"))
                .await
                .unwrap_err(),
        ),
        message(
            extract(&dir.join("a[1].zip"), &dir.join("x"))
                .await
                .unwrap_err(),
        ),
    ];
    assert_eq!(
        r.host.seen.lock().unwrap().execs.len(),
        before,
        "{refused:?}"
    );
    assert_eq!(refused[0], "Not an absolute path: relative");
    assert_eq!(refused[2], "Only items of one folder go in one archive");

    // Extract: an archive's `..`, absolute and through-a-link members stay inside the folder.
    let outside = dir.join("outside");
    std::fs::create_dir(&outside).unwrap();
    let mut evil = Vec::new();
    tar_member(&mut evil, "ok.txt", None, b"fine");
    tar_member(&mut evil, "../dotdot.txt", None, b"out");
    tar_member(&mut evil, &s(&outside.join("abs.txt")), None, b"out");
    tar_member(&mut evil, "link", Some(&s(&outside)), b"");
    tar_member(&mut evil, "link/through.txt", None, b"out");
    evil.resize(evil.len() + 1024, 0);
    std::fs::write(dir.join("evil.tar"), evil).unwrap();
    let into = dir.join("deep/into");
    let _ = extract(&dir.join("evil.tar"), &into).await;
    assert_eq!(read(&into.join("ok.txt")), "fine");
    assert_eq!(names(&outside), [""; 0]);
    assert!(!dir.join("deep/dotdot.txt").exists());

    // A whole tree's modes: a bit named in both `set` and `clear` is set, as over SFTP.
    let change = json!({ "paths": [s(&top)], "set": 0o750, "clear": 0o7777, "recurse": "all" });
    core.clone()
        .sftp_set_attrs(id.clone(), change.to_string())
        .await
        .unwrap();
    for path in [top.clone(), top.join("sub"), top.join("sub/@at.txt")] {
        let mode = path.metadata().unwrap().permissions().mode();
        assert_eq!(mode & 0o7777, 0o750, "{path:?}");
    }
    r.session.clone().close().await.unwrap();
}
