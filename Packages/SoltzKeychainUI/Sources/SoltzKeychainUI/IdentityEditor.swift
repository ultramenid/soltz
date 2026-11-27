// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel

/// A sheet that edits one identity: a reusable username with a password and/or an SSH key, which
/// may be pasted in and created with it. It owns no persistence: Save hands a new inline key to
/// `onSaveKey` first, then the identity (edited in place, so unknown JSON fields survive) and its
/// password to `onSave`. The stored password is never shown.
public struct IdentityEditor: View {
    @ViewState private var form: IdentityForm
    private let keys: [SshKey]
    private let connections: [Connection]
    private let folders: [Folder]
    private let onSave: (Identity, IdentitySecrets) -> Void
    private let onSaveKey: (SshKey, KeySecrets) -> Void
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - identity: the identity to edit; nil starts a new one, filed in `newFolderID` and its vault.
    ///   - keys: key choices, limited to the identity's vault.
    ///   - connections: for the "Used By" list.
    ///   - folders: folder choices, limited to the identity's vault.
    ///   - onSaveKey: a key pasted in as "New Key", saved before the identity that links it.
    public init(
        identity: Identity?,
        newFolderID: String? = nil,
        keys: [SshKey] = [],
        connections: [Connection] = [],
        folders: [Folder] = [],
        onSave: @escaping (Identity, IdentitySecrets) -> Void,
        onSaveKey: @escaping (SshKey, KeySecrets) -> Void
    ) {
        let folder = KeychainRules.keychainFolders(folders).first { $0.id == newFolderID }
        _form = ViewState(initialValue: IdentityForm(identity ?? KeychainRules.newIdentity(in: folder), isNew: identity == nil))
        self.keys = keys
        self.connections = connections
        self.folders = folders
        self.onSave = onSave
        self.onSaveKey = onSaveKey
    }

    public var body: some View {
        Form {
            Section {
                TextField("Label", text: $form.identity.name.orEmpty, prompt: Text("My Identity (optional)"))
                TextField("Tags", text: $form.tagsText, prompt: Text("Comma-separated"))
                FolderPicker(folderID: $form.identity.folderID, folders: folders, vaultID: form.identity.vaultID)
            }
            Section {
                TextField("Username", text: $form.identity.username, prompt: Text("root"))
                SecureField("Password", text: $form.password.typed, prompt: Text(form.isNew ? "Optional" : "Unchanged"))
                Picker("SSH Key", selection: $form.keyChoice) {
                    Text("None").tag(KeyChoice.none)
                    Text("New Key…").tag(KeyChoice.newKey)
                    Divider()
                    ForEach(keyChoices, id: \.id) { Text(KeychainRules.keyName($0)).tag(KeyChoice.key($0.id)) }
                    if case .key(let id) = form.keyChoice, !keyChoices.contains(where: { $0.id == id }) {
                        Text("Unavailable Key").tag(form.keyChoice)
                    }
                }
            } header: {
                Text("Credentials")
            } footer: {
                if !form.isNew { Text("The stored password is not shown. Leave it empty to keep it.") }
            }
            if form.keyChoice == .newKey {
                Section("New Key") {
                    TextField("Key Label", text: $form.newKey.key.name.orEmpty, prompt: Text("My SSH Key (optional)"))
                    KeyMaterialFields(form: $form.newKey)
                }
            }
            if !form.isNew {
                UsedBySection(hosts: KeychainRules.hosts(usingIdentity: form.identity.id, connections: connections))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(form.isNew ? "New Identity" : "Edit Identity")
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let (identity, secrets, newKey) = form.finalized()
                    if let (key, keySecrets) = newKey { onSaveKey(key, keySecrets) }
                    onSave(identity, secrets)
                    dismiss()
                }
                .disabled(form.missingRequired != nil)
                .help(form.missingRequired ?? "")
            }
        }
    }

    /// Live keys of the identity's vault (upstream `useVaultScopedItems`).
    private var keyChoices: [SshKey] {
        keys.filter { KeychainRules.isLive($0) && $0.vaultID == form.identity.vaultID }
            .sorted { KeychainRules.keyName($0).localizedStandardCompare(KeychainRules.keyName($1)) == .orderedAscending }
    }
}
