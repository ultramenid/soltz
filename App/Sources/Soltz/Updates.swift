// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation

/// Finds out whether a newer Soltz has been published and offers its download page.
// shortcut: it only tells and links; the user downloads and replaces the app. Move to Sparkle (download, verify,
// replace, relaunch) once builds are signed with a Developer ID.
@MainActor @Observable
final class Updates {
    /// The newest published release, as GitHub's "latest release" describes it.
    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlUrl: URL

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum Outcome: Equatable {
        case newer(Release)
        case current
        /// This build has no place to look (`SoltzUpdateRepo` is empty).
        case notSetUp
        case failed(String)
    }

    /// A release newer than this build, once a check has found one. Home's footer offers it.
    private(set) var available: Release?

    static let automatic = "checksForUpdates"
    private static let lastCheck = "updatesLastCheck"
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    /// Where releases are published: `SoltzUpdateRepo` in Info.plist, "owner/repo" on GitHub. nil when not set.
    static var repo: String? {
        (Bundle.main.infoDictionary?["SoltzUpdateRepo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.10.0" is newer than "0.9.2": the numbers are compared as numbers.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }

    /// Asks GitHub for `repo`'s newest release (`feed` stands in for it in tests). Sends nothing about the user or
    /// this Mac.
    @discardableResult
    func check(repo: String? = Updates.repo, feed: URL? = nil, current: String = Updates.current) async -> Outcome {
        guard let repo, let feed = feed ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .notSetUp }
        do {
            var request = URLRequest(url: feed, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed(http.statusCode == 404 ? "No release has been published yet." : "The server answered \(http.statusCode).")
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)
            // The page is opened in the browser: only the repository's own release page, whatever the feed says.
            guard release.htmlUrl.absoluteString.hasPrefix("https://github.com/\(repo)/") else {
                return .failed("The release has no download page.")
            }
            available = Self.isNewer(release.version, than: current) ? release : nil
            return available.map(Outcome.newer) ?? .current
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The quiet check as the app opens: at most once a day, unless turned off in Settings; never in a test run.
    func checkDaily() async {
        let defaults = UserDefaults.standard
        guard !(Smoke.requested || E2E.requested || Snapshot.requested), Self.repo != nil,
              defaults.object(forKey: Self.automatic) as? Bool ?? true,
              Date().timeIntervalSince(defaults.object(forKey: Self.lastCheck) as? Date ?? .distantPast) > 86_400
        else { return }
        if case .failed = await check() { return } // offline: try again next time
        defaults.set(Date(), forKey: Self.lastCheck)
    }

    func open(_ release: Release) { NSWorkspace.shared.open(release.htmlUrl) }
}

/// What "Check for Updates…" found, for its alert.
struct UpdateNotice {
    let title: String
    let message: String
    var release: Updates.Release?
}

extension Workspace {
    /// The menu's "Check for Updates…": always answers, with the download when there is one.
    func checkForUpdates() {
        Task {
            switch await updates.check() {
            case .newer(let release):
                updateNotice = UpdateNotice(title: "Soltz \(release.version) Is Available",
                                            message: "You have \(Updates.current). The download page opens in your browser.", release: release)
            case .current:
                updateNotice = UpdateNotice(title: "Soltz Is Up to Date", message: "\(Updates.current) is the newest version.")
            case .notSetUp:
                updateNotice = UpdateNotice(title: "Updates Aren’t Set Up", message: "This build has no release page to check.")
            case .failed(let why):
                updateNotice = UpdateNotice(title: "Couldn’t Check for Updates", message: why)
            }
        }
    }
}
