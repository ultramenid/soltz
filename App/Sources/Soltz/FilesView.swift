// SPDX-License-Identifier: AGPL-3.0-only
import SoltzFilesUI
import SwiftUI

extension Workspace {
    /// Upstream "Open in SFTP" (src/stores/uiStore.ts:360), as a tab: the session's host's files, at the session's
    /// directory, as upstream's terminal file panel follows it (followCwd), else at its home
    /// (`sftp_canonicalize(".")`, SFTPPage.tsx:148). A local session has none: Finder shows This Mac's.
    func showFiles(for session: TerminalSession?) {
        guard let session, session.args != nil else { return }
        duplicate(session, .tab, files: true)
    }

    /// An SSH session's files, made once; This Mac for nil, a local session or one already closed.
    func fileProvider(for sessionID: String?) -> any FileProvider {
        guard let sessionID, let session = sessions[sessionID], let coreID = session.args?["sessionId"]?.string else { return localFiles }
        if let provider = fileProviders[sessionID] { return provider }
        let provider = SftpFileProvider(core: core, sessionID: coreID, name: fileLabel(session))
        fileProviders[sessionID] = provider
        return provider
    }

    /// How the panes and the queue name a session's host: its saved name, else user@host.
    func fileLabel(_ session: TerminalSession) -> String {
        if let name = connections.first(where: { $0.id == session.hostID })?.name, !name.isEmpty { return name }
        return "\(session.args?["username"]?.string ?? "")@\(session.args?["host"]?.string ?? "")"
    }

    /// Where a files pane's Download puts what it copies from the host.
    static var downloads: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path(percentEncoded: false)
    }
}

extension FilesStyle {
    /// The file panes and the transfers card in the app's type, metrics and motion.
    @MainActor static var soltz: FilesStyle {
        FilesStyle(row: Theme.chromeRegular, detail: Theme.caption, title: Theme.bodyStrong, cardRadius: Theme.paneRadius,
                   gap: Theme.paneGap, fieldHeight: Theme.buttonHeight, fieldRadius: Theme.rowPill / 2 - 4, motion: Theme.motion)
    }
}

/// A session's pane on its host's files: one pane of upstream's SFTP page (src/components/filetransfer/SFTPPage.tsx),
/// the remote one. This Mac's side is Finder: files dropped from it are copied to the folder shown, Download copies
/// the selection to the Downloads folder, and a file opened is edited on this Mac and saved back. Dragging between
/// two files panes copies from one host to the other. Every copy goes through the app's queue (the transfers card).
struct FilesPane: View {
    let session: TerminalSession
    /// The pane's own buttons (split, maximize, close), after its menu.
    let buttons: AnyView
    @Environment(Workspace.self) private var workspace
    @ViewState private var reload = 0

    var body: some View {
        @Bindable var session = session
        // (A session closed a moment ago is no longer the workspace's: its fading pane must not show This Mac's files.)
        if session.ended || !session.isAttached || workspace.sessions[session.id] == nil {
            // The card a pane is, empty: the pane's state (connecting, disconnected, ended) shows over it.
            VStack(spacing: 0) {
                HStack {
                    title
                    Spacer()
                    buttons
                }
                .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10)
                Color.clear
            }
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.paneRadius, style: .continuous))
            .transition(.opacity)
        } else {
            let host = workspace.fileProvider(for: session.id), queue = workspace.transfers
            FilePaneView(provider: host, path: $session.filesPath, reloadID: reload, source: AnyView(title),
                         accessory: AnyView(buttons.padding(.trailing, -6)), // as far from the card's edge as a terminal's
                         transferTitle: { $0 == 1 ? "Download" : "Download \($0) Items" },
                         onTransfer: { queue.enqueue($0, from: host, to: workspace.localFiles, into: Workspace.downloads) },
                         onEdit: { items, app in
                             for item in items { queue.edit(item, on: host) { FilePaneView.open($0, with: app) } }
                         },
                         onReceive: { items, source, folder in
                             queue.enqueue(items, from: source, to: host, into: folder) { reload += 1 }
                         })
                .transition(.opacity)
        }
    }

    private var title: some View {
        Label(workspace.fileLabel(session), systemImage: TerminalSession.filesSymbol).font(Theme.chromeStrong).lineLimit(1)
            .help("\(workspace.fileLabel(session)) · SFTP")
            // The pane's handle, as a terminal's header is.
            .draggable(Dragged(kind: .pane, id: session.id)) { DragChip(title: workspace.fileLabel(session), systemImage: TerminalSession.filesSymbol) }
    }
}
