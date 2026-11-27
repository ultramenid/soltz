// SPDX-License-Identifier: AGPL-3.0-only
//! The secrets vault through the public API, with an in-memory keychain: these
//! tests never touch the login keychain.

use soltz_core::api::{Core, Keychain};
use soltz_core::vault::{VaultError, VaultMode, VaultStatus};
use std::path::Path;
use std::sync::Arc;

fn core(dir: &Path) -> Arc<Core> {
    Core::with_data_dir(dir.to_str().unwrap().into(), Keychain::Memory).unwrap()
}

async fn status(core: &Arc<Core>) -> VaultStatus {
    core.clone().vault_status().await.unwrap()
}

#[tokio::test]
async fn keychain_mode_opens_without_a_password_across_launches() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    assert_eq!(status(&core).await, VaultStatus::Uninitialised);
    assert!(matches!(
        core.secret_get("k".into()),
        Err(VaultError::Locked)
    ));

    core.clone().vault_initialise(None).await.unwrap();
    let mode = VaultMode::Keychain;
    assert_eq!(status(&core).await, VaultStatus::Unlocked { mode });
    core.secret_set("password:c1".into(), "pw".into()).unwrap();
    assert_eq!(
        core.secret_get("password:c1".into()).unwrap().as_deref(),
        Some("pw")
    );

    core.vault_lock();
    assert_eq!(status(&core).await, VaultStatus::Locked { mode });
    assert!(matches!(
        core.secret_get("password:c1".into()),
        Err(VaultError::Locked)
    ));
    core.clone().vault_unlock(None).await.unwrap();
    assert_eq!(
        core.secret_get("password:c1".into()).unwrap().as_deref(),
        Some("pw")
    );

    let relaunched = self::core(dir.path());
    assert_eq!(status(&relaunched).await, VaultStatus::Locked { mode });
    relaunched.clone().vault_unlock(None).await.unwrap();
    assert_eq!(
        relaunched
            .secret_get("password:c1".into())
            .unwrap()
            .as_deref(),
        Some("pw")
    );
    assert!(
        relaunched.clone().vault_initialise(None).await.is_err(),
        "set up twice"
    );
}

// The real Argon2id cost (128 MiB, t=3, p=4): soltz-crypto has no test parameters.
#[tokio::test]
async fn master_password_mode_refuses_a_wrong_password_and_keeps_deletions() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    assert!(core
        .clone()
        .vault_initialise(Some(String::new()))
        .await
        .is_err());
    core.clone()
        .vault_initialise(Some("correct horse".into()))
        .await
        .unwrap();
    let mode = VaultMode::MasterPassword;
    assert_eq!(status(&core).await, VaultStatus::Unlocked { mode });
    core.secret_set("password:a".into(), "1".into()).unwrap();
    core.secret_set("password:b".into(), "2".into()).unwrap();
    core.secret_delete("password:b".into()).unwrap();
    core.vault_lock();

    let wrong = core
        .clone()
        .vault_unlock(Some("battery staple".into()))
        .await;
    assert!(
        matches!(wrong, Err(VaultError::WrongKey { .. })),
        "{wrong:?}"
    );
    let none = core.clone().vault_unlock(None).await;
    assert!(matches!(none, Err(VaultError::Failed { .. })), "{none:?}");
    assert_eq!(status(&core).await, VaultStatus::Locked { mode });

    let relaunched = self::core(dir.path());
    relaunched
        .clone()
        .vault_unlock(Some("correct horse".into()))
        .await
        .unwrap();
    assert_eq!(
        relaunched
            .secret_get("password:a".into())
            .unwrap()
            .as_deref(),
        Some("1")
    );
    assert_eq!(relaunched.secret_get("password:b".into()).unwrap(), None);
}

#[tokio::test]
async fn a_secrets_file_the_keychain_has_no_key_for_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = dir.path().join("secrets.enc");
    std::fs::write(&secrets, b"someone else's vault").unwrap();
    let core = core(dir.path());

    assert!(core.clone().vault_initialise(None).await.is_err());
    assert_eq!(std::fs::read(&secrets).unwrap(), b"someone else's vault");
    assert_eq!(status(&core).await, VaultStatus::Uninitialised);
}

#[tokio::test]
async fn a_core_without_a_data_directory_has_no_vault() {
    let core = Core::new();
    assert!(matches!(
        core.clone().vault_status().await,
        Err(VaultError::Failed { .. })
    ));
    core.vault_lock();
}

/// The one test of the login keychain path. Ignored: it writes a throwaway item
/// (service `soltz-test-<pid>`), and a locked login keychain would prompt.
/// Run it by hand: `cargo test --test vault -- --ignored`.
#[tokio::test]
#[ignore = "writes to the login keychain"]
async fn the_login_keychain_round_trips_and_is_cleaned_up() {
    std::env::set_var("SOLTZ_KEYCHAIN_NS", format!("test-{}", std::process::id()));
    let dir = tempfile::tempdir().unwrap();
    let open =
        || Core::with_data_dir(dir.path().to_str().unwrap().into(), Keychain::System).unwrap();
    let core = open();
    core.clone().vault_initialise(None).await.unwrap();
    core.secret_set("k".into(), "v".into()).unwrap();
    let relaunched = open();
    relaunched.clone().vault_unlock(None).await.unwrap();
    let read = relaunched.secret_get("k".into());

    let service = format!("soltz-test-{}", std::process::id());
    let removed = std::process::Command::new("security")
        .args([
            "delete-generic-password",
            "-s",
            &service,
            "-a",
            "__bundle__",
        ])
        .status()
        .unwrap();
    assert_eq!(read.unwrap().as_deref(), Some("v"));
    assert!(removed.success(), "the test item must not stay behind");
}
