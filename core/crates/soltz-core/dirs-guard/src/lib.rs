// SPDX-License-Identifier: AGPL-3.0-only
//! Stands in for the `dirs` crate under soltz-core. The storage and known-hosts
//! modules call `dirs` only for a default folder (storage/config.rs' config dir,
//! the known-hosts legacy migration). Soltz names its data directory itself and
//! must never read, write or delete anywhere else, so every call here panics.

use std::path::PathBuf;

pub fn config_dir() -> Option<PathBuf> {
    refuse("config_dir")
}

pub fn data_dir() -> Option<PathBuf> {
    refuse("data_dir")
}

fn refuse(function: &str) -> ! {
    panic!("soltz-core resolved dirs::{function}(): it only works in its data directory")
}
