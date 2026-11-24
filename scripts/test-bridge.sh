#!/usr/bin/env bash
# Runs the bridge tests the way every gate needs them: on python3, and again on macOS's own /usr/bin/python3 when that is
# Python 3.9, which is what the app runs the bridge with and the oldest it supports. Arguments go to unittest (e.g. -v).
# check.sh, local-ci.sh and the hosted workflow all call this, so the version rule lives here only.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s bridge/tests "$@"
if [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version_info[:2] == (3, 9))' 2>/dev/null)" == True ]]; then
  /usr/bin/python3 -m unittest discover -s bridge/tests "$@"
fi
