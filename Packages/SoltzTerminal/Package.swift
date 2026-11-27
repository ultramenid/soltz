// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "SoltzTerminal",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SoltzTerminal", targets: ["SoltzTerminal"]),
        .executable(name: "SoltzTerminalDemo", targets: ["SoltzTerminalDemo"]),
    ],
    dependencies: [
        // Ghostty upstream 56de3f0f6786 as a prebuilt xcframework (host-managed I/O patch carried by the package),
        // version 2.2.2026112401. Pinned by commit, not by tag: a tag can be moved to other code, a commit cannot,
        // and the commit's manifest holds the checksum of the binary it downloads. See README, "What you trust".
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "df874b7f276f03e6341199af49a8c040fc045251"),
    ],
    targets: [
        .target(
            name: "SoltzTerminal",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(name: "SoltzTerminalDemo", dependencies: ["SoltzTerminal"]),
        .testTarget(
            name: "SoltzTerminalTests",
            dependencies: ["SoltzTerminal"],
            // shortcut: with Command Line Tools only, the swiftbuild backend does not pass Swift Testing's
            // macro plugin to the compiler; drop this once plain `swift test` finds it unaided.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
