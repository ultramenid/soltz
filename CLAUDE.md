# Soltz

Native macOS 27+ SSH client: terminal and file transfer only. SwiftUI app in `App/`, Rust core in `core/`,
Swift packages in `Packages/`.

## Layout: a sidebar, panes and one strip of tabs

- **Sidebar** (`HomeView`): a tree. Groups are folders of hosts; each host holds its open tabs as a folder holds
  files (`Workspace.sessionRows(of:)`): one row a tab, and a tab of several panes shows its icon as a stack of
  cards (`Theme.stackMost`). Both close and open from their chevron.
- **Main panel**: the panes of the tab on screen (`Workspace.shown` is its host; none shows a hint), and under them
  the one strip of tabs, every host's together. Tabs change places by dragging; a closed tab's neighbour shows.
- **A session shows its terminal or its host's files** (`TerminalSession.showsFiles`, `FilesPane`): Files is a kind of
  tab, not a page. "+" asks which. A files pane is the host only; This Mac's side is Finder (drop in to upload,
  Download, open to edit and save back). The shell is open under a files pane too, unseen: the files use its
  connection. So a files session is not kept in a multiplexer and runs no pre or post command (`forFiles`), and its
  shell exiting by itself reconnects it instead of closing the tab.
- **A session live on a host but not open here is listed under it, dimmed** (`Workspace.liveRows(of:)`, `LiveRow`,
  `liveRow`): another device's, or one this Mac left running. The host itself is asked (`Session.liveSessions`:
  tmux's own list, else GNU screen's) over a connected session of it, after a connect, after a close and when the
  app comes to the front; nothing is synced. A Quick Connect host's are under This Mac, named by `user@host`. A
  click, or Return on the row, joins it in a tab (`Workspace.join`, `forAttaching`): attach only, no pre-command.
  "End Session" in the row's menu ends it without opening it. Every terminal pane is a tmux session of its own;
  a files pane is none.
- **Closing a terminal ends its session on the host**, for every device that has it open
  (`TerminalSession.close`: `endLiveSession` before the core's own close, which would leave a session another
  client is attached to). A dropped one is ended over another connection of that host, if there is one
  (`Workspace.end`); otherwise it stays until its TTL and is listed as live. Quitting closes nothing: the sessions
  are what the next launch reopens.
- **A launch reopens the tabs of last time** (`Workspace.saved`, `reopen`; `workspace.json` in the data folder,
  written when the app is left and when it quits, no secret in it): each pane where it was, a terminal attached to
  the session it was (its tab goes if that has ended), a files pane on its folder, a local shell new. A Quick
  Connect pane is not reopened: its login is in no vault.
- **The device typed on has the session at its own size** (`take_size_command`, `resize-window`): on attaching, on
  a resize, and on the first key after three seconds without one. Other devices on that session mirror it. Check
  such a change against a real tmux: `window-size latest` does nothing for control clients, and tmux prints a tab
  in a format as `_`.
- **A host or a session dragged from the sidebar is new work on that host.** On a pane it opens a new pane on the
  side of it the pointer is nearest (`Workspace.openPane(for:beside:_:)`; the half it would take is lit while
  dragging), so a tab can hold panes of several hosts. On the strip, or on the panel while it is empty, it opens a
  new tab (`Workspace.openTab(for:)`).
- **A tab dragged from the strip is that tab.** On another tab it changes places; on a pane of the tab on screen it
  joins it: its panes move in beside that one and it leaves the strip.
- **A pane dragged by its header is that pane** (`Dragged.Kind.pane`): on a side of another pane it moves beside it,
  on its middle the two change places (`Workspace.swap`), on the strip it becomes a tab of its own.
- **Panes split the same way share the length equally** (`PaneNode.splitting`; dividers of other runs stay where
  they were put), and no split leaves a pane under `Theme.paneLeast`: the new pane opens in a tab of its own
  instead (`Workspace.place`). Under `Theme.paneNarrow` a pane's header keeps Maximize, Float and Close only.
- **A drag held over a tab brings that tab on screen** (`Theme.springLoad`), so the drop can go on to one of its panes.
- **From the keyboard**: ⇧⌘ with an arrow opens a new pane on that side of the active one (the Shell menu; ⌘D and
  ⇧⌘D stay for right and below), and ⇧⌘+ asks what "+" asks (`Workspace.askNewTab`: an AppKit menu over "+", as a
  SwiftUI `Menu` cannot be opened by code). A text field keeps ⇧⌘ with an arrow for its selection (`handleKey`).
- **When a drag does nothing, read what it did**: `log show --last 10m --predicate 'subsystem == "app.soltz"'`
  (`Workspace.drags`: kinds and outcomes, no names).
- **A floated pane** (`Workspace.float`, `floating`, `FloatingPanes`) is out of its tab, in a small card over the
  corner of the main panel whatever tab is on screen, its session live and still listed under its host. Its button,
  or its header dragged onto a pane or the strip, brings it back. **Minimized** (`setMinimized`), the card is a
  capsule in that corner; a click on it, or on its row in the sidebar, brings the card back.

## Design: one glass, everywhere

The sidebar's hosts card is the reference. Every page and popup uses the same two layers and nothing else:

1. **Window** — `WindowBackdrop()` (`App/Sources/Soltz/ContentView.swift`): untinted regular Liquid Glass over the
   desktop. Never tint or darken it per page.
2. **Card** — `.glassEffect(.regular, in: .rect(cornerRadius:, style: .continuous))` on the window glass.
   Popups use `Theme.cardRadius`; the sidebar and the terminal and file panes use `Theme.paneRadius`.

Rules:

- **No painted surfaces.** No fixed colours, gradients, opaque fills or custom materials for backgrounds. Use
  system semantic styles (`.primary`, `.secondary`, `.fill.quaternary`, `Color(nsColor: .controlColor)`). The one
  exception is the scrim behind a popup (`Theme.scrim`, drawn by `SheetCard`): the window steps back so the card
  reads as the thing to answer.
- **No theme system, one appearance.** Settings picks System, Light or Dark (`AppearanceSetting`), applied to the
  whole app in one place (`NSApp.appearance`, set in `ContentView`). Never set a colour scheme or appearance on a
  page, window or view: that is how the sidebar, the terminals and the file panes fell out of step.
- **Popups are sheets with `.glassSheet()`** (`Theme.swift`). Do not give a sheet its own background: glass inside a
  sheet's window renders as a flat grey panel. `SheetCards` makes every SwiftUI sheet clear and the main window draws
  the card under it (`SheetCard`). Alerts and confirmation dialogs stay the system's, but anything that asks for typing is a card
  (`GroupSheet`), not an alert with a text field. The system's grey panel and dimming are hidden as they are
  created (see `SheetCards.init`); hiding them any later flickers. The dimming a popup has is ours: it fades in and
  out with the card.
- **A popup's title is in the card** (`Theme.title`, top left), not a navigation or title bar. No new windows:
  Settings is a card too (`SettingsSheet`).
- **Type and spacing come from `Theme`** (`title`, `body`, `chrome`, `caption`, the card and sheet metrics). Do not
  write font sizes or paddings inline when a `Theme` value exists.
- **Buttons**: `Pill` for capsule buttons; `Pill(prominent: true)` for the one main action (Connect, Done, "+").
- **Drag and drop**: what is dragged shows as a `DragChip` (icon and name; a drag image is a still picture, so it is
  the one surface that is not glass). Where it would land gets the tint outline (`dropOutline`), a tint mark
  between tabs, or, for the half of a pane a new pane would take, the outline over a faint tint (`Theme.dropFill`). Files drag as the system's own rows. What the app itself drags (a host, a session, a tab) carries a
  type of its own (`Dragged`), never text: a terminal pastes dropped text into its shell. And over a pane the
  drop is taken by an AppKit view lying on top of it (`PaneDrop`): AppKit offers a drag to the frontmost view that
  asks for a type it carries and to no other, the file list asks for files, and SwiftUI's drag of anything carries
  a promise of a file. Test a drop with `SystemDrop` (Smoke.swift), a drop the system itself makes; a call into a
  view's dragging methods proves nothing about which view is offered the drag.
- **Motion**: one spring, `Theme.motion` (settles quickly, no bounce), and one entrance, `Theme.arrival` (fade from
  just under size). Pages, panes, cards, tabs and selection use them; no other durations or curves. Never animate
  something that follows the pointer (divider drags). `Theme.motion` is nil under Reduce Motion and in test runs.
- **Form inputs**: a grouped `Form`'s own rows (`TextField("Label", text:, prompt:)`): label left, value typed at
  the right, no box. Never `.roundedBorder`: it paints a black box on the glass.
- **Text boxes** (`TextEditor`): `.scrollContentBackground(.hidden)` plus `.background(.fill.quaternary, in: ...)`.

## Checking a visual change

Always look at real captures, in dark mode, before calling a UI change done:

```sh
SOLTZ_HARNESS=1 sh scripts/bundle-app.sh
build/test.noindex/SoltzTest.app/Contents/MacOS/Soltz --snapshot "$PWD/build/snapshots"   # absolute path
```

Read the `*-live.png` files (window over a colourful stand-in desktop). A new page or popup gets a capture in
`Snapshot.swift`. `new-host-opening.png`, `new-host-closing.png`, `pane-maximizing.png`, `tab-to-files.png`, `drop-to-pane.png`, `pane-floating.png` and `float-minimizing.png` are
frame-by-frame films of a transition: no frame may show a grey panel, the scrim at full strength before its card, or
a jump (that is a flicker on screen). Film a new transition with `film(...)` in `Snapshot.swift`.

## Tests

```sh
sh scripts/test-all.sh                          # every package
(cd core/crates/soltz-core && cargo test)       # Rust core
build/test.noindex/SoltzTest.app/Contents/MacOS/Soltz --smoke  # app, temp data, in-memory keychain
sh scripts/e2e.sh                               # app against a throwaway sshd on 127.0.0.1
```

`--smoke`, `--e2e` and `--snapshot` exist only in `build/test.noindex/SoltzTest.app` (`SOLTZ_HARNESS=1 sh scripts/bundle-app.sh`);
`build/Soltz.app`, the app people run, is built without them (`Harness.swift`).

No Xcode here (Command Line Tools only): `swift test` in `App/` needs
`-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.

Tests never touch real data: not `~/Library/Application Support/Soltz`, the login keychain, `~/.ssh`, or any host
other than 127.0.0.1.

## Signing and icon

`scripts/bundle-app.sh` signs ad hoc, so the Keychain asks for the vault key ("soltz") once after every rebuild;
"Always Allow" lasts until the next one. Only an Apple-issued certificate (Developer ID) stops that: macOS ties a
Keychain item to the build's hash otherwise, and a self-signed certificate was tried and is asked just the same.
The user chose to keep the key in the Keychain and accept the prompt.

The app icon is `App/Icon/AppIcon.icns` (`scripts/make-icon.sh`); the layered `AppIcon.icon` is used only where full
Xcode is installed.

## Updates

`Updates.swift` asks GitHub for the newest release of the repository named in Info.plist's `SoltzUpdateRepo`
("owner/repo", set in `scripts/bundle-app.sh`; empty turns the check off) and compares its tag (`v0.2.0`) with
`CFBundleShortVersionString`. It only tells and links to the download page; nothing is installed by the app. To
release: raise the version in `bundle-app.sh`, publish a GitHub release tagged `v<version>` with the app attached.

The repository is `ultramenid/soltz`. The app is attached as a zip made with `ditto`, which keeps the signature
(`zip` does not), from a clean clone of the tagged commit:

```sh
ditto -c -k --keepParent build/Soltz.app build/Soltz-<version>.zip
gh release create v<version> build/Soltz-<version>.zip --repo ultramenid/soltz --generate-notes
```

## Security rules

These came out of a security audit; keep them when changing the code they cover.

- **Host keys**: an unknown or changed key is always asked about (`verify_or_prompt`, `hostKeyAlert`); nothing pins a
  key silently. Cancel is the default button of every trust question. An answer names the fingerprint it is for.
- **Names from a host** (file names, the working directory from OSC 7) are checked before they reach a path or a shell
  (`is_plain_name` in the core, `Paths.isPlainName` in `TransferQueue`, the control-character filters in `client.rs`,
  `parse_live_sessions` for the session names a host lists).
- **Secrets**: saved logins, env-variable values, notes and pre/post commands live in the vault only
  (`sealingEnv` / `withEnv` in `Storage.swift`; the host's row on disk carries none of them); a connected session of a saved host keeps
  none in `TerminalSession.args` (`currentArgs` reads them again). A key login never carries the password too.
  Nothing secret goes to logs, UserDefaults, or is typed into a remote shell.
- **Clipboard**: a terminal program asks before writing it; reading it is refused (`SoltzTerminalModel.confirm`).
- **Test harnesses** (`--smoke`, `--e2e`, `--snapshot`) are never in `build/Soltz.app`.
- **Channels**: every channel a server tries to open that was not asked for is refused (`refuse` in `client.rs`).
- **Build**: hardened runtime, `--locked` cargo builds, the terminal engine pinned by commit and by the hash of its
  library (`ghostty_sha256` in `scripts/bundle-app.sh`; update it only together with the package pin).
