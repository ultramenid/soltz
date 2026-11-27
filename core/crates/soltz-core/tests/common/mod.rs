// SPDX-License-Identifier: AGPL-3.0-only
#![allow(dead_code)]

pub mod host;
pub mod sftp;

use soltz_core::api::{Core, HostKeyAction, SessionSink};
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Runs `connect` (reporting to `sink`) as a user who trusts every host key shown for the first time.
/// A changed key, whose event lists what is stored, is left to the test.
pub async fn trusting<T: Send + 'static>(
    core: &Arc<Core>,
    sink: &Arc<Recorder>,
    connect: impl Future<Output = T> + Send + 'static,
) -> T {
    let connecting = tokio::spawn(connect);
    let mut seen = 0;
    while !connecting.is_finished() {
        let asked = sink.events("ssh-host-key-conflict");
        for ask in &asked[seen..] {
            if ask["stored_entries"].as_array().is_some_and(Vec::is_empty) {
                let text = |field: &str| ask[field].as_str().unwrap().to_string();
                core.resolve_host_key(
                    text("session_id"),
                    text("new_fingerprint"),
                    HostKeyAction::AddNew,
                )
                .await;
            }
        }
        seen = asked.len();
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    connecting.await.unwrap()
}

/// A sink that keeps everything it is given.
#[derive(Default)]
pub struct Recorder {
    output: Mutex<Vec<u8>>,
    closed: Mutex<Option<bool>>,
    events: Mutex<Vec<(String, String)>>,
}

impl SessionSink for Recorder {
    fn output(&self, data: Vec<u8>) {
        self.output.lock().unwrap().extend(data);
    }
    fn closed(&self, clean_exit: bool) {
        *self.closed.lock().unwrap() = Some(clean_exit);
    }
    fn event(&self, name: String, payload_json: String) {
        self.events.lock().unwrap().push((name, payload_json));
    }
}

impl Recorder {
    pub fn bytes(&self) -> Vec<u8> {
        self.output.lock().unwrap().clone()
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.output.lock().unwrap()).into_owned()
    }
    pub fn closed(&self) -> Option<bool> {
        *self.closed.lock().unwrap()
    }
    pub fn events(&self, name: &str) -> Vec<serde_json::Value> {
        let events = self.events.lock().unwrap();
        events
            .iter()
            .filter(|(n, _)| n == name)
            .map(|(_, payload)| serde_json::from_str(payload).unwrap())
            .collect()
    }
}

pub async fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
