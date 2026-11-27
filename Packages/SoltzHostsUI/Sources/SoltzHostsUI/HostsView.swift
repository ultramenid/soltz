// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel

/// The hosts browser: folders with a breadcrumb, pinned hosts, search, tag filter, sort and a
/// grid/list toggle. It owns no persistence; it renders what it is given and reports intent.
/// Tombstoned records (`deleted_at` set) are never shown.
public struct HostsView: View {
    private let connections: [Connection]
    private let folders: [Folder]
    private let onConnect: (Connection) -> Void
    private let identities: [Identity]
    private let keys: [SshKey]
    private let onSave: (Connection, HostSecrets) -> Void
    private let onDelete: (Connection) -> Void
    private let onSaveFolder: (Folder) -> Void
    private let onDeleteFolder: (Folder) -> Void

    @ViewState private var folderID: String?
    @ViewState private var query = ""
    @ViewState private var tagFilter: Set<String> = []
    @ViewState private var selection: String?
    @ViewState private var editor: EditorRequest?
    @ViewState private var folderEditor: FolderRequest?
    @ViewState private var pendingDelete: PendingDelete?
    @FocusState private var gridFocused: Bool
    @AppStorage("SoltzHostsUI.sort") private var sort = HostSort.newest
    @AppStorage("SoltzHostsUI.layout") private var layout = HostLayout.grid

    /// - Parameters:
    ///   - onSave: a new, edited, duplicated, pinned or moved host, plus the secrets typed in the
    ///     editor (`HostSecrets.copyFrom` on a duplicate). The store stamps `updated_at` and `clocks`.
    ///   - onDelete: delete (tombstone) a host; the user has confirmed.
    ///   - onSaveFolder: a new, renamed or moved folder.
    ///   - onDeleteFolder: the user confirmed deleting the folder, its subfolders and every host
    ///     filed in them; the store cascades, as upstream `deleteFolder(id, cascade)` does.
    public init(
        connections: [Connection],
        folders: [Folder],
        onConnect: @escaping (Connection) -> Void,
        identities: [Identity] = [],
        keys: [SshKey] = [],
        onSave: @escaping (Connection, HostSecrets) -> Void = { _, _ in },
        onDelete: @escaping (Connection) -> Void = { _ in },
        onSaveFolder: @escaping (Folder) -> Void = { _ in },
        onDeleteFolder: @escaping (Folder) -> Void = { _ in }
    ) {
        self.connections = connections
        self.folders = folders
        self.onConnect = onConnect
        self.identities = identities
        self.keys = keys
        self.onSave = onSave
        self.onDelete = onDelete
        self.onSaveFolder = onSaveFolder
        self.onDeleteFolder = onDeleteFolder
    }

    public var body: some View {
        let level = HostRules.level(connections: connections, folders: folders, folderID: folderID,
                                    query: query, tags: tagFilter, sort: sort)
        VStack(spacing: 0) {
            if !level.path.isEmpty { breadcrumb(level.path) }
            if level.isEmpty {
                emptyState(level)
            } else if layout == .list {
                list(level)
            } else {
                grid(level)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $query, prompt: "Filter hosts")
        .toolbar { toolbar(level) }
        .onDeleteCommand { selection.map(requestDelete) }
        .sheet(item: $editor) { request in
            HostEditor(connection: request.connection, newType: request.type, newFolderID: request.folderID,
                       connections: connections, folders: folders, identities: identities, keys: keys, onSave: onSave)
        }
        .sheet(item: $folderEditor) { request in
            FolderEditor(folder: request.folder, parentID: request.parentID, folders: folders, onSave: onSaveFolder)
        }
        .confirmationDialog(deleteTitle, isPresented: $pendingDelete.isPresent(), titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) { delete(item, path: level.path) }
        } message: { item in
            Text(deleteMessage(item))
        }
    }

    // MARK: Layouts

    private func grid(_ level: HostsLevel) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                if !level.folders.isEmpty {
                    Section {
                        ForEach(level.folders) { folder in
                            tile(id: folder.id, symbol: "folder", title: folder.name, subtitle: folderSubtitle(folder))
                                .contextMenu { folderMenu(folder) }
                        }
                    } header: { sectionHeader("Folders") }
                }
                hostSection("Pinned", level.pinned)
                hostSection("Hosts", level.hosts)
            }
            .padding()
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            open(selection)
            return .handled
        }
    }

    @ViewBuilder
    private func hostSection(_ title: String, _ hosts: [Connection]) -> some View {
        if !hosts.isEmpty {
            Section {
                ForEach(hosts) { c in
                    tile(id: c.id, symbol: HostRules.symbol(c.connectionType), title: HostRules.displayName(c),
                         subtitle: HostRules.subtitle(c), detail: c.tags.isEmpty ? nil : c.tags.joined(separator: ", "),
                         pinned: c.pinned)
                        .contextMenu { hostMenu(c) }
                }
            } header: { sectionHeader(title) }
        }
    }

    private func list(_ level: HostsLevel) -> some View {
        List(selection: $selection) {
            if !level.folders.isEmpty {
                Section("Folders") {
                    ForEach(level.folders) { folder in
                        row(symbol: "folder", title: folder.name, subtitle: folderSubtitle(folder))
                    }
                }
            }
            if !level.pinned.isEmpty {
                Section("Pinned") { ForEach(level.pinned, content: hostRow) }
            }
            if !level.hosts.isEmpty {
                Section("Hosts") { ForEach(level.hosts, content: hostRow) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { menu(for: id) }
        } primaryAction: { ids in
            ids.first.map(open)
        }
    }

    private func hostRow(_ c: Connection) -> some View {
        row(symbol: HostRules.symbol(c.connectionType), title: HostRules.displayName(c), subtitle: HostRules.subtitle(c),
            detail: c.tags.isEmpty ? nil : c.tags.joined(separator: ", "), pinned: c.pinned)
    }

    private func row(symbol: String, title: String, subtitle: String, detail: String? = nil, pinned: Bool = false) -> some View {
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
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("Pinned") }
        }
    }

    private func tile(id: String, symbol: String, title: String, subtitle: String,
                      detail: String? = nil, pinned: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let selected = selection == id
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("Pinned") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: shape)
        .overlay { if selected { shape.strokeBorder(.tint, lineWidth: 2) } }
        .contentShape(shape)
        .onTapGesture(count: 2) { open(id) }
        .simultaneousGesture(TapGesture().onEnded {
            selection = id
            gridFocused = true
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(id) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private func breadcrumb(_ path: [Folder]) -> some View {
        HStack(spacing: 4) {
            Button("All Hosts") { navigate(to: nil) }
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
    private func emptyState(_ level: HostsLevel) -> some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !tagFilter.isEmpty {
            ContentUnavailableView {
                Label("No Matching Hosts", systemImage: "tag")
            } description: {
                Text("No hosts here have the selected tags.")
            } actions: {
                Button("Clear Filter") { tagFilter = [] }
            }
        } else if !level.path.isEmpty {
            ContentUnavailableView {
                Label("This Folder Is Empty", systemImage: "folder")
            } actions: {
                Button("New Host") { newHost(.ssh) }
            }
        } else {
            ContentUnavailableView {
                Label("No Hosts Yet", systemImage: "server.rack")
            } description: {
                Text("Add a server to connect to it in one click.")
            } actions: {
                Button("New Host") { newHost(.ssh) }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private func toolbar(_ level: HostsLevel) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Enclosing Folder", systemImage: "chevron.backward") { navigate(to: level.path.dropLast().last?.id) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(level.path.isEmpty)
        }
        ToolbarItem {
            Menu {
                Button("New Host") { newHost(.ssh) }
                Button("New Serial Host") { newHost(.serial) }
                Divider()
                Button("New Folder") { folderEditor = FolderRequest(folder: nil, parentID: level.path.last?.id) }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                newHost(.ssh)
            }
        }
        ToolbarItem {
            Picker("View", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(HostLayout.grid)
                Label("List", systemImage: "list.bullet").tag(HostLayout.list)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(HostSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem {
            let tags = Set(HostRules.tags(connections)).union(tagFilter).sorted()
            Menu {
                ForEach(tags, id: \.self) { tag in Toggle(tag, isOn: $tagFilter.contains(tag)) }
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
        if let c = connections.first(where: { $0.id == id }) {
            hostMenu(c)
        } else if let folder = folders.first(where: { $0.id == id }) {
            folderMenu(folder)
        }
    }

    @ViewBuilder
    private func hostMenu(_ c: Connection) -> some View {
        Button("Connect") { onConnect(c) }
        Divider()
        Button("Edit…") { editor = EditorRequest(connection: c) }
        Button("Duplicate") { onSave(HostRules.duplicate(c), HostSecrets(copyFrom: c.id)) }
        Button(c.pinned ? "Unpin" : "Pin") {
            var pinned = c
            pinned.pinned.toggle()
            onSave(pinned, HostSecrets())
        }
        Menu("Move to Folder") {
            Button("None") { move(c, to: nil) }.disabled(c.folderID == nil)
            ForEach(HostRules.folderChoices(folders, vaultID: c.vaultID), id: \.id) { choice in
                Button(choice.label) { move(c, to: choice.id) }.disabled(c.folderID == choice.id)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = .host(c) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("Open") { open(folder.id) }
        Button("Edit…") { folderEditor = FolderRequest(folder: folder) }
        Button("New Folder Inside") { folderEditor = FolderRequest(folder: nil, parentID: folder.id) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = .folder(folder) }
    }

    // MARK: Actions

    private func open(_ id: String) {
        if HostRules.hostFolders(folders).contains(where: { $0.id == id }) {
            navigate(to: id)
        } else if let c = connections.first(where: { $0.id == id && $0.deletedAt == nil }) {
            onConnect(c)
        }
    }

    private func navigate(to id: String?) {
        folderID = id
        selection = nil
    }

    private func newHost(_ type: ConnectionType) {
        editor = EditorRequest(connection: nil, type: type, folderID: folderID)
    }

    private func move(_ c: Connection, to folderID: String?) {
        var moved = c
        moved.folderID = folderID
        onSave(moved, HostSecrets())
    }

    private func requestDelete(_ id: String) {
        if let c = connections.first(where: { $0.id == id }) {
            pendingDelete = .host(c)
        } else if let folder = folders.first(where: { $0.id == id }) {
            pendingDelete = .folder(folder)
        }
    }

    private func delete(_ item: PendingDelete, path: [Folder]) {
        switch item {
        case .host(let c):
            onDelete(c)
        case .folder(let folder):
            onDeleteFolder(folder)
            if path.contains(where: { $0.id == folder.id }) { folderID = nil }
        }
        selection = nil
    }

    private var deleteTitle: String {
        switch pendingDelete {
        case .host(let c): "Delete “\(HostRules.displayName(c))”?"
        case .folder(let folder): "Delete Folder “\(folder.name)”?"
        case nil: ""
        }
    }

    /// Upstream `folderDeleteMessages`: a folder delete warns how many hosts go with it.
    private func deleteMessage(_ item: PendingDelete) -> String {
        guard case .folder(let folder) = item else { return "This cannot be undone." }
        let count = HostRules.hostCount(in: folder.id, connections: connections, folders: folders)
        return count == 0
            ? "This will delete the folder and everything inside it. This cannot be undone."
            : "This will delete the folder, its subfolders, and the \(count) \(count == 1 ? "host" : "hosts") inside. This cannot be undone."
    }

    private func folderSubtitle(_ folder: Folder) -> String {
        let count = HostRules.hostCount(in: folder.id, connections: connections, folders: folders)
        return "\(count) \(count == 1 ? "host" : "hosts")"
    }
}

private struct EditorRequest: Identifiable {
    let id = UUID()
    var connection: Connection?
    var type: ConnectionType = .ssh
    var folderID: String?
}

private struct FolderRequest: Identifiable {
    let id = UUID()
    var folder: Folder?
    var parentID: String?
}

private enum PendingDelete {
    case host(Connection)
    case folder(Folder)
}
