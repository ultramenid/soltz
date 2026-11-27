// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "SoltzKeychainUI",
    platforms: [.macOS("27.0")],
    products: [.library(name: "SoltzKeychainUI", targets: ["SoltzKeychainUI"])],
    dependencies: [.package(path: "../SoltzModel")],
    targets: [
        .target(name: "SoltzKeychainUI", dependencies: ["SoltzModel"]),
        .testTarget(
            name: "SoltzKeychainUITests",
            dependencies: ["SoltzKeychainUI", "SoltzModel"],
            // shortcut: with Command Line Tools only, swiftbuild does not hand Swift Testing's macro plugin
            // to the compiler; drop this once plain `swift test` finds it unaided.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ]
)
