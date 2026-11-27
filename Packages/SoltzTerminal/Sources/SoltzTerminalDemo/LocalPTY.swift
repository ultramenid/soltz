// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import SoltzTerminal

/// Stand-in for the Rust SSH core: a process on a local pseudo-terminal.
final class LocalPTY: Sendable {
    let master: Int32
    let pid: pid_t

    /// `argv[0]` starting with `-` makes a login shell.
    init?(path: String, argv: [String], size: SoltzTerminalSize?) {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        let slaveName = String(cString: ptsname(master))
        // Held open until the child has its own: a tty with no open slave forgets its winsize.
        defer { close(slave) }
        self.master = master
        if let size { Self.setSize(size, on: master) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened after setsid, so the slave becomes the shell's controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, cArgs, cEnv) == 0 else {
            close(master)
            return nil
        }
        self.pid = pid
    }

    /// Reads until EOF (the process exited or `terminate` ran) on a background thread.
    func startReading(_ onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [master] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(master, &buffer, buffer.count)
                if n <= 0 { break }
                onData(Data(buffer[0 ..< n]))
            }
            onEnd()
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }
    }

    func resize(_ size: SoltzTerminalSize) {
        Self.setSize(size, on: master)
    }

    private static func setSize(_ size: SoltzTerminalSize, on master: Int32) {
        var ws = winsize(
            ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
            ws_xpixel: UInt16(clamping: size.widthPixels), ws_ypixel: UInt16(clamping: size.heightPixels)
        )
        _ = withUnsafeMutablePointer(to: &ws) { ioctl(master, TIOCSWINSZ, $0) }
    }

    /// Closing the master hangs up the session; SIGKILL covers a shell that ignores SIGHUP.
    func terminate() {
        close(master)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
