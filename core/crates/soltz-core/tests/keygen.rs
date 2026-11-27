// SPDX-License-Identifier: AGPL-3.0-only
//! Key generation through the API: every key type upstream offers, plain and
//! encrypted, derived back to its public half and used to log in to a loopback
//! host. No assertion message shows private key material.

mod common;

use common::host::{key, serve, USER};
use common::{trusting, Recorder};
use serde_json::{json, Value};
use soltz_core::api::{Core, CoreError};
use std::sync::Arc;

const PASSPHRASE: &str = "correct horse";

/// `(options, expected key_type_label)`; RSA at 2048 only, to keep it fast.
fn kinds() -> Vec<(Value, &'static str)> {
    vec![
        (json!({ "keyType": "ed25519" }), "ED25519"),
        (json!({ "keyType": "ecdsa", "curve": "256" }), "ECDSA P-256"),
        (json!({ "keyType": "ecdsa", "curve": "384" }), "ECDSA P-384"),
        (json!({ "keyType": "ecdsa", "curve": "521" }), "ECDSA P-521"),
        (json!({ "keyType": "rsa", "bits": 2048 }), "RSA 2048"),
    ]
}

fn message(e: CoreError) -> String {
    match e {
        CoreError::Failed { message } | CoreError::Coded { message, .. } => message,
    }
}

#[tokio::test]
async fn every_key_type_derives_back_to_its_public_half_and_logs_in() {
    let host = serve(key(1)).await;
    let core = Core::new();
    for (i, (options, label)) in kinds().into_iter().enumerate() {
        // Alternate the two ciphers the UI offers; few KDF rounds keep the debug build quick.
        let cipher = ["aes256-ctr", "aes256-gcm"][i % 2];
        for passphrase in [None, Some(PASSPHRASE)] {
            let mut options = options.clone();
            if let Some(p) = passphrase {
                options["passphrase"] = json!(p);
                options["cipher"] = json!(cipher);
                options["rounds"] = json!(4);
            }
            let what = format!("{label}, encrypted: {}", passphrase.is_some());
            let pair: Value = serde_json::from_str(
                &core
                    .generate_ssh_keypair(options.to_string())
                    .await
                    .unwrap_or_else(|e| panic!("{what}: {}", message(e))),
            )
            .unwrap();
            assert_eq!(pair["key_type_label"], label, "{what}");
            let private = pair["private_key"].as_str().unwrap().to_string();
            let public = pair["public_key"].as_str().unwrap().to_string();
            assert!(
                private.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"),
                "{what}: not an OpenSSH private key"
            );

            let derived = core
                .ssh_public_key_from_private(private.clone(), passphrase.map(Into::into))
                .await
                .unwrap_or_else(|e| panic!("{what}: {}", message(e)));
            assert_eq!(derived, public, "{what}");

            if passphrase.is_some() {
                for wrong in [None, Some("wrong".to_string())] {
                    let e = core
                        .ssh_public_key_from_private(private.clone(), wrong)
                        .await
                        .expect_err("a wrong passphrase decrypted the key");
                    assert_eq!(message(e), "ENCRYPTED", "{what}");
                }
            }

            let public = russh::keys::PublicKey::from_openssh(&public).unwrap();
            host.seen.lock().unwrap().authorized_keys = vec![public];
            let sink = Arc::new(Recorder::default());
            let connect = core.clone().connect_ssh(
                sink.clone(),
                "127.0.0.1".into(),
                host.port,
                USER.into(),
                None,
                Some(private),
                passphrase.map(Into::into),
                80,
                24,
            );
            let session = trusting(&core, &sink, connect)
                .await
                .unwrap_or_else(|e| panic!("{what}: {}", message(e)));
            session.close().await.unwrap();
        }
    }
}

#[tokio::test]
async fn bad_options_and_non_keys_fail_with_upstreams_messages() {
    let core = Core::new();
    for (options, expected) in [
        (json!({ "keyType": "dsa" }), "Unsupported key type: dsa"),
        (
            json!({ "keyType": "ecdsa", "curve": "123" }),
            "Unknown ECDSA curve: 123",
        ),
    ] {
        let e = core
            .generate_ssh_keypair(options.to_string())
            .await
            .unwrap_err();
        assert_eq!(message(e), expected);
    }
    assert!(core.generate_ssh_keypair("{}".into()).await.is_err());
    let e = core
        .ssh_public_key_from_private("not a key".into(), None)
        .await
        .unwrap_err();
    assert_eq!(message(e), "INVALID");
}
