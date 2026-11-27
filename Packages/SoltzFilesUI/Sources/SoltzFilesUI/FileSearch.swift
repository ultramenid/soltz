// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Finds items by name anywhere under a folder by listing it folder by folder, which works the same on this Mac
/// and on a host (no remote shell).
enum FileSearch {
    static let maxResults = 500
    /// Items looked at, so a search from "/" on a host ends.
    static let maxVisited = 20_000

    struct Results: Equatable, Sendable {
        var entries: [FileEntry] = []
        /// What to tell the user when the walk stopped at a cap; nil when it saw everything.
        var cutShort: String?
    }

    /// The items under `root` whose names contain `query` (case- and accent-blind, as the pane's filter), the
    /// nearest folders first. `found` gets what there is so far after each folder that adds to it.
    static func run(_ query: String, under root: String, on provider: any FileProvider, showHidden: Bool,
                    maxResults: Int = maxResults, maxVisited: Int = maxVisited,
                    found: @MainActor (Results) -> Void = { _ in }) async throws -> Results {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = Results()
        guard !query.isEmpty else { return results }
        var folders = [root], next = 0, visited = 0
        walk: while next < folders.count {
            let folder = folders[next]
            next += 1
            let listed: [FileEntry]
            do {
                listed = try await provider.list(folder)
            } catch where folder != root {
                // A folder that cannot be read (permission denied) is passed over. The one the search starts in
                // is on screen, so failing there is the connection and is said.
                listed = []
            }
            try Task.checkCancellation()
            let before = results.entries.count
            for entry in FileRules.visible(listed, showHidden: showHidden, filter: "", sort: []) {
                guard visited < maxVisited else {
                    results.cutShort = "Stopped after \(maxVisited.formatted()) items. Search from a folder further in."
                    break walk
                }
                visited += 1
                if entry.name.localizedStandardContains(query) {
                    guard results.entries.count < maxResults else {
                        results.cutShort = "Showing the first \(maxResults.formatted()) matches. Type more to narrow them."
                        break walk
                    }
                    results.entries.append(entry)
                }
                // Not through a link: it can lead back up, and the walk would never end.
                if entry.isDir, !entry.isSymlink { folders.append(entry.path) }
            }
            if results.entries.count > before { await found(results) }
        }
        return results
    }

    /// The folder holding `path`, as a path from `root`: "" for an item of `root` itself.
    static func folder(of path: String, under root: String) -> String {
        let folder = Paths.parent(path) ?? "/"
        guard Paths.isSameOrUnder(folder, root) else { return folder }
        return folder.split(separator: "/").dropFirst(root.split(separator: "/").count).joined(separator: "/")
    }
}

/// A sheet: a search field and the items under `root` whose names contain what was typed.
struct FileSearchSheet: View {
    private let provider: any FileProvider
    private let root: String
    private let showHidden: Bool
    private let onPick: (FileEntry) -> Void
    @ViewState private var query: String
    @ViewState private var results = FileSearch.Results()
    @ViewState private var searching = false
    @ViewState private var failure: String?
    @ViewState private var selection: FileEntry.ID?
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.filesStyle) private var style

    /// - Parameter query: what the field starts with, e.g. the pane's filter.
    init(provider: any FileProvider, root: String, showHidden: Bool, query: String = "", onPick: @escaping (FileEntry) -> Void) {
        self.provider = provider
        self.root = root
        self.showHidden = showHidden
        self.onPick = onPick
        _query = ViewState(initialValue: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search “\(Paths.name(root))”").font(style.title)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $query, prompt: Text("Name"))
                    .textFieldStyle(.plain)
                    .focused($typing)
                    // The arrows walk the results while the field keeps the typing.
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .accessibilityLabel("Search by name in this folder and its subfolders")
            }
            .field(style)
            list
            HStack(spacing: 6) {
                // The words beside it say the same.
                if searching { ProgressView().controlSize(.small).accessibilityHidden(true) }
                Text(status).font(style.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { pick(results.entries.first { $0.id == selection }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .font(style.row)
        .padding(20)
        .frame(width: 520, height: 440)
        // A new text ends the walk of the one before, and closing the sheet ends the last.
        .task(id: query) { await search() }
        .onAppear { typing = true }
    }

    private var list: some View {
        ScrollViewReader { scroll in
            List(results.entries, selection: $selection) { entry in
                let folder = FileSearch.folder(of: entry.path, under: root)
                HStack(spacing: 6) {
                    // The folder's or file type's own icon, as the pane's rows.
                    Image(nsImage: entry.icon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(entry.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .listRowSeparator(.hidden)
                .help(folder.isEmpty ? entry.name : folder + "/" + entry.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.isDir ? "\(entry.name), folder" : entry.name)
                .accessibilityValue(folder.isEmpty ? "" : "in \(folder)")
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            // A double-click, as the pane opens a row.
            .contextMenu(forSelectionType: FileEntry.ID.self) { _ in } primaryAction: { ids in
                pick(results.entries.first { ids.contains($0.id) })
            }
            // Moved from the field, the selection can leave what is on screen.
            .onChange(of: selection) { if let selection { scroll.scrollTo(selection) } }
        }
        .overlay {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if let failure {
                ContentUnavailableView {
                    Label("Couldn’t Search", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else if results.entries.isEmpty, !searching, !text.isEmpty {
                ContentUnavailableView.search(text: text)
            }
        }
    }

    private var status: String {
        if let cutShort = results.cutShort { return cutShort }
        if searching { return "Searching…" }
        return results.entries.isEmpty ? "" : results.entries.count == 1 ? "1 item" : "\(results.entries.count) items"
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = FileSearch.Results()
        failure = nil
        selection = nil
        searching = !text.isEmpty
        guard searching else { return }
        do {
            // A pause in the typing first, so a host is not asked once per letter.
            try await Task.sleep(for: .milliseconds(300))
            show(try await FileSearch.run(text, under: root, on: provider, showHidden: showHidden) { show($0) })
            searching = false
        } catch {
            // A walk the next letter stopped has nothing to say.
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            searching = false
        }
    }

    private func show(_ found: FileSearch.Results) {
        guard !Task.isCancelled else { return }
        results = found
        // Return goes to what is highlighted, so something is from the first match on.
        if selection == nil { selection = found.entries.first?.id }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let entries = results.entries
        guard !entries.isEmpty else { return .ignored }
        let at = entries.firstIndex { $0.id == selection }.map { $0 + by } ?? 0
        selection = entries[min(max(at, 0), entries.count - 1)].id
        return .handled
    }

    private func pick(_ entry: FileEntry?) {
        guard let entry else { return }
        onPick(entry)
        dismiss()
    }
}
