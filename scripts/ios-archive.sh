#!/bin/bash
# Archives Side A Remote (Release: production push, getsidea.com links, iPhone only) and exports an .ipa for
# App Store Connect, then checks what's inside it. Nothing is uploaded; that's `xcrun altool --upload-app` or
# Transporter, by hand.
# Each archive takes the next build number (BUILD=<n> picks one, NO_BUMP=1 reuses the current one); project.yml
# records it once the export passes its checks, to commit.
# The team comes from TEAM_ID or APPLE_TEAM_ID, else from apps/ios/Local.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/../apps/ios"

team="${TEAM_ID:-${APPLE_TEAM_ID:-}}"
[ -n "$team" ] || team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' Local.xcconfig 2>/dev/null | tail -1)"
[ -n "$team" ] || { echo "No signing team. Set TEAM_ID, or fill in apps/ios/Local.xcconfig." >&2; exit 1; }

version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
current="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
build="${BUILD:-$current}"
[ -n "${NO_BUMP:-}" ] || [ -n "${BUILD:-}" ] || build=$((current + 1))
echo "Side A Remote $version ($build)"

# Signing needs an Apple account in Xcode › Settings › Accounts, or an App Store Connect API key (Users and
# Access › Integrations): ASC_KEY_PATH=<AuthKey_XXXX.p8> ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id>.
auth=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodegen --quiet

name="SideARemote-$version-$build"
archive="build/archive/$name.xcarchive"
export_dir="build/export/$name"
rm -rf "$archive" "$export_dir"
xcodebuild -project SideARemote.xcodeproj -scheme SideARemote -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"} DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" -quiet archive

options="$(mktemp -t export-options).plist"
trap 'rm -f "$options"' EXIT
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
# Packaging calls rsync with the system's options; Homebrew's rsync 3.x first on PATH fails it ("Copy failed").
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" -exportOptionsPlist "$options" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} -quiet

ipa="$(ls "$export_dir"/*.ipa)"
python3 -I "$(pwd)/../../scripts/ios-check-ipa.py" "$ipa"
# Only a build that made it this far takes the number.
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$current\"/CURRENT_PROJECT_VERSION: \"$build\"/" project.yml
echo "Ready to upload: $(pwd)/$ipa"
[ "$build" = "$current" ] || echo "project.yml now says build $build: commit it."
