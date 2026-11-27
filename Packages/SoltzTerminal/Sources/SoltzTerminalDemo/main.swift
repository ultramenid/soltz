// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzTerminal
import Synchronization
import SwiftUI

/// System chrome only: titled window, glass toolbar, behind-window blur showing through the
/// terminal's transparent background. The terminal is pinned to the safe area so no row hides
/// under the toolbar.
@MainActor func makeWindow(_ model: SoltzTerminalModel, title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.title = title
    window.toolbar = NSToolbar()
    window.isOpaque = false
    window.backgroundColor = .clear
    window.isReleasedWhenClosed = false
    let blur = NSVisualEffectView()
    blur.material = .underWindowBackground
    blur.blendingMode = .behindWindow
    window.contentView = blur
    let host = NSHostingView(rootView: SoltzTerminalView(model))
    host.translatesAutoresizingMaskIntoConstraints = false
    blur.addSubview(host)
    NSLayoutConstraint.activate([
        host.topAnchor.constraint(equalTo: blur.safeAreaLayoutGuide.topAnchor),
        host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
    ])
    return window
}

@MainActor func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

let da1Query = Data("\u{1b}[c".utf8)
func hasDA1Reply(_ data: Data) -> Bool { data.range(of: Data("\u{1b}[?".utf8)) != nil }

// MARK: - Interactive: the user's login shell on a local PTY

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

@MainActor func runInteractive() {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    guard let pty = LocalPTY(path: shell, argv: ["-" + (shell as NSString).lastPathComponent], size: nil) else {
        fatalError("could not start \(shell) on a PTY")
    }
    let model = SoltzTerminalModel(onInput: pty.write, onResize: pty.resize)
    let window = makeWindow(model, title: "Soltz Terminal")
    model.onTitleChange = { window.title = $0 }
    model.onWorkingDirectoryChange = { window.subtitle = $0 }
    pty.startReading(model.feed) { DispatchQueue.main.async { NSApp.terminate(nil) } }
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        pty.terminate()
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    model.focus()
}

// MARK: - --smoke: known bytes in, callbacks and screen text verified, exit 0

final class Recorder: Sendable {
    let input = Mutex(Data())
    let sizes = Mutex([SoltzTerminalSize]())
    var inputText: String { input.withLock { String(decoding: $0, as: UTF8.self) } }
}

@MainActor func runSmoke() async -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !ok { failures += 1 }
    }
    let recorder = Recorder()
    let model = SoltzTerminalModel(
        onInput: { data in recorder.input.withLock { $0.append(data) } },
        onResize: { size in recorder.sizes.withLock { $0.append(size) } }
    )
    var title: String?
    var directories: [String] = []
    model.onTitleChange = { title = $0 }
    model.onWorkingDirectoryChange = { directories.append($0) }

    // Fed before any surface exists: must be buffered until the view attaches.
    model.feed(Data((
        "\u{1b}]2;soltz-smoke\u{07}"
            + "\u{1b}]7;file://remote.example/home/remote\u{07}"
            + "\u{1b}]7;file://localhost/tmp/soltz-smoke\u{07}"
            + "\u{1b}[1;32mSOLTZ-SMOKE-OK\u{1b}[0m\r\n"
    ).utf8))

    let window = makeWindow(model, title: "smoke") // never ordered front
    window.contentView?.layoutSubtreeIfNeeded()
    let resized = await wait(3) { !recorder.sizes.withLock(\.isEmpty) }
    let size = recorder.sizes.withLock(\.last)
    check("surface created, resize callback fired", resized, size.map { "\($0.columns)x\($0.rows) \($0.widthPixels)x\($0.heightPixels)px" } ?? "none")

    model.feed(da1Query)
    check("input bytes out (DA1 reply via onInput)", await wait(2) { recorder.input.withLock { hasDA1Reply($0) } },
          recorder.inputText.debugDescription)
    check("title change (OSC 2)", await wait(2) { title == "soltz-smoke" }, title ?? "none")
    check("working directory (OSC 7, localhost)", await wait(2) { directories.contains { $0.contains("/tmp/soltz-smoke") } },
          directories.description)
    print("[INFO] OSC 7 with a non-local host delivered: \(directories.contains { $0.contains("/home/remote") })")

    var text = ""
    func screenShows(_ marker: String) async -> Bool {
        await wait(2) {
            text = model.readScreenText() ?? ""
            return text.contains(marker)
        }
    }
    model.feed(Data((0 ..< 300).map { "line-\($0)\r\n" }.joined().utf8))
    let read = await screenShows("line-299")
    check("screen + scrollback text readback", read && text.contains("SOLTZ-SMOKE-OK") && text.contains("line-0\n"),
          "\(text.split(separator: "\n").count) lines")

    // Unmount and remount, as a tab switch does: screen and scrollback must survive.
    window.contentView = NSHostingView(rootView: SoltzTerminalView(model))
    window.contentView?.layoutSubtreeIfNeeded()
    check("terminal state survives a SwiftUI remount", await screenShows("SOLTZ-SMOKE-OK") && text.contains("line-299"))

    if let size, let pty = LocalPTY(path: "/bin/sh", argv: ["sh", "-c", "stty size; echo SOLTZ-PTY-OK"], size: size) {
        pty.startReading(model.feed) {}
        let ok = await screenShows("SOLTZ-PTY-OK")
        check("PTY round trip (winsize from resize callback)", ok && text.contains("\(size.rows) \(size.columns)"),
              text.split(separator: "\n").suffix(3).joined(separator: " | "))
        pty.terminate()
    } else {
        check("PTY round trip", false, "no size or spawn failed")
    }

    // Kitty keyboard flags query, then DECRQM for bracketed paste, SGR mouse, synchronized output.
    recorder.input.withLock { $0 = Data() }
    model.feed(Data("\u{1b}[?u\u{1b}[?2004$p\u{1b}[?1006$p\u{1b}[?2026$p".utf8))
    let replies = ["\u{1b}[?0u", "\u{1b}[?2004;2$y", "\u{1b}[?1006;2$y", "\u{1b}[?2026;2$y"]
    let protocols = await wait(2) { replies.allSatisfy(recorder.inputText.contains) }
    check("protocol support (kitty keyboard, 2004, 1006, 2026)", protocols, recorder.inputText.debugDescription)

    // Palette follows the appearance: OSC 11 reports the active default background.
    func reportsBackground(under appearance: NSAppearance.Name, _ rgb: String) async -> Bool {
        window.appearance = NSAppearance(named: appearance)
        for _ in 0 ..< 10 { // the config change reaches the parser asynchronously
            recorder.input.withLock { $0 = Data() }
            model.feed(Data("\u{1b}]11;?\u{07}".utf8))
            if await wait(0.5, until: { recorder.inputText.contains("]11;") }), recorder.inputText.contains(rgb) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    check("light appearance -> light palette (OSC 11)", await reportsBackground(under: .aqua, "rgb:f7f7/f7f7/f7f7"),
          recorder.inputText.debugDescription)
    check("dark appearance -> dark palette (OSC 11)", await reportsBackground(under: .darkAqua, "rgb:2121/2121/2121"),
          recorder.inputText.debugDescription)

    let accepted = model.setFont(family: "Menlo", size: 15, lineHeight: 1.2)
    recorder.input.withLock { $0 = Data() }
    model.feed(da1Query)
    let alive = await wait(2) { recorder.input.withLock { hasDA1Reply($0) } }
    check("font change accepted, terminal alive", accepted && alive)

    window.close()
    return failures == 0 ? 0 : 1
}

// MARK: - --bench [MB]: throughput and main-thread stalls with the window on screen

@MainActor func runBench(megabytes: Int) async -> Int32 {
    let done = Mutex(false)
    let grid = Mutex<SoltzTerminalSize?>(nil)
    let model = SoltzTerminalModel(onInput: { data in
        if hasDA1Reply(data) { done.withLock { $0 = true } }
    }, onResize: { size in grid.withLock { $0 = size } })
    let window = makeWindow(model, title: "bench")
    window.orderFrontRegardless() // visible, so the renderer runs; not activated
    guard await wait(3, until: { model.readScreenText() != nil }) else { print("[FAIL] no surface"); return 1 }

    let chunk = Data(String(repeating: "y\r\n", count: 65536 / 3).utf8)
    let chunks = megabytes * 1_048_576 / chunk.count
    let start = Date()
    let enqueued = Mutex(0.0)
    Thread.detachNewThread {
        for _ in 0 ..< chunks { model.feed(chunk) }
        model.feed(da1Query) // its reply proves every byte before it was parsed
        enqueued.withLock { $0 = Date().timeIntervalSince(start) }
    }
    var maxStall = 0.0
    while !done.withLock(\.self), Date().timeIntervalSince(start) < 60 {
        let tick = Date()
        try? await Task.sleep(for: .milliseconds(5))
        maxStall = max(maxStall, Date().timeIntervalSince(tick) - 0.005)
    }
    let elapsed = Date().timeIntervalSince(start)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let mb = Double(chunks * chunk.count) / 1_048_576
    print(String(format: "[BENCH] %.0f MB in %.2fs = %.0f MB/s; producer enqueued all in %.3fs; max main-thread stall %.0f ms; peak RSS %.0f MB",
                 mb, elapsed, mb / elapsed, enqueued.withLock(\.self), maxStall * 1000, Double(usage.ru_maxrss) / 1_048_576))
    print("[BENCH] window visible: \(window.occlusionState.contains(.visible)), grid: \(grid.withLock(\.self).map { "\($0.columns)x\($0.rows) \($0.widthPixels)x\($0.heightPixels)px" } ?? "none")")
    window.close()
    return done.withLock(\.self) ? 0 : 1
}

// MARK: - Entry

let arguments = CommandLine.arguments
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if arguments.contains("--smoke") || arguments.contains("--bench") {
    app.setActivationPolicy(.accessory)
    Thread.detachNewThread { // watchdog: never leave a hung process behind
        Thread.sleep(forTimeInterval: arguments.contains("--smoke") ? 10 : 90)
        print("[FAIL] watchdog timeout")
        exit(2)
    }
    Task { @MainActor in
        let started = Date()
        let code: Int32 = if arguments.contains("--smoke") {
            await runSmoke()
        } else {
            await runBench(megabytes: arguments.last.flatMap { Int($0) } ?? 50)
        }
        print(String(format: "[DONE] exit %d after %.2fs", code, Date().timeIntervalSince(started)))
        exit(code)
    }
} else {
    app.setActivationPolicy(.regular)
    runInteractive()
}
app.run()
