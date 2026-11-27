// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "SoltzWorkspace",
    platforms: [.macOS("27.0")],
    products: [.library(name: "SoltzWorkspace", targets: ["SoltzWorkspace"])],
    targets: [
        .target(name: "SoltzWorkspace"),
        .testTarget(name: "SoltzWorkspaceTests", dependencies: ["SoltzWorkspace"]),
    ]
)
