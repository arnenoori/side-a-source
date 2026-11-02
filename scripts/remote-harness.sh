#!/bin/bash
# Runs the Remote test harness (Tests/SideATests/Remote/RemoteHarness.swift) so a phone or the Simulator can pair with
# it. `swift test` runs tests where other processes can't reach their listeners, so this starts the built test bundle
# itself. Build first with `swift build --build-tests`.
set -euo pipefail
cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
platform="$developer/Platforms/MacOSX.platform/Developer"
helper="$developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
bundle="$(find .build -path '*SideATests.xctest/Contents/MacOS/SideATests' -type f -print0 | xargs -0 ls -t | head -1)"
if [ -z "$bundle" ]; then
    echo "No test bundle; run swift build --build-tests first." >&2
    exit 1
fi
SIDEA_REMOTE_HARNESS=1 DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib" \
    exec "$helper" --test-bundle-path "$bundle" --testing-library swift-testing --filter remoteHarness
