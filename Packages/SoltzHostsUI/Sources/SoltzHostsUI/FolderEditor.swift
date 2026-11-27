// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SoltzModel

/// A sheet that creates, renames or moves a host folder. Save hands the folder to `onSave`;
/// an existing folder is edited in place, so its unknown JSON fields, colour and icon survive.
public struct FolderEditor: View {
    @ViewState private var name: String
    @ViewState private var parentID: String?
    private let folder: Folder?
    private let folders: [Folder]
    /// A folder stays in its vault; a new one takes its parent's (upstream `newFolderData`).
    private let vaultID: String
    private let onSave: (Folder) -> Void
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - folder: the folder to edit; nil creates one inside `parentID`.
    ///   - folders: every folder, for the parent picker.
    public init(folder: Folder?, parentID: String? = nil, folders: [Folder], onSave: @escaping (Folder) -> Void) {
        let parentID = folder == nil ? parentID : folder?.parentFolderID
        _name = ViewState(initialValue: folder?.name ?? "New Folder")
        _parentID = ViewState(initialValue: parentID)
        self.folder = folder
        self.folders = folders
        vaultID = folder?.vaultID
            ?? HostRules.hostFolders(folders).first { $0.id == parentID }?.vaultID
            ?? HostRules.defaultVaultID
        self.onSave = onSave
    }

    public var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Parent Folder", selection: $parentID) {
                Text("None").tag(String?.none)
                HostEditor.choices(HostRules.parentChoices(for: folder, vaultID: vaultID, folders: folders),
                                   current: parentID, missing: "Missing Folder")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(folder == nil ? "New Folder" : "Edit Folder")
        .frame(minWidth: 380, idealWidth: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let saved = HostRules.savedFolder(folder, name: name, parentID: parentID, vaultID: vaultID) {
                        onSave(saved)
                    }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
