// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Darwin
import Foundation
import SoltzCore
import SoltzFilesUI
import SoltzKeychainUI
import SoltzHostsUI
import SoltzModel

// Test harness: compiled only into SoltzTest.app (SOLTZ_HARNESS, scripts/bundle-app.sh). See Harness.swift.
#if SOLTZ_HARNESS

/// `--e2e`: what `--smoke` cannot reach, against a real SSH server. scripts/e2e.sh starts a throwaway sshd on
/// 127.0.0.1 and passes it in `SOLTZ_E2E_*`; this drives the window, storage, terminal and files
/// code paths the UI uses against it and prints one `[PASS]`/`[FAIL]`/`[INFO]` line per check, exiting 0 or 1.
/// Every file it touches lies in the run's temp directory, which the script deletes.
@MainActor
enum E2E {
    static let requested = CommandLine.arguments.contains("--e2e")
    static let env = ProcessInfo.processInfo.environment
    /// Inside the run's temp directory, with the in-memory keychain.
    static let dataDir = URL(filePath: env["SOLTZ_E2E_TMP"] ?? NSTemporaryDirectory()).appending(path: "data")

    nonisolated static func startWatchdog() {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 300)
            print("[FAIL] watchdog: e2e run did not finish within 300 s")
            exit(1)
        }
    }

    /// The server and paths scripts/e2e.sh hands over.
    struct Server {
        let port: Int64, user: String, key: String, wrongKey: String, work: String, local: String
        let hostFP: String, host2FP: String, ctl: String, tmp: String

        init?(_ env: [String: String]) {
            guard let port = env["SOLTZ_E2E_PORT"].flatMap(Int64.init), let user = env["SOLTZ_E2E_USER"],
                  let key = env["SOLTZ_E2E_KEY"], let wrongKey = env["SOLTZ_E2E_WRONG_KEY"], let work = env["SOLTZ_E2E_WORK"],
                  let local = env["SOLTZ_E2E_LOCAL"], let hostFP = env["SOLTZ_E2E_HOST_FP"],
                  let host2FP = env["SOLTZ_E2E_HOST2_FP"], let ctl = env["SOLTZ_E2E_CTL"], let tmp = env["SOLTZ_E2E_TMP"]
            else { return nil }
            (self.port, self.user, self.key, self.wrongKey, self.work, self.local) = (port, user, key, wrongKey, work, local)
            (self.hostFP, self.host2FP, self.ctl, self.tmp) = (hostFP, host2FP, ctl, tmp)
        }

        /// `e2e.sh ctl <command>`'s output.
        func ctl(_ command: String) async -> String {
            let (script, tmp) = (ctl, tmp)
            return await Task.detached {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(filePath: "/bin/sh")
                process.arguments = [script, "ctl", command]
                process.environment = ["SOLTZ_E2E_TMP": tmp, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                process.standardOutput = pipe
                guard (try? process.run()) != nil else { return "" }
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        }
    }

    typealias Check = (String, Bool, String) -> Void

    static func run(_ workspace: Workspace) async -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }
        func finish() -> Never {
            workspace.closeAll()
            Thread.sleep(forTimeInterval: 0.5) // lets the closes reach the core before exit
            try? FileManager.default.removeItem(at: dataDir)
            exit(failures == 0 ? 0 : 1)
        }
        guard let server = Server(env) else {
            check("SOLTZ_E2E_* environment from scripts/e2e.sh", false, "run it through scripts/e2e.sh")
            finish()
        }
        check("main window open", NSApp.windows.contains(where: \.isVisible))

        guard let host = await savedHost(workspace, server, check), let primary = await firstConnect(workspace, server, host, check) else {
            finish()
        }
        await terminal(workspace, server, primary, host, check)
        await backAndForth(workspace, primary, host, check)
        await files(workspace, server, primary, check)
        await reconnect(workspace, server, primary, check)
        await persistence(workspace, server, primary, host, check)
        await authFailures(workspace, server, check)
        await cancel(workspace, server, check)
        await changedHostKey(workspace, server, host, check)
        await remoteExit(workspace, workspace.connections.first { $0.id == host.id } ?? host, check)
        print("[INFO] not reachable from one loopback sshd: jump hosts, proxies, port knocking, agent forwarding, legacy algorithms")
        finish()
    }

    // MARK: - a. Saved key and host, first connect

    /// The temp client key saved as the keychain editor saves a key, and a host using it as the host editor saves one.
    /// Persistent sessions are off for it: see `persistence`, which covers that option on its own.
    private static func savedHost(_ workspace: Workspace, _ server: Server, _ check: Check) async -> Connection? {
        let error = { workspace.failure?.message ?? "" }
        let keyID = newID(), hostID = newID()
        guard let privateKey = try? String(contentsOfFile: server.key, encoding: .utf8),
              let publicKey = try? String(contentsOfFile: server.key + ".pub", encoding: .utf8),
              let key = try? SshKey(json: row(["id": .string(keyID), "name": "E2E key", "key_type": "ED25519"])),
              await workspace.perform("save key", {
                  try await workspace.save(key, KeySecrets(privateKey: privateKey, publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)))
              }),
              let host = try? Connection(json: row([
                  "id": .string(hostID), "name": "E2E loopback", "host": "127.0.0.1", "port": .int(server.port),
                  "username": .string(server.user), "tags": [], "auth_type": "key", "key_id": .string(keyID),
                  "persist_session": false, "pre_command": "printf 'E2E-PRE:%s\\n' ok",
              ])),
              await workspace.perform("save host", { try await workspace.save(host, HostSecrets()) }),
              let saved = workspace.connections.first(where: { $0.id == hostID })
        else {
            check("SSH key and host saved through the keychain and host editors' storage calls", false, error())
            return nil
        }
        let login = try? workspace.login(for: saved)
        check("SSH key and host saved through the keychain and host editors' storage calls; the host's login is the key",
              workspace.keys.contains { $0.id == keyID } && login?.privateKey == privateKey && login?.password == nil
                  && login?.username == server.user,
              "private key \(privateKey.count) bytes")
        return saved
    }

    /// The host list's double-click (`connect(to:)`), the host key trusted on first use in the app's own store.
    private static func firstConnect(_ workspace: Workspace, _ server: Server, _ host: Connection, _ check: Check) async -> TerminalSession? {
        let none = (try? await workspace.core.entityList(kind: .knownHosts)) == "[]"
        // Home's Open on the host's row.
        let onHome = workspace.shown == nil && workspace.homeGroups().flatMap(\.rows).contains { $0.id == host.id && $0.detail == "127.0.0.1:\(server.port)" }
        workspace.open(host.id)
        guard let session = workspace.activeSession, session.hostID == host.id else {
            check("saved host connects in a new tab", false, workspace.failure?.message ?? "Open opened nothing")
            return nil
        }
        check("Home lists the saved host; its Open enters the host's workspace, connecting there in a new tab",
              onHome && workspace.shown == host.id && workspace.tabs.count == 1, "")
        // A host never connected to: its key is asked about, with its fingerprint, before anything is sent.
        let fp = server.hostFP.replacingOccurrences(of: "SHA256:", with: "")
        let known = { (try? String(contentsOf: dataDir.appending(path: "known_hosts.json"), encoding: .utf8)) ?? "" }
        let asked = await wait(30) { session.conflict != nil || session.ended }
        let question = session.conflict
        let alert = await wait(5) { NSApp.windows.contains { $0.attachedSheet != nil } }
        // Return is the alert's Cancel: its default button is the one that refuses.
        let panel = NSApp.windows.compactMap(\.attachedSheet).first
        let buttons = (panel?.contentView).map(Self.buttons) ?? []
        let defaults = buttons.filter { $0.keyEquivalent == "\r" }.map(\.title)
        check("first connection to a host: its key is asked about (Trust This Host?, the server's fingerprint, nothing stored yet, not attached), Cancel the default button",
              none && asked && question?.isFirstSight == true && question?.newFingerprint?.contains(fp) == true && alert
                  && !session.isAttached && !known().contains(fp) && defaults == ["Cancel"],
              "\(question?.newFingerprint ?? "no question"), alert \(alert), buttons \(buttons.map(\.title)), default \(defaults)")
        session.answer(.addNew, via: workspace.core) // the alert's Trust
        let attached = await wait(30) { session.isAttached || session.ended }
        let args = session.args ?? [:]
        check("saved host connects in a new tab by the saved-host path: sshConnect with upstream's 27-key argument object; once connected the session keeps no key or password",
              attached && session.isAttached && args.count == 27 && args["privateKey"] == .null && args["password"] == .null
                  && args["connectionId"]?.string == host.id && args["persist"] == false && args["shellIntegration"] == true,
              session.isAttached ? "session \(session.coreID ?? "?")" : workspace.failure?.message ?? "step \(session.step ?? "none")")
        guard session.isAttached else { return nil }
        let recorded = await wait(10) { known().contains(fp) }
        check("trusted, the host key is recorded in the app's known_hosts.json (temp data dir)", recorded, "")
        return session
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    // MARK: - b. Terminal

    private static func terminal(_ workspace: Workspace, _ server: Server, _ primary: TerminalSession, _ host: Connection,
                                 _ check: Check) async {
        let work = server.work
        let shown = await ready(primary)
        check("the host's inline pre-command runs after connecting (upstream's preCommand, typed by the core)",
              primary.screenLines.contains("E2E-PRE:ok"), tail(primary))
        let echoed = await output(primary, #"printf 'E2E-ECHO:%s\n' "$((6*7))""#, "E2E-ECHO:")
        check("a command's output appears on the libghostty screen", shown && echoed == "42", "\(echoed ?? "nothing") — " + tail(primary))

        let full = primary.size
        let sizeAtStart = await output(primary, #"printf 'E2E-SIZE:%s\n' "$(stty size)""#, "E2E-SIZE:")
        check("terminal size reaches the remote: stty size = the pane's grid", full != nil && sizeAtStart == full.map { "\($0.rows) \($0.cols)" },
              "pane \(full.map { "\($0.rows)x\($0.cols)" } ?? "?"), remote \(sizeAtStart ?? "nothing")")

        let pwd = await output(primary, "cd '\(work)' && printf 'E2E-PWD:%s\\n' \"$PWD\"", "E2E-PWD:")
        check("ssh-cwd follows a cd into the work dir (it needs upstream's shell integration, on by default: its wrapper hooks zsh to emit OSC 7)",
              await wait(6) { primary.cwd == work } && pwd == work, "cwd \(primary.cwd ?? "none")")

        let odd = server.local + "/sp ace ünï"
        try? FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        let oddPwd = await output(primary, "cd '\(odd)' && printf 'E2E-PWD:%s\\n' \"$PWD\"", "E2E-PWD:")
        check("ssh-cwd decodes a directory with a space and non-ASCII letters (percent-encoded in OSC 7)",
              await wait(6) { primary.cwd == odd } && oddPwd == odd, "cwd \(primary.cwd ?? "none")")
        _ = await output(primary, "cd '\(work)' && printf 'E2E-PWD:%s\\n' \"$PWD\"", "E2E-PWD:")
        _ = await wait(6) { primary.cwd == work }

        // Split Right halves the pane (a resize), closing the new pane restores it; `stty size` on the host follows each.
        workspace.split(.right)
        guard let duplicate = workspace.activeSession, duplicate !== primary else {
            return check("Split Right in an SSH pane duplicates the session", false, "")
        }
        let dupReady = await wait(30) { duplicate.isAttached || duplicate.ended }
        _ = await ready(duplicate)
        let dupPwd = await output(duplicate, #"printf 'E2E-PWD:%s\n' "$PWD""#, "E2E-PWD:")
        check("Split Right in an SSH pane is upstream's duplicate-in-split: a second connection to the host, its own session id, its shell in the pane's directory",
              dupReady && duplicate.isAttached && duplicate.coreID != primary.coreID && duplicate.args?["connectionId"]?.string == host.id
                  && duplicate.args?["initialCwd"]?.string == work && dupPwd == work && workspace.layout.root?.leaves.count == 2,
              duplicate.isAttached ? "shell in \(dupPwd ?? "?")" : workspace.failure?.message ?? "not attached")
        let narrowed = await wait(5) { (primary.size?.cols ?? 0) < (full?.cols ?? 0) }
        let half = primary.size
        let sizeNarrow = await output(primary, #"printf 'E2E-SIZE:%s\n' "$(stty size)""#, "E2E-SIZE:")
        check("resize reaches the remote: after the split the original pane is narrower and stty size follows it",
              narrowed && sizeNarrow == half.map { "\($0.rows) \($0.cols)" },
              "pane \(half.map { "\($0.rows)x\($0.cols)" } ?? "?"), remote \(sizeNarrow ?? "nothing")")

        workspace.closePane() // the duplicate, the active pane
        let widened = await wait(5) { primary.size?.cols == full?.cols }
        let sizeBack = await output(primary, #"printf 'E2E-SIZE:%s\n' "$(stty size)""#, "E2E-SIZE:")
        check("closing the duplicate pane: the original is full width again and stty size follows",
              widened && sizeBack == full.map { "\($0.rows) \($0.cols)" } && workspace.sessions[duplicate.id] == nil,
              "remote \(sizeBack ?? "nothing")")
    }

    // MARK: - Away and back

    /// Leaving a workspace leaves its session running; the host's row then returns to it instead of connecting again.
    private static func backAndForth(_ workspace: Workspace, _ primary: TerminalSession, _ host: Connection, _ check: Check) async {
        let sessions = workspace.sessions.count
        workspace.show(nil)
        let home = workspace.shown == nil && workspace.liveState(host.id) == true
        let alive = await output(primary, #"printf 'E2E-HOME:%s\n' alive"#, "E2E-HOME:") == "alive"
        workspace.open(host.id)
        check("leaving the workspace keeps the session alive (it still runs commands); the host's row shows it live and returns to its workspace, no new connection",
              home && alive && workspace.shown == host.id && workspace.activeSession === primary && workspace.sessions.count == sessions
                  && primary.reconnectAttempts == 0, "")
    }

    // MARK: - i. Files

    private static func files(_ workspace: Workspace, _ server: Server, _ primary: TerminalSession, _ check: Check) async {
        let fm = FileManager.default
        let work = server.work, local = server.local
        let src = local + "/src", down = local + "/down"
        func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        do {
            try put(work + "/readme.txt", Data("remote side".utf8))
            try put(src + "/hello.txt", Data("hello".utf8))
            try put(src + "/tree/sub/deep.txt", Data("deep".utf8))
            try put(src + "/tree/sp ace/ünï cödé.txt", Data("spaced".utf8))
            try put(src + "/tree/data.bin", Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
            try fm.createDirectory(atPath: down, withIntermediateDirectories: true)
        } catch {
            return check("Files: temp folders set up", false, "\(error)")
        }

        // The session's files: a new tab on its host, on the directory its terminal is in (else its SFTP home: the
        // work directory, sshd's `-d`).
        let tabsBefore = workspace.tabs.count
        workspace.showFiles(for: primary)
        let pane = workspace.activeSession
        let opened = pane !== primary && pane?.showsFiles == true && pane?.hostID == primary.hostID && workspace.tabs.count == tabsBefore + 1
        guard let sftp = workspace.fileProvider(for: primary.id) as? SftpFileProvider else {
            return check("Files: a session's files are its SFTP provider's", false, "")
        }
        let home = try? await sftp.home()
        let listed = (try? await sftp.list(work))?.map(\.name).sorted() ?? []
        check("a session's files open in a new tab on its host, a second connection (SFTP home = the work dir), the work dir listed by the provider",
              opened && home.map(resolved) == resolved(work) && listed == ["readme.txt"],
              "home \(home ?? "?"), \(listed), tabs \(workspace.tabs.count)")
        check("the files tab's pane on screen, once connected: the host's work dir (1 item)",
              await wait(15) { pane?.isAttached == true && tables().contains { $0.numberOfRows == 1 } },
              tables().map { "\($0.numberOfRows) rows" }.joined(separator: ", "))
        if let tab = workspace.layout.activeSplitTabId, pane !== primary { workspace.closeTab(tab) }
        workspace.reveal(primary.id)

        let queue = workspace.transfers, localFiles = workspace.localFiles
        let up = work + "/up"
        guard (try? await sftp.mkdir(up)) != nil, let items = try? await localFiles.list(src),
              let hello = items.first(where: { $0.name == "hello.txt" }), let tree = items.first(where: { $0.name == "tree" })
        else { return check("Files: mkdir on the host and the local folder listed", false, "") }
        func rows(_ labels: String...) -> [TransferQueue.Transfer] { queue.transfers.filter { labels.contains($0.label) } }
        let made: Void? = try? await sftp.createFile(work + "/new.txt")
        check("Files: New File makes an empty file on the host", made != nil && fm.contents(atPath: work + "/new.txt") == Data(), "")
        try? fm.removeItem(atPath: work + "/new.txt") // the pane's row count below is of the work dir as it was
        queue.enqueue([hello, tree], from: localFiles, to: sftp, into: up)
        let uploaded = await wait(30) { queue.transfers.count == 2 && queue.transfers.allSatisfy(\.settled) }
        check("upload a file and a folder tree through the queue: rows done with progress events, contents equal on the host",
              uploaded && queue.transfers.allSatisfy { $0.status == .done && $0.total > 0 && $0.transferred == $0.total }
                  && fm.contentsEqual(atPath: src + "/hello.txt", andPath: up + "/hello.txt")
                  && fm.contentsEqual(atPath: src + "/tree", andPath: up + "/tree"),
              queue.transfers.map { "\($0.label) \($0.status) \($0.transferred)/\($0.total)" }.joined(separator: ", "))

        let remote = (try? await sftp.list(up)) ?? []
        queue.clearCompleted()
        queue.enqueue(remote, from: sftp, to: localFiles, into: down)
        let downloaded = await wait(30) { queue.transfers.count == 2 && queue.transfers.allSatisfy(\.settled) }
        check("download them back to another folder: rows done with progress events, contents equal to the originals",
              downloaded && remote.count == 2 && queue.transfers.allSatisfy { $0.status == .done && $0.total > 0 && $0.transferred == $0.total }
                  && fm.contentsEqual(atPath: src + "/hello.txt", andPath: down + "/hello.txt")
                  && fm.contentsEqual(atPath: src + "/tree", andPath: down + "/tree"),
              queue.transfers.map { "\($0.label) \($0.status) \($0.transferred)/\($0.total)" }.joined(separator: ", "))

        queue.clearCompleted()
        try? Data("hello v2".utf8).write(to: URL(filePath: src + "/hello.txt"))
        queue.enqueue([hello], from: localFiles, to: sftp, into: up)
        let asked = await wait(10) { queue.conflicts.count == 1 }
        if let pending = queue.conflicts.first { queue.resolveConflict(pending.id, .skip) }
        let skipped = await wait(10) { queue.conflicts.isEmpty && queue.transfers.isEmpty }
        check("uploading onto an existing remote file asks; Skip leaves it and drops the row",
              asked && skipped && text(up + "/hello.txt") == "hello",
              text(up + "/hello.txt") ?? "missing")
        queue.enqueue([hello], from: localFiles, to: sftp, into: up)
        _ = await wait(10) { queue.conflicts.count == 1 }
        if let pending = queue.conflicts.first { queue.resolveConflict(pending.id, .overwrite) }
        check("Replace uploads over it: row done, new content on the host",
              await wait(10) { queue.transfers.first?.settled == true } && queue.transfers.first?.status == .done
                  && text(up + "/hello.txt") == "hello v2",
              "\(queue.transfers.first.map { "\($0.status)" } ?? "no row"), \(text(up + "/hello.txt") ?? "missing")")
        queue.clearCompleted()

        // The "editor" saves the copy as soon as it is handed it.
        if let item = (try? await sftp.list(up))?.first(where: { $0.name == "hello.txt" }) {
            queue.edit(item, on: sftp) { try? Data("hello v3".utf8).write(to: $0, options: .atomic) }
        }
        let saved = await wait(15) { text(up + "/hello.txt") == "hello v3" && queue.transfers.allSatisfy(\.settled) }
        check("Edit on This Mac: the host's file opens as a copy here, and saving the copy puts it back without asking",
              saved && queue.conflicts.isEmpty && queue.transfers.count == 2 && queue.transfers.allSatisfy { $0.status == .done },
              "\(queue.transfers.map { "\($0.route) \($0.status)" }.joined(separator: ", ")), \(text(up + "/hello.txt") ?? "missing")")
        queue.clearCompleted()

        let edited = "édité\nline 2\n"
        let wrote = (try? await sftp.write(up + "/edit.txt", Data(edited.utf8))) != nil
        let readBack = (try? await sftp.read(up + "/edit.txt", maxBytes: 1 << 20)).map { String(decoding: $0, as: UTF8.self) }
        try? fm.createSymbolicLink(atPath: up + "/link", withDestinationPath: "renamed.txt")
        let link = (try? await sftp.list(up))?.first { $0.name == "link" }
        check("the editor's write and read on the host (sftp_write_file / sftp_read_file), and a symlink listed as one",
              wrote && readBack == edited && text(up + "/edit.txt") == edited && link?.isSymlink == true,
              "read \(readBack.map { "\($0.count) chars" } ?? "failed"), link \(link.map { "symlink \($0.isSymlink)" } ?? "missing")")
        try? fm.removeItem(atPath: up + "/link")
        try? fm.removeItem(atPath: up + "/edit.txt")

        let renamed = (try? await sftp.rename(up + "/hello.txt", to: up + "/renamed.txt")) != nil
        let chmod = (try? await sftp.changeMode([up + "/renamed.txt"], set: 0o640, clear: 0o7777)) != nil
        let mode = (try? fm.attributesOfItem(atPath: up + "/renamed.txt"))?[.posixPermissions] as? Int
        let deleted = (try? await sftp.delete(up + "/tree")) != nil
        let after = (try? await sftp.list(up))?.map(\.name) ?? []
        check("rename, chmod 640 and delete (a folder tree) on the host through the pane's provider",
              renamed && chmod && deleted && mode == 0o640 && after == ["renamed.txt"] && !fm.fileExists(atPath: up + "/tree")
                  && text(up + "/renamed.txt") == "hello v3",
              "mode \(mode.map { String($0, radix: 8) } ?? "?"), left \(after)")

        // The host's own copy, archive and whole-tree changes, all inside one folder that goes again.
        let ops = up + "/ops"
        func failure(_ run: () async throws -> Void) async -> String? {
            do { try await run(); return nil } catch { return error.localizedDescription }
        }
        func modes(_ paths: String...) -> [Int?] { paths.map { (try? fm.attributesOfItem(atPath: ops + $0))?[.posixPermissions] as? Int } }
        do {
            try put(ops + "/tree/sub/deep.txt", Data("deep".utf8))
            try put(ops + "/-dash.txt", Data("dash".utf8))
        } catch {
            return check("Files: folder for the host's own copies set up", false, "\(error)")
        }
        let copied = await failure {
            try await sftp.copy(ops + "/-dash.txt", to: ops + "/dash copy.txt")
            try await sftp.copy(ops + "/tree", to: ops + "/tree copy")
        }
        try? put(ops + "/-dash.txt", Data("changed".utf8))
        let overFile = await failure { try await sftp.copy(ops + "/-dash.txt", to: ops + "/dash copy.txt") }
        let overFolder = await failure { try await sftp.copy(ops + "/-dash.txt", to: ops + "/tree copy") }
        check("Duplicate on the host: a file and a folder tree copied there; a copy onto what is there is refused and changes nothing",
              copied == nil && text(ops + "/dash copy.txt") == "dash" && fm.contentsEqual(atPath: ops + "/tree", andPath: ops + "/tree copy")
                  && overFile?.hasSuffix("already exists") == true && overFolder?.hasSuffix("already exists") == true
                  && text(ops + "/dash copy.txt") == "dash" && !fm.fileExists(atPath: ops + "/tree copy/-dash.txt"),
              "\(copied ?? "copied"); over a file: \(overFile ?? "no error"); over a folder: \(overFolder ?? "no error")")

        let pack = ops + "/pack" + Archives.made
        let packed = await failure { try await sftp.compress([ops + "/tree", ops + "/-dash.txt"], to: pack) }
        let archived = fm.contents(atPath: pack)
        let packedAgain = await failure { try await sftp.compress([ops + "/tree copy"], to: pack) }
        let unpacked = await failure {
            try await sftp.mkdir(ops + "/out")
            try await sftp.extract(pack, into: ops + "/out")
        }
        let out = ((try? fm.contentsOfDirectory(atPath: ops + "/out")) ?? []).sorted()
        check("Compress and Extract on the host: items stored by their names and unpacked equal; an archive that is there is left as it is",
              packed == nil && archived?.isEmpty == false && packedAgain?.hasSuffix("already exists") == true && fm.contents(atPath: pack) == archived
                  && unpacked == nil && out == ["-dash.txt", "tree"] && fm.contentsEqual(atPath: ops + "/tree", andPath: ops + "/out/tree")
                  && text(ops + "/out/-dash.txt") == "changed",
              "\(packed ?? "packed"); again: \(packedAgain ?? "no error"); \(unpacked ?? "unpacked") \(out)")

        // Its own user and group: the only ones this user may give.
        let group = getgrgid(getgid()).map { String(cString: $0.pointee.gr_name) }
        let changed = await failure {
            try await sftp.changeMode([ops + "/tree"], set: 0o750, clear: 0o7777, owner: NSUserName(), group: group, recursive: true)
        }
        let inside = modes("/tree", "/tree/sub", "/tree/sub/deep.txt"), beside = modes("/tree copy/sub/deep.txt")
        let owners = (try? fm.attributesOfItem(atPath: ops + "/tree/sub/deep.txt")).map { [$0[.ownerAccountName] as? String, $0[.groupOwnerAccountName] as? String] }
        let badOwner = await failure {
            try await sftp.changeMode([ops + "/tree"], set: 0, clear: 0, owner: "soltz-no-such-user", group: nil, recursive: false)
        }
        check("mode 750, owner and group on a whole folder tree on the host; a user nobody has is the host's error",
              changed == nil && inside == [0o750, 0o750, 0o750] && beside != [0o750] && owners == [NSUserName(), group] && badOwner != nil,
              "\(changed ?? "changed") \(inside.map { $0.map { String($0, radix: 8) } ?? "?" }), owner and group \(owners ?? []); bad owner: \(badOwner ?? "no error")")
        try? await sftp.delete(ops)

        // A 200 MB upload cancelled once it is under way: no final file and no partial left on the host.
        let bigDir = work + "/big"
        guard let big = sparse(src + "/big.bin", megabytes: 200), (try? await sftp.mkdir(bigDir)) != nil else {
            return check("Files: 200 MB file made", false, "")
        }
        queue.enqueue([big], from: localFiles, to: sftp, into: bigDir)
        let started = await wait(20) { (queue.transfers.first?.transferred ?? 0) > 0 }
        let at = queue.transfers.first?.transferred ?? 0
        if let row = queue.transfers.first { queue.cancel(row.id) }
        let settled = await wait(20) { queue.transfers.first?.settled == true }
        try? await Task.sleep(for: .milliseconds(500))
        let leftover = (try? fm.contentsOfDirectory(atPath: bigDir)) ?? ["?"]
        check("cancel a 200 MB upload mid-way: row cancelled, no final file and no partial left on the host",
              started && at < 200 << 20 && settled && queue.transfers.first?.status == .cancelled && leftover.isEmpty,
              "cancelled at \(at >> 20) MB, \(queue.transfers.first.map { "\($0.status)" } ?? "no row"), host dir \(leftover)")
        queue.clearCompleted()
    }

    // MARK: - f. Automatic reconnect, Reconnect, transfer resume

    private static func reconnect(_ workspace: Workspace, _ server: Server, _ primary: TerminalSession, _ check: Check) async {
        let mark = "mark-\(Int.random(in: 1000...9999))"
        _ = await ready(primary)
        primary.send(Data("E2E_MARK=\(mark)\n".utf8))
        let coreID = primary.coreID

        // A 400 MB upload under way when the connection drops waits for it and goes on after the reconnect.
        let resumeDir = server.work + "/resume", queue = workspace.transfers
        guard let big = sparse(server.local + "/src/big2.bin", megabytes: 400),
              let sftp = workspace.fileProvider(for: primary.id) as? SftpFileProvider, (try? await sftp.mkdir(resumeDir)) != nil
        else { return check("Files: 400 MB file made", false, "") }
        queue.enqueue([big], from: workspace.localFiles, to: sftp, into: resumeDir)
        let underway = await wait(20) { (queue.transfers.first?.transferred ?? 0) > 0 }

        // And the session's own pane on its files, listing the work dir.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: server.work))?.count ?? -1
        primary.filesPath = server.work
        primary.showsFiles = true
        workspace.reveal(primary.id)
        let paneUp = await wait(10) { tables().contains { $0.numberOfRows == entries } }

        // The server drops the connection: no click, the backoff reconnects (upstream's first wait is 1.5 s). Watched in one
        // loop, since the pane, its files and the transfer each show the outage only until it is over.
        workspace.failure = nil
        let attempts = primary.reconnectAttempts
        var seen = (reconnecting: false, paneDown: false, waiting: false, runningWhileWaiting: false)
        _ = await server.ctl("drop")
        let back = await wait(30) {
            seen.reconnecting = seen.reconnecting || (primary.autoReconnecting && !primary.isAttached && !primary.ended)
            seen.paneDown = seen.paneDown || (seen.reconnecting && !tables().contains { $0.numberOfRows == entries })
            if queue.transfers.first?.waiting == true {
                seen.waiting = true
                seen.runningWhileWaiting = queue.transfers.first?.status == .running
            }
            return seen.reconnecting && primary.isAttached && !primary.autoReconnecting
        }
        _ = await ready(primary)
        let kept = await output(primary, #"printf 'E2E-MARK:%s\n' "$E2E_MARK""#, "E2E-MARK:")
        check("connection killed from the server side: the pane holds Reconnecting (never Disconnected, no alert), then reconnects by itself under the same core session id, one attempt, no click: a fresh shell (no persistence: the old shell's variable is gone)",
              back && primary.coreID == coreID && primary.reconnectAttempts == attempts + 1 && primary.args?["attachOnly"] == false
                  && kept == "" && workspace.failure == nil && workspace.sessions[primary.id] != nil,
              primary.isAttached ? "E2E_MARK=\(kept ?? "no answer"), \(primary.reconnectAttempts - attempts) attempts"
                  : workspace.failure?.message ?? "not attached")
        let paneDown = seen.paneDown, waiting = seen.waiting
        let listing = (try? await sftp.list(server.work))?.count
        let paneBack = await wait(10) { tables().contains { $0.numberOfRows == entries } }
        check("after the automatic reconnect the files pane went away with the drop and lists the work dir again",
              listing == entries && paneUp && paneDown && paneBack,
              "provider lists \(listing.map(String.init) ?? "nothing")/\(entries), "
                  + "pane \(paneUp ? "shown" : "missing") → \(paneDown ? "gone" : "kept") → \(paneBack ? "back" : "missing"); "
                  + tables().map { "\($0.numberOfRows) rows" }.joined(separator: ", "))
        primary.showsFiles = false

        let done = await wait(120) { queue.transfers.first?.settled == true }
        let row = queue.transfers.first
        let landed = resumeDir + "/big2.bin"
        let size = (try? FileManager.default.attributesOfItem(atPath: landed))?[.size] as? Int
        let parts = ((try? FileManager.default.contentsOfDirectory(atPath: resumeDir)) ?? []).filter { $0 != "big2.bin" }
        check("the upload under way waited through the drop (sftp-waiting) and finished after the automatic reconnect: the whole file, no partial left",
              underway && waiting && seen.runningWhileWaiting && done && row?.status == .done && size == 400 << 20 && parts.isEmpty
                  && FileManager.default.contentsEqual(atPath: big.path, andPath: landed),
              "\(row.map { "\($0.status), resumed at \($0.resumedAt.map { "\($0 >> 20) MB" } ?? "never")" } ?? "no row"), "
                  + "waiting seen \(waiting), \(size.map { "\($0 >> 20) MB" } ?? "no file"), other entries \(parts)")
        queue.clearCompleted()

        // The server stops: the backoff keeps trying on its schedule (1.5 s, then 3 s, then 5 s…) while the pane holds
        // Reconnecting; its Reconnect is upstream's "Retry now", an attempt at once.
        let before = primary.reconnectAttempts
        _ = await server.ctl("stop")
        let retrying = await wait(20) { primary.reconnectAttempts >= before + 2 && primary.waker.isSleeping }
        let holding = primary.autoReconnecting && !primary.isAttached && !primary.ended && workspace.failure == nil
        let scheduled = primary.reconnectAttempts
        workspace.reconnect(primary) // the pane's Reconnect, while it waits
        let atOnce = await wait(2) { primary.reconnectAttempts == scheduled + 1 }
        let stillHolding = await wait(5) { primary.waker.isSleeping } && primary.autoReconnecting && workspace.failure == nil
        check("with the server stopped the pane holds Reconnecting and retries on the schedule, no alert; its Reconnect tries at once and the waiting goes on",
              retrying && holding && atOnce && stillHolding,
              "\(primary.reconnectAttempts - before) attempts, \(workspace.failure?.message ?? "no alert")")
        _ = await server.ctl("start")
        let recovered = await wait(30) { primary.isAttached && !primary.autoReconnecting }
        let answers = await ready(primary)
        check("the server back: the next scheduled attempt reconnects by itself, same core session id, no alert",
              recovered && answers && primary.coreID == coreID && workspace.failure == nil,
              "\(primary.reconnectAttempts - before) attempts")

        // Cancel stops the retries; the pane's Reconnect is then a single attempt whose failure is shown.
        _ = await server.ctl("stop")
        _ = await wait(15) { primary.autoReconnecting }
        primary.connectTask?.cancel() // the pane's Cancel
        let cancelled = await wait(10) { primary.ended && primary.dropped && !primary.autoReconnecting } && workspace.failure == nil
        workspace.reconnect(primary) // the pane's Reconnect, now not waiting
        let failed = await wait(30) { primary.ended && workspace.failure != nil }
        check("Cancel stops the retries (Disconnected, Reconnect offered, no alert); a Reconnect while the server is down then fails with upstream's text and offers Reconnect again",
              cancelled && failed && primary.dropped && !primary.autoReconnecting && workspace.failure?.message == ErrorCode.connectionRefused.text,
              workspace.failure?.message ?? "no alert")
        workspace.failure = nil
        _ = await server.ctl("start")
        workspace.reconnect(primary)
        let manual = await wait(30) { primary.isAttached || primary.ended }
        let answered = await ready(primary)
        check("the pane's Reconnect once the server is back: same core session id, a shell that answers",
              manual && answered && primary.isAttached && primary.coreID == coreID, workspace.failure?.message ?? "")
    }

    // MARK: - g. Persistent sessions

    /// The host option left off above. The wrapper on the host picks tmux, else GNU screen; first ask the host, in the
    /// primary session's shell, whether a detached screen can start in one of this server's sessions at all.
    private static func persistence(_ workspace: Workspace, _ server: Server, _ primary: TerminalSession, _ host: Connection,
                                    _ check: Check) async {
        _ = await ready(primary)
        // `t` for tmux, `s` for screen, then how many probe screens are listed: `ts1`, `s0`, `0`…
        let probe = await output(primary, "printf 'E2E-PROBE:%s%s%s\\n' \"$(command -v tmux >/dev/null && echo t)\" "
                                     + "\"$(command -v screen >/dev/null && echo s)\" "
                                     + "\"$(screen -dmS soltz_e2e_probe sleep 3 2>/dev/null; sleep 1; screen -ls 2>/dev/null | grep -c soltz_e2e_probe)\"",
                                 "E2E-PROBE:") ?? ""
        let tmux = probe.contains("t"), screen = probe.contains("s")
        guard tmux || screen else { return print("[INFO] g. persistent sessions not tested: neither tmux nor screen on the host's PATH") }
        guard let persistent = try? Connection(json: row([
            "name": "E2E persistent", "host": "127.0.0.1", "port": .int(server.port), "username": .string(server.user), "tags": [],
            "auth_type": "key", "key_id": host.keyID.map(JSONValue.string) ?? .null,
        ])),
            await workspace.perform("save", { try await workspace.save(persistent, HostSecrets()) }),
            let session = workspace.connect(to: persistent)
        else { return check("g. persistent host saved and connecting", false, workspace.failure?.message ?? "") }
        defer { if let tab = workspace.layout.splitTabs.first(where: { $0.root.sessionIds.contains(session.id) }) { workspace.closeTab(tab.id) } }
        let attached = await wait(30) { session.isAttached || session.ended }

        // shortcut: this branch has never run (screen cannot start under the non-root sshd on this Mac); run the e2e
        // against a host where tmux or screen works before trusting it.
        if tmux || probe.hasSuffix("1") {
            let mark = "persist-\(Int.random(in: 1000...9999))"
            let up = await ready(session)
            session.send(Data("E2E_MARK=\(mark)\n".utf8))
            _ = await server.ctl("drop")
            let back = await wait(30) { session.reconnectAttempts > 0 && (session.isAttached || session.ended) && !session.autoReconnecting }
            _ = await ready(session)
            let kept = await output(session, #"printf 'E2E-MARK:%s\n' "$E2E_MARK""#, "E2E-MARK:")
            check("g. persistent session (\(tmux ? "tmux" : "GNU screen")): the automatic reconnect attaches (attachOnly) to the shell that survived the drop",
                  attached && up && back && session.args?["attachOnly"] == true && kept == mark, "\(kept ?? "nothing") (expected \(mark))")
        } else {
            let answers = await ready(session, tries: 3)
            print("[INFO] g. persistent sessions not testable here: tmux is not installed and GNU screen \(screenVersion()) is, but a "
                  + "screen server exits at once in this non-root sshd's sessions (a detached `screen -dmS` lists nothing; the same "
                  + "command works from a normal login). The app's persistent connect \(attached && session.isAttached ? "attaches" : "fails") "
                  + "and its shell \(answers ? "answers" : "never answers: upstream's wrapper waits on `screen -D -R` for a server that is gone, the pty only echoes what is typed")")
            // What can still be seen: a reconnect that finds no session on the host to attach to.
            workspace.failure = nil
            _ = await server.ctl("drop")
            let closed = await wait(30) { workspace.sessions[session.id] == nil }
            check("g. after a drop, a persistent session's automatic reconnect finds no session left on the host to attach to (SESSION_ENDED): its tab closes after one attempt, no alert, as in upstream",
                  attached && session.args?["attachOnly"] == true && closed && session.reconnectAttempts == 1 && workspace.failure == nil,
                  closed ? "" : "pane \(session.ended ? "ended" : "open"), \(workspace.failure?.message ?? "no alert")")
        }
        // The drop took the main session too; it comes back by itself.
        _ = await wait(30) { primary.isAttached && !primary.autoReconnecting }
    }

    // MARK: - d. Authentication failures

    private static func authFailures(_ workspace: Workspace, _ server: Server, _ check: Check) async {
        workspace.failure = nil
        let keyID = newID()
        guard let wrong = try? String(contentsOfFile: server.wrongKey, encoding: .utf8),
              let key = try? SshKey(json: row(["id": .string(keyID), "name": "E2E wrong key", "key_type": "ED25519"])),
              let host = try? Connection(json: row([
                  "name": "E2E wrong key", "host": "127.0.0.1", "port": .int(server.port), "username": .string(server.user),
                  "tags": [], "auth_type": "key", "key_id": .string(keyID),
              ])),
              await workspace.perform("save", {
                  try await workspace.save(key, KeySecrets(privateKey: wrong))
                  try await workspace.save(host, HostSecrets())
              }),
              let session = workspace.connect(to: host)
        else { return check("wrong key: host saved and connecting", false, workspace.failure?.message ?? "") }
        let failed = await wait(20) { session.ended }
        let message = workspace.failure?.message
        check("a key the server does not accept: SSH_KEY_REJECTED, shown as upstream's text; the pane ends offering Reconnect",
              failed && !session.isAttached && message == ErrorCode.sshKeyRejected.text, message ?? "no alert")
        if let tab = workspace.layout.activeSplitTabId { workspace.closeTab(tab) }
        workspace.failure = nil

        // A connected host whose saved key is then swapped for one the server refuses: the automatic reconnect after a
        // drop reads the saved key again, is rejected, and stops at once (upstream's FINAL_CODES: no fail2ban ban).
        guard let good = try? String(contentsOfFile: server.key, encoding: .utf8),
              let rotating = try? Connection(json: row([
                  "name": "E2E rotated key", "host": "127.0.0.1", "port": .int(server.port), "username": .string(server.user),
                  "tags": [], "auth_type": "key", "persist_session": false,
              ])),
              await workspace.perform("save", { try await workspace.save(rotating, HostSecrets(privateKey: good)) }),
              let live = workspace.connect(to: rotating), await wait(30, until: { live.isAttached || live.ended }), live.isAttached
        else { return check("wrong key on reconnect: a live session with the right key", false, workspace.failure?.message ?? "") }
        await workspace.perform("swap key") { try await workspace.save(rotating, HostSecrets(privateKey: wrong)) }
        _ = await server.ctl("drop")
        let stopped = await wait(20) { live.ended }
        try? await Task.sleep(for: .seconds(4)) // the schedule's next attempt (3 s after the first) would have come by now
        check("a wrong key stops the automatic reconnect: one attempt, refused with SSH_KEY_REJECTED shown as upstream's text, no retry; the pane offers Reconnect",
              stopped && live.reconnectAttempts == 1 && live.dropped && !live.autoReconnecting
                  && workspace.failure?.message == ErrorCode.sshKeyRejected.text,
              "\(live.reconnectAttempts) attempts, \(workspace.failure?.message ?? "no alert")")
        workspace.close(live.id)
        workspace.failure = nil

        guard let bare = try? Connection(json: row([
            "name": "E2E no key", "host": "127.0.0.1", "port": .int(server.port), "username": .string(server.user), "tags": [],
        ])),
            await workspace.perform("save", { try await workspace.save(bare, HostSecrets()) })
        else { return check("no key: host saved", false, "") }
        let opened = workspace.connect(to: bare)
        let form = workspace.connectForm
        check("a host with no key or password opens Quick Connect prefilled instead of connecting",
              opened == nil && form?.connection?.id == bare.id && form?.host == "127.0.0.1" && form?.username == server.user, "")
        workspace.connectForm = nil
        guard var typed = form else { return }
        typed.password = "not-the-password" // what Quick Connect's Connect sends with a password typed
        let probe = TerminalSession(title: "probe", font: workspace.font)
        do {
            try await workspace.connectSsh(probe, workspace.connectArgs(for: typed.target(), login: typed.login(key: nil)))
            check("password login on a key-only server is refused with SSH_NO_USABLE_AUTH_METHOD", false, "it connected")
        } catch CoreError.Coded(let code, let message) {
            check("password login on a key-only server is refused with SSH_NO_USABLE_AUTH_METHOD and the core's message (upstream's text takes {methods})",
                  code == .sshNoUsableAuthMethod && message.contains("publickey"), message)
        } catch {
            check("password login on a key-only server is refused with SSH_NO_USABLE_AUTH_METHOD", false, describe(error))
        }
        probe.close()
    }

    // MARK: - e. Cancel

    private static func cancel(_ workspace: Workspace, _ server: Server, _ check: Check) async {
        workspace.failure = nil
        guard let silent = Loopback.listen() else { return check("cancel: a silent listener", false, "") }
        defer { Loopback.stop(silent.fd) }
        guard let host = try? Connection(json: row([
            "name": "E2E silent", "host": "127.0.0.1", "port": .int(Int64(silent.port)), "username": .string(server.user), "tags": [],
        ])),
            await workspace.perform("save", { try await workspace.save(host, HostSecrets(password: "unused")) }),
            let session = workspace.connect(to: host)
        else { return check("cancel: host saved and connecting", false, "") }
        try? await Task.sleep(for: .milliseconds(1500)) // ssh-step reports nothing before the key exchange, which never comes
        let hanging = !session.isAttached && !session.ended
        session.connectTask?.cancel() // the pane's Cancel
        let ended = await wait(10) { session.ended }
        let closed = await Task.detached { Loopback.acceptsThenEOF(silent.fd) }.value
        check("cancel a connect to a port that accepts but never answers: the pane ends with no alert, the client closed its socket",
              hanging && ended && !session.isAttached && workspace.failure == nil && closed,
              "step \(session.step ?? "none"), socket \(closed ? "closed" : "still open"), \(workspace.failure?.message ?? "no alert")")
        if let tab = workspace.layout.activeSplitTabId { workspace.closeTab(tab) }
    }

    // MARK: - c, l. Changed host key, clean disconnect

    private static func changedHostKey(_ workspace: Workspace, _ server: Server, _ host: Connection, _ check: Check) async {
        workspace.closeAll()
        let oldFP = server.hostFP.replacingOccurrences(of: "SHA256:", with: ""), newFP = server.host2FP.replacingOccurrences(of: "SHA256:", with: "")
        func stored() async -> [String] {
            let rows = (try? await workspace.core.entityList(kind: .knownHosts)).flatMap { try? JSONDecoder().decode([KnownHost].self, from: Data($0.utf8)) }
            return (rows ?? []).filter { $0.host == "127.0.0.1" && Int64($0.port) == server.port }.map(\.fingerprint)
        }

        // The host editor's Save gives the host an inline post-command, run before disconnecting on close.
        var commands = workspace.connections.first { $0.id == host.id } ?? host
        commands.postCommand = "printf post > '\(server.work)/post-command.txt'"
        await workspace.perform("edit host") { try await workspace.save(commands, HostSecrets()) }
        guard let edited = workspace.connections.first(where: { $0.id == host.id }), let live = workspace.connect(to: edited),
              await wait(30, until: { live.isAttached || live.ended }), live.isAttached
        else { return check("changed host key: a live session on the old key", false, workspace.failure?.message ?? "") }

        // The server comes back with another host key: the dropped session's automatic reconnect meets it and asks, and
        // makes no other attempt while the question is open.
        workspace.failure = nil
        _ = await server.ctl("rekey")
        let asked = await wait(30) { live.conflict != nil || live.ended }
        let alert = await wait(5) { NSApp.windows.contains { $0.attachedSheet != nil } }
        let attempts = live.reconnectAttempts
        try? await Task.sleep(for: .seconds(4)) // longer than the schedule's next wait
        check("server restarted with another host key on the same port: the automatic reconnect gets ssh-host-key-conflict, the Host Key Changed alert on screen, no further attempt while it asks",
              asked && live.conflict?.newFingerprint?.contains(newFP) == true && alert && live.autoReconnecting
                  && live.reconnectAttempts == attempts && attempts >= 1,
              "\(live.conflict?.newFingerprint ?? "no conflict"), alert \(alert), \(attempts) attempts")
        live.answer(.abort, via: workspace.core) // the alert's Cancel
        let ended = await wait(15) { live.ended }
        let kept = await stored()
        check("Abort refuses: the retries stop (upstream stops on a refused host key) with the reason shown, the pane offers Reconnect, the stored key stays the old one",
              ended && !live.isAttached && !live.autoReconnecting && live.dropped && live.reconnectAttempts == attempts
                  && workspace.failure != nil && kept.count == 1 && kept[0].contains(oldFP),
              "\(workspace.failure?.message ?? "no alert"), \(kept)")
        workspace.failure = nil

        // The pane's Reconnect asks again; Replace connects.
        workspace.reconnect(live)
        _ = await wait(20) { live.conflict != nil || live.ended }
        let reasked = live.conflict?.newFingerprint?.contains(newFP) == true
        live.answer(.replace, via: workspace.core) // the alert's Replace Stored Keys
        let connected = await wait(20) { live.isAttached || live.ended }
        let replaced = await stored()
        check("Reconnect asks about the new key too; Replace connects, the stored key becomes the new one only",
              reasked && connected && live.isAttached && replaced.count == 1 && replaced[0].contains(newFP), "stored \(replaced)")

        // l. Closing a live tab: the post-command, then the session ends on the server (no process left under sshd).
        _ = await ready(live)
        let before = (await server.ctl("children"), await server.ctl("screens"))
        workspace.close(live.id)
        var after = ("?", "?")
        for _ in 0..<30 {
            after = (await server.ctl("children"), await server.ctl("screens"))
            if after == ("0", "0") { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let post = try? String(contentsOfFile: server.work + "/post-command.txt", encoding: .utf8)
        check("closing the tab runs the host's post-command, then ends the session on the server: no process left under sshd, no screen session",
              post == "post" && before.0 != "0" && after == ("0", "0") && workspace.sessions.isEmpty,
              "post-command \(post == "post" ? "ran" : "did not run"); before: \(before.0) processes, \(before.1) screens; after: \(after.0) processes, \(after.1) screens")
    }

    // MARK: - m. A clean remote exit

    /// `exit` in the remote shell: the channel ends with an exit-status, which upstream treats as the user closing the
    /// session, not as a drop.
    private static func remoteExit(_ workspace: Workspace, _ host: Connection, _ check: Check) async {
        workspace.failure = nil
        guard let session = workspace.connect(to: host), await wait(30, until: { session.isAttached || session.ended }),
              session.isAttached, await ready(session)
        else { return check("exit: a live session to the host", false, workspace.failure?.message ?? "") }
        session.send(Data("exit\n".utf8))
        let closed = await wait(15) { workspace.sessions[session.id] == nil }
        try? await Task.sleep(for: .seconds(2)) // longer than the first reconnect wait
        check("`exit` typed in the remote shell closes the tab (a clean remote exit): no reconnect, no alert, as in upstream",
              closed && session.reconnectAttempts == 0 && !session.autoReconnecting && workspace.failure == nil && workspace.sessions.isEmpty,
              closed ? "" : "pane \(session.ended ? "ended" : session.autoReconnecting ? "reconnecting" : "open")")
    }

    // MARK: - Helpers

    private static func newID() -> String { UUID().uuidString.lowercased() }

    private static func row(_ fields: JSONObject) -> JSONObject {
        ["id": .string(newID()), "created_at": "", "updated_at": "", "clocks": [:]].merging(fields) { _, given in given }
    }

    private static func put(_ path: String, _ data: Data) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(filePath: path))
    }

    /// A sparse file of zeros, made at once, as a pane would list it.
    private static func sparse(_ path: String, megabytes: Int) -> FileEntry? {
        guard FileManager.default.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path),
              (try? handle.truncate(atOffset: UInt64(megabytes) << 20)) != nil
        else { return nil }
        try? handle.close()
        return FileEntry(name: (path as NSString).lastPathComponent, path: path, size: UInt64(megabytes) << 20)
    }

    private static func resolved(_ path: String) -> String { URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false) }

    private static func screenVersion() -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/screen")
        process.arguments = ["--version"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "?" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return out.split(separator: " ").dropFirst(2).first.map(String.init) ?? "?"
    }

    /// The last screen lines, for a failure's detail.
    private static func tail(_ session: TerminalSession) -> String { session.screenLines.suffix(3).joined(separator: " | ") }

    /// Waits until the remote shell reads input: a probe typed every 2 s until its output shows.
    private static func ready(_ session: TerminalSession, tries: Int = 8) async -> Bool {
        for _ in 0..<tries where session.isAttached {
            session.send(Data("printf 'E2E-%s\\n' ready\n".utf8))
            if await wait(2, until: { session.screenLines.contains("E2E-ready") }) { return true }
        }
        return false
    }

    /// Types `command` and returns what follows `marker` on the next new line that starts with it.
    private static func output(_ session: TerminalSession, _ command: String, _ marker: String) async -> String? {
        let count = { session.screenLines.count { $0.hasPrefix(marker) } }
        let before = count()
        session.send(Data((command + "\n").utf8))
        guard await wait(10, until: { count() > before }) else { return nil }
        return session.screenLines.last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
    }

    /// Every table in the app's windows (the panes are SwiftUI `Table`s).
    private static func tables() -> [NSTableView] {
        func walk(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
        return NSApp.windows.compactMap(\.contentView).flatMap(walk)
    }

    private static func wait(_ seconds: Double = 4, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// Blocking BSD sockets on 127.0.0.1 for the cancel check; the blocking calls run off the main actor.
enum Loopback {
    private static func address(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func withAddress<T>(_ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address(port)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }

    private static func timeout(_ fd: Int32, seconds: Int) {
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// A socket listening on 127.0.0.1, on a port the kernel picks.
    static func listen() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withAddress(0, { bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    static func stop(_ fd: Int32) {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    /// Accepts the connection waiting on `fd` and reads it to its end: true when the peer closed it within 5 s.
    static func acceptsThenEOF(_ fd: Int32) -> Bool {
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 5000) == 1 else { return false }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return false }
        defer { close(client) }
        timeout(client, seconds: 5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n == 0 { return true }
            if n < 0 { return false }
        }
    }
}
#endif
