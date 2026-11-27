// SPDX-License-Identifier: AGPL-3.0-only
import SoltzHostsUI
import SoltzModel
import SwiftUI
import UniformTypeIdentifiers

/// What the New host card asks for, and Edit… shows again by the same names and in the same order (`HostEditor`,
/// compact): a label, where an SSH host is, who logs in, its group, and a password or a key file.
struct NewHostForm: Identifiable {
    let id = UUID()
    /// The name it goes by on Home; empty shows the host.
    var label = ""
    var host = ""
    var user = ""
    var port = "22"
    /// Log in with `keyFile` instead of `password`.
    var useKey = false
    var password = ""
    var keyFile: URL?
    var passphrase = ""
    /// The group it is filed in; nil is none.
    var groupID: String?

    /// A pasted `user@host:port` (or `user@host`, `host:port`) goes to its three fields.
    mutating func spreadAddress() {
        guard host.contains("@") || host.contains(":"),
              let match = host.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(?:([^\s@]+)@)?([^\s@:]+)(?::(\d{1,5}))?/)
        else { return }
        if let pasted = match.1 { user = String(pasted) }
        if let pasted = match.3 { port = String(pasted) }
        host = String(match.2)
    }

    /// A host or user name as typed by a person: not an option in disguise (a leading "-"), and nothing invisible that
    /// would show as another name in a title or a trust question (control and format characters).
    static func isPlain(_ text: String) -> Bool {
        !text.hasPrefix("-") && !text.unicodeScalars.contains {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    /// Why Connect is unavailable; nil when the host can be saved.
    var problem: String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "Enter the host." }
        if host.contains(where: \.isWhitespace) { return "A host has no spaces." }
        if !Self.isPlain(host) || !Self.isPlain(user) { return "The host and user cannot start with “-” or hold control characters." }
        if !(1...65535).contains(Int(port.trimmingCharacters(in: .whitespaces)) ?? 0) { return "Ports are between 1 and 65535." }
        if useKey && keyFile == nil { return "Choose a key file." }
        return nil
    }

    /// The new host and its secrets as the full editor's Save hands them to `Workspace.save`, which stamps it. Reads
    /// the key file; with no password typed the secrets are empty and the login prompt asks.
    func host(id: String = UUID().uuidString.lowercased()) throws -> (Connection, HostSecrets) {
        if let problem { throw ConnectProblem(problem) }
        let key = try useKey ? keyFile.map(HostEditor.readKey) : nil
        let user = user.trimmingCharacters(in: .whitespaces)
        var json: JSONObject = [
            "id": .string(id), "host": .string(host.trimmingCharacters(in: .whitespaces)),
            "port": .int(Int64(port.trimmingCharacters(in: .whitespaces)) ?? 22),
            "username": .string(user.isEmpty ? "root" : user), "auth_type": key == nil ? "password" : "key", "tags": [], "created_at": "",
            "updated_at": "", "clocks": [:], "connection_type": "ssh", "vault_id": .string(Workspace.personalVault),
            "web_secure": true, "persist_session": true, "agent_forwarding": false,
        ]
        if let groupID { json["folder_id"] = .string(groupID) }
        var connection = try Connection(json: json)
        let label = label.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { connection.name = label }
        return (connection,
                HostSecrets(password: key == nil && !password.isEmpty ? password : nil, privateKey: key,
                            passphrase: key != nil && !passphrase.isEmpty ? passphrase : nil))
    }
}

extension Workspace {
    /// The New host card's Connect: the host saved with the login typed, through the full editor's storage call, then
    /// connected. With no password or key typed the login prompt asks, saving its answer to the host. Returns the
    /// saved host; a key file that cannot be read is shown and nothing is saved.
    @discardableResult
    func create(_ form: NewHostForm) async -> Connection? {
        var built: (host: Connection, secrets: HostSecrets)?
        guard await perform("Couldn’t Save the Host", {
            let new = try form.host()
            built = new
            try await save(new.0, new.1)
        }), let built, let saved = connections.first(where: { $0.id == built.host.id })
        else { return nil }
        newHost = nil
        if built.secrets.password == nil && built.secrets.privateKey == nil {
            // shortcut: lets the sheet finish closing so the login prompt's sheet can open; present both from one
            // sheet if the pause ever shows.
            try? await Task.sleep(for: .milliseconds(350))
        }
        if connect(to: saved) == nil { connectForm?.save = true }
        return saved
    }
}

/// A compact card for a new SSH host: host, user, port, and a password or a key file; Connect saves and connects it.
struct NewHostView: View {
    @ViewState var form: NewHostForm
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var saving = false
    @ViewState private var choosingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New host").font(Theme.title).padding(.horizontal, Theme.sheetInset).padding(.top, 20)
            Form {
                Section {
                    field("Label", $form.label, prompt: "My Server (optional)")
                    field("Host", $form.host, prompt: "192.168.1.1")
                        .onChange(of: form.host) { form.spreadAddress() }
                    field("Port", $form.port, prompt: "22")
                    field("Username", $form.user, prompt: "root")
                    let groups = workspace.folders.filter { $0.objectType == .connection && $0.deletedAt == nil }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    if !groups.isEmpty {
                        LabeledContent("Group") {
                            Picker("Group", selection: $form.groupID) {
                                Text("None").tag(String?.none)
                                ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                Section {
                    LabeledContent("Log in with") {
                        Picker("Log in with", selection: $form.useKey) {
                            Text("Password").tag(false)
                            Text("Key").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: Theme.fieldWidth)
                    }
                    if form.useKey {
                        LabeledContent("Key file") {
                            Button { choosingKey = true } label: {
                                Text(form.keyFile?.lastPathComponent ?? "Choose…").lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: Theme.fieldWidth - 24)
                            }
                            .buttonStyle(Pill(height: 22, font: Theme.body))
                            .help(form.keyFile?.path(percentEncoded: false) ?? "Choose a private key, such as ~/.ssh/id_ed25519")
                        }
                        secure("Passphrase", $form.passphrase, prompt: "If the key has one")
                    } else {
                        secure("Password", $form.password, prompt: "Asked later if empty")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(saving)

            SheetActions(problem: form.host.isEmpty ? nil : form.problem, action: "Connect",
                         disabled: form.problem != nil || saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    await workspace.create(form)
                    saving = false
                }
            }
        }
        .frame(width: Theme.sheetWidth)
        .glassSheet()
        .animation(Theme.motion, value: form.useKey)
        // Opens where keys live; they are in a hidden folder.
        .fileDialogDefaultDirectory(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh"))
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { form.keyFile = url }
        }
    }

    /// The grouped form's own row, as the full editor's fields are: the label, and the value typed at the right.
    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        TextField(label, text: text, prompt: Text(prompt))
    }

    private func secure(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        SecureField(label, text: text, prompt: Text(prompt))
    }
}
