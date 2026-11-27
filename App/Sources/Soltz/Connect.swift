// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzCore
import SoltzHostsUI
import SoltzModel

/// A saved host's login, as upstream `resolveCredentials` (src/services/credentialLogic.ts) builds it.
struct Login: Equatable {
    var username: String
    var password: String?
    var privateKey: String?
    var passphrase: String?
}

/// A connect that cannot start, in upstream's words.
struct ConnectProblem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// SSH sessions: the `ssh_connect` arguments as upstream's frontend builds them, connecting, Reconnect, Split
/// and what upstream does around a connect.
extension Workspace {
    // MARK: - Credentials

    /// A stored secret; an empty one counts as none.
    func secret(_ key: String) throws -> String? {
        try core.secretGet(key: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Upstream `resolveCredentials`: the identity's username, password and keychain key when the host has a
    /// (live) identity; else the host's username and password, and its keychain key (`key_id`) or pasted key.
    func login(for host: Connection) throws -> Login {
        if let identity = identities.first(where: { $0.id == host.identityID }) { return try login(identity) }
        let key = try secret(host.keyID.map { "key:\($0):private" } ?? "key:\(host.id)")
        // A host that logs in with a key never sends its password too: a server, or whoever answers for it, could
        // refuse the key to be handed the password instead.
        return Login(username: host.username, password: host.authType == .key && key != nil ? nil : try secret("password:\(host.id)"),
                     privateKey: key,
                     passphrase: try secret(host.keyID.map { "key:\($0):passphrase" } ?? "passphrase:\(host.id)"))
    }

    /// Upstream `identityCredentials`.
    func login(_ identity: Identity) throws -> Login {
        let key = try identity.keyID.flatMap { try secret("key:\($0):private") }
        // As for a host: an identity with a key logs in with the key alone.
        return Login(username: identity.username, password: key != nil ? nil : try secret("identity:\(identity.id):password"),
                     privateKey: key,
                     passphrase: try identity.keyID.flatMap { try secret("key:\($0):passphrase") })
    }

    // MARK: - Connect arguments

    static func newSessionID() -> String { "soltz-\(UUID().uuidString.lowercased())" }

    /// Upstream `buildSshConnectOptions` + `sshConnect` (src/stores/sessionStore.ts:146, src/services/ssh.ts:49): the
    /// object its frontend invokes `ssh_connect` with. `cols`/`rows` come from the pane once it is laid out.
    // shortcut: Soltz has no global settings yet, so upstream's defaults stand in for them: proxy "none", keepalive
    // "balanced", persistent sessions, shell integration and the 24 h detached TTL on; `terminalColors` is null
    // (Soltz has no themes; upstream sends its theme's colours). Read them from Settings once it has them.
    func connectArgs(for host: Connection, login: Login) throws -> JSONObject {
        // Upstream `firstHopConnection`: the first jump host's saved connection (none if it is gone), else the host.
        let firstHop = host.jumpHosts.first.map { jump in connections.first { $0.id == jump.connectionID } } ?? host
        let (interval, max): (Int64, Int64) = switch host.keepalivePreset ?? .balanced {
        case .fast: (2, 2)
        case .tolerant: (5, 4)
        case .off: (0, 0)
        default: (3, 3)
        }
        let jumps = try jumpHosts(of: host)
        return [
            "sessionId": .string(Self.newSessionID()),
            "host": .string(host.host),
            "port": .int(Int64(host.port == 0 ? 22 : host.port)),
            "username": .string(login.username),
            "password": nullable(login.password),
            "privateKey": nullable(login.privateKey),
            "passphrase": nullable(login.passphrase),
            "connectionId": .string(host.id),
            "jumpHosts": jumps.isEmpty ? .null : .array(jumps),
            "envVars": host.envVars.isEmpty ? .null : .array(host.envVars.map { [.string($0.key), .string($0.value)] }),
            "agentForwarding": .bool(host.agentForwarding),
            "legacyAlgorithms": .bool(host.legacyAlgorithms),
            "preCommand": nullable(inlineCommand(host, post: false)),
            "autoForward": false,
            "shellIntegration": .bool(host.shellIntegration ?? true),
            "keepaliveIntervalSecs": .int(interval),
            "keepaliveMax": .int(max),
            "persist": .bool(host.persistSession ?? true),
            "detachedTtlSecs": .int(24 * 3600),
            "restore": .null,
            "attachOnly": .null,
            "cols": .null,
            "rows": .null,
            "initialCwd": .null,
            "proxy": try proxySpec(for: firstHop.flatMap { $0.proxy == nil ? nil : $0 } ?? host),
            "knock": try knockSpec(for: firstHop),
            "terminalColors": .null,
        ]
    }

    /// Upstream `resolveJumpHosts` (src/services/credentials.ts:46): a jump host naming a saved connection takes that
    /// connection's address and full login; otherwise its snapshot, with the snapshot identity's login or the
    /// `password:`/`key:` slots of the id it names.
    func jumpHosts(of host: Connection) throws -> [JSONValue] {
        // `legacy`: the hop's own Legacy Algorithms; the target's does not weaken the hops before it.
        func hop(_ address: String, _ port: UInt16, _ username: String, _ login: Login, legacy: Bool = false) -> JSONValue {
            var hop: JSONObject = ["host": .string(address), "port": .int(Int64(port)), "username": .string(username),
                                   "legacyAlgorithms": .bool(legacy)]
            hop["password"] = login.password.map(JSONValue.string)
            hop["privateKey"] = login.privateKey.map(JSONValue.string)
            hop["passphrase"] = login.passphrase.map(JSONValue.string)
            return .object(hop)
        }
        return try host.jumpHosts.map { jump in
            if let saved = connections.first(where: { $0.id == jump.connectionID }) {
                let login = try login(for: saved)
                return hop(saved.host, saved.port == 0 ? 22 : saved.port, login.username.isEmpty ? saved.username : login.username, login,
                           legacy: saved.legacyAlgorithms)
            }
            guard let address = jump.host, let port = jump.port else {
                return ["host": .string(jump.host ?? ""), "port": .int(Int64(jump.port ?? 22)), "username": .string(jump.username ?? "")]
            }
            if let identity = identities.first(where: { $0.id == jump.identityID }) {
                let login = try login(identity)
                return hop(address, port, login.username, login)
            }
            return hop(address, port, jump.username ?? "", Login(username: "", password: try secret("password:\(jump.connectionID)"),
                                                                 privateKey: try secret("key:\(jump.connectionID)")))
        }
    }

    /// Upstream `resolveProxy` (src/services/proxy.ts:20) for the host's own proxy, its password in `proxy_password:<id>`.
    func proxySpec(for host: Connection) throws -> JSONValue {
        guard let proxy = host.proxy else { return .null } // the global proxy, "none" by default
        let defaultPort: UInt16
        let label: String
        switch proxy.mode {
        case .direct, .system: return ["kind": .string(proxy.mode.rawValue)]
        case .socks5: (defaultPort, label) = (1080, "SOCKS5")
        case .http: (defaultPort, label) = (8080, "HTTP")
        case .https: (defaultPort, label) = (443, "HTTPS")
        default: return .null
        }
        guard let address = proxy.host?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw ConnectProblem("Proxy is set to \(label) but has no host")
        }
        var spec: JSONObject = ["kind": .string(proxy.mode.rawValue), "host": .string(address),
                                "port": .int(Int64(proxy.port.flatMap { $0 == 0 ? nil : $0 } ?? defaultPort))]
        if let username = proxy.username, !username.isEmpty { spec["username"] = .string(username) }
        if let password = try? secret("proxy_password:\(host.id)") { spec["password"] = .string(password) }
        return .object(spec)
    }

    /// Upstream `resolveKnock` (src/services/portKnock.ts:58) for the first hop, its sequence in `knock_sequence:<id>`.
    func knockSpec(for host: Connection?) throws -> JSONValue {
        guard let host, let knock = host.portKnock, knock.enabled else { return .null }
        guard let sequence = try? secret("knock_sequence:\(host.id)") else {
            throw ConnectProblem("The knock sequence for this host isn’t available on this device.")
        }
        guard let steps = Self.knockSteps(sequence) else {
            throw ConnectProblem("This host’s knock sequence is invalid. Fix it in the host’s Port Knocking settings.")
        }
        return ["steps": .array(steps), "delay_ms": .int(Int64(knock.delayMs ?? 200)), "settle_ms": .int(Int64(knock.settleMs ?? 500))]
    }

    /// Upstream `parseKnockSequence`: `7000/tcp,8000/udp`, 1 to 16 steps, TCP when unsaid. nil when invalid.
    nonisolated static func knockSteps(_ text: String) -> [JSONValue]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...16).contains(parts.count) else { return nil }
        var steps: [JSONValue] = []
        for part in parts {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let proto = pieces.count > 1 ? pieces[1] : "tcp"
            guard let port = Int(pieces[0].trimmingCharacters(in: .whitespaces)), (1...65535).contains(port),
                  proto == "tcp" || proto == "udp" else { return nil }
            steps.append(["port": .int(Int64(port)), "protocol": .string(proto)])
        }
        return steps
    }

    /// Upstream `resolveHostCommand`: a host's inline pre or post command, which the
    /// core runs. A host whose command names a snippet (set by another client) runs nothing: its inline text is hidden
    /// in the editor then, and may be stale.
    func inlineCommand(_ host: Connection, post: Bool) -> String? {
        guard (post ? host.postSnippetID : host.preSnippetID)?.isEmpty ?? true else { return nil }
        let text = (post ? host.postCommand : host.preCommand)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: - Connecting

    /// A saved host's double-click: an SSH host with a stored password or key connects in a new tab, one with
    /// neither opens Quick Connect prefilled. Other connection types cannot open yet. `files` opens the tab on the
    /// host's files instead of its terminal.
    @discardableResult
    func connect(to host: Connection, _ placement: Placement = .tab, files: Bool = false) -> TerminalSession? {
        guard host.connectionType == .ssh else {
            failure = Failure(title: "\(Self.typeName(host.connectionType)) Hosts Aren’t Available Yet",
                              message: "Soltz connects to SSH hosts for now.")
            return nil
        }
        let login: Login
        var args: JSONObject
        do {
            login = try self.login(for: host)
            guard login.password != nil || login.privateKey != nil else {
                connectForm = ConnectForm(host)
                connectForm?.files = files
                return nil
            }
            args = try connectArgs(for: host, login: login)
            if files { args = Self.forFiles(args) }
        } catch {
            failure = Failure(title: "Couldn’t Connect", message: describe(error))
            return nil
        }
        let session = TerminalSession(title: host.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(login.username)@\(host.host)", font: font)
        session.hostID = host.id
        session.showsFiles = files
        add(session, placement)
        open(session, args)
        return session
    }

    /// A files tab's connection: its shell is never seen, so it is not kept in a multiplexer on the host, and the
    /// host's pre-command, written for a terminal, is not run in it.
    static func forFiles(_ args: JSONObject) -> JSONObject {
        var args = args
        args["persist"] = false
        args["preCommand"] = .null
        return args
    }

    /// A connection to a session live on the host already, one joined or one a launch reopens: only ever attached
    /// to, as it is, so no directory is set and the host's pre-command, written for a new shell, is not typed into it.
    static func forAttaching(_ args: JSONObject, to sessionID: String) -> JSONObject {
        args.merging(["sessionId": .string(sessionID), "attachOnly": true, "persist": true, "initialCwd": .null,
                      "preCommand": .null]) { $1 }
    }

    /// Connects `session` in its pane; Cancel (`connectTask`) stops it. A failure is reported and leaves the pane
    /// ended, offering Reconnect (`failed`).
    func open(_ session: TerminalSession, _ args: JSONObject) {
        session.args = args
        session.connectTask = Task {
            do {
                try await connectSsh(session, args)
                await connected(session)
            } catch {
                failed(session, error)
            }
        }
    }

    /// Upstream `ssh_connect` with `args` and the pane's size; cancelling the calling task cancels the connect.
    func connectSsh(_ session: TerminalSession, _ args: JSONObject) async throws {
        var args = args
        if let size = session.size {
            args["cols"] = .int(Int64(size.cols))
            args["rows"] = .int(Int64(size.rows))
        }
        session.args = args
        session.attach(try await core.sshConnect(sink: session.sink, argsJson: try jsonString(args)))
        // Connected: a saved host's secrets do not stay in memory with the tab. Reconnect and Split read them from
        // the vault again (`currentArgs`); a login typed into Quick Connect, which the vault does not hold, stays.
        if savedLogin(of: session) != nil {
            for secret in ["password", "privateKey", "passphrase", "jumpHosts", "proxy", "knock", "envVars"] { session.args?[secret] = .null }
        }
    }

    /// The saved host `session` was opened from and its login, when the vault holds one.
    private func savedLogin(of session: TerminalSession) -> (host: Connection, login: Login)? {
        guard let host = connections.first(where: { $0.id == session.hostID }), let login = try? login(for: host),
              login.password != nil || login.privateKey != nil else { return nil }
        return (host, login)
    }

    /// What to connect `session`'s host with now: a saved host's login and options read again, as upstream resolves
    /// them per attempt; otherwise what the session was opened with.
    func currentArgs(of session: TerminalSession) throws -> JSONObject? {
        guard let saved = savedLogin(of: session) else { return session.args }
        return try connectArgs(for: saved.host, login: saved.login)
    }

    /// After a first connect, `last_used_at` is stamped. The lists reload after every connect, a Reconnect too, so a
    /// host key the connect trusted or replaced shows on the Known Hosts page.
    func connected(_ session: TerminalSession, first: Bool = true) async {
        if let key = liveKey(of: session) { refreshLive(key) }
        guard let host = connections.first(where: { $0.id == session.hostID }) else { return await reload() }
        guard first else { return await reload() }
        await perform("Couldn’t Save the Host") { try await markUsed(host.id) }
    }

    /// Split Right / Down and New Tab: another session like the active one.
    func split(_ placement: Placement) { duplicate(activeSession, placement) }

    /// Another session like `source`, upstream's "Duplicate in split" (src/services/duplicateSession.ts:46): a second
    /// connection to the same host, in the session's directory; for a local shell, or none, a local shell. It shows
    /// what `source` shows, its terminal or its files, unless `files` says which.
    /// With `joining` it is no new session but that one, live on the host already (`forAttaching`).
    func duplicate(_ source: TerminalSession?, _ placement: Placement, files: Bool? = nil, joining: LiveSession? = nil) {
        guard let source, source.args != nil else { return newLocalTerminal(placement) }
        // The host's login and its way in (proxy, jump hosts, knock) are read again. A session whose saved host was
        // deleted since has neither left (`connectSsh` wiped them): it is refused rather than dialled directly.
        var args: JSONObject
        do {
            guard let current = try currentArgs(of: source), current["password"] != .null || current["privateKey"] != .null else {
                failure = Failure(title: "Couldn’t Open Another Session",
                                  message: "This session’s host is no longer saved, so its login is gone. Add the host again to open more on it.")
                return
            }
            args = current
        } catch {
            failure = Failure(title: "Couldn’t Open Another Session", message: describe(error))
            return
        }
        if files ?? source.showsFiles { args = Self.forFiles(args) }
        // Where the session is: a files pane's folder, a terminal's directory.
        let folder = source.showsFiles ? source.filesPath : source.cwd ?? ""
        args["sessionId"] = .string(Self.newSessionID())
        args["attachOnly"] = .null
        args["initialCwd"] = nullable(folder.isEmpty ? nil : folder)
        if let joining { args = Self.forAttaching(args, to: joining.sessionId) }
        let session = TerminalSession(title: source.title, font: font)
        session.hostID = source.hostID
        session.showsFiles = files ?? source.showsFiles
        session.filesPath = folder
        add(session, placement)
        open(session, args)
    }

    // MARK: - Live on the host

    /// What a session's host is known by in `live`: a saved host's id, or for Quick Connect its address; nil for a
    /// local shell.
    func liveKey(of session: TerminalSession) -> String? {
        guard let args = session.args else { return nil }
        return session.hostID ?? "\(Self.quick)\(args["username"]?.string ?? "")@\(args["host"]?.string ?? "")"
    }

    /// What starts a Quick Connect host's key in `live`; the rest is what it is called, `user@host`.
    nonisolated static let quick = "quick:"

    /// A host's connected session: what the host is asked over, and what a join's connection is made like.
    func connectedSession(of key: String) -> TerminalSession? {
        sessions.values.first { liveKey(of: $0) == key && $0.isAttached && !$0.ended }
    }

    /// The persistent sessions on a sidebar row's host that are not open here, newest first: another device's, or
    /// this Mac's from before it quit. Read from the host itself, so nothing is synced and nothing leaves this Mac.
    /// This Mac's row has those of the Quick Connect hosts, whose sessions it lists.
    func liveRows(of row: String) -> [LiveRow] {
        let open = Set(sessions.values.compactMap(\.coreID))
        let keys = row == Self.thisMac ? live.keys.filter { $0.hasPrefix(Self.quick) }.sorted() : [row]
        return keys.flatMap { key in
            (live[key] ?? []).filter { !open.contains($0.sessionId) }.sorted { $0.created > $1.created }
                .map { LiveRow(key: key, session: $0) }
        }
    }

    /// The live row of that id, while it is listed.
    func liveRow(_ id: String) -> LiveRow? {
        live.keys.lazy.flatMap { self.liveRows(of: $0.hasPrefix(Self.quick) ? Self.thisMac : $0) }.first { $0.id == id }
    }

    /// Asks the host of `key`, or every host with a session, what is live on it: after a connect, after a close,
    /// and when the app comes to the front. A host with no connection left lists nothing; one that does not answer
    /// keeps what it listed.
    func refreshLive(_ key: String? = nil) {
        for key in key.map({ [$0] }) ?? Array(Set(sessions.values.compactMap(liveKey)).union(live.keys)) {
            guard let via = connectedSession(of: key)?.coreSession else {
                live[key] = nil
                continue
            }
            Task { if let found = try? await via.liveSessions() { live[key] = found } }
        }
    }

    /// A tab on a session live on the host: the same shell and scrollback, shared with whoever else has it open
    /// until one of them closes it, which ends it for all.
    func join(_ row: LiveRow) {
        duplicate(connectedSession(of: row.key), .tab, files: false, joining: row.session)
    }

    /// Ends a session live on the host without opening it, whoever has it open.
    func endLive(_ row: LiveRow) {
        guard let via = connectedSession(of: row.key)?.coreSession else { return }
        Task {
            if (try? await via.endLiveSession(sessionId: row.session.sessionId)) != true {
                failure = Failure(title: "Couldn’t End the Session", message: "The host did not confirm that it ended.")
            }
            refreshLive(row.key)
        }
    }

    /// Upstream `persistConnectAuth` (src/stores/sessionStore.ts:529), Quick Connect's "save to host": the username
    /// typed, and a typed key (`key:<id>`, `passphrase:<id>`) or password (`password:<id>`) in place of the host's.
    func persistConnectAuth(to host: Connection, _ form: ConnectForm, key: String?) async throws {
        var host = connections.first { $0.id == host.id } ?? host
        let username = form.username.trimmingCharacters(in: .whitespaces)
        if !username.isEmpty { host.username = username }
        var secrets = HostSecrets()
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), form.useKey, !key.isEmpty {
            (host.identityID, host.keyID, host.authType) = (nil, nil, .key)
            secrets = HostSecrets(privateKey: key, passphrase: form.passphrase.isEmpty ? nil : form.passphrase)
        } else if !form.useKey, !form.password.isEmpty {
            (host.identityID, host.keyID, host.authType) = (nil, nil, .password)
            secrets = HostSecrets(password: form.password)
        }
        try await save(host, secrets)
    }

    /// Upstream `connection_set_last_used` (commands/connections.rs:298).
    func markUsed(_ hostID: String) async throws {
        let stored: [Connection] = try await list(.connections)
        guard var host = stored.first(where: { $0.id == hostID }) else { return }
        let now = Self.timestamp()
        host.lastUsedAt = now
        host.clocks["last_used_at"] = now
        host.updatedAt = host.clocks.values.max() ?? now
        try await core.entitySave(kind: .connections, row: String(decoding: JSONEncoder().encode(host), as: UTF8.self))
    }

    static func typeName(_ type: ConnectionType) -> String {
        switch type {
        case .serial: "Serial"
        case .ftp: "FTP"
        case .webdav: "WebDAV"
        case .web: "Web"
        default: type.rawValue
        }
    }
}

/// A session live on a host and not open here, as the sidebar lists it under `key`'s host.
struct LiveRow: Identifiable {
    /// The host's key in `Workspace.live`.
    let key: String
    let session: LiveSession
    var id: String { "live:\(key):\(session.sessionId)" }
    /// A Quick Connect host's `user@host`: its rows are under This Mac, which is no name for it.
    var host: String? { key.hasPrefix(Workspace.quick) ? String(key.dropFirst(Workspace.quick.count)) : nil }
}

/// `value` as a JSON string, or null.
func nullable(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

func jsonString(_ object: JSONObject) throws -> String {
    String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
}

extension ErrorCode {
    /// Upstream's en `errors.<code>` (src/i18n/locales/en/errors.json), as `describeError` (src/services/backendErrors.ts:115)
    /// shows it. nil for the codes whose text takes parameters: the bridge drops them, so the core's own message shows.
    var text: String? {
        switch self {
        case .permissionDenied: "Permission denied"
        case .notFound: "No such file or directory"
        case .alreadyExists: "A file or folder with that name already exists"
        case .storageFull: "Not enough disk space or quota left"
        case .readOnlyFilesystem: "The file system is read-only"
        case .connectionRefused: "The host refused the connection — check the address and port, and that the service is running"
        case .hostUnreachable: "The host is unreachable — check the address and your network connection"
        case .timedOut: "Operation timed out"
        case .connectionLost: "The connection was lost"
        case .connectionLostResumable: "The connection was lost — retry the transfer to continue where it stopped"
        case .transferVerifyFailed: "The copy didn’t match the original, so it was discarded — retry to copy it again"
        case .transferSourceChanged: "The file kept changing while it was copied — retry once it has finished being written"
        case .sshKeyRejected: "Public key authentication rejected"
        case .sshPasswordRejected: "Password authentication rejected — check the username and password"
        case .sshPasswordExpired: "The server requires a new password — sign in once from a terminal and change it there"
        case .loginRejected: "The server rejected the username or password"
        case .resourceLocked: "The file is locked on the server — someone else may have it open"
        case .vaultLocked: "Vault is locked"
        case .vaultUnreadable: "This device’s vault cannot be opened with your key"
        case .vaultSignInRequired: "Team vaults require an active server connection. Sign in to continue."
        case .vaultReadOnly: "You don’t have write access to this vault. Ask a vault manager for a role that can make changes."
        case .vaultPermissionsUnavailable: "Unable to verify vault permissions because the keychain is unavailable. Try again."
        case .vaultPermissionsCorrupted: "Vault permission data is corrupted. Sign in again to refresh access."
        case .knockUdpViaProxy: "UDP knocks can’t go through a proxy. Use TCP steps or a direct connection for this host."
        case .deviceFileAccessOff: "File access is off on that device. Turn it on in Settings › Devices on the device."
        case .deviceAccessDenied: "The device declined the request to open its files."
        case .deviceApprovalTimedOut: "Nobody answered the request on the device in time."
        case .deviceBusy: "That device has too many file sessions open. Close one and try again."
        case .deviceUnreachable: "Can’t reach that device. Check that it’s on and on the same network."
        case .deviceAccessExpired: "Access to this device ended. Open it again to ask for permission."
        case .deviceReadOnly: "That device shares these folders read-only."
        case .deviceForgotten: "You forgot this device, so its files were closed."
        case .sshLegacyAlgorithmsRequired, .sshNoCommonAlgorithm, .sshPromptUnanswerable,
             .sshNoUsableAuthMethod, .sshAuthTimeout, .vaultRoleReadOnly: nil
        }
    }
}
