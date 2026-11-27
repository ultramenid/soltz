// SPDX-License-Identifier: AGPL-3.0-only
mod common;

use common::{wait_for, Recorder};
use soltz_core::api::Core;
use std::sync::Arc;

/// Whether a row of the rendered terminal reads `line`: the command's output, not
/// the typed command (the user's own shell and prompt draw around both).
fn on_screen(sink: &Recorder, line: &str) -> bool {
    let mut terminal = vt100::Parser::new(24, 80, 0);
    terminal.process(&sink.bytes());
    terminal
        .screen()
        .contents()
        .lines()
        .any(|row| row.trim_end() == line)
}

#[tokio::test]
async fn a_local_shell_runs_what_is_written_and_reports_its_exit() {
    let sink = Arc::new(Recorder::default());
    let shell = Core::new()
        .open_local_shell(sink.clone(), 80, 24)
        .await
        .unwrap();

    shell
        .clone()
        .write(b"echo soltz-ok\n".to_vec())
        .await
        .unwrap();
    wait_for("soltz-ok", || on_screen(&sink, "soltz-ok")).await;

    shell.clone().resize(100, 30).await.unwrap();
    shell.clone().write(b"exit\n".to_vec()).await.unwrap();
    wait_for("the close", || sink.closed().is_some()).await;
    assert_eq!(sink.closed(), Some(true), "`exit` is a clean exit");
    shell.close().await.unwrap();
}
