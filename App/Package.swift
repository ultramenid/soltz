// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "Soltz",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../Packages/SoltzCore"),
        .package(path: "../Packages/SoltzFilesUI"),
        .package(path: "../Packages/SoltzHostsUI"),
        .package(path: "../Packages/SoltzKeychainUI"),
        .package(path: "../Packages/SoltzModel"),
        .package(path: "../Packages/SoltzTerminal"),
        .package(path: "../Packages/SoltzWorkspace"),
    ],
    targets: [
        // Run it as build/Soltz.app (scripts/bundle-app.sh): a bare executable has no bundle identity.
        .executableTarget(
            name: "Soltz",
            dependencies: [
                .product(name: "SoltzCore", package: "SoltzCore"),
                .product(name: "SoltzFilesUI", package: "SoltzFilesUI"),
                .product(name: "SoltzHostsUI", package: "SoltzHostsUI"),
                .product(name: "SoltzKeychainUI", package: "SoltzKeychainUI"),
                .product(name: "SoltzModel", package: "SoltzModel"),
                .product(name: "SoltzTerminal", package: "SoltzTerminal"),
                .product(name: "SoltzWorkspace", package: "SoltzWorkspace"),
            ]
        ),
        .testTarget(
            name: "SoltzTests",
            dependencies: ["Soltz"],
            // shortcut: with Command Line Tools only, swiftbuild does not hand Swift Testing's macro plugin
            // to the compiler; drop this once plain `swift test` finds it unaided.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
