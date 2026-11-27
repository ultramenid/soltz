// SPDX-License-Identifier: AGPL-3.0-only
//! Entity files and the secrets store. Their functions that resolve
//! a default config folder (`config_dir()` and the per-file helpers built on it) are
//! never called here; Soltz passes its data directory to the path-taking ones.

#[allow(dead_code)]
pub mod config;

#[allow(dead_code)]
pub mod secrets;
