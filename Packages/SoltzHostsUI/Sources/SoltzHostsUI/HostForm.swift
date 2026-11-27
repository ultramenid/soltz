// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SoltzModel

/// The secrets a host form edits. They live in the secret store, never in the Connection JSON.
/// `nil` leaves the stored value as it is; an empty string clears it.
public struct HostSecrets: Equatable, Sendable {
    public var password: String?
    /// A key pasted into the form instead of a keychain key.
    public var privateKey: String?
    public var passphrase: String?
    public var proxyPassword: String?
    /// The knock ports in upstream `formatKnockSequence` form: "7000/tcp,8000/udp".
    public var knockSequence: String?
    /// Set on a duplicate: copy every secret stored for this connection id to the new record,
    /// as upstream `copyObjectSecrets` does (skipping serial hosts and inline keys of keychain-key hosts).
    public var copyFrom: String?

    public init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil,
                proxyPassword: String? = nil, knockSequence: String? = nil, copyFrom: String? = nil) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.proxyPassword = proxyPassword
        self.knockSequence = knockSequence
        self.copyFrom = copyFrom
    }
}

enum KnockProtocol: String, CaseIterable, Sendable {
    case tcp, udp
}

struct KnockStep: Identifiable, Hashable, Sendable {
    var id = UUID()
    var port: UInt16?
    var proto: KnockProtocol = .tcp
}

enum KnockIssue: Equatable {
    case empty, port, udpProxy, udpSystem

    var message: String {
        switch self {
        case .empty: "Add at least one port."
        case .port: "Ports must be between 1 and 65535."
        case .udpProxy: "UDP knocks can't go through this host's proxy. Use TCP steps or a direct connection."
        case .udpSystem: "UDP knocks fail if the system proxy is in use."
        }
    }
}

struct WebdavTarget: Equatable {
    var url: String
    var host: String
    var port: UInt16
    var secure: Bool
}

/// Editor state for one host: the record being edited plus what the form keeps beside it.
/// Rules from upstream `ConnectionForm.tsx`, `SerialConnectionForm.tsx`, `PortKnockPanel.tsx`,
/// `ProxyFields.tsx` and `utils/connectionType.ts`.
struct HostForm {
    static let types: [ConnectionType] = [.ssh, .serial, .ftp, .webdav, .web]
    static let proxyModes: [ProxyMode] = [.direct, .system, .socks5, .http, .https]
    static let baudRates: [UInt32] = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400, 460_800, 921_600]
    static let maxKnockSteps = 16
    static let knockDefaults = (delayMs: 200, settleMs: 500)

    /// The record being edited. Editing mutates it in place, so unknown JSON fields survive.
    var connection: Connection
    let isNew: Bool
    var tagsText: String
    var webdavURL: String
    var customBaud: Bool
    /// Log in with a key (a keychain key, or a key file) instead of the password, as New host's switch.
    var useKey: Bool
    /// Secrets typed this session; nil means untouched.
    var password: String?
    /// The text of the key file chosen this session, and the file's name to show.
    var privateKey: String?
    var keyFileName: String?
    var passphrase: String?
    var proxyPassword: String?
    // shortcut: the stored knock sequence is not loaded (no secret-store access here), so steps
    // start empty and replace it only once edited; add a secret loader to show it.
    var knockSteps: [KnockStep] = [] { didSet { knockEdited = true } }
    private(set) var knockEdited = false
    private let hadPortKnock: Bool
    /// The host is stored with a key file's text of its own.
    let hadInlineKey: Bool

    init(_ connection: Connection, isNew: Bool) {
        self.connection = connection
        self.isNew = isNew
        tagsText = connection.tags.joined(separator: ", ")
        webdavURL = connection.webdavURL ?? ""
        customBaud = connection.serialBaud.map { !Self.baudRates.contains($0) } ?? false
        useKey = connection.authType == .key
        hadPortKnock = connection.portKnock != nil
        hadInlineKey = !isNew && connection.authType == .key && connection.keyID == nil && connection.identityID == nil
    }

    // MARK: Fields with upstream side effects

    var type: ConnectionType {
        get { connection.connectionType }
        set {
            let previous = connection.connectionType
            if connection.username == HostRules.defaultUsername(previous) {
                connection.username = HostRules.defaultUsername(newValue)
            }
            if newValue != .webdav, newValue != .serial,
               previous == .webdav || connection.port == 0 || [22, 21, 443].contains(connection.port) {
                connection.port = HostRules.defaultPort(newValue)
            }
            connection.connectionType = newValue
        }
    }

    /// SSH accepts `user@host[:port]` and splits it.
    var host: String {
        get { connection.host }
        set {
            guard type == .ssh, let match = newValue.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /([^\s@]+)@([^\s@:]+)(?::(\d{1,5}))?/) else {
                connection.host = newValue
                return
            }
            connection.host = String(match.2)
            if connection.identityID == nil { connection.username = String(match.1) }
            if let port = match.3.flatMap({ UInt16($0) }), port > 0 { connection.port = port }
        }
    }

    /// Empty in the field means "use the type's default port".
    var port: UInt16? {
        get { connection.port == 0 ? nil : connection.port }
        set { connection.port = newValue ?? 0 }
    }

    /// Toggling HTTPS flips a default port to the other scheme's.
    var webSecure: Bool {
        get { connection.webSecure }
        set {
            if connection.port == Self.webDefaultPort(!newValue) { connection.port = Self.webDefaultPort(newValue) }
            connection.webSecure = newValue
        }
    }

    var anonymous: Bool {
        get { connection.username == "anonymous" }
        set { connection.username = newValue ? "anonymous" : "" }
    }

    /// Picking a keychain key drops a key file chosen this session.
    var keyID: String? {
        get { connection.keyID }
        set {
            connection.keyID = newValue
            if newValue != nil { (privateKey, keyFileName) = (nil, nil) }
        }
    }

    /// nil inherits the global proxy.
    var proxyMode: ProxyMode? {
        get { connection.proxy?.mode }
        set {
            if let newValue, connection.proxy != nil {
                connection.proxy?.mode = newValue
            } else {
                connection.proxy = newValue.map { make(["mode": .string($0.rawValue)]) }
            }
        }
    }

    var proxyIsCustom: Bool { proxyMode.map { [.socks5, .http, .https].contains($0) } ?? false }

    static func defaultProxyPort(_ mode: ProxyMode?) -> UInt16 {
        switch mode {
        case .socks5: 1080
        case .http: 8080
        default: 443
        }
    }

    /// Non-optional view of `proxy` for field bindings; only shown once a mode is set.
    var proxy: ProxyOverride {
        get { connection.proxy ?? make(["mode": .string(ProxyMode.direct.rawValue)]) }
        set { connection.proxy = newValue }
    }

    /// Non-optional view of `port_knock`; created on first edit.
    var knock: PortKnock {
        get { connection.portKnock ?? make(["enabled": false]) }
        set { connection.portKnock = newValue }
    }

    var baudPreset: UInt32? {
        get { customBaud ? nil : connection.serialBaud ?? 115_200 }
        set {
            customBaud = newValue == nil
            if let newValue { connection.serialBaud = newValue }
        }
    }

    // MARK: Validation

    var webdavTarget: WebdavTarget? { Self.parseWebdavURL(webdavURL) }

    /// Upstream `canSave`: the one required field per type, and New host's "a key login has a key". Ports are clamped
    /// as typed, so always valid.
    var missingRequired: String? {
        switch type {
        case .serial: (connection.serialPort ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a serial port." : nil
        case .webdav: webdavTarget == nil ? "Enter a valid server URL." : nil
        case .ssh where !connection.host.trimmingCharacters(in: .whitespaces).isEmpty:
            useKey && connection.identityID == nil && keyID == nil && !hasKeyText ? "Choose a key file." : nil
        case .ssh, .ftp, .web: connection.host.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a host." : nil
        default: nil
        }
    }

    /// A key file's text is at hand: chosen this session, or stored with the host.
    private var hasKeyText: Bool {
        privateKey.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? hadInlineKey
    }

    // shortcut: an inherited proxy is not resolved (no settings access), so UDP-through-proxy is
    // only caught for a host-level proxy; pass the global proxy mode in to check it too.
    func knockIssues(enabled: Bool) -> [KnockIssue] {
        guard enabled else { return [] }
        guard !knockSteps.isEmpty else { return [.empty] }
        var issues: [KnockIssue] = []
        if knockSteps.contains(where: { $0.port == nil }) { issues.append(.port) }
        if knockSteps.contains(where: { $0.proto == .udp }) {
            if proxyIsCustom { issues.append(.udpProxy) } else if proxyMode == .system { issues.append(.udpSystem) }
        }
        return issues
    }

    /// Upstream `editedKnockSequence`: only an edited, valid sequence is written.
    var editedKnockSequence: String? {
        guard knockEdited else { return nil }
        let issues = knockIssues(enabled: true)
        if issues.contains(.port) || (knock.enabled && issues.contains(.empty)) { return nil }
        return knockSteps.map { "\($0.port ?? 0)/\($0.proto.rawValue)" }.joined(separator: ",")
    }

    // MARK: Save

    /// The record and secrets to hand back. Fields the chosen type's upstream form does not submit
    /// are reset to their defaults, as Rust `merge_form_into_connection` does; unknown keys stay.
    func finalized(identities: [Identity]) -> (Connection, HostSecrets) {
        var c = connection
        var secrets = HostSecrets()
        c.name = Self.trimmedOrNil(c.name)
        c.tags = Self.parseTags(tagsText)
        c.notes = c.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        c.preCommand = Self.trimmedOrNil(c.preCommand)
        c.postCommand = Self.trimmedOrNil(c.postCommand)
        if let proxyHost = c.proxy?.host { c.proxy?.host = Self.trimmedOrNil(proxyHost) }

        switch c.connectionType {
        case .ssh:
            c.host = c.host.trimmingCharacters(in: .whitespaces)
            if c.port == 0 { c.port = 22 }
            if c.identityID != nil { c.keyID = nil }
            if let identity = identities.first(where: { $0.id == c.identityID }) {
                c.username = identity.username
                c.authType = identity.keyID == nil ? .password : .key
            } else {
                if !useKey { c.keyID = nil }
                c.authType = useKey ? .key : .password
            }
            if !(hadPortKnock || knock.enabled || !knockSteps.isEmpty) { c.portKnock = nil }
            Self.resetSerial(&c)
            Self.resetFileFields(&c, keeping: nil)
            // A key login leaves the stored password alone (it is not sent while there is a key).
            if !useKey || c.identityID != nil { secrets.password = password }
            if c.identityID == nil, c.keyID == nil {
                if useKey {
                    secrets.privateKey = privateKey
                    // A new key file does not keep the old one's passphrase.
                    secrets.passphrase = passphrase ?? (privateKey == nil ? nil : "")
                } else if hadInlineKey {
                    // Switched to Password: the stored key would still be offered, so it goes.
                    (secrets.privateKey, secrets.passphrase) = ("", "")
                }
            }
            secrets.proxyPassword = proxyPassword
            secrets.knockSequence = editedKnockSequence

        case .serial:
            c.host = ""
            c.port = 0
            c.username = ""
            c.authType = .password
            c.serialPort = Self.trimmedOrNil(c.serialPort)
            c.serialBaud = c.serialBaud.flatMap { $0 == 0 ? nil : $0 } ?? 115_200
            c.serialDataBits = c.serialDataBits ?? 8
            c.serialParity = c.serialParity ?? SerialParity.none
            c.serialStopBits = c.serialStopBits ?? 1
            c.serialFlowControl = c.serialFlowControl ?? SerialFlowControl.none
            c.serialAutoReconnect = c.serialAutoReconnect ?? true
            Self.resetSSH(&c, keepSessionCommands: true)
            Self.resetFileFields(&c, keeping: nil)

        case .ftp, .web, .webdav:
            let target = c.connectionType == .webdav ? webdavTarget : nil
            let proxy = c.connectionType == .webdav ? c.proxy : nil
            c.host = target?.host ?? c.host.trimmingCharacters(in: .whitespaces)
            c.port = target?.port ?? (c.port != 0 ? c.port : c.connectionType == .web ? Self.webDefaultPort(c.webSecure) : 21)
            c.authType = .password
            Self.resetSSH(&c, keepSessionCommands: false)
            Self.resetSerial(&c)
            Self.resetFileFields(&c, keeping: c.connectionType)
            c.webdavURL = target?.url
            c.proxy = proxy
            if c.connectionType != .web { secrets.password = password }
            if c.connectionType == .webdav { secrets.proxyPassword = proxyPassword }

        default:
            break  // A type from a newer upstream: leave its fields alone.
        }
        return (c, secrets)
    }

    private static func resetSSH(_ c: inout Connection, keepSessionCommands: Bool) {
        c.identityID = nil
        c.keyID = nil
        c.jumpHosts = []
        c.envVars = []
        c.agentForwarding = false
        c.legacyAlgorithms = false
        c.shellIntegration = nil
        c.keepalivePreset = nil
        c.persistSession = nil
        c.proxy = nil
        c.portKnock = nil
        if keepSessionCommands { return }
        c.preCommand = nil
        c.postCommand = nil
        c.preSnippetID = nil
        c.postSnippetID = nil
        c.askVarsEachTime = false
        c.terminalEncoding = nil
    }

    private static func resetSerial(_ c: inout Connection) {
        c.serialPort = nil
        c.serialBaud = nil
        c.serialDataBits = nil
        c.serialParity = nil
        c.serialStopBits = nil
        c.serialFlowControl = nil
        c.serialAutoReconnect = nil
    }

    private static func resetFileFields(_ c: inout Connection, keeping type: ConnectionType?) {
        if type != .ftp { c.ftpSecure = false }
        if type != .web { c.webSecure = false }
        if type != .webdav { c.webdavURL = nil }
    }

    // MARK: Helpers

    static func webDefaultPort(_ secure: Bool) -> UInt16 { secure ? 443 : 80 }

    static func trimmedOrNil(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // shortcut: tags are typed comma-separated, so a tag cannot contain a comma; use a token field if that matters.
    /// Trimmed, non-empty, first occurrence kept (upstream `TagSelector`).
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Upstream `parseWebdavUrl` (mirrors Rust `DavBase::parse`): http(s), a host, no credentials,
    /// query or fragment; the path gains a trailing slash and a default port is dropped.
    static func parseWebdavURL(_ raw: String) -> WebdavTarget? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("?"), !text.contains("#"), var url = URLComponents(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let secure = scheme == "https"
        let port = url.port ?? Int(webDefaultPort(secure))
        guard (1...65535).contains(port) else { return nil }
        url.scheme = scheme
        url.percentEncodedHost = url.percentEncodedHost?.lowercased()
        if port == Int(webDefaultPort(secure)) { url.port = nil }
        if !url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath += "/" }
        guard let string = url.string else { return nil }
        return WebdavTarget(url: string, host: host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                            port: UInt16(port), secure: secure)
    }
}
