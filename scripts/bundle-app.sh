#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Builds the app in release and assembles build/Soltz.app, the supported way to run it: a bare
# SwiftPM executable has no bundle identity, which breaks menus and window focus.
# Smoke test: build/Soltz.app/Contents/MacOS/Soltz --smoke
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$root/Packages/SoltzCore/SoltzCoreFFI.xcframework" ] || sh "$root/scripts/build-core.sh"

# SOLTZ_HARNESS=1 builds the test harnesses in (--smoke, --e2e, --snapshot) and makes build/test.noindex/SoltzTest.app, with its
# own bundle id so a test run never shares settings with the real app. The app people run has none of them.
# It lives in a .noindex folder, which Spotlight skips: in build/ itself it showed up as a second "Soltz" among the apps.
if [ -n "${SOLTZ_HARNESS:-}" ]; then
  flags="-Xswiftc -DSOLTZ_HARNESS"
  app="$root/build/test.noindex/SoltzTest.app"
else
  flags=""
  app="$root/build/Soltz.app"
fi

cd "$root/App"
# The terminal engine is a prebuilt library from a third party (README, "What you trust"). Its bytes are pinned here,
# in this repository, beside the commit pin in Packages/SoltzTerminal/Package.swift: nothing is built or linked if the
# library that was downloaded is not the one this pin was made for, whatever the package's own manifest says.
ghostty_sha256=a5f828c89be73e8e5b104dc9bfd91b0ec845ec5228152e66cde63029fde22bf1
swift package resolve
ghostty="$root/App/.build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"
if [ "$(shasum -a 256 "$ghostty" | cut -d' ' -f1)" != "$ghostty_sha256" ]; then
  echo "error: $ghostty is not the pinned terminal engine build; not building" >&2
  exit 1
fi
# shellcheck disable=SC2086
swift build -c release $flags
# shellcheck disable=SC2086
bin="$(swift build -c release $flags --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Soltz" "$app/Contents/MacOS/Soltz"
# SwiftPM resource bundles (libghostty's terminfo and shell integration); it looks in Contents/Resources first.
for bundle in "$bin"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# The icon. AppIcon.icon is the layered source macOS draws the light, dark, clear and tinted icons from, and only
# actool (full Xcode) can compile it; with Command Line Tools alone the app gets the one static AppIcon.icns, the
# dark tile (scripts/make-icon.sh says why and rebuilds it).
cp "$root/App/Icon/AppIcon.icns" "$app/Contents/Resources/"
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$root/App/Icon/AppIcon.icon" --compile "$app/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 27.0 --output-partial-info-plist "$root/build/icon.plist" >/dev/null
fi

# SoltzUpdateRepo is where releases are published, "owner/repo" on GitHub (Updates.swift); empty turns the update
# check off. CFBundleShortVersionString is what a release's tag (v0.2.0) is compared with.
# The licence and the notices of what is built in travel with the app.
cp "$root/LICENSE" "$root/NOTICE.md" "$app/Contents/Resources/"

cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Soltz</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.soltz.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Soltz</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>27.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Soltz connects to SSH servers on your local network.</string>
	<key>SoltzUpdateRepo</key>
	<string>ultramenid/soltz</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>app.soltz.drag</string>
			<key>UTTypeDescription</key>
			<string>Soltz drag</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

[ -z "${SOLTZ_HARNESS:-}" ] || plutil -replace CFBundleIdentifier -string app.soltz.mac.test "$app/Contents/Info.plist"

# Ad hoc: the Keychain then asks for the vault key again after every rebuild ("Always Allow" is remembered per
# build). Only an Apple-issued certificate changes that; a self-signed one was tried and is asked just the same.
# Hardened runtime (--options runtime): no library can be injected into the app (DYLD_INSERT_LIBRARIES is ignored
# and only code signed with it loads), so another program cannot read the vault key or logins from inside it.
codesign --force --options runtime --sign - "$app"
echo "Built $app"
