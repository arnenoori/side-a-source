#!/bin/bash
# Run after notarization. Publish the binary before deploying the generated feed.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
python3 scripts/check-release.py "v$version"
python3 scripts/verify-downloads.py
: "${SPARKLE_TOOLS:=.build/artifacts/sparkle/Sparkle/bin}"
: "${SPARKLE_ACCOUNT:=com.arnenoori.sidea}"
folder=".build/appcast-$version"
mkdir -p "$folder"
cp "dist/SideA-$version-macOS-universal.dmg" "$folder/"
cp "releases/v$version.md" "$folder/SideA-$version-macOS-universal.md"
key_args=(--account "$SPARKLE_ACCOUNT")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then key_args=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
"$SPARKLE_TOOLS/generate_appcast" "${key_args[@]}" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/arnenoori/side-a-releases/releases/download/v$version/" "$folder"
"$SPARKLE_TOOLS/sign_update" "${key_args[@]}" --verify "$folder/appcast.xml"
python3 scripts/verify-appcast.py "$folder/appcast.xml" "dist/SideA-$version-macOS-universal.dmg"
cp "$folder/appcast.xml" dist/appcast.xml
