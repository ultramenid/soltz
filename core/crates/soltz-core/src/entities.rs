// SPDX-License-Identifier: AGPL-3.0-only
//! The entity files of the data directory, read and written by upstream's own
//! types and functions (storage/config.rs), so each file is what upstream writes.
//! Rows cross the FFI as JSON, which Packages/SoltzModel decodes.
//!
//! Rows are stored as given: like upstream's frontend, the caller stamps `clocks`,
//! `updated_at` and `created_at`. Only a delete stamps, as upstream's does.

use crate::api::{blocking, failed, Core, CoreError};
use crate::commands::vault_object::{
    adopt_into, find_mut, impl_vault_object, live, tombstone, VaultObject,
};
use crate::storage::config::{
    load_json, load_json_migrated, save_json, Connection, Folder, Identity, KnownHost, SshKey,
};
use serde::{de::DeserializeOwned, Serialize};
use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntityKind {
    Connections,
    Identities,
    SshKeys,
    Folders,
    /// Listed and deleted only: entries are added by connecting (trust on first use).
    KnownHosts,
}

// As commands/<entity>.rs implements it upstream.
impl_vault_object!(Connection, "Connection");
impl_vault_object!(Identity, "Identity");
impl_vault_object!(SshKey, "Key");
impl_vault_object!(Folder, "Folder");
impl_vault_object!(KnownHost, "Known host");

/// One entity file, by the operations every kind shares.
trait File: Sync {
    fn list(&self, dir: &Path) -> Result<String, String>;
    fn save(&self, dir: &Path, row: &str) -> Result<(), String>;
    fn delete(&self, dir: &Path, id: &str, now: &str) -> Result<(), String>;
    /// `rows` (a JSON array) written to `path` the way upstream writes this file.
    fn write_all(&self, path: PathBuf, rows: &str) -> Result<(), String>;
}

/// A file of upstream's typed records: loaded through its migrations, tombstoned
/// by `vault_object::tombstone`, written by `config::save_json`.
struct Typed<T> {
    name: &'static str,
    load: fn(PathBuf) -> Result<Vec<T>, String>,
}

impl<T: VaultObject + Serialize + DeserializeOwned> File for Typed<T> {
    fn list(&self, dir: &Path) -> Result<String, String> {
        to_json(&live((self.load)(dir.join(self.name))?))
    }

    fn save(&self, dir: &Path, row: &str) -> Result<(), String> {
        let row: T = from_json(row)?;
        let path = dir.join(self.name);
        let mut rows = (self.load)(path.clone())?;
        adopt_into(&mut rows, row);
        save_json(path, &rows)
    }

    fn delete(&self, dir: &Path, id: &str, now: &str) -> Result<(), String> {
        let path = dir.join(self.name);
        let mut rows = (self.load)(path.clone())?;
        tombstone(find_mut(&mut rows, id)?, now);
        save_json(path, &rows)
    }

    fn write_all(&self, path: PathBuf, rows: &str) -> Result<(), String> {
        save_json(path, &from_json::<Vec<T>>(rows)?)
    }
}

fn to_json(value: &impl Serialize) -> Result<String, String> {
    serde_json::to_string(value).map_err(|e| e.to_string())
}

fn from_json<T: DeserializeOwned>(json: &str) -> Result<T, String> {
    serde_json::from_str(json).map_err(|e| e.to_string())
}

/// The file names are config.rs' (`connections_file()` and its siblings).
fn file(kind: EntityKind) -> &'static dyn File {
    match kind {
        EntityKind::Connections => &Typed::<Connection> {
            name: "connections.json",
            load: load_json_migrated,
        },
        EntityKind::Identities => &Typed::<Identity> {
            name: "identities.json",
            load: load_json_migrated,
        },
        EntityKind::SshKeys => &Typed::<SshKey> {
            name: "ssh_keys.json",
            load: load_json_migrated,
        },
        EntityKind::Folders => &Typed::<Folder> {
            name: "folders.json",
            load: load_json,
        },
        // Read and written by the core's `KnownHostsStore`; only `write_all` comes here.
        EntityKind::KnownHosts => &Typed::<KnownHost> {
            name: "known_hosts.json",
            load: load_json,
        },
    }
}

/// For tests: writes `rows` (a JSON array of `kind`) to `path` with upstream's own
/// types and writer, to compare with what the core wrote.
#[doc(hidden)]
pub fn write_as_upstream(kind: EntityKind, rows: &str, path: &Path) -> Result<(), String> {
    file(kind).write_all(path.to_path_buf(), rows)
}

#[uniffi::export]
impl Core {
    /// The rows of `kind` that are alive (as upstream's `*_list`: tombstones left
    /// out), as a JSON array in file order.
    pub async fn entity_list(self: Arc<Self>, kind: EntityKind) -> Result<String, CoreError> {
        if kind == EntityKind::KnownHosts {
            return to_json(&self.known_hosts.list().await).map_err(failed);
        }
        self.on_data_dir(move |dir| file(kind).list(dir)).await
    }

    /// Inserts `row` (one JSON object), or replaces the row with its `id`, exactly
    /// as given. Fields upstream's record type lacks are dropped, as upstream drops
    /// them. Known hosts cannot be saved: connecting adds them.
    pub async fn entity_save(
        self: Arc<Self>,
        kind: EntityKind,
        row: String,
    ) -> Result<(), CoreError> {
        // shortcut: no edit of a known host's name or vault, add one (upstream `known_host_move_vault`) when the app needs it.
        if kind == EntityKind::KnownHosts {
            return Err(failed("Known hosts are added by connecting, not saved"));
        }
        self.on_data_dir(move |dir| file(kind).save(dir, &row))
            .await
    }

    /// Soft-deletes the row with `id`, as upstream's delete does: `deleted_at`,
    /// the `__deleted__` clock and `updated_at` are stamped now, and the row stays
    /// in the file so the deletion can sync. One row only: deleting a folder does
    /// not cascade to its subfolders and contents as upstream's `folder_delete` does.
    pub async fn entity_delete(
        self: Arc<Self>,
        kind: EntityKind,
        id: String,
    ) -> Result<(), CoreError> {
        // shortcut: no folder cascade, port `folders.rs`' `folder_delete` when the app deletes folders.
        if kind == EntityKind::KnownHosts {
            self.known_hosts.delete(&id).await;
            return Ok(());
        }
        let now = chrono::Utc::now().to_rfc3339();
        self.on_data_dir(move |dir| file(kind).delete(dir, &id, &now))
            .await
    }
}

impl Core {
    /// Runs `job` on the data directory, one at a time, off the caller's thread.
    async fn on_data_dir<T: Send + 'static>(
        self: Arc<Self>,
        job: impl FnOnce(&Path) -> Result<T, String> + Send + 'static,
    ) -> Result<T, CoreError> {
        blocking(move || {
            let data = self.data()?;
            let _one_at_a_time = data
                .entity_write
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            job(&data.dir)
        })
        .await
        .map_err(failed)
    }
}
