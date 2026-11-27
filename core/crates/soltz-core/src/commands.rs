// SPDX-License-Identifier: AGPL-3.0-only
//! The entity helpers, key generation and the SFTP layer.

#[allow(dead_code, unused_imports)]
pub mod crdt;
pub mod keygen;
#[allow(dead_code, unused_imports, unused_macros)]
pub mod sftp;

/// The file commands `Core`'s `sftp*` methods run, here so it reaches
/// `commands/sftp`'s `pub(super)` helpers.
pub(crate) mod files;
#[allow(dead_code, unused_imports, unused_macros)]
pub mod vault_object;
