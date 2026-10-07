#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for architecture in arm64 x86_64; do
  python3 scripts/verify-bundle.py "dist/$architecture/Side A.app" --architectures "$architecture"
done
app_path="$PWD/dist/universal/Side A.app"
if [[ -d "$app_path" ]]; then rm -rf "$app_path"; fi
mkdir -p "$(dirname "$app_path")"
ditto "dist/arm64/Side A.app" "$app_path"
lipo -create "dist/arm64/Side A.app/Contents/MacOS/SideA" \
  "dist/x86_64/Side A.app/Contents/MacOS/SideA" -output "$app_path/Contents/MacOS/SideA"
codesign --force --sign - "$app_path"
python3 scripts/verify-bundle.py "$app_path" --architectures arm64 x86_64
