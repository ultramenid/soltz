// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SoltzCore
import SwiftUI

/// Asks for the master password of a vault that has one. It cannot be dismissed: saved hosts need the
/// vault's secrets, as upstream's lock screen holds the whole app.
struct UnlockVaultView: View {
    @Environment(Workspace.self) private var workspace
    @ViewState private var password = ""
    @ViewState private var failure: String?
    @ViewState private var unlocking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SecureField("Master Password", text: $password)
                } header: {
                    Text("Enter your master password to unlock your saved hosts.")
                } footer: {
                    if let failure { Label(failure, systemImage: "exclamationmark.triangle") }
                }
            }
            .formStyle(.grouped)
            .disabled(unlocking)

            HStack {
                if unlocking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Quit Soltz") { NSApp.terminate(nil) }
                Button("Unlock") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || unlocking)
            }
            .padding()
        }
        .frame(width: 400)
        .interactiveDismissDisabled()
    }

    private func unlock() {
        unlocking = true
        Task {
            do {
                try await workspace.core.vaultUnlock(masterPassword: password)
                workspace.vaultLocked = false
                await workspace.reload()
                workspace.reopenWorkspace()
            } catch VaultError.WrongKey {
                failure = "That password is incorrect."
            } catch {
                failure = describe(error)
            }
            unlocking = false
        }
    }
}
