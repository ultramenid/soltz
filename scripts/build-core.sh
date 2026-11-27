#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Builds the Rust core (core/crates/soltz-core) as a release static library for
# aarch64-apple-darwin and regenerates its Swift bindings in Packages/SoltzCore:
# Sources/SoltzCore/SoltzCore.swift and SoltzCoreFFI.xcframework (library + C header).
# Safe to rerun: cargo builds incrementally, and the outputs are staged in a temp
# dir and swapped in by rename, so a package build in between sees old or new, briefly neither.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/core/crates/soltz-core"
pkg="$root/Packages/SoltzCore"
target=aarch64-apple-darwin
lib="$crate/target/$target/release/libsoltz_core.a"
xcframework="$pkg/SoltzCoreFFI.xcframework"

cd "$crate"
# The builder's home folder (their user name) stays out of the app: rustc records source paths for panic messages.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~"
# --locked: exactly the dependency versions in Cargo.lock, or the build stops.
cargo rustc --locked --release --lib --crate-type staticlib --target "$target"
cargo build --locked --features bindgen --bin uniffi-bindgen-swift

gen="$(mktemp -d)"
trap 'rm -rf "$gen"' EXIT
./target/debug/uniffi-bindgen-swift "$lib" "$gen" \
  --swift-sources --headers --modulemap \
  --module-name SoltzCoreFFI --modulemap-filename module.modulemap

# shortcut: a hand-written single-slice XCFramework (no xcodebuild with Command Line
# Tools), arm64 macOS only; build it with `xcodebuild -create-xcframework` once Xcode is around.
staged="$gen/SoltzCoreFFI.xcframework"
slice="$staged/macos-arm64"
# The module map sits in a folder named after the module, so it cannot collide with
# another static XCFramework's in the shared include directory.
mkdir -p "$slice/Headers/SoltzCoreFFI"
cp "$lib" "$slice/"
cp "$gen/SoltzCoreFFI.h" "$gen/module.modulemap" "$slice/Headers/SoltzCoreFFI/"
cat >"$staged/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libsoltz_core.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libsoltz_core.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

rm -rf "$xcframework"
mv "$staged" "$xcframework"
mv "$gen/SoltzCore.swift" "$pkg/Sources/SoltzCore/SoltzCore.swift"
echo "SoltzCore: $(du -h "$lib" | cut -f1) static library, bindings in $pkg"
