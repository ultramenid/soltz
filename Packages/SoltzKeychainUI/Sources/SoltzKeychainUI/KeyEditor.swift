// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel

/// A sheet that imports, generates or edits one SSH key. It owns no persistence: Save hands the
/// record (edited in place, so unknown JSON fields survive) and the key material typed to `onSave`.
/// Stored secrets are never shown; an existing key's public half and fingerprint are, with Copy
/// and Export. The store stamps `updated_at` and `clocks`.
public struct KeyEditor: View {
    @ViewState private var form: KeyForm
    @ViewState private var generating: Bool
    @ViewState private var storedPublicKey: String?
    @ViewState private var loadingPublicKey = false
    @ViewState private var problem: String?
    private let connections: [Connection]
    private let identities: [Identity]
    private let folders: [Folder]
    private let operations: KeyOperations
    private let onSave: (SshKey, KeySecrets) -> Void
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - key: the key to edit; nil starts a new one, filed in `newFolderID` and its vault.
    ///   - generate: a new key opens on Generate instead of Import.
    ///   - connections, identities: for the "Used By" list.
    ///   - folders: folder choices, limited to the key's vault.
    public init(
        key: SshKey?,
        generate: Bool = false,
        newFolderID: String? = nil,
        connections: [Connection] = [],
        identities: [Identity] = [],
        folders: [Folder] = [],
        operations: KeyOperations,
        onSave: @escaping (SshKey, KeySecrets) -> Void
    ) {
        let folder = KeychainRules.keychainFolders(folders).first { $0.id == newFolderID }
        _form = ViewState(initialValue: KeyForm(key ?? KeychainRules.newKey(in: folder), isNew: key == nil))
        _generating = ViewState(initialValue: key == nil && generate)
        self.connections = connections
        self.identities = identities
        self.folders = folders
        self.operations = operations
        self.onSave = onSave
    }

    public var body: some View {
        Form {
            Section {
                TextField("Label", text: $form.key.name.orEmpty,
                          prompt: Text(KeychainRules.defaultKeyName(type: form.info.type ?? form.key.keyType)))
                TextField("Tags", text: $form.tagsText, prompt: Text("Comma-separated"))
                FolderPicker(folderID: $form.key.folderID, folders: folders, vaultID: form.key.vaultID)
            }
            if form.isNew {
                Picker("Source", selection: $generating) {
                    Text("Import").tag(false)
                    Text("Generate").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if generating {
                KeyGenSections(operations: operations) { generated, passphrase in
                    form.apply(generated, passphrase: passphrase)
                    generating = false
                }
            } else {
                Section {
                    KeyMaterialFields(form: $form)
                } header: {
                    Text(form.isNew ? "Key Material" : "Replace Key Material")
                } footer: {
                    if !form.isNew { Text("Stored secrets are not shown. Leave a field empty to keep what is stored.") }
                }
            }
            if !form.isNew {
                publicKeySection
                let usage = KeychainRules.usage(ofKey: form.key.id, connections: connections, identities: identities)
                UsedBySection(hosts: usage.hosts, identities: usage.identities)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(form.isNew ? (generating ? "Generate Key Pair" : "Import Key") : "Edit Key")
        .frame(minWidth: 520, idealWidth: 580, minHeight: 480, idealHeight: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let (key, secrets) = form.finalized()
                    onSave(key, secrets)
                    dismiss()
                }
                .disabled(generating || form.missingRequired != nil)
                .help(generating ? "Generate the key first." : form.missingRequired ?? "")
            }
        }
        .task {
            guard !form.isNew else { return }
            loadingPublicKey = true
            storedPublicKey = try? await operations.publicKey(form.key)
            loadingPublicKey = false
        }
        .alert("Couldn't Complete", isPresented: $problem.isPresent(), presenting: problem) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private var publicKeySection: some View {
        Section("Public Key") {
            if let pub = storedPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
                Text(pub)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Public key")
                LabeledContent("Fingerprint") {
                    Text(KeyText.fingerprint(pub) ?? "Not a valid public key")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy Public Key") { KeyActions.copy(pub) }
                    if let fingerprint = KeyText.fingerprint(pub) {
                        Button("Copy Fingerprint") { KeyActions.copy(fingerprint) }
                    }
                }
            } else if loadingPublicKey {
                ProgressView().controlSize(.small)
            } else {
                Text(KeyActions.noPublicKey).foregroundStyle(.secondary)
            }
            HStack {
                Button("Export Public Key…") { export(publicHalf: true) }
                    .disabled(storedPublicKey == nil)
                Button("Export Private Key…") { export(publicHalf: false) }
            }
        }
    }

    private func export(publicHalf: Bool) {
        let key = form.key
        Task { problem = await KeyActions.export(key, publicHalf: publicHalf, operations) }
    }
}

/// Private key, passphrase and public key fields with upstream's live checks, plus import from a file.
/// Shared by the key editor and the identity editor's inline key.
struct KeyMaterialFields: View {
    @Binding var form: KeyForm
    @ViewState private var choosingFile = false
    @ViewState private var fileProblem: String?

    var body: some View {
        let info = form.info
        LabeledContent("Private Key") {
            TextEditor(text: $form.privateKey.orEmpty)
                .scrollContentBackground(.hidden)
                .background(.fill.quaternary, in: .rect(cornerRadius: 6))
                .font(.callout.monospaced())
                .frame(minHeight: 110)
                .accessibilityLabel("Private key")
        }
        if KeychainRules.nonEmpty(form.privateKey) != nil {
            if !info.valid {
                warning(info.error ?? "Invalid key")
            } else {
                Label(status(info), systemImage: info.type == nil ? "questionmark.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        SecureField("Passphrase", text: $form.passphrase.typed, prompt: Text(form.isNew ? "Optional" : "Unchanged"))
        if info.encrypted, KeychainRules.nonEmpty(form.passphrase) == nil {
            Text("This key is protected by a passphrase. Enter it to store it with the key.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        LabeledContent("Public Key") {
            TextEditor(text: Binding(get: { form.publicKey ?? "" }, set: { form.setPublicKey($0) }))
                .scrollContentBackground(.hidden)
                .background(.fill.quaternary, in: .rect(cornerRadius: 6))
                .font(.callout.monospaced())
                .frame(minHeight: 50)
                .accessibilityLabel("Public key")
        }
        if let pub = form.publicKey, KeyText.isPublicKeyInvalid(pub) {
            warning("Not an SSH public key. Expected “ssh-ed25519 AAAA… comment” on one line. It will not save.")
        }
        // shortcut: no drag-and-drop target like upstream `KeyFileDropZone`; add `.dropDestination(for: URL.self)` if asked.
        LabeledContent("Key File") {
            Button("Choose File…") { choosingFile = true }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { load($0) }
        .fileDialogBrowserOptions(.includeHiddenFiles)
        if let fileProblem { warning(fileProblem) }
    }

    private func status(_ info: KeyInfo) -> String {
        let type = info.type ?? "Unknown type"
        return info.encrypted ? "\(type), passphrase-protected" : type
    }

    /// Upstream `KeyFileDropZone`: a public key file fills the public field, anything else the private one.
    private func load(_ result: Result<URL, any Error>) {
        fileProblem = nil
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Key files are a few kilobytes; refuse to pull anything big into a text field.
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? 0 <= 1_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fileProblem = "Could not read \(url.lastPathComponent) as a key file."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if KeyText.isPublicKeyFile(name: url.lastPathComponent, text: trimmed) {
            form.setPublicKey(trimmed)
        } else {
            form.privateKey = trimmed
        }
    }
}

/// Upstream `KeyGenFields`: type, size, passphrase, cipher and rounds, then Generate.
struct KeyGenSections: View {
    let operations: KeyOperations
    let onGenerated: (GeneratedKey, String?) -> Void
    @ViewState private var gen = KeyGenForm()
    @ViewState private var busy = false
    @ViewState private var failure: String?

    var body: some View {
        Section("Key Type") {
            Picker("Type", selection: $gen.algorithm) {
                ForEach(KeyAlgorithm.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if gen.algorithm == .ecdsa {
                Picker("Elliptic Curve", selection: $gen.curve) {
                    ForEach(KeyGenForm.curves, id: \.self) { Text("P-\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if gen.algorithm == .rsa {
                Picker("Key Size", selection: $gen.bits) {
                    ForEach(KeyGenForm.rsaSizes, id: \.self) { Text("\($0) bits").tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        Section {
            SecureField("Passphrase", text: $gen.passphrase, prompt: Text("Optional"))
            Toggle("Save Passphrase", isOn: $gen.savePassphrase)
            if !gen.passphrase.isEmpty {
                Picker("Cipher", selection: $gen.cipher) {
                    ForEach(KeyGenForm.ciphers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                TextField("Rounds", text: $gen.rounds.digits(1...10_000), prompt: Text(String(KeyGenForm.defaultRounds)))
            }
        } header: {
            Text("Passphrase")
        } footer: {
            if !gen.passphrase.isEmpty {
                Text("Rounds are bcrypt-pbkdf iterations that turn the passphrase into the encryption key. More slows down brute-force attacks and key loading a little. OpenSSH uses 16.")
            }
        }
        Section {
            if let failure { KeyMaterialFields.warning(failure) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "Generating…" : "Generate") { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
    }

    private func generate() {
        busy = true
        failure = nil
        let options = gen.options
        let passphrase = gen.savedPassphrase
        Task {
            do {
                onGenerated(try await operations.generate(options), passphrase)
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Upstream `LinkedToSection`: what signs in with this key or identity.
struct UsedBySection: View {
    let hosts: [Connection]
    var identities: [Identity] = []

    var body: some View {
        if !hosts.isEmpty || !identities.isEmpty {
            Section("Used By") {
                ForEach(identities) { i in
                    Label(KeychainRules.identityName(i), systemImage: "person.text.rectangle")
                }
                ForEach(hosts) { c in
                    LabeledContent {
                        Text("\(c.username)@\(c.host):\(c.port)").foregroundStyle(.secondary)
                    } label: {
                        Label(KeychainRules.hostName(c), systemImage: "server.rack")
                    }
                }
            }
        }
    }
}

/// Folder choices of one vault, plus the current folder when it is not among them.
struct FolderPicker: View {
    @Binding var folderID: String?
    let folders: [Folder]
    let vaultID: String

    var body: some View {
        let choices = KeychainRules.folderChoices(folders, vaultID: vaultID)
        Picker("Folder", selection: $folderID) {
            Text("None").tag(String?.none)
            ForEach(choices, id: \.id) { Text($0.label).tag(Optional($0.id)) }
            if let folderID, !choices.contains(where: { $0.id == folderID }) {
                Text("Missing Folder").tag(Optional(folderID))
            }
        }
    }
}

extension KeyMaterialFields {
    static func warning(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
    }

    func warning(_ text: String) -> some View { Self.warning(text) }
}
