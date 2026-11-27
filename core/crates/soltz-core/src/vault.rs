// SPDX-License-Identifier: AGPL-3.0-only
//! The secrets vault: `secrets.enc` in the data directory, opened by upstream's
//! `SecretsStore` (same format), and the key material upstream keeps in the OS
//! keychain, under upstream's bundle keys but Soltz's own service name.
//!
//! Two of upstream's vault modes, as src/services/account.ts sets them up: the
//! keychain holds a random key (`local-nopassword`), or the key is derived from a
//! master password with Argon2id + HKDF (soltz-crypto), salted with a random
//! account id the keychain holds (`local`). Account mode needs a server.

use crate::api::{blocking, Core, Keychain};
use crate::crypto::{derive_keys, hex, random_bytes};
use crate::error::{AppError, ErrorCode};
use crate::keychain_bundle;
use keyring_core::CredentialStore;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};

// The keychain bundle keys and modes upstream writes (account.ts; `master_password`
// is commands/vault_secret.rs' `PLAIN`, which holds the hex key in keychain mode).
const MODE: &str = "mode";
const ACCOUNT_ID: &str = "account_id";
const DEVICE_KEY: &str = "master_password";
const KEYCHAIN_MODE: &str = "local-nopassword";
const PASSWORD_MODE: &str = "local";

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultMode {
    /// The OS keychain holds the vault key: nothing to type.
    Keychain,
    /// The key is derived from a master password, typed to unlock.
    MasterPassword,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultStatus {
    Uninitialised,
    Locked { mode: VaultMode },
    Unlocked { mode: VaultMode },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum VaultError {
    /// Unlock the vault first.
    #[error("Secrets store is locked")]
    Locked,
    /// The master password, or the key in the keychain, does not open `secrets.enc`.
    #[error("{message}")]
    WrongKey { message: String },
    #[error("{message}")]
    Failed { message: String },
}

impl From<AppError> for VaultError {
    fn from(e: AppError) -> Self {
        match e.code() {
            Some(ErrorCode::VaultLocked) => Self::Locked,
            Some(ErrorCode::VaultUnreadable) => Self::WrongKey {
                message: e.to_string(),
            },
            _ => e.to_string().into(),
        }
    }
}

impl From<String> for VaultError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

impl From<&str> for VaultError {
    fn from(message: &str) -> Self {
        message.to_string().into()
    }
}

impl From<keyring_core::Error> for VaultError {
    fn from(e: keyring_core::Error) -> Self {
        format!("Keychain error: {e}").into()
    }
}

/// The keychain item of one data directory's vault: every key in one bundle
/// (upstream keychain_bundle.rs), so an unsigned rebuild prompts once, not per key.
pub(crate) struct VaultKeys {
    store: Arc<CredentialStore>,
    service: String,
}

impl VaultKeys {
    pub(crate) fn new(keychain: Keychain, dir: &Path) -> Result<Self, String> {
        let inner = match keychain {
            Keychain::System => apple_native_keyring_store::keychain::Store::new()
                .map_err(|e| format!("Keychain unavailable: {e}"))?,
            Keychain::Memory => memory_store(dir),
        };
        Ok(Self {
            store: keychain_bundle::Store::new(inner, |service| service.starts_with("soltz")),
            // For tests only: a release build always uses "soltz", whatever its environment says.
            service: match std::env::var("SOLTZ_KEYCHAIN_NS") {
                Ok(ns) if cfg!(debug_assertions) && !ns.is_empty() => format!("soltz-{ns}"),
                _ => "soltz".to_string(),
            },
        })
    }

    /// `Ok(None)` when the key is absent; `Err` when the keychain failed.
    fn read(&self, key: &str) -> keyring_core::Result<Option<String>> {
        match self.store.build(&self.service, key, None)?.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(keyring_core::Error::NoEntry) => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn write(&self, key: &str, value: &str) -> keyring_core::Result<()> {
        self.store
            .build(&self.service, key, None)?
            .set_password(value)
    }

    fn mode(&self) -> Result<Option<VaultMode>, VaultError> {
        Ok(match self.read(MODE)?.as_deref() {
            None => None,
            Some(KEYCHAIN_MODE) => Some(VaultMode::Keychain),
            Some(PASSWORD_MODE) => Some(VaultMode::MasterPassword),
            Some(other) => return Err(format!("Unsupported vault mode {other}").into()),
        })
    }
}

fn memory_store(dir: &Path) -> Arc<CredentialStore> {
    static STORES: LazyLock<Mutex<HashMap<PathBuf, Arc<CredentialStore>>>> =
        LazyLock::new(Default::default);
    let mut stores = STORES.lock().unwrap_or_else(PoisonError::into_inner);
    let store = stores
        .entry(dir.to_path_buf())
        .or_insert_with(|| keyring_core::mock::Store::new().expect("the mock store cannot fail"));
    Arc::clone(store)
}

/// What account.ts' `deriveKeys(password, accountId).enc_key` returns.
fn password_key(password: &str, account_id: &str) -> Result<[u8; 32], VaultError> {
    Ok(derive_keys(password, account_id)?.enc_key)
}

/// account.ts' `hexToBytes` of the stored keychain-mode key.
fn device_key(hex: &str) -> Result<[u8; 32], VaultError> {
    let bytes: Option<Vec<u8>> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect();
    bytes
        .and_then(|b| b.try_into().ok())
        .ok_or_else(|| "The keychain's vault key is not 32 bytes of hex".into())
}

#[uniffi::export]
impl Core {
    /// Whether this data directory has a vault, its mode, and whether it is open.
    pub async fn vault_status(self: Arc<Self>) -> Result<VaultStatus, VaultError> {
        blocking(move || {
            let data = self.data()?;
            Ok(match data.keys.mode()? {
                None => VaultStatus::Uninitialised,
                Some(mode) if data.secrets.is_unlocked() => VaultStatus::Unlocked { mode },
                Some(mode) => VaultStatus::Locked { mode },
            })
        })
        .await
    }

    /// Sets the vault up and leaves it unlocked. With `master_password`, the key is
    /// derived from it (Argon2id, about a second); without, it is random and the
    /// keychain keeps it. Refuses when a vault exists, and when a `secrets.enc` is
    /// there that the keychain has no key for (the file is left untouched).
    pub async fn vault_initialise(
        self: Arc<Self>,
        master_password: Option<String>,
    ) -> Result<(), VaultError> {
        blocking(move || {
            let data = self.data()?;
            if data.keys.mode()?.is_some() {
                return Err("A vault is already set up".into());
            }
            let path = data.secrets_path();
            if path.exists() {
                return Err("secrets.enc exists, but the keychain holds no vault for it".into());
            }
            let account_id = uuid::Uuid::new_v4().to_string();
            let (key, mode) = match master_password {
                Some(password) if password.is_empty() => {
                    return Err("The master password is empty".into())
                }
                Some(password) => (password_key(&password, &account_id)?, PASSWORD_MODE),
                None => {
                    let key: [u8; 32] = random_bytes(32).try_into().expect("32 random bytes");
                    data.keys.write(DEVICE_KEY, &hex(&key))?;
                    (key, KEYCHAIN_MODE)
                }
            };
            data.keys.write(ACCOUNT_ID, &account_id)?;
            // Last: the mode is what makes the vault exist.
            data.keys.write(MODE, mode)?;
            Ok(data.secrets.unlock(path, key, true)?)
        })
        .await
    }

    /// Opens `secrets.enc`: with `master_password` in master-password mode, with
    /// the keychain's key in keychain mode (where `master_password` is ignored).
    pub async fn vault_unlock(
        self: Arc<Self>,
        master_password: Option<String>,
    ) -> Result<(), VaultError> {
        blocking(move || {
            let data = self.data()?;
            let path = data.secrets_path();
            // Certainly absent, not merely unreadable.
            let missing = matches!(path.try_exists(), Ok(false));
            let key = match (data.keys.mode()?, master_password) {
                (None, _) => return Err("No vault is set up".into()),
                // No vault file to open: it starts empty under a fresh key, never under one that was
                // sitting in the keychain before anything was encrypted with it.
                (Some(VaultMode::Keychain), _) if missing => {
                    let key: [u8; 32] = random_bytes(32).try_into().expect("32 random bytes");
                    data.keys.write(DEVICE_KEY, &hex(&key))?;
                    key
                }
                (Some(VaultMode::Keychain), _) => device_key(
                    &data
                        .keys
                        .read(DEVICE_KEY)?
                        .ok_or("The keychain holds no vault key")?,
                )?,
                (Some(VaultMode::MasterPassword), None) => {
                    return Err("This vault needs its master password".into())
                }
                (Some(VaultMode::MasterPassword), Some(password)) => {
                    let account_id = data
                        .keys
                        .read(ACCOUNT_ID)?
                        .ok_or("The keychain holds no account id")?;
                    password_key(&password, &account_id)?
                }
            };
            let keychain = data.keys.mode()? == Some(VaultMode::Keychain);
            Ok(data.secrets.unlock(path, key, keychain && missing)?)
        })
        .await
    }

    /// Drops the key from memory; `secrets.enc` stays as it is.
    pub fn vault_lock(&self) {
        if let Ok(data) = self.data() {
            data.secrets.lock();
        }
    }

    pub fn secret_get(&self, key: String) -> Result<Option<String>, VaultError> {
        Ok(self.data()?.secrets.get(&key)?)
    }

    /// Stamps the key's clock, as upstream does for sync.
    pub fn secret_set(&self, key: String, value: String) -> Result<(), VaultError> {
        Ok(self.data()?.secrets.set(key, value)?)
    }

    /// Leaves a tombstone (a clock without a value), as upstream does for sync.
    pub fn secret_delete(&self, key: String) -> Result<(), VaultError> {
        Ok(self.data()?.secrets.delete(&key)?)
    }
}
