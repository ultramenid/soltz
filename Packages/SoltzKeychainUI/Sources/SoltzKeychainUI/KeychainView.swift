// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel

/// The keychain: SSH keys and identities in folders, with pinned items first, search, tag filter
/// and sort. It owns no persistence; it renders what it is given and reports intent. Tombstoned
/// records are never shown.
public struct KeychainView: View {
    private let keys: [SshKey]
    private let identities: [Identity]
    private let connections: [Connection]
    private let folders: [Folder]
    private let operations: KeyOperations
    private let onSaveKey: (SshKey, KeySecrets) -> Void
    private let onDeleteKey: (SshKey) -> Void
    private let onSaveIdentity: (Identity, IdentitySecrets) -> Void
    private let onDeleteIdentity: (Identity) -> Void
    private let onSaveFolder: (Folder) -> Void
    private let onDeleteFolder: (Folder) -> Void

    @ViewState private var folderID: String?
    @ViewState private var query = ""
    @ViewState private var tagFilter: Set<String> = []
    @ViewState private var selection: String?
    @ViewState private var editor: Editor?
    @ViewState private var pendingDelete: PendingDelete?
    @ViewState private var naming: FolderNaming?
    @ViewState private var folderName = ""
    @ViewState private var problem: String?
    @AppStorage("SoltzKeychainUI.sort") private var sort = KeychainSort.newest

    /// - Parameters:
    ///   - connections: hosts, to say which use a key or identity.
    ///   - folders: every folder; only live `keychain` ones are shown.
    ///   - operations: generation, and reading a stored key's halves for copy and export.
    ///   - onSaveKey: a new, edited, duplicated, pinned or moved key, plus its key material.
    ///     The store stamps `updated_at` and `clocks`.
    ///   - onDeleteKey, onDeleteIdentity: delete (tombstone); the user has confirmed.
    ///   - onSaveIdentity: a new, edited, duplicated, pinned or moved identity, plus its password.
    ///   - onSaveFolder: a new or renamed keychain folder.
    ///   - onDeleteFolder: the user confirmed deleting the folder, its subfolders and every key and
    ///     identity filed in them; the store cascades, as upstream `deleteFolder` does.
    public init(
        keys: [SshKey],
        identities: [Identity],
        connections: [Connection] = [],
        folders: [Folder] = [],
        operations: KeyOperations,
        onSaveKey: @escaping (SshKey, KeySecrets) -> Void,
        onDeleteKey: @escaping (SshKey) -> Void,
        onSaveIdentity: @escaping (Identity, IdentitySecrets) -> Void,
        onDeleteIdentity: @escaping (Identity) -> Void,
        onSaveFolder: @escaping (Folder) -> Void = { _ in },
        onDeleteFolder: @escaping (Folder) -> Void = { _ in }
    ) {
        self.keys = keys
        self.identities = identities
        self.connections = connections
        self.folders = folders
        self.operations = operations
        self.onSaveKey = onSaveKey
        self.onDeleteKey = onDeleteKey
        self.onSaveIdentity = onSaveIdentity
        self.onDeleteIdentity = onDeleteIdentity
        self.onSaveFolder = onSaveFolder
        self.onDeleteFolder = onDeleteFolder
    }

    public var body: some View {
        let level = KeychainRules.level(keys: keys, identities: identities, folders: folders, folderID: folderID,
                                        query: query, tags: tagFilter, sort: sort)
        VStack(spacing: 0) {
            if !level.path.isEmpty { breadcrumb(level.path) }
            if level.isEmpty { emptyState(level) } else { list(level) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $query, prompt: "Filter keys and identities")
        .toolbar { toolbar(level) }
        .onDeleteCommand { selection.map(requestDelete) }
        .sheet(item: $editor) { editor in
            switch editor {
            case .key(let key, let generate):
                KeyEditor(key: key, generate: generate, newFolderID: folderID, connections: connections,
                          identities: identities, folders: folders, operations: operations, onSave: onSaveKey)
            case .identity(let identity):
                IdentityEditor(identity: identity, newFolderID: folderID, keys: keys, connections: connections,
                               folders: folders, onSave: onSaveIdentity, onSaveKey: onSaveKey)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $pendingDelete.isPresent(), titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) { delete(item, path: level.path) }
        } message: { item in
            Text(deleteMessage(item))
        }
        .alert(naming?.folder == nil ? "New Folder" : "Rename Folder", isPresented: $naming.isPresent(), presenting: naming) { naming in
            TextField("Name", text: $folderName)
            Button(naming.folder == nil ? "Create" : "Rename") {
                if let saved = KeychainRules.savedFolder(naming.folder, name: folderName, parent: naming.parent) { onSaveFolder(saved) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Complete", isPresented: $problem.isPresent(), presenting: problem) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    // MARK: Layout

    // shortcut: single selection, so no bulk delete/move/export as in upstream; make `selection` a Set to add them.
    private func list(_ level: KeychainLevel) -> some View {
        List(selection: $selection) {
            if !level.folders.isEmpty {
                Section("Folders") {
                    ForEach(level.folders) { folder in
                        let count = KeychainRules.itemCount(in: folder.id, keys: keys, identities: identities, folders: folders)
                        row(symbol: "folder", title: folder.name, subtitle: KeychainRules.count(count, "item", "items"))
                    }
                }
            }
            if !level.pinnedKeys.isEmpty || !level.pinnedIdentities.isEmpty {
                Section("Pinned") {
                    ForEach(level.pinnedKeys, content: keyRow)
                    ForEach(level.pinnedIdentities, content: identityRow)
                }
            }
            if !level.keys.isEmpty {
                Section("SSH Keys") { ForEach(level.keys, content: keyRow) }
            }
            if !level.identities.isEmpty {
                Section("Identities") { ForEach(level.identities, content: identityRow) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { menu(for: id) }
        } primaryAction: { ids in
            ids.first.map(open)
        }
    }

    private func keyRow(_ k: SshKey) -> some View {
        let added = KeychainRules.date(k.createdAt).map { " · Added \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return row(symbol: "key.horizontal", title: KeychainRules.keyName(k), subtitle: (k.keyType ?? "SSH key") + added,
                   tags: k.tags, pinned: k.pinned)
    }

    private func identityRow(_ i: Identity) -> some View {
        let signIn: String = switch i.keyID {
        case nil: "Password"
        case let id?: keys.first { $0.id == id && KeychainRules.isLive($0) }.map { "Key: \(KeychainRules.keyName($0))" } ?? "Missing Key"
        }
        return row(symbol: "person.text.rectangle", title: KeychainRules.identityName(i),
                   subtitle: KeychainRules.nonEmpty(i.name) == nil ? signIn : "\(i.username) · \(signIn)", tags: i.tags, pinned: i.pinned)
    }

    private func row(symbol: String, title: String, subtitle: String, tags: [String] = [], pinned: Bool = false) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
            Spacer()
            if !tags.isEmpty { Text(tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("Pinned") }
        }
    }

    private func breadcrumb(_ path: [Folder]) -> some View {
        HStack(spacing: 4) {
            Button("Keychain") { navigate(to: nil) }
            ForEach(path) { folder in
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
                Button(folder.name) { navigate(to: folder.id) }
                    .disabled(folder.id == path.last?.id)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    @ViewBuilder
    private func emptyState(_ level: KeychainLevel) -> some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !tagFilter.isEmpty {
            ContentUnavailableView {
                Label("No Matching Items", systemImage: "tag")
            } description: {
                Text("No keys or identities here have the selected tags.")
            } actions: {
                Button("Clear Filter") { tagFilter = [] }
            }
        } else if !level.path.isEmpty {
            ContentUnavailableView {
                Label("This Folder Is Empty", systemImage: "folder")
            } actions: {
                Button("Add Key") { editor = .key(nil, generate: false) }
                Button("Add Identity") { editor = .identity(nil) }
            }
        } else {
            ContentUnavailableView {
                Label("No Keys or Identities Yet", systemImage: "key.horizontal")
            } description: {
                Text("Store reusable SSH key pairs, and combine a username with credentials for reuse across hosts.")
            } actions: {
                Button("Import Key") { editor = .key(nil, generate: false) }.buttonStyle(.borderedProminent)
                Button("Generate Key Pair") { editor = .key(nil, generate: true) }
                Button("New Identity") { editor = .identity(nil) }
            }
        }
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private func toolbar(_ level: KeychainLevel) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Enclosing Folder", systemImage: "chevron.backward") { navigate(to: level.path.dropLast().last?.id) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(level.path.isEmpty)
        }
        ToolbarItem {
            Menu {
                Button("Import Key…") { editor = .key(nil, generate: false) }
                Button("Generate Key Pair…") { editor = .key(nil, generate: true) }
                Button("New Identity…") { editor = .identity(nil) }
                Divider()
                Button("New Folder…") { name(nil, parent: level.path.last) }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                editor = .key(nil, generate: false)
            }
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(KeychainSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem {
            let tags = Set(KeychainRules.tags(keys: keys, identities: identities)).union(tagFilter).sorted()
            Menu {
                ForEach(tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { tagFilter.contains(tag) }, set: {
                        if $0 { tagFilter.insert(tag) } else { tagFilter.remove(tag) }
                    }))
                }
                if !tagFilter.isEmpty {
                    Divider()
                    Button("Clear Filter") { tagFilter = [] }
                }
            } label: {
                Label("Filter by Tag", systemImage: tagFilter.isEmpty ? "tag" : "tag.fill")
            }
            .disabled(tags.isEmpty)
        }
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        if let k = keys.first(where: { $0.id == id }) {
            keyMenu(k)
        } else if let i = identities.first(where: { $0.id == id }) {
            identityMenu(i)
        } else if let folder = folders.first(where: { $0.id == id }) {
            folderMenu(folder)
        }
    }

    @ViewBuilder
    private func keyMenu(_ k: SshKey) -> some View {
        Button("Edit…") { editor = .key(k, generate: false) }
        Button("Duplicate") { onSaveKey(KeychainRules.duplicate(k), KeySecrets(copyFrom: k.id)) }
        Divider()
        Button("Copy Public Key") { run { await KeyActions.copyPublicKey(k, operations) } }
        // shortcut: upstream's "Add to host" (append the public half to a host's authorized_keys over SSH)
        // is not here; it needs a remote-exec callback and a host picker.
        Menu("Export") {
            Button("Public Key…") { run { await KeyActions.export(k, publicHalf: true, operations) } }
            Button("Private Key…") { run { await KeyActions.export(k, publicHalf: false, operations) } }
        }
        Divider()
        Button(k.pinned ? "Unpin" : "Pin") {
            var pinned = k
            pinned.pinned.toggle()
            onSaveKey(pinned, KeySecrets())
        }
        moveMenu(current: k.folderID, vaultID: k.vaultID) { folderID in
            var moved = k
            moved.folderID = folderID
            onSaveKey(moved, KeySecrets())
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = .key(k) }
    }

    @ViewBuilder
    private func identityMenu(_ i: Identity) -> some View {
        Button("Edit…") { editor = .identity(i) }
        Button("Duplicate") { onSaveIdentity(KeychainRules.duplicate(i), IdentitySecrets(copyFrom: i.id)) }
        Divider()
        Button(i.pinned ? "Unpin" : "Pin") {
            var pinned = i
            pinned.pinned.toggle()
            onSaveIdentity(pinned, IdentitySecrets())
        }
        moveMenu(current: i.folderID, vaultID: i.vaultID) { folderID in
            var moved = i
            moved.folderID = folderID
            onSaveIdentity(moved, IdentitySecrets())
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = .identity(i) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("Open") { navigate(to: folder.id) }
        Button("Rename…") { name(folder, parent: nil) }
        Button("New Folder Inside…") { name(nil, parent: folder) }
        Menu("Move To") {
            Button("Top Level") { move(folder, to: nil) }.disabled(folder.parentFolderID == nil)
            ForEach(KeychainRules.parentChoices(for: folder, folders: folders), id: \.id) { choice in
                Button(choice.label) { move(folder, to: choice.id) }.disabled(folder.parentFolderID == choice.id)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = .folder(folder) }
    }

    private func moveMenu(current: String?, vaultID: String, move: @escaping (String?) -> Void) -> some View {
        Menu("Move to Folder") {
            Button("None") { move(nil) }.disabled(current == nil)
            ForEach(KeychainRules.folderChoices(folders, vaultID: vaultID), id: \.id) { choice in
                Button(choice.label) { move(choice.id) }.disabled(current == choice.id)
            }
        }
    }

    // MARK: Actions

    private func open(_ id: String) {
        if KeychainRules.keychainFolders(folders).contains(where: { $0.id == id }) {
            navigate(to: id)
        } else if let k = keys.first(where: { $0.id == id }) {
            editor = .key(k, generate: false)
        } else if let i = identities.first(where: { $0.id == id }) {
            editor = .identity(i)
        }
    }

    private func navigate(to id: String?) {
        folderID = id
        selection = nil
    }

    private func name(_ folder: Folder?, parent: Folder?) {
        folderName = folder?.name ?? "New Folder"
        naming = FolderNaming(folder: folder, parent: parent)
    }

    private func move(_ folder: Folder, to parentID: String?) {
        var moved = folder
        moved.parentFolderID = parentID
        onSaveFolder(moved)
    }

    /// Runs a key action and shows what went wrong, if anything.
    private func run(_ action: @escaping @MainActor () async -> String?) {
        Task { problem = await action() }
    }

    private func requestDelete(_ id: String) {
        if let k = keys.first(where: { $0.id == id }) {
            pendingDelete = .key(k)
        } else if let i = identities.first(where: { $0.id == id }) {
            pendingDelete = .identity(i)
        } else if let folder = folders.first(where: { $0.id == id }) {
            pendingDelete = .folder(folder)
        }
    }

    private func delete(_ item: PendingDelete, path: [Folder]) {
        switch item {
        case .key(let k): onDeleteKey(k)
        case .identity(let i): onDeleteIdentity(i)
        case .folder(let folder):
            onDeleteFolder(folder)
            if path.contains(where: { $0.id == folder.id }) { folderID = nil }
        }
        selection = nil
    }

    private var deleteTitle: String {
        switch pendingDelete {
        case .key(let k): "Delete “\(KeychainRules.keyName(k))”?"
        case .identity(let i): "Delete “\(KeychainRules.identityName(i))”?"
        case .folder(let folder): "Delete Folder “\(folder.name)”?"
        case nil: ""
        }
    }

    private func deleteMessage(_ item: PendingDelete) -> String {
        switch item {
        case .key(let k):
            let usage = KeychainRules.usage(ofKey: k.id, connections: connections, identities: identities)
            return KeychainRules.deleteMessage(hosts: usage.hosts, identities: usage.identities)
        case .identity(let i):
            return KeychainRules.deleteMessage(hosts: KeychainRules.hosts(usingIdentity: i.id, connections: connections))
        case .folder(let folder):
            return KeychainRules.folderDeleteMessage(
                itemCount: KeychainRules.itemCount(in: folder.id, keys: keys, identities: identities, folders: folders))
        }
    }
}

private enum Editor: Identifiable {
    case key(SshKey?, generate: Bool)
    case identity(Identity?)

    var id: String {
        switch self {
        case .key(let k, let generate): "key-\(k?.id ?? (generate ? "generate" : "import"))"
        case .identity(let i): "identity-\(i?.id ?? "new")"
        }
    }
}

private struct FolderNaming {
    /// The folder to rename; nil creates one inside `parent`.
    var folder: Folder?
    var parent: Folder?
}

private enum PendingDelete {
    case key(SshKey)
    case identity(Identity)
    case folder(Folder)
}
