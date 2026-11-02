#!/usr/bin/env bash
# Builds this checkout, runs it in place of the installed Side A, and puts the installed one back when it quits.
set -euo pipefail
cd "$(dirname "$0")/.."
architecture="$(uname -m)"
./scripts/build-app.sh debug "$architecture"
open -W -n "dist/$architecture/Side A.app"
[[ -d "/Applications/Side A.app" ]] && open "/Applications/Side A.app"
