// SPDX-License-Identifier: AGPL-3.0-only
//! Copies and archives the host makes itself (`cp`, `tar`, `zip`/`unzip`) through its shell, so
//! nothing travels through this machine. Every path reaches a script as an argument, never as text.

use crate::error::AppError;
use crate::sftp::backend::{is_plain_name, FileBackend, TransferEvents};
use crate::ssh::exec::exit_error;

/// Before COPY and COMPRESS: stops when something, a dangling link included, is at `$1`.
const NEW: &str = r#"if [ -e "$1" ] || [ -L "$1" ]; then printf '%s already exists\n' "$1" >&2; exit 1; fi
"#;

/// `$1` the copy, `$2` what is copied: links stay links, modes and times are kept.
const COPY: &str = r#"cp -RPp -- "$2" "$1""#;

/// `$1` the archive, `$2` its kind, `$3` the folder the names after it are in.
// The noclobber line makes the archive without ever writing over one, so removing it after a failure is safe.
// COPYFILE_DISABLE: a Mac's tar adds no `._name` files.
// GNU tar's exit 1 keeps the archive: it ends so when a file changed while it was read (a live log), with
// everything packed; what it said is still shown. Any other tar's exit 1 is a failure like the rest.
const COMPRESS: &str = r#"( set -C; : >"$1" ) || exit
a=$1; k=$2; d=$3; shift 3
case $k in
  zip) cd -- "$d" && zip -qry - "$@" >"$a" </dev/null ;;
  *) COPYFILE_DISABLE=1 tar -c"$k"f "$a" -C "$d" -- "$@" </dev/null ;;
esac || { rc=$?; { [ "$k" != zip ] && [ "$rc" -eq 1 ] && tar --version 2>/dev/null | grep -q GNU; } || rm -f -- "$a"; exit "$rc"; }
"#;

/// `$1` the archive, `$2` its kind, `$3` the folder, there and empty. Neither tool gets `-P`, `-:` or an
/// overwrite flag: both then drop `/` and `..` from a member's name and write through no link they unpacked.
// unzip's exit 1 is a warning with everything unpacked (a `/` it dropped from a name): not a failure.
const EXTRACT: &str = r#"case $2 in
  zip) unzip -qn "$1" -d "$3" </dev/null || [ "$?" -eq 1 ] ;;
  *) tar -x"$2"f "$1" -C "$3" </dev/null ;;
esac
"#;

/// Archive endings (Swift's `Archives.endings`) and tar's flag for each: none for a plain tar, `zip` for zip.
const KINDS: [(&str, &str); 8] = [
    (".tar.gz", "z"),
    (".tgz", "z"),
    (".tar.bz2", "j"),
    (".tbz2", "j"),
    (".tar.xz", "J"),
    (".txz", "J"),
    (".tar", ""),
    (".zip", "zip"),
];

fn kind(archive: &str) -> Result<&'static str, String> {
    let lower = archive.to_lowercase();
    let known = KINDS.iter().find(|(ending, _)| lower.ends_with(ending));
    known
        .map(|(_, kind)| *kind)
        .ok_or_else(|| format!("Not an archive Soltz knows: {archive}"))
}

/// A relative path would be read from wherever the host's shell starts, one starting with `-` as an
/// option, and GNU tar takes `host:file` for a tape on another machine.
fn absolute(path: &str) -> Result<(), String> {
    match path.starts_with('/') {
        true => Ok(()),
        false => Err(format!("Not an absolute path: {path}")),
    }
}

/// The folder `paths` share and their names in it, as `./name`: no name is then an option (`-x`) or,
/// to bsdtar, an archive to include (`@x`).
fn members(paths: &[String]) -> Result<(&str, Vec<String>), String> {
    let mut parent = None;
    let mut names = Vec::new();
    for path in paths {
        absolute(path)?;
        let (dir, name) = path.rsplit_once('/').unwrap_or_default();
        if !is_plain_name(name, false) {
            return Err(format!("Not a file or folder name: {path}"));
        }
        if *parent.get_or_insert(dir) != dir {
            return Err("Only items of one folder go in one archive".into());
        }
        names.push(format!("./{name}"));
    }
    let parent = parent.ok_or("Nothing to compress")?;
    Ok((if parent.is_empty() { "/" } else { parent }, names))
}

/// Exit 127 is the shell not finding `tool`.
async fn run<E, B>(
    backend: &B,
    label: &str,
    tool: &str,
    script: &str,
    args: &[&str],
) -> Result<(), AppError>
where
    E: TransferEvents,
    B: FileBackend<E> + ?Sized,
{
    let out = backend.run_sh(script, args).await?;
    if out.code == Some(127) {
        return Err(format!("{label}: {tool} is not installed on the host").into());
    }
    Ok(exit_error(label, out.code, &out.stderr)?)
}

/// A copy of `from`, a file or a folder with everything in it, at `to`; fails when something is there.
pub async fn copy<E, B>(backend: &B, from: &str, to: &str) -> Result<(), AppError>
where
    E: TransferEvents,
    B: FileBackend<E> + ?Sized,
{
    absolute(from)?;
    absolute(to)?;
    run(
        backend,
        "Copy failed",
        "cp",
        &[NEW, COPY].concat(),
        &[to, from],
    )
    .await
}

/// Packs `paths`, items of one folder, by their names into a new `archive`; fails when something is there.
pub async fn compress<E, B>(backend: &B, paths: &[String], archive: &str) -> Result<(), AppError>
where
    E: TransferEvents,
    B: FileBackend<E> + ?Sized,
{
    absolute(archive)?;
    let kind = kind(archive)?;
    let (parent, names) = members(paths)?;
    let mut args = vec![archive, kind, parent];
    args.extend(names.iter().map(String::as_str));
    let tool = if kind == "zip" { "zip" } else { "tar" };
    run(
        backend,
        "Compress failed",
        tool,
        &[NEW, COMPRESS].concat(),
        &args,
    )
    .await
}

/// Unpacks `archive` into the folder `dir`, which the caller made empty.
pub async fn extract<E, B>(backend: &B, archive: &str, dir: &str) -> Result<(), AppError>
where
    E: TransferEvents,
    B: FileBackend<E> + ?Sized,
{
    absolute(archive)?;
    absolute(dir)?;
    let kind = kind(archive)?;
    // shortcut: unzip reads these in the archive's own name as a pattern and could open the zip beside
    // it; hand it the archive on stdin (`unzip /dev/stdin`) once that is known to work on the hosts met.
    if kind == "zip" && archive.contains(['*', '?', '[', '\\']) {
        return Err(format!(
            "Rename the archive first, unzip cannot open a name with * ? [ or \\ in it: {archive}"
        )
        .into());
    }
    let tool = if kind == "zip" { "unzip" } else { "tar" };
    run(
        backend,
        "Extract failed",
        tool,
        EXTRACT,
        &[archive, kind, dir],
    )
    .await
}
