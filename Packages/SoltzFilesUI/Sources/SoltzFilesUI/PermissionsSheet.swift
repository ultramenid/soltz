// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Mode bits for one or more items, as checkboxes and an octal field, then the owning user and group and whether
/// folders pass it all on to what is inside (upstream PermissionsDialog.tsx). A bit the selection disagrees on shows
/// mixed and is left alone unless the user sets it.
struct PermissionsSheet: View {
    private let entries: [FileEntry]
    private let initial: [Bool?]
    private let ownership: Bool
    private let onApply: (_ set: UInt32, _ clear: UInt32, _ owner: String?, _ group: String?, _ recursive: Bool) -> Void
    @ViewState private var bits: [Bool?]
    @ViewState private var octal: String
    @ViewState private var owner = ""
    @ViewState private var group = ""
    @ViewState private var recursive = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.filesStyle) private var style

    /// - Parameter ownership: offer the user and group too: on a host; this Mac changes them only as an administrator.
    init(entries: [FileEntry], ownership: Bool = false,
         onApply: @escaping (_ set: UInt32, _ clear: UInt32, _ owner: String?, _ group: String?, _ recursive: Bool) -> Void) {
        let initial = PermissionBits.tri(entries.compactMap(\.permissions))
        self.entries = entries
        self.initial = initial
        self.ownership = ownership
        self.onApply = onApply
        _bits = ViewState(initialValue: initial)
        _octal = ViewState(initialValue: PermissionBits.octal(initial) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entries.count == 1 ? "Permissions for “\(entries[0].name)”" : "Permissions for \(entries.count) Items")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Read")
                    Text("Write")
                    Text("Execute")
                }
                .foregroundStyle(.secondary)
                ForEach(Array(["Owner", "Group", "Others"].enumerated()), id: \.offset) { row, who in
                    GridRow {
                        Text(who)
                        ForEach(Array(["read", "write", "execute"].enumerated()), id: \.offset) { column, what in
                            checkbox(row * 3 + column, "\(who) \(what)").labelsHidden()
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                checkbox(9, "Set user ID")
                checkbox(10, "Set group ID")
                checkbox(11, "Sticky")
            }
            // The fields are the panes' quiet ones: a bordered field paints a black box on the glass.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Octal")
                    HStack(spacing: 8) {
                        TextField("Octal", text: $octal, prompt: Text("Mixed"))
                            .textFieldStyle(.plain)
                            .monospaced()
                            .field(style)
                            .frame(width: 70)
                            .onChange(of: octal) {
                                if let parsed = PermissionBits.parseOctal(octal, current: bits), parsed != bits { bits = parsed }
                            }
                        Text(PermissionBits.mode(bits).map(FileRules.symbolic) ?? "Mixed").monospaced().foregroundStyle(.secondary)
                    }
                }
                if ownership {
                    GridRow {
                        Text("User")
                        TextField("User", text: $owner, prompt: Text("Unchanged")).textFieldStyle(.plain).field(style).frame(width: 160)
                    }
                    GridRow {
                        Text("Group")
                        TextField("Group", text: $group, prompt: Text("Unchanged")).textFieldStyle(.plain).field(style).frame(width: 160)
                    }
                }
            }
            if entries.contains(where: \.isDir) {
                Toggle("Apply the changes to everything inside", isOn: $recursive).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entries.count == 1 ? "Apply" : "Apply to \(entries.count) Items") {
                    // Only the bits changed here, inside folders too: a folder's whole mode on its files would make
                    // them all executable, a file's on folders would close them.
                    let change = PermissionBits.change(from: initial, to: bits)
                    onApply(change.set, change.clear, Self.typed(owner), Self.typed(group), recursive)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bits == initial && Self.typed(owner) == nil && Self.typed(group) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private static func typed(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A native checkbox; a mixed bit gets two sources that disagree, which `Toggle` draws as mixed.
    private func checkbox(_ i: Int, _ title: String) -> some View {
        let sources = bits[i] == nil
            ? [Binding(get: { true }, set: { set(i, $0) }), Binding(get: { false }, set: { set(i, $0) })]
            : [Binding(get: { bits[i] ?? false }, set: { set(i, $0) })]
        return Toggle(title, sources: sources, isOn: \.self)
            .toggleStyle(.checkbox)
            .accessibilityLabel(title)
    }

    private func set(_ i: Int, _ on: Bool) {
        bits[i] = on
        octal = PermissionBits.octal(bits) ?? ""
    }
}
