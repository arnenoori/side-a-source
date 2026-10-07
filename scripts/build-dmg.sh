#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-bundle.py "dist/universal/Side A.app" --architectures arm64 x86_64
swift design/build_installer.swift dist/installer-background.png
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
: "${DMGBUILD:=.build/dmg-tools/bin/dmgbuild}"
"$DMGBUILD" -s scripts/dmg-settings.py "Side A" "dist/SideA-$version-macOS-universal.dmg"
.build/dmg-tools/bin/python scripts/verify-dmg.py "dist/SideA-$version-macOS-universal.dmg"
