// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "SoltzModel",
    platforms: [.macOS("27.0")],
    products: [.library(name: "SoltzModel", targets: ["SoltzModel"])],
    targets: [
        .target(name: "SoltzModel"),
        .testTarget(name: "SoltzModelTests", dependencies: ["SoltzModel"], resources: [.copy("Fixtures")]),
    ]
)
