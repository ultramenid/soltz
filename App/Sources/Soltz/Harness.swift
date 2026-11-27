// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// The test harnesses (`--smoke`, `--e2e`, `--snapshot`: Smoke.swift, E2E.swift, Snapshot.swift) run scripts, read
// files named by environment variables and write where they are told, so they are not in the app people run:
// without SOLTZ_HARNESS these stand in for them and nothing answers to those arguments.
#if !SOLTZ_HARNESS
@MainActor
enum Smoke {
    static let requested = false
    static let dataDir = URL(filePath: "/")
    nonisolated static func startWatchdog() {}
    static func run(_: Workspace) async {}
}

@MainActor
enum E2E {
    static let requested = false
    static let dataDir = URL(filePath: "/")
    nonisolated static func startWatchdog() {}
    static func run(_: Workspace) async {}
}

@MainActor
enum Snapshot {
    static let requested = false
    static let dataDir = URL(filePath: "/")
    nonisolated static func startWatchdog() {}
    static func run(_: Workspace) async {}
}
#endif
