#!/bin/bash
# Sparkle contains nested executables; sign from the inside out, never with --deep.
set -euo pipefail
framework="${1:?Sparkle framework required}"
shift
for component in \
  "Versions/B/XPCServices/Downloader.xpc" \
  "Versions/B/XPCServices/Installer.xpc" \
  "Versions/B/Autoupdate" \
  "Versions/B/Updater.app"; do
  codesign "$@" "$framework/$component"
done
codesign "$@" "$framework"
