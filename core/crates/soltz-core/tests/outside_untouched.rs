// SPDX-License-Identifier: AGPL-3.0-only
//! Soltz never reads, writes, migrates or deletes files outside its data directory.
//! HOME points at a temp dir holding another app's files (entity files, known hosts,
//! a vault), and every storage call runs against a Soltz
//! data directory beside them. One test in its own binary: HOME is process-wide.

mod common;

use common::host::{key, serve, PASSWORD, USER};
use common::{trusting, Recorder};
use serde_json::json;
use soltz_core::api::{Cancellation, Core, Keychain};
use soltz_core::entities::EntityKind;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

/// Every file under `root` but `skip`, with its bytes and modification time.
fn snapshot(root: &Path, skip: &Path) -> BTreeMap<PathBuf, (Vec<u8>, SystemTime)> {
    let mut files = BTreeMap::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.starts_with(skip) {
                continue;
            }
            if path.is_dir() {
                // A folder holding `skip` changes when `skip` is created in it.
                let modified = match skip.starts_with(&path) {
                    true => SystemTime::UNIX_EPOCH,
                    false => path.metadata().unwrap().modified().unwrap(),
                };
                files.insert(path.clone(), (Vec::new(), modified));
                dirs.push(path);
            } else {
                let modified = path.metadata().unwrap().modified().unwrap();
                files.insert(path.clone(), (std::fs::read(&path).unwrap(), modified));
            }
        }
    }
    files
}

#[tokio::test]
async fn files_outside_the_data_dir_are_left_exactly_as_they_were() {
    let home = tempfile::tempdir().unwrap();
    std::env::set_var("HOME", home.path());
    let support = home.path().join("Library/Application Support");
    let other = support.join("other");
    let other_data = support.join("com.other.app");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::create_dir_all(&other_data).unwrap();
    let fakes = [
        (
            other.join("connections.json"),
            json!([{ "id": "other-conn" }]).to_string(),
        ),
        (
            other.join("known_hosts.json"),
            json!({ "old.example:22": "SHA256:legacy" }).to_string(),
        ),
        (
            other.join(".known_hosts"),
            json!({ "older.example:2222": "SHA256:older" }).to_string(),
        ),
        (
            other_data.join("secrets.enc"),
            "not really ciphertext".to_string(),
        ),
    ];
    for (path, content) in &fakes {
        std::fs::write(path, content).unwrap();
    }
    let soltz = support.join("Soltz");
    let before = snapshot(home.path(), &soltz);

    let core = Core::with_data_dir(soltz.to_str().unwrap().into(), Keychain::Memory).unwrap();
    core.clone().vault_initialise(None).await.unwrap();
    core.secret_set("password:c1".into(), "pw".into()).unwrap();
    core.secret_delete("password:c1".into()).unwrap();
    core.vault_lock();
    core.clone().vault_unlock(None).await.unwrap();
    core.clone().vault_status().await.unwrap();
    let stamps = json!({ "created_at": "t", "updated_at": "t", "deleted_at": null, "clocks": {} });
    for kind in [
        EntityKind::Connections,
        EntityKind::Identities,
        EntityKind::SshKeys,
        EntityKind::Folders,
    ] {
        let mut row = json!({ "id": "x", "name": "n", "username": "u", "tags": [],
            "last_used_at": null });
        row.as_object_mut()
            .unwrap()
            .extend(stamps.as_object().unwrap().clone());
        core.clone()
            .entity_save(kind, row.to_string())
            .await
            .unwrap();
        core.clone().entity_list(kind).await.unwrap();
        core.clone().entity_delete(kind, "x".into()).await.unwrap();
    }
    core.clone()
        .entity_list(EntityKind::KnownHosts)
        .await
        .unwrap();
    // Writes known_hosts.json, as every trust and delete does.
    core.clone()
        .entity_delete(EntityKind::KnownHosts, "x".into())
        .await
        .unwrap();
    // Connecting trusts the host's key.
    let host = serve(key(1)).await;
    let args = json!({"host": "127.0.0.1", "port": host.port, "username": USER,
        "password": PASSWORD, "persist": false});
    let sink = Arc::new(Recorder::default());
    let connect = (core.clone()).ssh_connect(sink.clone(), args.to_string(), Cancellation::new());
    let session = trusting(&core, &sink, connect).await.unwrap();
    session.close().await.unwrap();
    assert!(soltz.join("known_hosts.json").exists());
    assert!(soltz.join("secrets.enc").exists());

    assert_eq!(snapshot(home.path(), &soltz), before);
    for (path, content) in &fakes {
        assert_eq!(&std::fs::read_to_string(path).unwrap(), content);
    }
}
