#!/bin/bash
# Sign and notarize the already tested universal bundle. Never rebuild in this stage.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Developer ID Application identity required}"
: "${APPLE_TEAM_ID:?Personal Apple Developer team required}"
: "${NOTARY_KEY_ID:?App Store Connect API key ID required}"
: "${NOTARY_KEY_PATH:?Path to API private key required}"
[[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo "Developer ID identity required" >&2; exit 1; }
app_path="$PWD/dist/universal/Side A.app"
python3 scripts/verify-bundle.py "$app_path" --architectures arm64 x86_64
signing_args=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then signing_args+=(--keychain "$SIGNING_KEYCHAIN"); fi
./scripts/sign-framework.sh "$app_path/Contents/Frameworks/Sparkle.framework" "${signing_args[@]}"
codesign "${signing_args[@]}" "$app_path"
details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
[[ "$details" == *"TeamIdentifier=$APPLE_TEAM_ID"* ]] || { echo "Wrong signing team" >&2; exit 1; }
[[ "$details" == *"runtime"* && "$details" == *"Timestamp="* ]] || { echo "Missing hardened runtime or timestamp" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
archive="$PWD/dist/SideA-$version-macOS-universal.zip"
ditto -c -k --keepParent "$app_path" "$archive"
notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
if [[ -n "${NOTARY_ISSUER_ID:-}" ]]; then notary_args+=(--issuer "$NOTARY_ISSUER_ID"); fi
xcrun notarytool submit "$archive" "${notary_args[@]}" --wait --timeout 20m --output-format json > dist/notarization.json
python3 -c 'import json; r=json.load(open("dist/notarization.json")); print("Notarization:", r.get("status")); assert r.get("status") == "Accepted", "Apple did not accept this build"'
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
python3 scripts/verify-bundle.py "$app_path" --architectures arm64 x86_64
# The downloadable ZIP must contain the stapled app, not the pre-notarization copy.
rm "$archive"
ditto -c -k --keepParent "$app_path" "$archive"
./scripts/build-dmg.sh
dmg="$PWD/dist/SideA-$version-macOS-universal.dmg"
dmg_signing_args=(--force --sign "$SIGNING_IDENTITY" --timestamp)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then dmg_signing_args+=(--keychain "$SIGNING_KEYCHAIN"); fi
codesign "${dmg_signing_args[@]}" "$dmg"
xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --timeout 20m --output-format json > dist/notarization-dmg.json
python3 -c 'import json; r=json.load(open("dist/notarization-dmg.json")); print("Installer notarization:", r.get("status")); assert r.get("status") == "Accepted", "Apple did not accept this installer"'
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
.build/dmg-tools/bin/python scripts/verify-dmg.py "$dmg"
(cd dist && shasum -a 256 "$(basename "$archive")" "$(basename "$dmg")" > SHA256SUMS.txt)
