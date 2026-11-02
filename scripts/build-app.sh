#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
architecture="${2:-$(uname -m)}"
if [[ "$mode" != "release" && "$mode" != "debug" ]]; then
  echo "Usage: $0 [release|debug] [arm64|x86_64]" >&2
  exit 2
fi
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture" >&2; exit 2 ;; esac
triple="$architecture-apple-macosx14.0"
cp bridge/*.py Sources/SideA/Resources/
swift build -c "$mode" --triple "$triple" --scratch-path ".build/package-$architecture"
bin_dir="$(swift build -c "$mode" --triple "$triple" --scratch-path ".build/package-$architecture" --show-bin-path)"
app_path="$PWD/dist/$architecture/Side A.app"
if [[ $# -lt 2 ]]; then app_path="$PWD/dist/Side A.app"; fi
if [[ -d "$app_path" ]]; then rm -rf "$app_path"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/SideA" "$app_path/Contents/MacOS/SideA"
cp "$bin_dir/SideAKeepAwake" "$app_path/Contents/MacOS/SideAKeepAwake"
# Hosted sessions run on this tmux, so they never need Homebrew; it is already universal.
tmux_build="$(./scripts/build-tmux.sh | tail -n 1)"
mkdir -p "$app_path/Contents/Helpers"
cp "$tmux_build" "$app_path/Contents/Helpers/tmux"
ditto "$(dirname "$tmux_build")/terminfo" "$app_path/Contents/Resources/terminfo"
ditto "$(dirname "$tmux_build")/licenses" "$app_path/Contents/Resources/Licenses"
daemon="$app_path/Contents/Library/LaunchDaemons/com.sidea.keepawake.plist"
mkdir -p "$(dirname "$daemon")"
cp scripts/com.sidea.keepawake.plist "$daemon"
# AppResources reads these fixed paths, never SwiftPM's resource bundle, whose layout changes between toolchains.
mkdir -p "$app_path/Contents/Resources/bridge"
cp bridge/*.py "$app_path/Contents/Resources/bridge/"
cp Sources/SideA/Resources/discman.json "$app_path/Contents/Resources/discman.json"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
# Local builds get their own identity and no updater, so they never install updates over themselves
# or collide with an installed copy's updater. Release builds opt in; verify-bundle.py rejects anything else.
if [[ "${SIDEA_RELEASE_BUILD:-}" != 1 ]]; then
  plist="$app_path/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string com.arnenoori.sidea.dev "$plist"
  plutil -replace CFBundleDisplayName -string "Side A Dev" "$plist"
  plutil -remove SUFeedURL "$plist"
  plutil -replace SUEnableAutomaticChecks -bool NO "$plist"
  plutil -replace AssociatedBundleIdentifiers -json '["com.arnenoori.sidea.dev"]' "$daemon"
fi
plutil -lint -s "$daemon"
if [[ -f design/SideA.icns ]]; then cp design/SideA.icns "$app_path/Contents/Resources/SideA.icns"; fi
framework_source=".build/package-$architecture/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$framework_source"
mkdir -p "$app_path/Contents/Frameworks"
ditto "$framework_source" "$app_path/Contents/Frameworks/Sparkle.framework"
./scripts/sign-framework.sh "$app_path/Contents/Frameworks/Sparkle.framework" --force --sign -
./scripts/sign-helper.sh "$app_path" --force --sign -
codesign --force --sign - "$app_path"
echo "$app_path"
