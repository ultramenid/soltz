// SPDX-License-Identifier: AGPL-3.0-only
//! SSH key generation, by upstream's own commands (commands/keygen.rs).

use crate::api::{failed, on_runtime, Core, CoreError};
use crate::commands::keygen;

/// `generate_ssh_keypair`'s arguments in the JSON upstream's frontend invokes it
/// with (src/services/keys.ts `generateSshKeypair`).
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyGenArgs {
    key_type: String,
    curve: Option<String>,
    bits: Option<u32>,
    passphrase: Option<String>,
    cipher: Option<String>,
    rounds: Option<u32>,
}

#[uniffi::export]
impl Core {
    /// Upstream's `generate_ssh_keypair`. `options_json`, camelCase: `keyType`
    /// (`ed25519`, `ecdsa`, `rsa`) and optionally `curve` (`256`/`384`/`521`, ECDSA),
    /// `bits` (RSA, default 4096), `passphrase` (empty or absent: unencrypted),
    /// `cipher` (`aes256-ctr` default, `aes256-gcm`), `rounds` (bcrypt KDF, default 16).
    /// Returns `{private_key, public_key, key_type_label}` (OpenSSH PEM, OpenSSH
    /// public line, e.g. `ECDSA P-384`).
    pub async fn generate_ssh_keypair(&self, options_json: String) -> Result<String, CoreError> {
        let a: KeyGenArgs = serde_json::from_str(&options_json).map_err(failed)?;
        let pair = on_runtime(keygen::generate_ssh_keypair(
            a.key_type,
            a.curve,
            a.bits,
            a.passphrase,
            a.cipher,
            a.rounds,
        ))
        .await
        .map_err(failed)?;
        serde_json::to_string(&pair).map_err(failed)
    }

    /// Upstream's `ssh_public_key_from_private`: the OpenSSH public line of an
    /// OpenSSH or PuTTY private key. Fails with the message `ENCRYPTED` when the
    /// passphrase is missing or wrong, `INVALID` when it is not a private key.
    pub async fn ssh_public_key_from_private(
        &self,
        private_key: String,
        passphrase: Option<String>,
    ) -> Result<String, CoreError> {
        on_runtime(keygen::ssh_public_key_from_private(private_key, passphrase))
            .await
            .map_err(failed)
    }
}
