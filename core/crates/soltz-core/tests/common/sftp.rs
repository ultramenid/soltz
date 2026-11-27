// SPDX-License-Identifier: AGPL-3.0-only
//! The smallest SFTP server the file tests need, on russh-sftp's server side.
//! Every path lives under `root`, a temp dir; `..` is refused. `delay` slows each
//! read and write, so a test can act while a transfer is under way.

use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode,
};
use std::collections::HashMap;
use std::fs::{FileTimes, OpenOptions};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

pub struct Fs {
    root: PathBuf,
    delay: Duration,
    open: HashMap<String, Open>,
    next: u64,
}

enum Open {
    File(std::fs::File),
    /// The listing, until `readdir` has handed it out.
    Dir(Option<Vec<File>>),
}

impl Fs {
    pub fn new(root: &Path, delay: Duration) -> Self {
        Self {
            root: root.canonicalize().unwrap(),
            delay,
            open: HashMap::new(),
            next: 0,
        }
    }

    fn path(&self, path: &str) -> Result<PathBuf, StatusCode> {
        let mut out = self.root.clone();
        for c in Path::new(path).components() {
            match c {
                Component::RootDir | Component::CurDir => {}
                Component::Normal(name) => out.push(name),
                _ => return Err(StatusCode::PermissionDenied),
            }
        }
        Ok(out)
    }

    fn handle(&mut self, id: u32, open: Open) -> Handle {
        self.next += 1;
        let handle = self.next.to_string();
        self.open.insert(handle.clone(), open);
        Handle { id, handle }
    }

    fn file(&mut self, handle: &str) -> Result<&mut std::fs::File, StatusCode> {
        match self.open.get_mut(handle) {
            Some(Open::File(f)) => Ok(f),
            _ => Err(StatusCode::Failure),
        }
    }
}

fn code(e: std::io::Error) -> StatusCode {
    match e.kind() {
        ErrorKind::NotFound => StatusCode::NoSuchFile,
        ErrorKind::PermissionDenied => StatusCode::PermissionDenied,
        _ => StatusCode::Failure,
    }
}

fn ok(id: u32) -> Status {
    Status {
        id,
        status_code: StatusCode::Ok,
        error_message: "Ok".into(),
        language_tag: "en-US".into(),
    }
}

fn attrs(meta: std::io::Result<std::fs::Metadata>, id: u32) -> Result<Attrs, StatusCode> {
    Ok(Attrs {
        id,
        attrs: FileAttributes::from(&meta.map_err(code)?),
    })
}

impl russh_sftp::server::Handler for Fs {
    type Error = StatusCode;

    fn unimplemented(&self) -> StatusCode {
        StatusCode::OpUnsupported
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        flags: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, StatusCode> {
        let write = flags.intersects(OpenFlags::WRITE | OpenFlags::APPEND);
        let file = OpenOptions::new()
            .read(flags.contains(OpenFlags::READ) || !write)
            .write(flags.contains(OpenFlags::WRITE))
            .append(flags.contains(OpenFlags::APPEND))
            .create(flags.contains(OpenFlags::CREATE))
            .truncate(flags.contains(OpenFlags::TRUNCATE))
            .create_new(flags.contains(OpenFlags::EXCLUDE))
            .open(self.path(&filename)?)
            .map_err(code)?;
        Ok(self.handle(id, Open::File(file)))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, StatusCode> {
        self.open.remove(&handle).ok_or(StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, StatusCode> {
        tokio::time::sleep(self.delay).await;
        let file = self.file(&handle)?;
        file.seek(SeekFrom::Start(offset)).map_err(code)?;
        let mut data = vec![0; len as usize];
        let n = file.read(&mut data).map_err(code)?;
        if n == 0 {
            return Err(StatusCode::Eof);
        }
        data.truncate(n);
        Ok(Data { id, data })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, StatusCode> {
        tokio::time::sleep(self.delay).await;
        let file = self.file(&handle)?;
        file.seek(SeekFrom::Start(offset)).map_err(code)?;
        file.write_all(&data).map_err(code)?;
        Ok(ok(id))
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        attrs(self.path(&path)?.symlink_metadata(), id)
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        attrs(self.path(&path)?.metadata(), id)
    }

    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, StatusCode> {
        attrs(self.file(&handle)?.metadata(), id)
    }

    async fn setstat(
        &mut self,
        id: u32,
        path: String,
        attrs: FileAttributes,
    ) -> Result<Status, StatusCode> {
        let path = self.path(&path)?;
        if let Some(mode) = attrs.permissions {
            let mode = std::fs::Permissions::from_mode(mode & 0o7777);
            std::fs::set_permissions(&path, mode).map_err(code)?;
        }
        if let (Some(atime), Some(mtime)) = (attrs.atime, attrs.mtime) {
            let at = |secs: u32| UNIX_EPOCH + Duration::from_secs(secs.into());
            let times = FileTimes::new()
                .set_accessed(at(atime))
                .set_modified(at(mtime));
            let file = std::fs::File::open(&path).map_err(code)?;
            file.set_times(times).map_err(code)?;
        }
        Ok(ok(id))
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, StatusCode> {
        let mut files = Vec::new();
        for entry in std::fs::read_dir(self.path(&path)?).map_err(code)? {
            let entry = entry.map_err(code)?;
            let meta = entry.path().symlink_metadata().map_err(code)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            files.push(File::new(name, FileAttributes::from(&meta)));
        }
        Ok(self.handle(id, Open::Dir(Some(files))))
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, StatusCode> {
        match self.open.get_mut(&handle) {
            Some(Open::Dir(listing)) => listing
                .take()
                .map(|files| Name { id, files })
                .ok_or(StatusCode::Eof),
            _ => Err(StatusCode::Failure),
        }
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, StatusCode> {
        std::fs::remove_file(self.path(&filename)?).map_err(code)?;
        Ok(ok(id))
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _: FileAttributes,
    ) -> Result<Status, StatusCode> {
        std::fs::create_dir(self.path(&path)?).map_err(code)?;
        Ok(ok(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, StatusCode> {
        std::fs::remove_dir(self.path(&path)?).map_err(code)?;
        Ok(ok(id))
    }

    /// As OpenSSH's sftp-server: lexically, then through symlinks where the path exists.
    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, StatusCode> {
        let mut parts = Vec::new();
        for part in path.split('/') {
            match part {
                "" | "." => {}
                ".." => drop(parts.pop()),
                name => parts.push(name),
            }
        }
        let mut real = format!("/{}", parts.join("/"));
        if let Ok(canonical) = self.root.join(parts.join("/")).canonicalize() {
            if let Ok(inside) = canonical.strip_prefix(&self.root) {
                real = format!("/{}", inside.to_string_lossy());
            }
        }
        Ok(Name {
            id,
            files: vec![File::dummy(real)],
        })
    }

    /// As OpenSSH's sftp-server (SFTP v3): never over an existing name.
    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, StatusCode> {
        let (from, to) = (self.path(&oldpath)?, self.path(&newpath)?);
        if to.symlink_metadata().is_ok() {
            return Err(StatusCode::Failure);
        }
        std::fs::rename(from, to).map_err(code)?;
        Ok(ok(id))
    }

    async fn readlink(&mut self, id: u32, path: String) -> Result<Name, StatusCode> {
        let target = std::fs::read_link(self.path(&path)?).map_err(code)?;
        Ok(Name {
            id,
            files: vec![File::dummy(target.to_string_lossy())],
        })
    }
}
