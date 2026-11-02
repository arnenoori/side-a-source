#!/bin/bash
# Builds Side A Remote (Debug, ids ending in .dev) and installs and launches it on a connected iPhone.
# The team comes from TEAM_ID or APPLE_TEAM_ID, else from apps/ios/Local.xcconfig.
# DEVICE=<name, UDID or devicectl identifier> picks one phone when several are connected.
set -euo pipefail
cd "$(dirname "$0")/../apps/ios"

team="${TEAM_ID:-${APPLE_TEAM_ID:-}}"
if [ -z "$team" ] && ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]\{10\}' Local.xcconfig; then
    echo "No signing team. Set TEAM_ID, or copy apps/ios/Local.xcconfig.template to Local.xcconfig and fill it in." >&2
    exit 1
fi

xcodegen --quiet

# Built for any iPhone first, so a signing problem shows before a phone is needed.
derived=build/device
xcodebuild -project SideARemote.xcodeproj -scheme SideARemote -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived" -allowProvisioningUpdates \
    ${team:+DEVELOPMENT_TEAM="$team"} -quiet build || {
    echo "If the profiles don't match the application-groups entitlement, build once in Xcode so it registers the App Group (apps/ios/README.md, step 2)." >&2
    exit 1
}
app="$derived/Build/Products/Debug-iphoneos/SideARemote.app"
[ -d "$app" ] || { echo "Build produced no app at $app." >&2; exit 1; }

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
xcrun devicectl list devices --json-output "$list" >/dev/null
device="$(python3 -I - "$list" "${DEVICE:-}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2]
# devicectl lists simulators too: keep real phones it can reach now.
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d.get("hardwareProperties", {}).get("reality") == "physical"
          and d.get("connectionProperties", {}).get("tunnelState") not in ("unavailable", "disconnected")]
if wanted:
    phones = [d for d in phones
              if wanted in (d["identifier"], d.get("hardwareProperties", {}).get("udid"), d.get("deviceProperties", {}).get("name"))]
print(phones[0]["identifier"] if phones else "")
PY
)"
if [ -z "$device" ]; then
    echo "Built $app, but no iPhone is connected. Plug it in, trust this Mac, and turn on Developer Mode." >&2
    exit 1
fi

xcrun devicectl device install app --device "$device" "$app"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
xcrun devicectl device process launch --device "$device" "$bundle" >/dev/null 2>&1 \
    || echo "Installed $bundle. Unlock the iPhone and open Side A; it couldn't be launched while locked."
