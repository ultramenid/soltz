// SPDX-License-Identifier: AGPL-3.0-only
//! Upstream's SFTP commands (commands/sftp/{ops,dir,transfer,editor}.rs)
//! for Swift: the same names, arguments and results (JSON where structured), over
//! upstream's backend and resumable copy engine, on an SFTP channel riding one of
//! this core's SSH sessions.
//!
//! Not here: standalone `sftp_connect`, FTP, WebDAV, Docker, the tar commands,
//! `sftp_read_image` and `sftp_owners`.
//!
//! Soltz's own: `sftp_copy`, `sftp_compress` and `sftp_extract` (sftp/on_host.rs).

use super::sftp::editor::read_for_editor;
use super::sftp::resume::{copy_one, copy_tree, mark_resume};
use super::sftp::{get_backend, get_endpoint, run_backend_transfer, with_transfer};
use crate::api::{event_name, failed, on_runtime, Core, CoreError};
use crate::error::AppError;
use crate::sftp::attrs::AttrChange;
use crate::sftp::backend::TransferEvents;
use crate::sftp::on_host;
use crate::sftp::FileBackend;
use serde::Serialize;
use std::future::Future;
use std::path::Path;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// Receives one transfer's events, on background threads, while its call runs.
#[uniffi::export(with_foreign)]
pub trait TransferSink: Send + Sync {
    /// Upstream's `sftp-<kind>-<transfer id>` events, less the id, with their JSON
    /// payloads: `sftp-progress` (`{transferred, total}`, bytes, in order),
    /// `sftp-resumed` (`{offset}`: bytes already in place when a copy picked up
    /// again), `sftp-waiting` (`{waiting}`: the link dropped, or came back) and
    /// `sftp-skipped` (a remote path the local system cannot hold, as a JSON string).
    fn event(&self, name: String, payload_json: String);
}

/// One transfer's [`TransferSink`] as the copy engine's events.
pub(crate) struct Events {
    sink: Arc<dyn TransferSink>,
    transfer_id: String,
}

impl Events {
    fn new(sink: Arc<dyn TransferSink>, transfer_id: &str) -> Self {
        let transfer_id = transfer_id.to_string();
        Self { sink, transfer_id }
    }
}

impl TransferEvents for Events {
    fn send<S: Serialize + Clone>(&self, event: &str, payload: S) {
        let payload = serde_json::to_string(&payload).unwrap_or_default();
        let name = event_name(event, &self.transfer_id);
        self.sink.event(name.to_string(), payload);
    }
}

/// Upstream takes any local path its frontend sends; Soltz takes only absolute
/// ones, so none resolves against the process's working directory.
fn absolute(local_path: &str) -> Result<(), CoreError> {
    match Path::new(local_path).is_absolute() {
        true => Ok(()),
        false => Err(failed("Local paths must be absolute")),
    }
}

#[uniffi::export]
impl Core {
    /// Upstream's `sftp_open`: an SFTP channel on the SSH session `session_id`
    /// ([`crate::api::Session::id`]), following it across a reconnect under that id.
    /// Returns the `sftpId` every other `sftp*` call takes.
    pub async fn sftp_open(self: Arc<Self>, session_id: String) -> Result<String, CoreError> {
        on_runtime(async move {
            let handle = self.ssh.get_session_handle(&session_id).await?;
            self.sftp.open(handle).await
        })
        .await
        .map_err(failed)
    }

    pub async fn sftp_close(self: Arc<Self>, sftp_id: String) {
        on_runtime(async move { self.sftp.close(&sftp_id).await }).await
    }

    /// `true` for a directory, `false` for anything else, `nil` when nothing is there.
    pub async fn sftp_stat(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<Option<bool>, CoreError> {
        self.on_backend(sftp_id, |b| async move { b.stat(&path).await })
            .await
    }

    /// A JSON array of `{name, path, size, is_dir, is_symlink, modified, permissions}`,
    /// folders first. A symlink is listed with `is_symlink` and the `is_dir` of its target.
    pub async fn sftp_list_dir(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<String, CoreError> {
        let files = self
            .on_backend(sftp_id, |b| async move { b.list_dir(&path).await })
            .await?;
        serde_json::to_string(&files).map_err(failed)
    }

    /// The absolute path `path` names (`.` is the login directory).
    pub async fn sftp_canonicalize(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<String, CoreError> {
        self.on_backend(sftp_id, |b| async move { b.canonicalize(&path).await })
            .await
    }

    pub async fn sftp_mkdir(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move { b.mkdir(&path).await })
            .await
    }

    pub async fn sftp_touch(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move { b.touch(&path).await })
            .await
    }

    /// Rename or move, within the session.
    pub async fn sftp_rename(
        self: Arc<Self>,
        sftp_id: String,
        from: String,
        to: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move { b.rename(&from, &to).await })
            .await
    }

    /// A file, or a directory with everything under it; a symlink is removed, never followed.
    pub async fn sftp_delete(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move { b.delete(&path).await })
            .await
    }

    /// A copy of `from` (a file, or a folder with everything in it) at `to`, made by the host's
    /// own `cp`: needs a POSIX shell there, and fails when something is at `to`.
    pub async fn sftp_copy(
        self: Arc<Self>,
        sftp_id: String,
        from: String,
        to: String,
    ) -> Result<(), CoreError> {
        self.on_backend(
            sftp_id,
            |b| async move { on_host::copy(&*b, &from, &to).await },
        )
        .await
    }

    /// Packs `paths` (items of one folder, stored by their names) into a new `archive` with the
    /// host's `tar`, or `zip` for a `.zip`: fails when something is at `archive`.
    pub async fn sftp_compress(
        self: Arc<Self>,
        sftp_id: String,
        paths: Vec<String>,
        archive: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move {
            on_host::compress(&*b, &paths, &archive).await
        })
        .await
    }

    /// Unpacks `archive` with the host's `tar`, or `unzip` for a `.zip`, into the folder `dir`,
    /// which the caller made empty: what is in a folder already may be written over.
    pub async fn sftp_extract(
        self: Arc<Self>,
        sftp_id: String,
        archive: String,
        dir: String,
    ) -> Result<(), CoreError> {
        self.on_backend(sftp_id, |b| async move {
            on_host::extract(&*b, &archive, &dir).await
        })
        .await
    }

    /// Upstream's `sftp_set_attrs`. `change_json`: `{paths, set, clear, owner?, group?,
    /// recurse?}` (`set`/`clear`: mode bits; `recurse`: `all`|`files`|`dirs`). A mode
    /// change alone goes over SFTP; owners and recursion need a POSIX shell on the host.
    pub async fn sftp_set_attrs(
        self: Arc<Self>,
        sftp_id: String,
        change_json: String,
    ) -> Result<(), CoreError> {
        let change: AttrChange = serde_json::from_str(&change_json).map_err(failed)?;
        if change.paths.is_empty() {
            return Ok(());
        }
        self.on_backend(sftp_id, |b| async move { b.set_attrs(&change).await })
            .await
    }

    /// Upstream's `sftp_read_file`, for the editor: `{content, size}` for a text file
    /// of at most `max_bytes`. Otherwise it fails with upstream's error object as the
    /// message: `{"kind":"too_large","size","limit"}`, `{"kind":"binary"}`,
    /// `{"kind":"image","mime","size"}` or `{"kind":"io","message"}`.
    pub async fn sftp_read_file(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
        max_bytes: u64,
    ) -> Result<String, CoreError> {
        let read = on_runtime(async move {
            let backend = get_backend(&self.sftp, &sftp_id).await?;
            let size = backend.file_size(&path).await;
            read_for_editor(size, max_bytes, |limit| backend.read_file(&path, limit)).await
        })
        .await;
        match read {
            Ok(file) => serde_json::to_string(&file).map_err(failed),
            Err(e) => Err(failed(serde_json::to_string(&e).map_err(failed)?)),
        }
    }

    /// Upstream's `sftp_write_file`: replaces `path` with `content`, one write per path at a time.
    pub async fn sftp_write_file(
        self: Arc<Self>,
        sftp_id: String,
        path: String,
        content: String,
    ) -> Result<(), CoreError> {
        on_runtime(async move {
            let lock = self.sftp.path_lock(&sftp_id, &path).await;
            let _one_writer = lock.lock().await;
            get_backend(&self.sftp, &sftp_id)
                .await?
                .write_file(&path, &content)
                .await
        })
        .await
        .map_err(failed)
    }

    /// Upstream's `sftp_upload`: one local file to `remote_path`, through the resumable
    /// copy engine (a temp file beside the target, swapped in when complete).
    /// Returns when the transfer ends; `sink` gets its events meanwhile.
    pub async fn sftp_upload(
        self: Arc<Self>,
        sftp_id: String,
        local_path: String,
        remote_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        absolute(&local_path)?;
        self.backend_transfer(sftp_id, transfer_id, sink, |b, e, tid, token| async move {
            b.upload_file(&e, &local_path, &remote_path, &tid, &token)
                .await
        })
        .await
    }

    /// Upstream's `sftp_download`: as [`Core::sftp_upload`], the other way.
    pub async fn sftp_download(
        self: Arc<Self>,
        sftp_id: String,
        remote_path: String,
        local_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        absolute(&local_path)?;
        self.backend_transfer(sftp_id, transfer_id, sink, |b, e, tid, token| async move {
            b.download_file(&e, &remote_path, &local_path, &tid, &token)
                .await
        })
        .await
    }

    /// Upstream's `sftp_upload_dir`: a local tree, file by file; symlinks are left out.
    pub async fn sftp_upload_dir(
        self: Arc<Self>,
        sftp_id: String,
        local_path: String,
        remote_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        absolute(&local_path)?;
        self.backend_transfer(sftp_id, transfer_id, sink, |b, e, tid, token| async move {
            b.upload_dir(&e, &local_path, &remote_path, &tid, &token)
                .await
        })
        .await
    }

    /// Upstream's `sftp_download_dir`: a remote tree, file by file; names this system
    /// cannot hold are skipped and reported (`sftp-skipped`).
    pub async fn sftp_download_dir(
        self: Arc<Self>,
        sftp_id: String,
        remote_path: String,
        local_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        absolute(&local_path)?;
        self.backend_transfer(sftp_id, transfer_id, sink, |b, e, tid, token| async move {
            b.download_dir(&e, &remote_path, &local_path, &tid, &token)
                .await
        })
        .await
    }

    /// Upstream's `sftp_transfer`: one file from one SFTP session to another, streamed.
    pub async fn sftp_transfer(
        self: Arc<Self>,
        src_sftp_id: String,
        src_path: String,
        dst_sftp_id: String,
        dst_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        self.host_to_host(
            src_sftp_id,
            src_path,
            dst_sftp_id,
            dst_path,
            transfer_id,
            sink,
            false,
        )
        .await
    }

    /// Upstream's `sftp_transfer_dir`: a tree from one SFTP session to another.
    pub async fn sftp_transfer_dir(
        self: Arc<Self>,
        src_sftp_id: String,
        src_path: String,
        dst_sftp_id: String,
        dst_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
    ) -> Result<(), CoreError> {
        self.host_to_host(
            src_sftp_id,
            src_path,
            dst_sftp_id,
            dst_path,
            transfer_id,
            sink,
            true,
        )
        .await
    }

    /// Stops the transfer `transfer_id`, whether it has started yet or not: it
    /// fails with `Transfer cancelled` and leaves no partial file at its target.
    pub async fn sftp_cancel_transfer(self: Arc<Self>, transfer_id: String) {
        on_runtime(async move { self.sftp.cancel_transfer(&transfer_id).await }).await
    }

    /// Upstream's `sftp_mark_resume`: the transfer about to start under `transfer_id`
    /// is a Retry of a failed one with that id, so a folder copy skips files that
    /// already landed. A single file picks up from its kept partial copy either way.
    pub fn sftp_mark_resume(&self, transfer_id: String) {
        mark_resume(&transfer_id);
    }
}

impl Core {
    /// `op` on `sftp_id`'s backend, on the core's runtime.
    async fn on_backend<T, E, F, Fut>(
        self: Arc<Self>,
        sftp_id: String,
        op: F,
    ) -> Result<T, CoreError>
    where
        T: Send + 'static,
        AppError: From<E>,
        F: FnOnce(Arc<dyn FileBackend>) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, E>> + Send,
    {
        on_runtime(async move {
            let backend = get_backend(&self.sftp, &sftp_id).await?;
            op(backend).await.map_err(AppError::from)
        })
        .await
        .map_err(CoreError::from)
    }

    /// Upstream's `backend_transfer_command!`: `run` on `sftp_id`'s backend as the
    /// registered, cancellable transfer `transfer_id`, reporting to `sink`.
    async fn backend_transfer<F, Fut>(
        self: Arc<Self>,
        sftp_id: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
        run: F,
    ) -> Result<(), CoreError>
    where
        F: FnOnce(Arc<dyn FileBackend>, Events, String, CancellationToken) -> Fut + Send + 'static,
        Fut: Future<Output = Result<(), AppError>> + Send,
    {
        on_runtime(async move {
            let events = Events::new(sink, &transfer_id);
            let tid = transfer_id.clone();
            run_backend_transfer(&self.sftp, &sftp_id, &transfer_id, |b, token| {
                run(b, events, tid, token)
            })
            .await
        })
        .await
        .map_err(CoreError::from)
    }

    /// `sftp_transfer` (`dir` false) and `sftp_transfer_dir` (true).
    async fn host_to_host(
        self: Arc<Self>,
        src_sftp_id: String,
        src_path: String,
        dst_sftp_id: String,
        dst_path: String,
        transfer_id: String,
        sink: Arc<dyn TransferSink>,
        dir: bool,
    ) -> Result<(), CoreError> {
        on_runtime(async move {
            let src = get_endpoint(&self.sftp, &src_sftp_id).await?;
            let dst = get_endpoint(&self.sftp, &dst_sftp_id).await?;
            let events = Events::new(sink, &transfer_id);
            let (src, dst, tid) = (&*src, &*dst, &transfer_id);
            with_transfer(&self.sftp, &transfer_id, |token| async move {
                match dir {
                    false => copy_one(&events, src, &src_path, dst, &dst_path, tid, &token).await,
                    true => copy_tree(&events, src, &src_path, dst, &dst_path, tid, &token).await,
                }
            })
            .await
        })
        .await
        .map_err(CoreError::from)
    }
}
