#!/bin/bash
# The helpers are nested code: sign them before the app, the keep-awake helper under the identifier its XPC peers require.
set -euo pipefail
app="${1:?Side A.app required}"
shift
codesign "$@" --options runtime --identifier com.sidea.keepawake "$app/Contents/MacOS/SideAKeepAwake"
codesign "$@" --options runtime --identifier com.sidea.tmux "$app/Contents/Helpers/tmux"
