// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzHostsUI
import SoltzModel
import SoltzWorkspace
import SwiftUI

/// One host row of the sidebar's card: a saved SSH host, a session whose host was deleted since, or This Mac.
struct HomeRow: Identifiable, Equatable {
    /// The workspace it opens.
    let id: String
    let name: String
    let detail: String
    var host: Connection?
}

extension Workspace {
    /// The sidebar's host rows by group (a host folder of the vault): hosts in no group and This Mac first, then each group's hosts
    /// under its name (its path, for a folder inside another). Only SSH hosts are listed, the one type Soltz connects
    /// to; a session whose host is gone keeps a row while it lives. An empty group shows too, so a new one can be
    /// seen and filled, but not in a search: there only what was found shows.
    func homeGroups(matching query: String = "") -> [(folder: Folder?, title: String?, rows: [HomeRow])] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func path(_ id: String?) -> String? {
            var names: [String] = [], next = id, seen: Set<String> = []
            while let id = next, let folder = byID[id], seen.insert(id).inserted {
                names.insert(folder.name, at: 0)
                next = folder.parentFolderID
            }
            return names.isEmpty ? nil : names.joined(separator: " / ")
        }
        func matches(_ row: HomeRow) -> Bool {
            query.isEmpty || [row.name, row.detail, row.host?.username ?? ""].contains { $0.localizedStandardContains(query) }
        }
        let hosts = connections.filter { $0.connectionType == .ssh }.map { host in
            let name = host.name.flatMap { $0.isEmpty ? nil : $0 }
            let address = host.port == 22 || host.port == 0 ? host.host : "\(host.host):\(host.port)"
            return (folder: host.folderID.flatMap { byID[$0] }, row: HomeRow(id: host.id, name: name ?? address,
                                                                             detail: name == nil ? host.username : address, host: host))
        }
        let saved = Set(hosts.map(\.row.id))
        let orphans = Set(tabs.map(key(of:))).subtracting(saved.union([Self.thisMac])).sorted().map {
            HomeRow(id: $0, name: name(of: $0), detail: "Session")
        }
        let local = HomeRow(id: Self.thisMac, name: "Local terminal", detail: "This Mac")
        // Most recently used first, then by name.
        let byName = { (a: HomeRow, b: HomeRow) in
            let (x, y) = (a.host?.lastUsedAt ?? "", b.host?.lastUsedAt ?? "")
            return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let filed = Dictionary(grouping: hosts.filter { $0.folder != nil }, by: { $0.folder!.id })
        let filled = filed.compactMap { id, members in byID[id].map { (folder: $0, title: path(id) ?? $0.name, rows: members.map(\.row).sorted(by: byName)) } }
        let empty = folders.filter { $0.objectType == .connection && $0.deletedAt == nil && filed[$0.id] == nil }
            .map { (folder: $0, title: path($0.id) ?? $0.name, rows: [HomeRow]()) }
        let named = (filled + empty).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return ([(folder: Folder?.none, title: String?.none, rows: hosts.filter { $0.folder == nil }.map(\.row).sorted(by: byName) + orphans + [local])]
            + named.map { (folder: Optional($0.folder), title: Optional($0.title), rows: $0.rows) })
            // A group whose name matches shows all its hosts.
            .map { group in
                let named = !query.isEmpty && group.title?.localizedStandardContains(query) == true
                return (folder: group.folder, title: group.title, rows: named ? group.rows : group.rows.filter(matches))
            }
            .filter { !$0.rows.isEmpty || ($0.folder != nil && query.isEmpty) }
    }

    /// Files `host` in a group, or in none.
    func move(_ host: Connection, toGroup folderID: String?) async throws {
        var host = connections.first { $0.id == host.id } ?? host
        host.folderID = folderID
        try await save(host, HostSecrets())
    }

    /// A new group, empty or with `host` as its first member.
    func newGroup(_ name: String, with host: Connection? = nil) async throws {
        let folder = try Folder(json: ["id": .string(UUID().uuidString.lowercased()), "name": .string(name), "created_at": "",
                                       "updated_at": "", "clocks": [:]])
        try await save(folder)
        if let host { try await move(host, toGroup: folder.id) }
    }

    func rename(_ folder: Folder, to name: String) async throws {
        var folder = folder
        folder.name = name
        try await save(folder)
    }

    /// Deletes a group and keeps its hosts: they leave it first, because deleting a folder deletes what it still holds.
    func deleteGroup(_ folder: Folder) async throws {
        let inside = Self.subtree(folder.id, folders.map { ($0.id, $0.parentFolderID) })
        for host in connections where host.folderID.map(inside.contains) == true { try await move(host, toGroup: nil) }
        try await delete(folder)
    }

    /// Whether a workspace has tabs: nil when it has none, true while any of its sessions lives.
    func liveState(_ key: String) -> Bool? {
        let mine = tabs(of: key)
        guard !mine.isEmpty else { return nil }
        return mine.contains { !hasEnded($0) }
    }

    /// A row's Open: back to the host's tab when it has one, else a new connection (or local shell).
    func open(_ key: String) {
        if liveState(key) != nil { show(key) } else { openTab(for: Dragged(kind: .host, id: key)) }
    }
}

/// What the group card names: a new group (`host` moves into it, if given) or `folder` renamed.
struct GroupNaming: Identifiable {
    let id = UUID()
    var folder: Folder?
    var host: Connection?
    var name = ""
}

/// New group and Rename group as a card: New host's rows, for one name.
struct GroupSheet: View {
    @ViewState var form: GroupNaming
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 0) {
            Text(form.folder == nil ? "New group" : "Rename group").font(Theme.title)
                .padding(.horizontal, Theme.sheetInset).padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            Form {
                Section {
                    TextField("Name", text: $form.name, prompt: Text("Group name"))
                } footer: {
                    if let host = form.host {
                        Text("“\(host.name.flatMap { $0.isEmpty ? nil : $0 } ?? host.host)” moves into it.")
                    } else if form.folder == nil {
                        Text("Drag hosts onto it, or right-click a host and choose Move to Group.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            SheetActions(action: form.folder == nil ? "Create" : "Rename", disabled: name.isEmpty || name == form.folder?.name,
                         cancel: { dismiss() }) {
                let form = form
                workspace.change("Couldn’t Save the Group") {
                    if let folder = form.folder { try await workspace.rename(folder, to: name) }
                    else { try await workspace.newGroup(name, with: form.host) }
                }
                dismiss()
            }
        }
        .frame(width: Theme.sheetWidth)
        .glassSheet()
    }
}

/// The sidebar: a tree in one glass card. Groups are folders of hosts, and each host holds its open sessions (terminals
/// and files) as a folder holds files; both close and open from their chevron. A click shows a session, or the tab of
/// a host that has some; Return, a double-click or the row's "+" opens a host. Arrows move through hosts and sessions.
/// A host or a session dragged onto the main panel opens a new tab there.
struct HomeView: View {
    @Environment(Workspace.self) private var workspace
    @ViewState private var selection: String?
    @ViewState private var query = ""
    @ViewState private var pendingDelete: Connection?
    @ViewState private var hovered: String?
    @ViewState private var pendingGroupDelete: Folder?
    /// The closed groups' and hosts' ids, comma-separated (what `AppStorage` can hold; the key is from when only
    /// groups closed).
    @AppStorage("homeCollapsedGroups") private var closedRows = ""
    @Namespace private var pill
    @FocusState private var focused: Bool

    /// Nothing is closed to a filter: what is typed is looked for everywhere.
    private var closed: Set<String> { query.isEmpty ? Set(closedRows.split(separator: ",").map(String.init)) : [] }

    var body: some View {
        let groups = workspace.homeGroups(matching: query)
        let closed = closed
        let rows = groups.flatMap { group in group.folder.map { closed.contains($0.id) } == true ? [] : group.rows }
        // What the arrows step through: each host, then the sessions it shows.
        let ids = rows.flatMap { row in [row.id] + (closed.contains(row.id) ? [] : workspace.sessions(of: row.id).map(\.id)) }
        let active = workspace.shown == nil ? nil : workspace.activeSession?.id
        VStack(alignment: .leading, spacing: 0) {
            header
            search(ids)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A group is its folder (nil: the hosts in none), so rows keep their place while a search narrows.
                    ForEach(groups, id: \.folder?.id) { group in
                        section(group.folder, group.title, group.rows, closed)
                    }
                    if rows.isEmpty, !query.isEmpty {
                        Text("No hosts match “\(query)”").font(Theme.body).foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.cardInset - Theme.rowInset).frame(height: Theme.rowHeight)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Theme.rowInset)
                .animation(Theme.motion, value: selection)
                .animation(Theme.motion, value: hovered)
                .animation(Theme.motion, value: workspace.dropTarget)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: Theme.sidebarWidth)
        .animation(Theme.motion, value: closedRows) // the rows follow a folder opening or closing
        .animation(Theme.motion, value: ids)  // and what a search finds, hosts loading, added, deleted, sessions opening
        // A pane beside the panes, so their radius.
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.paneRadius, style: .continuous))
        // The first row stays selected until the user picks another (the list fills in once the hosts load).
        .onChange(of: ids, initial: true) { old, ids in
            if selection == old.first || !ids.contains(selection ?? "") {
                selection = active.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            }
        }
        // The pill follows the session that has the keys, however it got them (a click here or in a pane, a tab below).
        .onChange(of: active) { if let key = $1 { selection = key } }
        .onAppear { focused = true }
        // The last session closed: the keyboard is the search's again.
        .onChange(of: workspace.shown) { if $1 == nil { focused = true } }
        .confirmationDialog("Delete “\(pendingDelete.map { $0.name ?? $0.host } ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { host in
            Button("Delete", role: .destructive) { workspace.change("Couldn’t Delete the Host") { try await workspace.delete(host) } }
        } message: { _ in
            Text("Its open sessions keep running.")
        }
        .confirmationDialog("Delete Group “\(pendingGroupDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingGroupDelete != nil }, set: { if !$0 { pendingGroupDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingGroupDelete) { folder in
            Button("Delete Group", role: .destructive) { workspace.change("Couldn’t Delete the Group") { try await workspace.deleteGroup(folder) } }
        } message: { _ in
            Text("Its hosts stay in the list, in no group.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Hosts").font(Theme.title)
            Spacer()
            Button("New Group", systemImage: "folder.badge.plus") { workspace.naming = GroupNaming() }
                .labelStyle(.iconOnly)
                .buttonStyle(Pill(circle: true, height: Theme.addButton, font: Theme.chrome))
                .help("New Group")
            Button("New Host", systemImage: "plus") { workspace.newHost = NewHostForm() }
                .labelStyle(.iconOnly)
                .buttonStyle(Pill(prominent: true, circle: true, height: Theme.addButton))
                .help("New Host")
        }
        .padding(.leading, Theme.cardInset)
        .padding(.trailing, Theme.rowInset + 5)
        .frame(height: Theme.headerHeight)
    }

    /// Search: it has the keyboard while no terminal does, so typing searches, the arrows move through what is found
    /// and Return opens it.
    private func search(_ ids: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search", text: $query, prompt: Text("Search hosts"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1, in: ids) }
                .onKeyPress(.upArrow) { move(-1, in: ids) }
                .onKeyPress(.return) {
                    guard let selection, ids.contains(selection) else { return .ignored }
                    if workspace.sessions[selection] != nil { workspace.reveal(selection) } else { workspace.open(selection) }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion, value: query.isEmpty)
        .font(Theme.body)
        .padding(.horizontal, Theme.cardInset - Theme.rowInset)
        .frame(height: Theme.searchField)
        .background(.fill.quaternary, in: .rect(cornerRadius: Theme.rowPill / 2 - 4, style: .continuous))
        .padding(.horizontal, Theme.rowInset)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, Theme.rowInset).padding(.top, 7)
            HStack {
                if let release = workspace.updates.available {
                    Button("Update to \(release.version)", systemImage: "arrow.down.circle.fill") { workspace.updates.open(release) }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .help("Soltz \(release.version) is available; opens its download page")
                        .transition(.opacity)
                } else {
                    Text("No account. Free, forever.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") { workspace.showingSettings = true }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .help("Terminal font and size")
            }
            .font(Theme.body)
            .padding(.horizontal, Theme.cardInset)
            .frame(height: Theme.footerHeight)
        }
    }

    // MARK: Tree

    /// One group: its folder row, then its hosts a level in, each with its sessions a level further. The hosts in no
    /// group stand at the top level. A host dropped anywhere on a group joins it; on the hosts in none, it leaves its
    /// group.
    private func section(_ folder: Folder?, _ title: String?, _ rows: [HomeRow], _ closed: Set<String>) -> some View {
        let isClosed = folder.map { closed.contains($0.id) } == true
        let zone = folder?.id ?? ""
        let level = folder == nil ? 0 : 1
        return VStack(alignment: .leading, spacing: 0) {
            if let folder, let title { groupRow(folder, title, count: rows.count, closed: isClosed) }
            if !isClosed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { host in
                        let sessions = workspace.sessions(of: host.id)
                        let hostClosed = closed.contains(host.id)
                        hostRow(host, level: level, sessions: sessions, closed: hostClosed).transition(.opacity)
                        if !hostClosed, !sessions.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(sessions, id: \.id) { sessionRow($0, level: level + 1).transition(.opacity) }
                            }
                            .background(alignment: .leading) { guide(level: level) }
                            .transition(.opacity)
                        }
                    }
                    if folder != nil, rows.isEmpty {
                        Text("Drag a host here").font(Theme.caption).foregroundStyle(.tertiary)
                            .padding(.leading, inset(1) + Theme.treeSlot)
                            .frame(maxWidth: .infinity, minHeight: Theme.sessionRow, alignment: .leading)
                    }
                }
                .background(alignment: .leading) { if folder != nil { guide(level: 0) } }
                .transition(.opacity)
            }
        }
        .padding(.top, folder == nil ? 0 : Theme.paneGap) // a group stands a little apart from what is above it
        .dropOutline(workspace.dropTarget == zone, radius: Theme.rowPill / 2 - 4)
        .dropDestination(for: Dragged.self) { drags, _ in
            guard let host = workspace.connections.first(where: { host in drags.contains { $0.kind == .host && $0.id == host.id } }) else { return false }
            regroup(host, folder?.id)
            return true
        } isTargeted: { over in
            if over { workspace.dropTarget = zone } else if workspace.dropTarget == zone { workspace.dropTarget = nil }
        }
    }

    /// Where a row of `level` starts, from the list's edge.
    private func inset(_ level: Int) -> CGFloat { 6 + CGFloat(level) * Theme.treeIndent }

    /// Where its pill starts: at the edge for the top level, else just right of the guide line it hangs from, so the
    /// line never runs through a selection.
    private func pillStart(_ level: Int) -> CGFloat { level == 0 ? 0 : inset(level - 1) + Theme.treeSlot }

    /// The line down from a folder's chevron, beside what it holds.
    private func guide(level: Int) -> some View {
        Rectangle().fill(.separator).frame(width: 1).padding(.leading, inset(level) + Theme.treeSlot / 2).padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    /// A folder's chevron, in its slot; a row that holds nothing keeps the slot, so names line up.
    private func chevron(_ id: String?, closed: Bool) -> some View {
        ZStack {
            if let id {
                Button(closed ? "Open" : "Close", systemImage: "chevron.right") { toggle(id) }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(closed ? 0 : 90))
                    .frame(width: Theme.treeSlot, height: Theme.treeSlot).contentShape(.rect)
                    .transition(.opacity)
            }
        }
        .frame(width: Theme.treeSlot)
        .animation(Theme.motion, value: closed)
    }

    private func toggle(_ id: String) {
        var ids = Set(closedRows.split(separator: ",").map(String.init))
        if !ids.insert(id).inserted { ids.remove(id) }
        closedRows = ids.sorted().joined(separator: ",")
    }

    /// A group as a folder: click to close or open it; rename and delete from its menu.
    private func groupRow(_ folder: Folder, _ title: String, count: Int, closed: Bool) -> some View {
        HStack(spacing: 4) {
            chevron(folder.id, closed: closed)
            Image(systemName: closed ? "folder.fill" : "folder").foregroundStyle(.secondary).frame(width: Theme.treeIcon)
                .contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
            // Quieter than a host's name: a folder is where hosts are, not something to open.
            Text(title).font(Theme.bodyStrong).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)").font(Theme.chromeRegular).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.leading, inset(0))
        .padding(.trailing, Theme.cardInset - Theme.rowInset)
        .frame(height: Theme.treeRow)
        .background { highlight(folder.id) }
        .onHover { hovered = $0 ? folder.id : (hovered == folder.id ? nil : hovered) }
        .padding(.vertical, 1) // a host row's pitch
        .contentShape(.rect)
        .onTapGesture { toggle(folder.id) }
        .contextMenu {
            Button("Rename…") { workspace.naming = GroupNaming(folder: folder, name: folder.name) }
            Button("Delete Group…", role: .destructive) { pendingGroupDelete = folder }
        }
        .help(closed ? "Show this group’s hosts" : "Hide this group’s hosts")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), group, \(count) hosts")
        .accessibilityValue(closed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits([.isHeader, .isButton])
    }

    /// A host, the folder of its sessions.
    private func hostRow(_ row: HomeRow, level: Int, sessions: [TerminalSession], closed: Bool) -> some View {
        let live = workspace.liveState(row.id)
        // Closed, it stands for the session inside that has the keys.
        let mark = closed ? sessions.first { $0.id == selection }?.id ?? row.id : row.id
        let isHovered = hovered == row.id
        return HStack(spacing: 4) {
            chevron(sessions.isEmpty ? nil : row.id, closed: closed)
            Image(systemName: row.id == Workspace.thisMac ? "laptopcomputer" : "server.rack")
                .foregroundStyle(live == true ? .primary : .secondary).frame(width: Theme.treeIcon).accessibilityHidden(true)
            Text(row.name).font(Theme.bodyStrong).lineLimit(1).layoutPriority(1)
            if let live {
                Circle().fill(live ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary)).frame(width: 6, height: 6)
                    .help(live ? "Connected" : "Session ended")
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            // One slot for what the row says and what it does, so it keeps its width under the pointer.
            ZStack(alignment: .trailing) {
                if isHovered {
                    // What to open on it: its terminal or its files.
                    Menu {
                        NewTabItems(terminal: { workspace.openTab(for: Dragged(kind: .host, id: row.id)) },
                                    files: row.host.map { host in { workspace.connect(to: host, files: true) } })
                    } label: {
                        Image(systemName: "plus").font(.system(size: Theme.paneIcon)).foregroundStyle(.secondary)
                            .frame(width: Theme.paneButton, height: Theme.paneButton).contentShape(.circle)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("New tab on \(row.name): its terminal or its files")
                    .accessibilityLabel("New Tab")
                    .transition(Theme.arrival)
                } else {
                    Text(closed && !sessions.isEmpty ? "\(sessions.count)" : row.detail)
                        .font(Theme.chromeRegular).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, inset(level) - pillStart(level))
        .padding(.trailing, isHovered ? 4 : Theme.cardInset - Theme.rowInset)
        .frame(height: Theme.treeRow)
        .animation(Theme.motion, value: live) // the dot arrives, greys and leaves with its session
        .background { highlight(mark) }
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
        .padding(.leading, pillStart(level))
        .padding(.vertical, 1)
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded {
            // A host with sessions shows its tab (the pill goes to the session shown); one without is only selected.
            if live != nil {
                workspace.show(row.id)
                selection = workspace.activeSession?.id
            } else {
                selection = row.id
                focused = true
            }
        })
        .onTapGesture(count: 2) { workspace.open(row.id) }
        // Onto a group (a saved host joins it), or onto the main panel: a new tab on this host.
        .draggable(Dragged(kind: .host, id: row.id)) {
            DragChip(title: row.name, systemImage: row.host == nil ? "laptopcomputer" : "server.rack")
        }
        .contextMenu { hostMenu(row) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(live == true ? "Connected" : live == false ? "Session ended" : "")
        .accessibilityAddTraits(selection == mark ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workspace.open(row.id) }
    }

    @ViewBuilder private func hostMenu(_ row: HomeRow) -> some View {
        Button("New Terminal Tab") { workspace.openTab(for: Dragged(kind: .host, id: row.id)) }
        if let host = row.host {
            Button("New Files Tab") { workspace.connect(to: host, files: true) }
            Divider()
            Button("Edit…") { workspace.editing = host }
            Button("Duplicate") { workspace.change("Couldn’t Duplicate the Host") { try await workspace.duplicate(host) } }
            Menu("Move to Group") {
                let groups = workspace.folders.filter { $0.objectType == .connection && $0.deletedAt == nil }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                Toggle("None", isOn: Binding(get: { host.folderID == nil }, set: { _ in regroup(host, nil) }))
                ForEach(groups) { folder in
                    Toggle(folder.name, isOn: Binding(get: { host.folderID == folder.id }, set: { _ in regroup(host, folder.id) }))
                }
                Divider()
                Button("New Group…") { workspace.naming = GroupNaming(host: host) }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = host }
        }
    }

    /// A session of the host above it, as a file in its folder: a terminal, or the host's files. A click shows it,
    /// in its tab and pane; dragged onto the main panel, it opens another like it in a new tab.
    private func sessionRow(_ session: TerminalSession, level: Int) -> some View {
        let id = session.id
        let ended = session.ended
        let title = workspace.label(of: session)
        let symbol = session.showsFiles ? TerminalSession.filesSymbol : "terminal"
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(Theme.chromeRegular).foregroundStyle(.secondary).frame(width: Theme.treeIcon)
                .accessibilityHidden(true)
            Text(title).font(Theme.body).lineLimit(1)
            Spacer(minLength: 4)
            if hovered == id {
                Button("Close", systemImage: "xmark") { workspace.close(id) }
                    .labelStyle(.iconOnly).buttonStyle(PaneButton())
                    .help("Close this session")
                    .transition(Theme.arrival)
            }
        }
        .foregroundStyle(ended ? .secondary : .primary)
        .padding(.leading, inset(level) + Theme.treeSlot + 4 - pillStart(level))
        .padding(.trailing, 4)
        .frame(height: Theme.sessionRow)
        .background { highlight(id) }
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .padding(.leading, pillStart(level))
        .padding(.vertical, 1)
        .contentShape(.rect)
        .onTapGesture {
            selection = id
            workspace.reveal(id)
        }
        .draggable(Dragged(kind: .session, id: id)) { DragChip(title: title, systemImage: symbol) }
        .contextMenu { Button("Close") { workspace.close(id) } }
        .help(ended ? "\(title) — ended" : title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ended ? "\(title), session, ended" : "\(title), session")
        .accessibilityAddTraits(selection == id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workspace.reveal(id) }
        .accessibilityAction(named: "Close") { workspace.close(id) }
    }

    /// A row's hover and selection.
    @ViewBuilder private func highlight(_ id: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.rowPill / 2 - 4, style: .continuous)
        // Always there and faded, so the hover follows the pointer from row to row.
        shape.fill(.fill.quaternary).opacity(hovered == id && selection != id ? 1 : 0)
        if selection == id {
            // Lighter than the card in both appearances: white in light mode, translucent white in dark. One
            // pill for the list, so it glides from row to row.
            shape.fill(Color(nsColor: .controlColor)).matchedGeometryEffect(id: "selection", in: pill)
        }
    }

    private func regroup(_ host: Connection, _ folderID: String?) {
        guard host.folderID != folderID else { return }
        workspace.change("Couldn’t Move the Host") { try await workspace.move(host, toGroup: folderID) }
    }

    private func move(_ step: Int, in ids: [String]) -> KeyPress.Result {
        guard !ids.isEmpty else { return .handled }
        let index = selection.flatMap(ids.firstIndex) ?? (step > 0 ? -1 : ids.count)
        selection = ids[min(max(index + step, 0), ids.count - 1)]
        return .handled
    }
}
