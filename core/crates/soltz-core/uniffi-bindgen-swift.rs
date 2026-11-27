// SPDX-License-Identifier: AGPL-3.0-only
//! `cargo run --features bindgen --bin uniffi-bindgen-swift -- <lib.a> <out> --swift-sources …`
fn main() {
    uniffi::uniffi_bindgen_swift()
}
