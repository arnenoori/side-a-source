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
for executable in SideA SideAKeepAwake SideAPool; do
  lipo -create "dist/arm64/Side A.app/Contents/MacOS/$executable" \
    "dist/x86_64/Side A.app/Contents/MacOS/$executable" -output "$app_path/Contents/MacOS/$executable"
done
./scripts/sign-helper.sh "$app_path" --force --sign -
codesign --force --sign - "$app_path"
python3 scripts/verify-bundle.py "$app_path" --architectures arm64 x86_64
