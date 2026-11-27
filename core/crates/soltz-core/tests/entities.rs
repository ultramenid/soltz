// SPDX-License-Identifier: AGPL-3.0-only
//! Entity files through the public API, against a temp data directory.

use serde_json::{json, Value};
use soltz_core::api::{Core, Keychain};
use soltz_core::entities::{write_as_upstream, EntityKind};
use std::path::Path;
use std::sync::Arc;

const T: &str = "2026-01-01T00:00:00+00:00";

fn core(dir: &Path) -> Arc<Core> {
    Core::with_data_dir(dir.to_str().unwrap().into(), Keychain::Memory).unwrap()
}

/// One row of every kind that has a file of its own (known hosts: tests/ssh.rs).
/// Each clock map holds one entry: serde writes a map in random order, upstream too.
fn samples() -> Vec<(EntityKind, &'static str, Value)> {
    use EntityKind::*;
    let stamps = |field: &str| json!({ "created_at": T, "updated_at": T, "deleted_at": null, "clocks": { field: T } });
    let row = |fields: Value, field: &str| {
        let mut row = stamps(field);
        row.as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        row
    };
    vec![
        (
            Connections,
            "connections.json",
            row(
                json!({
                    "id": "c1", "name": "web", "host": "example.com", "port": 22, "username": "root",
                    "auth_type": "key", "tags": ["prod"], "last_used_at": null, "folder_id": "f1",
                    "env_vars": [{ "id": "e1", "key": "TERM", "value": "xterm" }],
                    "proxy": { "mode": "socks5", "host": "127.0.0.1", "port": 1080 },
                }),
                "host",
            ),
        ),
        (
            Identities,
            "identities.json",
            row(
                json!({
                    "id": "i1", "name": "admin", "username": "root", "key_id": "k1", "tags": [],
                }),
                "username",
            ),
        ),
        (
            SshKeys,
            "ssh_keys.json",
            row(
                json!({
                    "id": "k1", "name": "deploy", "key_type": "ed25519",
                }),
                "name",
            ),
        ),
        (
            Folders,
            "folders.json",
            row(
                json!({
                    "id": "f1", "name": "Servers", "color": "#22c55e", "pinned": true,
                }),
                "name",
            ),
        ),
    ]
}

async fn list(core: &Arc<Core>, kind: EntityKind) -> Vec<Value> {
    serde_json::from_str(&core.clone().entity_list(kind).await.unwrap()).unwrap()
}

fn on_disk(path: &Path) -> Vec<Value> {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[tokio::test]
async fn every_kind_is_written_byte_for_byte_as_upstream_writes_it() {
    let dir = tempfile::tempdir().unwrap();
    let upstream = tempfile::tempdir().unwrap();
    let core = core(dir.path());

    for (kind, file, row) in samples() {
        core.clone()
            .entity_save(kind, row.to_string())
            .await
            .unwrap();

        write_as_upstream(kind, &json!([row]).to_string(), &upstream.path().join(file)).unwrap();
        let ours = std::fs::read(dir.path().join(file)).unwrap();
        assert_eq!(
            String::from_utf8(ours).unwrap(),
            std::fs::read_to_string(upstream.path().join(file)).unwrap(),
            "{file}"
        );

        let listed = list(&core, kind).await;
        assert_eq!(
            listed,
            on_disk(&dir.path().join(file)),
            "{file}: listed as stored"
        );
        assert_eq!(listed[0]["id"], row["id"]);
    }
}

#[tokio::test]
async fn saving_a_known_id_replaces_that_row_in_place() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    for (kind, file, row) in samples() {
        let mut second = row.clone();
        second["id"] = json!("second");
        let mut renamed = row.clone();
        renamed["name"] = json!("renamed");
        for r in [&row, &second, &renamed] {
            core.clone().entity_save(kind, r.to_string()).await.unwrap();
        }
        let ids: Vec<_> = list(&core, kind)
            .await
            .iter()
            .map(|r| r["id"].clone())
            .collect();
        assert_eq!(ids, [row["id"].clone(), json!("second")], "{file}");
        assert_eq!(list(&core, kind).await[0]["name"], "renamed", "{file}");
    }
}

#[tokio::test]
async fn a_delete_leaves_a_tombstone_that_the_list_leaves_out() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    for (kind, file, row) in samples() {
        let id = row["id"].as_str().unwrap().to_string();
        core.clone()
            .entity_save(kind, row.to_string())
            .await
            .unwrap();
        core.clone().entity_delete(kind, id.clone()).await.unwrap();

        assert!(list(&core, kind).await.is_empty(), "{file}");
        let stored = &on_disk(&dir.path().join(file))[0];
        let deleted_at = stored["deleted_at"].as_str().expect("a delete stamp");
        assert!(deleted_at > T, "{file}");
        assert_eq!(stored["clocks"]["__deleted__"], deleted_at, "{file}");
        assert_eq!(stored["updated_at"], deleted_at, "{file}: the newest clock");
        assert_eq!(
            stored["clocks"][row["clocks"].as_object().unwrap().keys().next().unwrap()],
            T
        );

        let missing = core.clone().entity_delete(kind, "nope".into()).await;
        assert!(missing.is_err(), "{file}: deleting an unknown id");
    }
}

#[tokio::test]
async fn a_row_upstream_cannot_read_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let no_clocks = json!({ "id": "c1", "tags": [], "created_at": T, "updated_at": T });
    assert!(core
        .clone()
        .entity_save(EntityKind::Connections, no_clocks.to_string())
        .await
        .is_err());
    assert!(!dir.path().join("connections.json").exists());
}

#[tokio::test]
async fn a_core_without_a_data_directory_has_no_entities() {
    assert!(Core::new()
        .entity_list(EntityKind::Connections)
        .await
        .is_err());
    assert!(Core::with_data_dir("relative/dir".into(), Keychain::Memory).is_err());
}
