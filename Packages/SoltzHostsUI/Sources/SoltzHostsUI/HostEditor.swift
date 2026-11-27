// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel
import UniformTypeIdentifiers

/// A sheet that edits one host, new or existing. It owns no persistence: Save hands the record
/// (edited in place, so unknown JSON fields survive) and the secrets typed to `onSave`.
/// The store stamps `updated_at` and `clocks`.
public struct HostEditor: View {
    @ViewState private var form: HostForm
    @ViewState private var serialPorts = HostEditor.detectedSerialPorts()
    @ViewState private var choosingKey = false
    @ViewState private var keyProblem: String?
    private let motion: Animation?
    private let compactWidth: CGFloat?
    private let storedKey: String?
    private let connections: [Connection]
    private let folders: [Folder]
    private let identities: [Identity]
    private let keys: [SshKey]
    private let actions: ((String?, @escaping () -> Void) -> AnyView)?
    private let onSave: (Connection, HostSecrets) -> Void
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - connection: the host to edit; nil starts a new one of `newType`, filed in `newFolderID`.
    ///   - connections: jump-host candidates.
    ///   - folders, identities, keys: picker choices, limited to the host's vault.
    ///   - compactWidth: the app's New host card's width. An SSH host then shows that card's rows only (label, host,
    ///     port, username, group, login) at that width; whatever else it has stays as stored. nil is the full editor.
    ///   - storedKey: what tells the key stored with the host from another (its type and comment, or fingerprint),
    ///     shown where a new host shows the file chosen.
    ///   - motion: the app's animation for rows that come and go with the Password / Key switch.
    ///   - actions: the app's own buttons under the form, given why Save is unavailable (nil when it is not) and
    ///     Save itself; nil keeps the system's toolbar.
    public init(
        connection: Connection?,
        newType: ConnectionType = .ssh,
        newFolderID: String? = nil,
        connections: [Connection] = [],
        folders: [Folder] = [],
        identities: [Identity] = [],
        keys: [SshKey] = [],
        compactWidth: CGFloat? = nil,
        storedKey: String? = nil,
        motion: Animation? = nil,
        actions: ((String?, @escaping () -> Void) -> AnyView)? = nil,
        onSave: @escaping (Connection, HostSecrets) -> Void
    ) {
        let folder = HostRules.hostFolders(folders).first { $0.id == newFolderID }
        _form = ViewState(initialValue: HostForm(connection ?? HostRules.newConnection(type: newType, in: folder),
                                             isNew: connection == nil))
        self.connections = connections
        self.folders = folders
        self.identities = identities
        self.keys = keys
        self.motion = motion
        self.compactWidth = compactWidth
        self.storedKey = storedKey
        self.actions = actions
        self.onSave = onSave
    }

    public var body: some View {
        if let actions {
            VStack(spacing: 0) {
                fields
                // The full form scrolls: room between its last row in view and the buttons.
                actions(form.missingRequired, save).padding(.top, compact ? 0 : 12)
            }
            .frame(width: compact ? compactWidth : nil)
        } else {
            fields
                .navigationTitle(form.isNew ? "New Host" : "Edit Host")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(form.missingRequired != nil)
                            .help(form.missingRequired ?? "")
                    }
                }
        }
    }

    private func save() {
        let (connection, secrets) = form.finalized(identities: identities)
        onSave(connection, secrets)
        dismiss()
    }

    private var compact: Bool { compactWidth != nil && form.type == .ssh }

    private var fields: some View {
        Form {
            general
            switch form.type {
            case .ssh where compact:
                authentication
            case .ssh:
                authentication
                proxy
                jumpHosts
                portKnocking
                environment
                session
                advanced
            case .serial:
                serialSettings
                session
            case .ftp, .webdav:
                credentials
                if form.type == .webdav { proxy }
            default:
                EmptyView()
            }
            if !compact {
                Section("Notes") {
                    TextEditor(text: $form.connection.notes.orEmpty)
                        .scrollContentBackground(.hidden)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 6))
                        .frame(minHeight: 80)
                        .accessibilityLabel("Notes")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(compact)
        .fixedSize(horizontal: false, vertical: compact)
        .frame(minWidth: compact ? nil : 520, idealWidth: compact ? nil : 580,
               minHeight: compact ? nil : 520, idealHeight: compact ? nil : 720)
        .animation(motion, value: form.useKey)
        // Opens where keys live; they are in a hidden folder.
        .fileDialogDefaultDirectory(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh"))
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            do {
                form.privateKey = try Self.readKey(url)
                (form.keyFileName, keyProblem) = (url.lastPathComponent, nil)
            } catch {
                keyProblem = error.localizedDescription
            }
        }
    }

    // MARK: Sections

    private var general: some View {
        Section {
            if !compact {
                Picker("Type", selection: $form.type) {
                    ForEach(Self.options(HostForm.types, current: form.type), id: \.self) { Text(Self.title($0)).tag($0) }
                }
            }
            TextField("Label", text: $form.connection.name.orEmpty,
                      prompt: Text(form.type == .serial ? "My Device (optional)" : "My Server (optional)"))
            switch form.type {
            case .serial:
                TextField("Serial Port", text: $form.connection.serialPort.orEmpty, prompt: Text("/dev/cu.usbserial"))
                if !serialPorts.isEmpty {
                    Menu("Detected Ports") {
                        ForEach(serialPorts, id: \.self) { port in Button(port) { form.connection.serialPort = port } }
                    }
                }
                Picker("Baud Rate", selection: $form.baudPreset) {
                    ForEach(HostForm.baudRates, id: \.self) { Text($0.formatted()).tag(Optional($0)) }
                    Text("Custom").tag(UInt32?.none)
                }
                if form.customBaud {
                    TextField("Custom Baud Rate", text: $form.connection.serialBaud.digits(1...UInt32.max), prompt: Text("115200"))
                }
            case .webdav:
                TextField("Server URL", text: $form.webdavURL,
                          prompt: Text("https://cloud.example.com/remote.php/dav/files/me/"))
                if let target = form.webdavTarget {
                    if !target.secure {
                        Self.warning("Not encrypted: your password is sent in the clear. Use https:// if the server supports it.")
                    }
                } else if !form.webdavURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Self.warning("Enter an http:// or https:// address, without a username, password, ? or #.")
                }
            default:
                TextField("Host", text: $form.host, prompt: Text("192.168.1.1"))
                TextField("Port", text: $form.port.digits(1...65535), prompt: Text(String(
                    form.type == .web ? HostForm.webDefaultPort(form.webSecure) : HostRules.defaultPort(form.type))))
                if form.type == .web { Toggle("Use HTTPS", isOn: $form.webSecure) }
            }
            if [.ssh, .ftp, .webdav].contains(form.type) {
                if let identity = selectedIdentity {
                    LabeledContent("Username", value: identity.username)
                } else {
                    TextField("Username", text: $form.connection.username, prompt: Text(HostRules.defaultUsername(form.type)))
                }
            }
            if !compact { TextField("Tags", text: $form.tagsText, prompt: Text("Comma-separated")) }
            let groups = HostRules.folderChoices(folders, vaultID: form.connection.vaultID)
            // As New host: no Group row while there are no groups.
            if !compact || !groups.isEmpty || form.connection.folderID != nil {
                Picker("Group", selection: $form.connection.folderID) {
                    Text("None").tag(String?.none)
                    Self.choices(groups, current: form.connection.folderID, missing: "Missing Group")
                }
            }
        }
    }

    private var authentication: some View {
        Section {
            // Shown only with something to pick: a vault from upstream may hold identities and keys.
            if !identityChoices.isEmpty || form.connection.identityID != nil {
                Picker("Identity", selection: $form.connection.identityID) {
                    Text("None").tag(String?.none)
                    Self.choices(identityChoices, current: form.connection.identityID, missing: "Unavailable Identity")
                }
            }
            if let identity = selectedIdentity {
                LabeledContent("Signs In With", value: identity.keyID == nil ? "Password" : "SSH key")
            } else if form.connection.identityID == nil {
                // New host's login rows: the switch, then a password, or a key file and its passphrase.
                LabeledContent("Log in with") {
                    Picker("Log in with", selection: $form.useKey) {
                        Text("Password").tag(false)
                        Text("Key").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: Self.fieldWidth)
                }
                if form.useKey {
                    if !keyChoices.isEmpty || form.keyID != nil {
                        Picker("SSH Key", selection: $form.keyID) {
                            Text("None").tag(String?.none)
                            Self.choices(keyChoices, current: form.keyID, missing: "Unavailable Key")
                        }
                    }
                    if form.keyID == nil {
                        LabeledContent("Key file") {
                            Button { choosingKey = true } label: {
                                Text(form.keyFileName ?? (form.hadInlineKey ? storedKey ?? "Stored key" : "Choose…"))
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: Self.fieldWidth + 36) // room for a key's type and comment
                            }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                            .help(form.keyFileName == nil && form.hadInlineKey
                                  ? "\(storedKey ?? "The stored key") is kept; choose a file to replace it"
                                  : "Choose a private key, such as ~/.ssh/id_ed25519")
                        }
                        if let keyProblem { Self.warning(keyProblem) }
                        SecureField("Passphrase", text: $form.passphrase.typed,
                                    prompt: Text(form.keyFileName == nil && form.hadInlineKey ? "Unchanged" : "If the key has one"))
                    }
                } else {
                    SecureField("Password", text: $form.password.typed, prompt: Text(form.isNew ? "Asked later if empty" : "Unchanged"))
                }
            }
        } footer: {
            if !form.isNew && !compact { Text("Stored secrets are not shown. Leave a field empty to keep what is stored.") }
        }
    }

    private var credentials: some View {
        Section("Credentials") {
            SecureField("Password", text: $form.password.typed, prompt: secretPrompt)
            if form.type == .ftp {
                Toggle("Explicit FTPS (AUTH TLS)", isOn: $form.connection.ftpSecure)
                Toggle("Anonymous Login", isOn: $form.anonymous)
            }
        }
    }

    private var proxy: some View {
        Section("Proxy") {
            Picker("Proxy", selection: $form.proxyMode) {
                Text("Inherit from Settings").tag(ProxyMode?.none)
                ForEach(Self.options(HostForm.proxyModes, current: form.proxyMode), id: \.self) {
                    Text(Self.title($0)).tag(Optional($0))
                }
            }
            if form.proxyIsCustom {
                TextField("Proxy Host", text: $form.proxy.host.orEmpty, prompt: Text("proxy.example.com"))
                if (form.connection.proxy?.host ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    Self.warning("Proxy is set to \(Self.title(form.proxy.mode)) but has no host.")
                }
                TextField("Proxy Port", text: $form.proxy.port.digits(1...65535),
                          prompt: Text(String(HostForm.defaultProxyPort(form.proxyMode))))
                TextField("Proxy Username", text: $form.proxy.username.orEmpty, prompt: Text("Optional"))
                SecureField("Proxy Password", text: $form.proxyPassword.typed, prompt: secretPrompt)
            }
        }
    }

    private var jumpHosts: some View {
        Section {
            ForEach(form.connection.jumpHosts) { hop in
                let target = connections.first { $0.id == hop.connectionID && $0.deletedAt == nil }
                HStack {
                    VStack(alignment: .leading) {
                        Text(target.map(HostRules.displayName) ?? "\(hop.username ?? "?")@\(hop.host ?? "?")")
                        Text(target.map { "\($0.username)@\($0.host):\($0.port)" }
                             ?? "\(hop.username ?? "?")@\(hop.host ?? "?"):\(hop.port ?? 22)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RowControls(id: hop.id, items: $form.connection.jumpHosts)
                }
            }
            Menu("Add Jump Host") {
                ForEach(jumpCandidates) { c in
                    Button(HostRules.displayName(c)) {
                        form.connection.jumpHosts.append(make(["id": .string(HostRules.newID()), "connection_id": .string(c.id)]))
                    }
                }
            }
            .disabled(jumpCandidates.isEmpty)
        } header: {
            Text("Jump Hosts")
        } footer: {
            Text(form.connection.jumpHosts.isEmpty
                 ? "Add hosts to connect through before the final destination."
                 : "Connected in order before reaching this host.")
        }
    }

    private var portKnocking: some View {
        Section {
            Toggle("Knock Before Connecting", isOn: $form.knock.enabled)
            ForEach($form.knockSteps) { $step in
                HStack {
                    TextField("Knock Port", text: $step.port.digits(1...65535), prompt: Text("Port"))
                    Picker("Protocol", selection: $step.proto) {
                        ForEach(KnockProtocol.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    RowControls(id: step.id, items: $form.knockSteps)
                }
            }
            Button("Add Port") { form.knockSteps.append(KnockStep()) }
                .disabled(form.knockSteps.count >= HostForm.maxKnockSteps)
            TextField("Delay Between Knocks (ms)", text: $form.knock.delayMs.digits(0...999_999),
                      prompt: Text(String(HostForm.knockDefaults.delayMs)))
            TextField("Wait After Last Knock (ms)", text: $form.knock.settleMs.digits(0...999_999),
                      prompt: Text(String(HostForm.knockDefaults.settleMs)))
            TextField("Firewall Window (s)", text: $form.knock.windowSecs.digits(0...99_999), prompt: Text("None"))
            if form.isNew || form.knockEdited {
                ForEach(form.knockIssues(enabled: form.knock.enabled), id: \.message) { Self.warning($0.message) }
            }
        } header: {
            Text("Port Knocking")
        } footer: {
            Text(form.isNew || form.knockEdited
                 ? "Sent from this Mac, through this host's proxy, before every SSH, SFTP and port-forward connection."
                 : "The stored sequence is kept unless you add ports here, which replaces it.")
        }
    }

    private var environment: some View {
        Section {
            ForEach($form.connection.envVars) { $variable in
                HStack {
                    TextField("Variable Name", text: $variable.key, prompt: Text("KEY")).labelsHidden()
                    Text("=").foregroundStyle(.secondary)
                    TextField("Variable Value", text: $variable.value, prompt: Text("value")).labelsHidden()
                    RowControls(id: variable.id, items: $form.connection.envVars, reorders: false)
                }
            }
            Button("Add Variable") {
                form.connection.envVars.append(make(["id": .string(HostRules.newID()), "key": "", "value": ""]))
            }
        } header: {
            Text("Environment Variables")
        } footer: {
            Text("Set in the remote session environment when connecting.")
        }
    }

    private var session: some View {
        Section {
            command("Pre-Command", text: $form.connection.preCommand.orEmpty, snippet: $form.connection.preSnippetID,
                    prompt: "Session pre-command")
            command("Post-Command", text: $form.connection.postCommand.orEmpty, snippet: $form.connection.postSnippetID,
                    prompt: "Session post-command")
            if form.connection.preSnippetID != nil || form.connection.postSnippetID != nil {
                Toggle("Ask for Variables Each Time", isOn: $form.connection.askVarsEachTime)
            }
            Picker("Encoding", selection: $form.connection.terminalEncoding) {
                Text("UTF-8 (default)").tag(String?.none)
                ForEach(Self.encodings, id: \.group) { group in
                    Section(group.group) {
                        ForEach(group.options, id: \.value) { Text($0.title).tag(Optional($0.value)) }
                    }
                }
                if let current = form.connection.terminalEncoding,
                   !Self.encodings.contains(where: { $0.options.contains { $0.value == current } }) {
                    Text(current).tag(Optional(current))
                }
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Commands run in the session after it opens, and when the tab closes.")
        }
    }

    private var advanced: some View {
        Section("Advanced") {
            Picker("Keepalive", selection: $form.connection.keepalivePreset) {
                Text("Inherit from Settings").tag(KeepalivePreset?.none)
                ForEach(Self.options([.fast, .balanced, .tolerant, .off], current: form.connection.keepalivePreset), id: \.self) {
                    Text(Self.title($0)).tag(Optional($0))
                }
            }
            Picker("Persistent Session", selection: $form.connection.persistSession) { Self.inheritOnOff }
            Picker("Shell Integration", selection: $form.connection.shellIntegration) { Self.inheritOnOff }
            Toggle("Agent Forwarding", isOn: $form.connection.agentForwarding)
            Toggle("Legacy Algorithms", isOn: $form.connection.legacyAlgorithms)
                .help("Allow weak legacy algorithms (diffie-hellman-group1-sha1, 3des-cbc, hmac-sha1, …) for old devices such as legacy Cisco IOS.")
            Toggle("Reachability Check", isOn: $form.connection.pingDisabled.inverted)
        }
    }

    private var serialSettings: some View {
        Section("Serial") {
            Picker("Data Bits", selection: $form.connection.serialDataBits.or(8)) {
                ForEach(Self.options([5, 6, 7, 8], current: form.connection.serialDataBits), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Stop Bits", selection: $form.connection.serialStopBits.or(1)) {
                ForEach(Self.options([1, 2], current: form.connection.serialStopBits), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Parity", selection: $form.connection.serialParity.or(SerialParity.none)) {
                ForEach(Self.options([.none, .even, .odd], current: form.connection.serialParity), id: \.self) {
                    Text(Self.title($0)).tag($0)
                }
            }
            Picker("Flow Control", selection: $form.connection.serialFlowControl.or(SerialFlowControl.none)) {
                ForEach(Self.options([.none, .xonXoff, .rtsCts], current: form.connection.serialFlowControl), id: \.self) {
                    Text(Self.title($0)).tag($0)
                }
            }
            Toggle("Auto-Reconnect", isOn: $form.connection.serialAutoReconnect.or(true))
                .help("Reopen the port automatically after a drop. Turn this off for boards you reflash.")
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func command(_ title: String, text: Binding<String>, snippet: Binding<String?>, prompt: String) -> some View {
        // shortcut: a snippet chosen in upstream is kept and can be dropped, not picked; pass snippets in to pick one.
        if snippet.wrappedValue != nil {
            LabeledContent(title) {
                Button("Use Inline Command") { snippet.wrappedValue = nil }
            }
        } else {
            TextField(title, text: text, prompt: Text(prompt))
        }
    }

    private var secretPrompt: Text { Text(form.isNew ? "Optional" : "Unchanged") }

    private var selectedIdentity: Identity? {
        identities.first { $0.id == form.connection.identityID && $0.deletedAt == nil }
    }

    /// Live identities and keys of the host's vault (upstream `useVaultScopedItems`).
    private var identityChoices: [(id: String, label: String)] {
        identities.filter { $0.deletedAt == nil && $0.vaultID == form.connection.vaultID }
            .map { (id: $0.id, label: $0.name ?? $0.username) }
    }

    private var keyChoices: [(id: String, label: String)] {
        keys.filter { $0.deletedAt == nil && $0.vaultID == form.connection.vaultID }
            .map { (id: $0.id, label: $0.name ?? $0.keyType ?? $0.id) }
    }

    /// Same vault, SSH, not this host, not already in the chain (upstream `HostPickerPanel` with `excludeId`).
    private var jumpCandidates: [Connection] {
        HostRules.sorted(connections.filter { c in
            c.deletedAt == nil && c.id != form.connection.id && c.vaultID == form.connection.vaultID
                && c.connectionType == .ssh && !form.connection.jumpHosts.contains { $0.connectionID == c.id }
        }, by: .nameAscending)
    }

    // MARK: Static helpers

    /// The width of the Password / Key switch: the app's `Theme.fieldWidth`, which this package cannot see.
    static let fieldWidth: CGFloat = 154

    /// The key file's text, which is what the core takes.
    public nonisolated static func readKey(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Key files are a few kilobytes: nothing big, and nothing that is not a file (a pipe would never end), is read.
        let about = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard about.isRegularFile == true, about.fileSize ?? 0 <= 1_000_000 else {
            throw KeyFileProblem(errorDescription: "“\(url.lastPathComponent)” is not a key file.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    struct KeyFileProblem: LocalizedError {
        let errorDescription: String?
    }

    static func detectedSerialPorts() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
    }

    static func warning(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
    }

    /// `list`, plus the current value when it is one this build does not know.
    static func options<T: Hashable>(_ list: [T], current: T?) -> [T] {
        guard let current, !list.contains(current) else { return list }
        return list + [current]
    }

    @ViewBuilder
    static func choices(_ list: [(id: String, label: String)], current: String?, missing: String) -> some View {
        ForEach(list, id: \.id) { Text($0.label).tag(Optional($0.id)) }
        if let current, !list.contains(where: { $0.id == current }) {
            Text(missing).tag(Optional(current))
        }
    }

    @ViewBuilder
    static var inheritOnOff: some View {
        Text("Inherit from Settings").tag(Bool?.none)
        Text("On").tag(Bool?.some(true))
        Text("Off").tag(Bool?.some(false))
    }

    static func title(_ type: ConnectionType) -> String {
        switch type {
        case .ssh: "SSH / SFTP"
        case .serial: "Serial"
        case .ftp: "FTP"
        case .webdav: "WebDAV"
        case .web: "Web (HTTP/HTTPS)"
        default: type.rawValue
        }
    }

    static func title(_ mode: ProxyMode) -> String {
        switch mode {
        case .direct: "Direct"
        case .system: "System"
        case .socks5: "SOCKS5"
        case .http: "HTTP"
        case .https: "HTTPS"
        default: mode.rawValue
        }
    }

    /// Upstream `KEEPALIVE_PRESETS` labels with their detection times.
    static func title(_ preset: KeepalivePreset) -> String {
        switch preset {
        case .fast: "Fast (~4 s)"
        case .balanced: "Balanced (~9 s)"
        case .tolerant: "Tolerant (~20 s)"
        case .off: "Off"
        default: preset.rawValue
        }
    }

    static func title(_ parity: SerialParity) -> String {
        switch parity {
        case .none: "None"
        case .even: "Even"
        case .odd: "Odd"
        default: parity.rawValue
        }
    }

    static func title(_ flow: SerialFlowControl) -> String {
        switch flow {
        case .none: "None"
        case .xonXoff: "XON/XOFF"
        case .rtsCts: "RTS/CTS"
        default: flow.rawValue
        }
    }

    /// Upstream `EncodingSelector` groups; UTF-8 is the unset default.
    static let encodings: [(group: String, options: [(value: String, title: String)])] = [
        ("Unicode", [("utf-16le", "UTF-16 LE"), ("utf-16be", "UTF-16 BE")]),
        ("Western European", [("iso-8859-1", "ISO-8859-1 (Latin-1)"), ("iso-8859-15", "ISO-8859-15 (Latin-9)"), ("windows-1252", "Windows-1252")]),
        ("Central European", [("iso-8859-2", "ISO-8859-2 (Latin-2)"), ("windows-1250", "Windows-1250")]),
        ("Cyrillic", [("iso-8859-5", "ISO-8859-5"), ("koi8-r", "KOI8-R"), ("koi8-u", "KOI8-U"), ("windows-1251", "Windows-1251"), ("ibm866", "IBM866")]),
        ("Greek", [("iso-8859-7", "ISO-8859-7"), ("windows-1253", "Windows-1253")]),
        ("Hebrew", [("iso-8859-8", "ISO-8859-8"), ("windows-1255", "Windows-1255")]),
        ("Arabic", [("iso-8859-6", "ISO-8859-6"), ("windows-1256", "Windows-1256")]),
        ("Turkish", [("iso-8859-9", "ISO-8859-9"), ("windows-1254", "Windows-1254")]),
        ("Baltic", [("iso-8859-13", "ISO-8859-13"), ("windows-1257", "Windows-1257")]),
        ("Vietnamese", [("windows-1258", "Windows-1258")]),
        ("Chinese Simplified", [("gbk", "GBK / GB2312"), ("gb18030", "GB18030")]),
        ("Chinese Traditional", [("big5", "Big5")]),
        ("Japanese", [("shift-jis", "Shift-JIS"), ("euc-jp", "EUC-JP")]),
        ("Korean", [("euc-kr", "EUC-KR")]),
    ]
}

/// Move up, move down and remove buttons for a row of an ordered list.
struct RowControls<Item: Identifiable>: View {
    let id: Item.ID
    @Binding var items: [Item]
    var reorders = true

    var body: some View {
        let index = items.firstIndex { $0.id == id }
        HStack(spacing: 4) {
            if reorders {
                Button("Move Up", systemImage: "chevron.up") {
                    if let index, index > 0 { items.swapAt(index, index - 1) }
                }
                .disabled(index == 0)
                Button("Move Down", systemImage: "chevron.down") {
                    if let index, index < items.count - 1 { items.swapAt(index, index + 1) }
                }
                .disabled(index == items.count - 1)
            }
            Button("Remove", systemImage: "minus.circle") {
                if let index { items.remove(at: index) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
