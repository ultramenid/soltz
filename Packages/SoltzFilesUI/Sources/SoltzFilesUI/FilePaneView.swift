// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One file pane as a glass card: a one-row header (source, path, a "more" menu), a sortable list,
/// the per-item actions and drag and drop. It owns no queue; it reports items to copy through `onTransfer`
/// and `onReceive`.
public struct FilePaneView: View {
    private let provider: any FileProvider
    @Binding private var path: String
    @Binding private var selection: [FileEntry]
    private let reloadID: Int
    private let source: AnyView?
    private let accessory: AnyView?
    private let transferTitle: ((Int) -> String)?
    private let onTransfer: (([FileEntry]) -> Void)?
    private let onEdit: (([FileEntry], URL?) -> Void)?
    private let onReceive: (([FileEntry], any FileProvider, String) -> Void)?

    @ViewState private var paneID = UUID()
    @ViewState private var entries: [FileEntry] = []
    @ViewState private var home: String?
    @ViewState private var history = PathHistory()
    @ViewState private var loading = false
    @ViewState private var loadError: String?
    @ViewState private var selectedIDs: Set<String> = []
    @ViewState private var sortOrder = [FileComparator(.name)]
    @ViewState private var extraColumns: Set<FileColumn> = []
    @ViewState private var filter = ""
    @ViewState private var filtering = false
    @ViewState private var editingPath = false
    @ViewState private var pathText = ""
    @ViewState private var renaming: String?
    @ViewState private var renameText = ""
    @ViewState private var creatingFolder = false
    /// What the naming alert makes: a file, or a folder.
    @ViewState private var creatingFile = false
    @ViewState private var folderName = ""
    @ViewState private var pendingDelete: [FileEntry]?
    @ViewState private var moving: [FileEntry]?
    @ViewState private var searching = false
    /// A search result to select once its folder is listed.
    @ViewState private var revealing: String?
    @ViewState private var previewURL: URL?
    @ViewState private var previewTask: Task<Void, Never>?
    @ViewState private var moveText = ""
    @ViewState private var favourites: [String] = []
    /// Work on the file system under way (a copy, an archive), shown as the path bar's spinner.
    @ViewState private var busy = 0
    @ViewState private var permissions: PermissionsRequest?
    @ViewState private var failure: Failure?
    @ViewState private var dropTargeted = false
    @FocusState private var pathFocused: Bool
    @FocusState private var filterFocused: Bool
    @FocusState private var renameFocused: Bool
    @AppStorage("SoltzFilesUI.showHidden") private var showHidden = false

    @Environment(\.filesStyle) private var style

    /// - Parameters:
    ///   - path: the folder shown; empty opens the provider's home. The pane writes it as the user moves.
    ///   - selection: the selected entries, for the caller's transfer buttons.
    ///   - reloadID: change it to list the folder again, e.g. after a copy into it lands.
    ///   - source: shown first in the header, e.g. the caller's source popup; nil shows the provider's name.
    ///   - accessory: shown last in the header, after the pane's menu, e.g. the caller's own buttons for the pane.
    ///   - transferTitle: what `onTransfer` is called in the menu, for the number of entries selected; nil calls it
    ///     "Transfer to Other Pane" (a pane on its own has no other pane: "Download").
    ///   - onTransfer: the context menu's "Transfer to Other Pane" for the selected entries (the keyboard's way
    ///     to what dragging does); nil hides it.
    ///   - onEdit: opening files of a provider that is not this Mac (`TransferQueue.edit`) in the app chosen from
    ///     "Edit With", or in this Mac's text editor for nil; nil leaves them unopened.
    ///   - onReceive: entries dropped on the pane, from Finder (`LocalFileProvider`) or another pane, with
    ///     their provider and the folder to copy them into; nil turns dropping off.
    public init(provider: any FileProvider, path: Binding<String>, selection: Binding<[FileEntry]> = .constant([]),
                reloadID: Int = 0, source: AnyView? = nil, accessory: AnyView? = nil,
                transferTitle: ((Int) -> String)? = nil,
                onTransfer: (([FileEntry]) -> Void)? = nil, onEdit: (([FileEntry], URL?) -> Void)? = nil,
                onReceive: (([FileEntry], any FileProvider, String) -> Void)? = nil) {
        self.provider = provider
        _path = path
        _selection = selection
        self.reloadID = reloadID
        self.source = source
        self.accessory = accessory
        self.transferTitle = transferTitle
        self.onTransfer = onTransfer
        self.onEdit = onEdit
        self.onReceive = onReceive
    }

    public var body: some View {
        let visible = visible
        VStack(spacing: 0) {
            header
            content(visible)
                .onDrop(of: [.fileURL, PaneDrag.type], isTargeted: $dropTargeted) { items in
                    guard onReceive != nil, loadError == nil, !path.isEmpty else { return false }
                    Task { await receive(items) }
                    return true
                }
        }
        .glassEffect(.regular, in: style.cardShape)
        .overlay {
            if dropTargeted { style.cardShape.strokeBorder(.tint, lineWidth: 2).allowsHitTesting(false).transition(.opacity) }
        }
        .animation(style.motion, value: dropTargeted)
        .animation(style.motion, value: loadError)
        .task(id: "\(path)\n\(reloadID)") { await load() }
        .onChange(of: selectedIDs) { syncSelection() }
        .onChange(of: filter) { pruneSelection() }
        .onChange(of: showHidden) { pruneSelection() }
        .sheet(isPresented: $searching) {
            FileSearchSheet(provider: provider, root: path, showHidden: showHidden, query: filter) { reveal($0) }
        }
        .quickLookPreview($previewURL)
        // A host's file was copied here to be looked at: the copy goes when the preview does.
        .onChange(of: previewURL) { old, new in if let old, old != new { FilePreview.discard(old) } }
        .onChange(of: provider.name, initial: true) { favourites = Favourites.list(for: provider.name) }
        .alert(moving.map { $0.count == 1 ? "Move “\($0[0].name)”" : "Move \($0.count) Items" } ?? "",
               isPresented: $moving.isPresent(), presenting: moving) { items in
            TextField("Folder", text: $moveText)
            Button("Move") { move(items, to: moveText) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Type the folder to move to. “~” is the home folder.")
        }
        .alert(creatingFile ? "New File" : "New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { create(folderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name the new \(creatingFile ? "file" : "folder") in “\(Paths.name(path))”.")
        }
        .confirmationDialog(deleteTitle, isPresented: $pendingDelete.isPresent(), titleVisibility: .visible,
                            presenting: pendingDelete) { items in
            Button(provider.isLocal ? "Move to Trash" : "Delete", role: .destructive) { delete(items) }
        } message: { items in
            if provider.isLocal {
                Text("You can put \(items.count == 1 ? "it" : "them") back from the Trash.")
            } else {
                Text(items.count == 1 ? "This item will be deleted immediately. You can’t undo this action."
                                      : "These items will be deleted immediately. You can’t undo this action.")
            }
        }
        .sheet(item: $permissions) { request in
            PermissionsSheet(entries: request.entries, ownership: !provider.isLocal) { set, clear, owner, group, recursive in
                perform("Couldn’t Change Permissions") {
                    try await provider.changeMode(request.entries.map(\.path), set: set, clear: clear,
                                                  owner: owner, group: group, recursive: recursive)
                }
            }
        }
        .alert(failure?.title ?? "", isPresented: $failure.isPresent(), presenting: failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: Header

    /// One row: what the pane shows, then where it is (the path in a field, with Back, Forward and Enclosing Folder at
    /// its start), then "more". The filter is a second row while it is in use.
    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let source { source } else { Text(provider.name).font(style.row.weight(.semibold)).lineLimit(1) }
                pathBar
                moreMenu
                if let accessory { accessory }
            }
            if filtering || !filter.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Filter", text: $filter, prompt: Text("Filter by name"))
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                        .onExitCommand { filter = ""; filtering = false }
                        .onChange(of: filterFocused) { was, now in if was && !now && filter.isEmpty { filtering = false } }
                        .task {
                            try? await Task.sleep(for: .milliseconds(50))
                            filterFocused = true
                        }
                        .accessibilityLabel("Filter by name")
                    Button("Clear Filter", systemImage: "xmark.circle.fill") { filter = ""; filtering = false }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .field(style)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(style.row)
        .controlSize(.small)
        .padding(.leading, Self.rowInset) // the title over the names below it
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        // The path field, the spinner and the filter come and go with the app's one motion.
        .animation(style.motion, value: [editingPath, loading || busy > 0, filtering || !filter.isEmpty])
    }

    /// Where the pane is, in a field like a search field: the three ways to move, then the path, which edits on a
    /// click on its last part.
    private var pathBar: some View {
        HStack(spacing: 0) {
            navButton("chevron.left", "Back", "⌘[", enabled: !history.back.isEmpty) { goBack() }
            navButton("chevron.right", "Forward", "⌘]", enabled: !history.forward.isEmpty) { goForward() }
            navButton("chevron.up", "Enclosing Folder", "⌘↑", enabled: Paths.parent(path) != nil) { goUp() }
            Divider().frame(height: 12).padding(.leading, 4).padding(.trailing, 8)
            if editingPath {
                TextField("Path", text: $pathText)
                    .textFieldStyle(.plain)
                    .focused($pathFocused)
                    .onSubmit { go(to: pathText) }
                    .onExitCommand { editingPath = false }
                    .onChange(of: pathFocused) { was, now in if was && !now { editingPath = false } }
                    .task {
                        try? await Task.sleep(for: .milliseconds(50))
                        pathFocused = true
                    }
                    .transition(.opacity)
            } else {
                breadcrumb.transition(.opacity)
            }
            if loading || busy > 0 { ProgressView().controlSize(.small).padding(.leading, 6).transition(.opacity) }
        }
        .field(style, leading: 4)
    }

    /// Back, Forward and Enclosing Folder: a quiet symbol in the path field.
    private func navButton(_ symbol: String, _ title: String, _ keys: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(style.detail.weight(.semibold)).frame(width: 20, height: 20).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .help("\(title) (\(keys))")
    }

    /// The pane's actions that are not about the selection, with the shortcuts the list answers.
    private var moreMenu: some View {
        Menu {
            Button("Enclosing Folder") { goUp() }.disabled(Paths.parent(path) == nil)
            Button("Home Folder") { navigate(to: "") }
            Button("Go to Folder…") { startEditingPath() }
            Menu("Favourites") {
                ForEach(favourites, id: \.self) { folder in Button(folder) { navigate(to: folder) } }
                if !favourites.isEmpty { Divider() }
                Button(favourites.contains(path) ? "Remove This Folder" : "Add This Folder") {
                    favourites = Favourites.toggle(path, for: provider.name)
                }
                .disabled(path.isEmpty)
            }
            Divider()
            Button("New Folder") { startNew(file: false) }.disabled(path.isEmpty)
            Button("New File") { startNew(file: true) }.disabled(path.isEmpty)
            Toggle("Show Hidden Files", isOn: $showHidden)
            Button(filtering || !filter.isEmpty ? "Clear Filter" : "Filter…") { toggleFilter() }
            Button("Search Subfolders…") { searching = true }.disabled(path.isEmpty)
            Divider()
            Button("Refresh") { Task { await load() } }
            Button("Copy Path") { copy(path) }.disabled(path.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .help("Enclosing Folder ⌘↑, Go to Folder ⇧⌘G, Hidden Files ⇧⌘., Filter ⌘F, Quick Look Space")
    }

    /// The path as quiet text whose parts open their folder; the last part edits the path, as ⇧⌘G does.
    private var breadcrumb: some View {
        let crumbs = path.isEmpty ? [] : Paths.breadcrumb(path, home: home)
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(crumbs.enumerated()), id: \.element.path) { i, crumb in
                    if i > 0 && crumbs[i - 1].path != "/" { Text("/") }
                    Button(crumb.name) { crumb.path == path ? startEditingPath() : navigate(to: crumb.path) }
                        .foregroundStyle(crumb.path == path ? .primary : .secondary) // where it is, among where it came through
                        .help(crumb.path == path ? "Edit Path (⇧⌘G)" : crumb.path)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.leading, for: .alignment)
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    // MARK: Listing

    @ViewBuilder
    private func content(_ visible: [FileEntry]) -> some View {
        if let loadError {
            ContentUnavailableView {
                Label("Couldn’t Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
                if Paths.parent(path) != nil { Button("Enclosing Folder") { goUp() } }
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 0) {
                columns { column in sortButton(column) }
                    .font(style.detail)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Self.rowInset)
                    .padding(.top, 4)
                    .contextMenu {
                        ForEach([FileColumn.permissions, .owner], id: \.self) { column in
                            Toggle(Self.titles[column] ?? "", isOn: Binding(
                                get: { extraColumns.contains(column) },
                                set: { if $0 { extraColumns.insert(column) } else { extraColumns.remove(column) } }))
                        }
                    }
                list(visible).overlay { emptyState(visible) }
            }
            .transition(.opacity)
        }
    }

    // MARK: Columns

    private static let titles: [FileColumn: String] =
        [.name: "Name", .size: "Size", .modified: "Modified", .permissions: "Permissions", .owner: "Owner"]
    /// Fixed widths; Name takes the rest.
    private static let widths: [FileColumn: CGFloat] = [.size: 70, .modified: 110, .permissions: 90, .owner: 80]
    /// Where the inset list draws a row's content (measured), which the header repeats to sit over its columns.
    private static let rowInset: CGFloat = 16
    /// One line of the listing or its header: Name, then Size and Modified, then Permissions and Owner once
    /// shown from the header's context menu.
    // shortcut: columns have fixed widths and a fixed order; make them resizable if users ask.
    private func columns(@ViewBuilder _ cell: @escaping (FileColumn) -> some View) -> some View {
        HStack(spacing: 12) {
            cell(.name).frame(maxWidth: .infinity, alignment: .leading)
            let shown = [FileColumn.size, .modified, .permissions, .owner].filter { [.size, .modified].contains($0) || extraColumns.contains($0) }
            ForEach(shown, id: \.self) { column in
                cell(column).frame(width: Self.widths[column], alignment: column == .size ? .trailing : .leading)
            }
        }
        .lineLimit(1)
    }

    /// A column title: quiet, sorts by its column on click and flips the order on a second click.
    private func sortButton(_ column: FileColumn) -> some View {
        let current = sortOrder.first
        let ascending = current?.column == column && current?.order == .forward
        let title = Self.titles[column] ?? ""
        return Button {
            sortOrder = [FileComparator(column, order: ascending ? .reverse : .forward)]
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if current?.column == column {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").imageScale(.small)
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Sort by \(title)")
    }

    @ViewBuilder
    private func cell(_ column: FileColumn, _ entry: FileEntry) -> some View {
        switch column {
        case .name: nameCell(entry)
        case .size: Text(entry.isDir ? "Folder" : FileRules.size(entry.size)).monospacedDigit().foregroundStyle(.secondary)
        case .modified:
            Text(entry.modified.map { FileRules.modified($0) } ?? "--")
                .foregroundStyle(.secondary)
                .help(entry.modified?.formatted(date: .complete, time: .standard) ?? "")
        case .permissions: Text(entry.permissions.map(FileRules.symbolic) ?? "--").monospaced().foregroundStyle(.secondary)
        case .owner: Text(entry.owner ?? "--").foregroundStyle(.secondary)
        }
    }

    /// A `List` rather than a `Table`: a table's header, row separators and row font cannot be made this quiet.
    private func list(_ visible: [FileEntry]) -> some View {
        List(selection: $selectedIDs) {
            ForEach(visible) { entry in
                columns { cell($0, entry) }
                    .font(style.row)
                    .listRowSeparator(.hidden)
                    .itemProvider { dragItem(entry) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids.isEmpty ? [] : visible.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            open(visible.filter { ids.contains($0.id) })
        }
        .onKeyPress(.return) {
            guard renaming == nil else { return .ignored }
            open(selectedEntries)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .delete, .space, "g", "G", ".", ">", "f", "[", "]"], phases: .down) { press in
            // Only the four modifiers a user holds count; Caps Lock, keypad and function flags do not.
            switch (press.key, press.modifiers.intersection([.command, .shift, .option, .control])) {
            case (.upArrow, .command): goUp()
            case (.space, []):
                // Not while a name is being typed in a row.
                guard renaming == nil, let file = selectedEntries.first(where: { !$0.isDir }) else { return .ignored }
                preview(file)
            case (.delete, .command): if !selectedEntries.isEmpty { pendingDelete = selectedEntries }
            case ("g", [.command, .shift]), ("G", [.command, .shift]): startEditingPath()
            case (".", [.command, .shift]), (">", [.command, .shift]): showHidden.toggle()
            case ("f", .command): filtering = true; filterFocused = true
            case ("[", .command): goBack()
            case ("]", .command): goForward()
            default: return .ignored
            }
            return .handled
        }
    }

    private func nameCell(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            // The folder, link or file type's own icon, as Finder lists them; the Size column says "Folder" in words.
            Image(nsImage: entry.icon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
            if renaming == entry.id {
                TextField("Name", text: $renameText)
                    .focused($renameFocused)
                    .onSubmit { commitRename(entry) }
                    .onExitCommand { renaming = nil }
                    // Clicking away commits, as in Finder; focus that never arrived does not.
                    .onChange(of: renameFocused) { was, now in if was && !now { commitRename(entry) } }
                    .task {
                        // After the context menu that started the rename hands focus back to the list.
                        try? await Task.sleep(for: .milliseconds(50))
                        renameFocused = true
                    }
            } else {
                Text(entry.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.isSymlink ? "\(entry.name) (symbolic link)" : entry.name)
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ visible: [FileEntry]) -> some View {
        if visible.isEmpty, !loading, !path.isEmpty {
            // Hit testing passes through to the list, so its background menu still works.
            if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: filter).allowsHitTesting(false)
            } else if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text(onReceive == nil ? "" : "Drop files here to copy them into this folder."))
                    .allowsHitTesting(false)
            } else {
                ContentUnavailableView {
                    Label("Only Hidden Items", systemImage: "eye.slash")
                } actions: {
                    Button("Show Hidden Files") { showHidden = true }
                }
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(_ items: [FileEntry]) -> some View {
        if items.isEmpty {
            Button("New Folder") { startNew(file: false) }
            Button("New File") { startNew(file: true) }
            Toggle("Show Hidden Files", isOn: $showHidden)
            Button("Copy Path") { copy(path) }
        } else {
            let folder = items.count == 1 && items[0].isDir
            Button(folder || provider.isLocal ? "Open" : "Edit on This Mac") { open(items) }
                .disabled(!folder && !((provider.isLocal || onEdit != nil) && items.contains { !$0.isDir }))
            // Files on either side: this Mac's open in the app picked, a host's as a copy that goes back on each save.
            let files = items.filter { !$0.isDir }
            if !files.isEmpty, provider.isLocal || onEdit != nil {
                Menu(provider.isLocal ? "Open With" : "Edit With") {
                    ForEach(Self.editors(for: files.map(\.name)), id: \.self) { app in
                        Button { open(files, with: app) } label: {
                            Label { Text(app.deletingPathExtension().lastPathComponent) } icon: { Image(nsImage: Self.menuIcon(app)) }
                                .labelStyle(.titleAndIcon) // a menu drops the icon otherwise
                        }
                    }
                }
            }
            if items.count == 1, !folder { Button("Quick Look") { preview(items[0]) } }
            if let onTransfer {
                Button(transferTitle?(items.count)
                    ?? (items.count == 1 ? "Transfer to Other Pane" : "Transfer \(items.count) Items to Other Pane")) { onTransfer(items) }
            }
            Divider()
            Button("Rename") { startRename(items[0]) }.disabled(items.count != 1)
            Button("Move to…") { moveText = path; moving = items }
            Button("Duplicate") { duplicate(items) }
            // A symlink lists its own mode, and changing it would land on the target (upstream `canEditPermissions`).
            Button("Permissions…") { permissions = PermissionsRequest(entries: items) }
                .disabled(!items.allSatisfy { $0.permissions != nil && !$0.isSymlink })
            Button(items.count == 1 ? "Copy Path" : "Copy Paths") { copy(FileRules.copyPathText(items)) }
            Divider()
            if items.count == 1, !items[0].isDir, Archives.isArchive(items[0].name) {
                Button("Extract") { extract(items[0]) }
            }
            Button(items.count == 1 ? "Compress" : "Compress \(items.count) Items") { compress(items) }
            Divider()
            Button("New Folder") { startNew(file: false) }
            Button("New File") { startNew(file: true) }
            Divider()
            Button(provider.isLocal ? "Move to Trash…" : items.count == 1 ? "Delete…" : "Delete \(items.count) Items…",
                   role: .destructive) { pendingDelete = items }
        }
    }

    // MARK: Actions

    private var visible: [FileEntry] {
        FileRules.visible(entries, showHidden: showHidden, filter: filter, sort: sortOrder)
    }

    /// Only rows the user can see: the filter and the hidden-files toggle drop rows from the selection.
    private var selectedEntries: [FileEntry] { visible.filter { selectedIDs.contains($0.id) } }

    private func pruneSelection() {
        selectedIDs.formIntersection(visible.map(\.id))
        syncSelection()
    }

    private func load() async {
        let folder = path
        loading = true
        defer { if folder == path { loading = false } }
        do {
            guard !folder.isEmpty else {
                home = try await provider.home()
                path = home ?? ""
                return
            }
            // Once, for the path's "~".
            if home == nil { home = try? await provider.home() }
            let listed = try await provider.list(folder)
            // A slow listing of a folder the user already left must not replace the new one.
            guard folder == path, !Task.isCancelled else { return }
            entries = listed
            loadError = nil
            if let found = revealing {
                selectedIDs = [found]
                revealing = nil
            }
            pruneSelection()
        } catch is CancellationError {
            return
        } catch {
            guard folder == path else { return }
            entries = []
            loadError = error.localizedDescription
        }
    }

    private func syncSelection() {
        selection = selectedEntries
    }

    /// - Parameter remember: the folder left goes on Back's list; false for Back and Forward themselves.
    private func navigate(to newPath: String, remember: Bool = true) {
        guard newPath != path || newPath.isEmpty else { return }
        // Home again while at home (an empty path lists it afresh) is not a move.
        if remember, !path.isEmpty, (newPath.isEmpty ? home : newPath) != path { history.moved(from: path) }
        path = newPath
        selectedIDs = []
        filter = ""
        filtering = false
        renaming = nil
    }

    private func toggleFilter() {
        if filtering || !filter.isEmpty {
            filter = ""
            filtering = false
        } else {
            filtering = true
        }
    }

    private func goUp() {
        if let parent = Paths.parent(path) { navigate(to: parent) }
    }

    private func goBack() {
        if let folder = history.goBack(from: path) { navigate(to: folder, remember: false) }
    }

    private func goForward() {
        if let folder = history.goForward(from: path) { navigate(to: folder, remember: false) }
    }

    private func startEditingPath() {
        pathText = path
        editingPath = true
    }

    /// The path bar's text: `~` and relative paths resolve, symlinks resolve, and a file opens its folder.
    private func go(to text: String) {
        editingPath = false
        perform("Couldn’t Open “\(text)”", reload: false) {
            let target = try await provider.realpath(Paths.resolve(text, cwd: path, home: try await provider.home()))
            guard let isDir = try await provider.stat(target) else { throw FileError("The folder can’t be found.") }
            navigate(to: isDir ? target : Paths.parent(target) ?? "/")
        }
    }

    /// - Parameter app: the app picked from "Open With" or "Edit With"; nil is the row's own open.
    private func open(_ items: [FileEntry], with app: URL? = nil) {
        if app == nil, items.count == 1, items[0].isDir { return navigate(to: items[0].path) }
        let files = items.filter { !$0.isDir }
        // A host's file opens as a copy in this Mac's text editor, where upstream opens its editor tab.
        guard provider.isLocal else { onEdit?(files, app); return }
        for file in files.map({ URL(filePath: $0.path) }) {
            if let app { Self.open(file, with: app) } else { NSWorkspace.shared.open(file) }
        }
    }

    /// Opens `file` in `app`, the one picked from "Edit With"; for nil, in the app this Mac uses for plain text,
    /// whatever the file's name: unasked, a file from a host never goes to the app its name asks for, which could
    /// run it (a `.command`, an app, a file marked executable).
    public static func open(_ file: URL, with app: URL?) {
        guard let app = app ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Edit With" for files with these names: this Mac's text editor first, then every app that opens plain text
    /// or one of the files' own types, by name.
    static func editors(for names: [String]) -> [URL] {
        let types = [UTType.plainText] + names.compactMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        let apps = types.flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var seen = Set<String>()
        return ([NSWorkspace.shared.urlForApplication(toOpen: .plainText)].compactMap { $0 } + apps)
            .filter { seen.insert($0.lastPathComponent).inserted } // one row per name: a second copy of an app adds nothing
    }

    private static func menuIcon(_ app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// A search result: a folder opens, a file is selected in its own folder.
    private func reveal(_ entry: FileEntry) {
        guard !entry.isDir, let folder = Paths.parent(entry.path) else { return navigate(to: entry.path) }
        guard folder == path else { revealing = entry.id; return navigate(to: folder) }
        (filter, filtering) = ("", false) // or the row it selects could be one the filter hides
        selectedIDs = [entry.id]
    }

    /// Quick Look: this Mac's file itself, a host's as a copy fetched for it (`FilePreview`).
    private func preview(_ entry: FileEntry) {
        previewTask?.cancel() // Space on another row while one is still arriving
        previewTask = Task {
            busy += 1
            defer { busy -= 1 }
            do {
                let url = try await FilePreview.url(for: entry, on: provider)
                if Task.isCancelled { FilePreview.discard(url) } else { previewURL = url }
            } catch is CancellationError {
            } catch {
                failure = Failure(title: "Couldn’t Preview “\(entry.name)”", message: error.localizedDescription)
            }
        }
    }

    private func startRename(_ entry: FileEntry) {
        renameText = entry.name
        renaming = entry.id
    }

    private func commitRename(_ entry: FileEntry) {
        guard renaming == entry.id else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.name else { return }
        perform("Couldn’t Rename “\(entry.name)”") {
            guard Paths.isPlainName(name) else { throw FileError("“\(name)” can’t be used as a name.") }
            let target = Paths.join(Paths.parent(entry.path) ?? "/", name)
            try await provider.rename(entry.path, to: target)
            selectedIDs = [target]
        }
    }

    private func startNew(file: Bool) {
        folderName = file ? "untitled.txt" : "untitled folder"
        creatingFile = file
        creatingFolder = true
    }

    private func create(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = creatingFile
        let target = Paths.join(path, name) // where the pane is now, not where it is when the work runs
        perform(file ? "Couldn’t Create File" : "Couldn’t Create Folder") {
            guard Paths.isPlainName(name) else { throw FileError("“\(name)” can’t be used as a \(file ? "file" : "folder") name.") }
            if file {
                // Asked first for its plain words; `createFile` itself never writes over a file.
                guard try await provider.stat(target) == nil else { throw FileError("“\(name)” already exists.") }
                try await provider.createFile(target)
                open([FileEntry(name: name, path: target)]) // to be written in, which is what a new file is for
            } else {
                try await provider.mkdir(target)
            }
            selectedIDs = [target]
        }
    }

    /// To the folder typed, as Go to Folder reads it; nothing there is replaced (`rename` fails on a name in use).
    private func move(_ items: [FileEntry], to text: String) {
        let from = path
        perform(items.count == 1 ? "Couldn’t Move “\(items[0].name)”" : "Couldn’t Move Every Item") {
            let folder = try await provider.realpath(Paths.resolve(text, cwd: from, home: try await provider.home()))
            guard try await provider.stat(folder) == true else { throw FileError("“\(text)” is not a folder.") }
            for item in items where Paths.parent(item.path) != folder {
                guard !Paths.isSameOrUnder(folder, item.path) else { throw FileError("“\(item.name)” can’t be moved into itself.") }
                let target = Paths.join(folder, item.name)
                // Asked first: not every server refuses a rename onto a name in use.
                guard try await provider.stat(target) == nil else { throw FileError("“\(item.name)” is already in “\(Paths.name(folder))”.") }
                try await provider.rename(item.path, to: target)
            }
        }
    }

    /// The folder `items` are in and the names in use there, read when the action is asked for: the pane may show
    /// another folder by the time the work runs.
    private func home(of items: [FileEntry]) -> (folder: String, taken: Set<String>) {
        (items.first.flatMap { Paths.parent($0.path) } ?? path, Set(entries.map(\.name)))
    }

    private func duplicate(_ items: [FileEntry]) {
        let (folder, names) = home(of: items)
        perform(items.count == 1 ? "Couldn’t Duplicate “\(items[0].name)”" : "Couldn’t Duplicate Every Item") {
            var taken = names, made = Set<String>()
            for item in items {
                let name = FileRules.copyName(item, taken: taken)
                taken.insert(name)
                try await provider.copy(item.path, to: Paths.join(folder, name))
                made.insert(Paths.join(folder, name))
            }
            if path == folder { selectedIDs = made }
        }
    }

    private func compress(_ items: [FileEntry]) {
        let (folder, taken) = home(of: items)
        let archive = Paths.join(folder, FileRules.freeName(items.count == 1 ? items[0].name : "Archive", ending: Archives.made, taken: taken))
        perform(items.count == 1 ? "Couldn’t Compress “\(items[0].name)”" : "Couldn’t Compress \(items.count) Items") {
            try await provider.compress(items.map(\.path), to: archive)
            if path == folder { selectedIDs = [archive] }
        }
    }

    /// Into a new folder named after the archive, so nothing in this one is written over.
    private func extract(_ item: FileEntry) {
        let (parent, taken) = home(of: [item])
        let folder = Paths.join(parent, FileRules.freeName(Archives.stem(item.name), taken: taken))
        perform("Couldn’t Extract “\(item.name)”") {
            try await provider.mkdir(folder)
            do {
                try await provider.extract(item.path, into: folder)
            } catch {
                // Nothing came out: the folder made for it goes again. One with something in it stays.
                if (try? await provider.list(folder))?.isEmpty == true { try? await provider.delete(folder) }
                throw error
            }
            if path == parent { selectedIDs = [folder] }
        }
    }

    private func delete(_ items: [FileEntry]) {
        let verb = provider.isLocal ? "Move" : "Delete"
        perform(items.count == 1 ? "Couldn’t \(verb) “\(items[0].name)”" : "Couldn’t \(verb) Every Item") {
            for item in items { try await provider.delete(item.path) }
        }
    }

    private var deleteTitle: String {
        guard let items = pendingDelete else { return "" }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) Items"
        return provider.isLocal ? "Move \(what) to the Trash?" : "Delete \(what)?"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Runs `action`, shows its error under `title`, then lists the folder again.
    private func perform(_ title: String, reload: Bool = true, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            busy += 1
            defer { busy -= 1 }
            do {
                try await action()
            } catch {
                failure = Failure(title: title, message: error.localizedDescription)
            }
            if reload { await load() }
        }
    }

    // MARK: Drag and drop

    /// A local entry drags as its file URL, so Finder and other apps take it; a remote one as a token only
    /// this app can read, which the receiving pane turns back into the entry and its provider.
    private func dragItem(_ entry: FileEntry) -> NSItemProvider? {
        PaneDrag.starting.append(entry)
        if provider.isLocal { return NSItemProvider(contentsOf: URL(filePath: entry.path)) }
        let token = PaneDrag.register(PaneDrag.Item(pane: paneID, entry: entry, provider: provider))
        let item = NSItemProvider()
        item.registerDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier, visibility: .ownProcess) { done in
            done(Data(token.utf8), nil)
            return nil
        }
        return item
    }

    private func receive(_ items: [NSItemProvider]) async {
        guard let onReceive else { return }
        var urls: [URL] = [], dragged: [PaneDrag.Item] = []
        for item in items {
            if item.hasItemConformingToTypeIdentifier(PaneDrag.type.identifier) {
                let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                    _ = item.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in done.resume(returning: data) }
                }
                if let data, let found = PaneDrag.take(String(decoding: data, as: UTF8.self)) { dragged.append(found) }
            } else {
                let url = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
                    _ = item.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
        }
        PaneDrag.clear()
        // Rows dropped back on the pane they came from stay where they are.
        for group in Dictionary(grouping: dragged.filter { $0.pane != paneID }, by: \.pane).values {
            onReceive(group.map(\.entry), group[0].provider, path)
        }
        let files = urls.compactMap { try? LocalFileProvider.entry(at: $0.path(percentEncoded: false)) }
            .filter { !(provider.isLocal && Paths.parent($0.path) == path) }
        if !files.isEmpty { onReceive(files, LocalFileProvider(), path) }
    }
}

/// Rows dragged out of remote panes, by token, until a pane takes them.
@MainActor
public enum PaneDrag {
    /// The entries of the drag that is starting: the app reads and clears it to draw its drag image.
    public static var starting: [FileEntry] = []

    static let type = UTType(exportedAs: "app.soltz.files.pane-drag")

    struct Item {
        var pane: UUID
        var entry: FileEntry
        var provider: any FileProvider
    }

    // shortcut: a drag that never lands leaves its tokens until the next drop clears them; fine for a session.
    private static var items: [String: Item] = [:]

    static func register(_ item: Item) -> String {
        let token = UUID().uuidString
        items[token] = item
        return token
    }

    static func take(_ token: String) -> Item? { items.removeValue(forKey: token) }

    static func clear() { items.removeAll() }
}

struct PermissionsRequest: Identifiable {
    let id = UUID()
    var entries: [FileEntry]
}

private struct Failure {
    var title: String
    var message: String
}

extension View {
    /// A header field: the quiet fill of a search field, not a second glass on the card.
    func field(_ style: FilesStyle, leading: CGFloat = 8) -> some View {
        padding(.leading, leading)
            .padding(.trailing, 8)
            .frame(height: style.fieldHeight)
            .background(.fill.quaternary, in: .rect(cornerRadius: style.fieldRadius, style: .continuous))
    }
}

extension FileEntry {
    /// The system icon for the entry's type, by name: folders, symlinks, then the file extension.
    @MainActor var icon: NSImage {
        let type: UTType = isDir ? .folder : isSymlink ? .symbolicLink
            : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
