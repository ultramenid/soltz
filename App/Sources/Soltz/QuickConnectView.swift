// SPDX-License-Identifier: AGPL-3.0-only
import SoltzCore
import SoltzHostsUI
import SwiftUI
import UniformTypeIdentifiers

/// The login prompt of a saved host with no stored password or key: host, port, user and a password or private key
/// file; connects through the core with the host's options, showing its `ssh-step` progress and asking about a changed
/// host key, and can save what was typed to the host.
struct QuickConnectView: View {
    @ViewState var form: ConnectForm
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var pending: TerminalSession?
    @ViewState private var failure: String?
    @ViewState private var choosingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log In to \(form.connection.flatMap { $0.name?.isEmpty == false ? $0.name : nil } ?? form.host)")
                .font(Theme.title).padding(.horizontal, Theme.sheetInset).padding(.top, 20)
            Form {
                Section {
                    // A saved host's address is not edited here: a login typed for another address and saved would
                    // be stored under this host, and sent to it from then on.
                    TextField("Host", text: $form.host, prompt: Text("example.com")).disabled(form.connection != nil)
                    TextField("Port", value: $form.port, format: .number.grouping(.never)).disabled(form.connection != nil)
                    TextField("Username", text: $form.username)
                }
                Section {
                    Picker("Authentication", selection: $form.useKey) {
                        Text("Password").tag(false)
                        Text("Private Key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if form.useKey {
                        LabeledContent("Private Key") {
                            Button(form.keyFile?.lastPathComponent ?? "Choose…") { choosingKey = true }
                        }
                        SecureField("Passphrase", text: $form.passphrase, prompt: Text("Optional"))
                    } else {
                        SecureField("Password", text: $form.password)
                    }
                    if form.connection != nil {
                        Toggle("Save to Host", isOn: $form.save)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(pending != nil)

            HStack {
                if let pending {
                    ProgressView().controlSize(.small)
                    Text(Self.label(for: pending.step)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(Pill(height: Theme.buttonHeight, font: Theme.body.weight(.medium)))
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(Pill(prominent: true, height: Theme.buttonHeight, font: Theme.body.weight(.semibold)))
                    .disabled(!form.isComplete || pending != nil)
            }
            .padding(.horizontal, Theme.sheetInset - 6)
            .padding(.bottom, 16)
        }
        .frame(width: Theme.sheetWidth + 40)
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { form.keyFile = url }
        }
        .alert("Couldn’t Connect", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
        .hostKeyAlert(pending, host: form.host, core: workspace.core)
    }

    static func label(for step: String?) -> String {
        switch step {
        case "knocking": "Knocking…"
        case "tcp_connected": "Connected"
        case "handshake": "Checking host key…"
        case "authenticating": "Authenticating…"
        case "opening_shell": "Opening shell…"
        default: "Connecting…"
        }
    }

    private func connect() {
        let form = form
        let session = TerminalSession(title: "\(form.username)@\(form.host)", font: workspace.font)
        session.hostID = form.connection?.id
        session.showsFiles = form.files
        pending = session
        session.connectTask = Task {
            do {
                let key = try form.keyFile.map(HostEditor.readKey)
                if form.save, let host = form.connection { // upstream saves first and ignores a failure
                    try? await workspace.persistConnectAuth(to: host, form, key: key)
                }
                let args = try workspace.connectArgs(for: form.target(), login: form.login(key: key))
                try await workspace.connectSsh(session, form.files ? Workspace.forFiles(args) : args)
                guard pending === session else { return }
                workspace.add(session)
                dismiss()
                await workspace.connected(session)
            } catch {
                session.close()
                guard pending === session, !(error is CancellationError) else { return }
                pending = nil
                failure = describe(error)
            }
        }
    }

    private func cancel() {
        if let pending {
            pending.answer(.abort, via: workspace.core)
            pending.close() // cancels the connect
        }
        pending = nil
        dismiss()
    }

}

extension View {
    /// Asks about the host key `session` reports while connecting: one seen for the first time, or one that differs
    /// from the key trusted before. Cancel is the default button, so Return never trusts a key, and the user is shown
    /// what to compare: the host and port, the new fingerprint, and the trusted one when there is one.
    func hostKeyAlert(_ session: TerminalSession?, host: String, core: Core) -> some View {
        let conflict = session?.conflict
        let first = conflict?.isFirstSight == true
        let name = conflict.map { "\($0.host ?? host):\($0.port ?? 22)" } ?? host
        return alert(first ? "Trust This Host?" : "Host Key Changed", isPresented: .constant(conflict != nil)) {
            Button("Cancel", role: .cancel) { session?.answer(.abort, via: core) }.keyboardShortcut(.defaultAction)
            if first {
                Button("Trust") { session?.answer(.addNew, via: core) }
            } else {
                Button("Replace Trusted Key", role: .destructive) { session?.answer(.replace, via: core) }
            }
        } message: {
            if let conflict {
                let new = conflict.newFingerprint ?? "unknown"
                if first {
                    Text("Soltz has not connected to \(name) before. Trust it only if this is the server’s own key fingerprint:\n\n\(new)")
                } else {
                    let old = (conflict.storedEntries ?? []).map(\.fingerprint).joined(separator: "\n")
                    Text("The key of \(name) differs from the one trusted before. Someone may be intercepting the connection.\n\nTrusted:\n\(old.isEmpty ? "unknown" : old)\n\nNow presented:\n\(new)")
                }
            }
        }
    }
}
