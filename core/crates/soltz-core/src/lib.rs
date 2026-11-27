// SPDX-License-Identifier: AGPL-3.0-only
//! Soltz core: local-shell and SSH session code, SFTP file layer, key generation,
//! entity storage and secrets vault, behind a UniFFI API ([`api`], [`entities`],
//! [`vault`], and `Core`'s `sftp*` and key methods).
//! Where the code came from: NOTICE.md.

// The session entry points mirror the app's call shapes.
#![allow(clippy::too_many_arguments)]

uniffi::setup_scaffolding!();

pub mod api;
pub mod entities;
mod keys;
pub mod vault;

// Not every item is used by the facade, hence the allows.
macro_rules! lenient {
    ($($name:ident),* $(,)?) => {$(
        #[allow(dead_code, unused_imports)]
        mod $name;
    )*};
}
lenient!(
    clock,
    crypto,
    error,
    keychain_bundle,
    knock,
    known_hosts,
    local,
    port_forward,
    proxy,
    recent_ids,
    sftp,
    shell_integration,
    ssh,
    terminal_output,
    tls,
);

/// One process-wide runtime, usable from any thread (the PTY reader is a plain thread).
mod async_runtime {
    use std::future::Future;
    use std::sync::LazyLock;
    use tokio::runtime::{Builder, Runtime};
    use tokio::task::JoinHandle;

    // 8 MiB stacks: the russh call chains run deep.
    static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
        Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(8 * 1024 * 1024)
            .build()
            .expect("failed to build tokio runtime")
    });

    pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        RUNTIME.spawn(future)
    }

    pub fn spawn_blocking<F, R>(job: F) -> JoinHandle<R>
    where
        F: FnOnce() -> R + Send + 'static,
        R: Send + 'static,
    {
        RUNTIME.spawn_blocking(job)
    }
}

/// Entity files (config.rs) and the secrets store (secrets.rs).
mod storage;

/// The tombstone and clock helpers every entity shares, key generation and the SFTP layer.
mod commands;

/// What `sftp::backend`'s `dyn FileBackend` reports transfers to.
pub(crate) use commands::files::Events as AppEvents;

// Stand-ins for the few items the modules above name but Soltz never reaches.

/// For `commands::vault_object::refile_into_folder`, which Soltz never calls: team-vault roles need an account server.
mod vault_auth {
    pub fn check_vault_write(_vault_ids: &[String]) -> Result<(), crate::error::AppError> {
        unreachable!("soltz-core has no team vaults")
    }
}

/// For `error`'s SFTP status mapping.
mod device_files {
    pub mod link {
        pub const READ_ONLY_MESSAGE: &str = "device-read-only";
    }
}
