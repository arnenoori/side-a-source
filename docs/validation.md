# Validation

How Side A is checked before a release. Tests never touch real logins: they run in temporary
folders with fake CLIs and a fake Keychain. What only real accounts can show is checked by hand.

## Local gates

`./scripts/local-ci.sh` runs every gate on this Mac and stops at the first failure:

1. `actionlint` on the workflows and `shellcheck` on `scripts/*.sh`.
2. Packaging and release tests (`scripts/tests`): release tags, notes and the update feed.
3. Bridge tests (`bridge/tests`).
4. Copies the bridge into the app's resources, then `swift test`.
5. The download page in `site/`: install, test and build.
6. Release builds for arm64 and x86_64, joined into a universal app. Intel is cross-compiled;
   it is not run on this Mac.
7. The disk image, built with Python 3.10 or later, then mounted and checked.

GitHub runs the same suites on native Apple Silicon and Intel runners (`.github/workflows/ci.yml`).

## Bridge tests

`python3 -m unittest discover -s bridge/tests -v`

- **Logins** (`test_bridge.py`): Keychain slot names match the CLI's; a slot holding another
  account's login is refused; reading usage never writes a login; a renewal spends its refresh
  token once; a trade moves logins between items and a crash finishes it forward; Side A waits
  for Claude Code's refresh lock and releases it.
- **Switching:** the `~/.zshrc` line survives aliases, `set -u` and upgrades; `sidea use` keeps
  one terminal on one account; busy slots follow Claude Code's storage rule; a session's own limit
  error names the full account.
- **Hooks:** the statusline wrapper keeps the user's line; the limit hook is silent and
  removable; the island hooks install beside the user's own for both CLIs and come out cleanly;
  the hook relays the island's answer over a real socket and steps aside when Side A is gone; a
  note or stop reaches a working session at its next tool call.
- **Usage:** each response and Codex turn counts once; two Macs share totals through the sync
  folder without logins.
- **Codex** (`test_codex.py`): the Mac's Codex login is read where Codex keeps it and never
  copied; a revoked login asks for sign-in.
- **Sessions** (`test_sessions.py`): indexing, titles and branches; Codex sessions; live sessions
  listed waiting first; the current step and health flags; incremental reindexing; opening a
  conversation around a search hit.

## Swift tests

`swift test`

- **Models:** duplicate identities, path traversal and unknown providers fail closed; the
  library is saved with private permissions; old libraries migrate without changing accounts.
- **Planner:** expiring quota goes first and idle windows are primed; overnight agent traffic
  doesn't count as working hours; spent Fable caps are skipped; Fable sessions trade with a login
  only other models use; a session's limit error fills that limit; trades wait for a pause unless
  the account is out of room; weekly forecasts follow a weekday rhythm.
- **Island:** requests read the command, reason and suggested rule; Codex commands and patches
  show as they will run; destructive commands need a click; answers are one JSON line the hook
  understands; questions and plans are answered by sending their input back; a request is settled
  once Claude Code's registry says its session stopped waiting after it arrived, and never for Codex
  or headless runs.
- **Pricing, diagnostics and analytics:** API prices, the status.claude.com filter, diagnostic
  canaries, and analytics that need consent, honor revocation and stay off in the demo.
- **Warp:** the tab picked is the pane still running the session, by Warp's focus link and, without one, by folder.

## Demo mode

```sh
open -n "dist/Side A.app" --args --demo
```

The demo uses a temporary root (`$TMPDIR/SideA-preview-<pid>`) with fictional Claude and Codex
accounts, limits and running sessions. It does not sign in, read real usage, check for updates,
send analytics, or install the shell line, statusline or hooks. Use it to inspect layout, copy,
VoiceOver and Reduce Motion, and for screenshots. **Show a sample request** in Settings > General
tries the island without a session.

## Live checks

Some behavior depends on real accounts and real Claude Code sessions. It is checked by hand on a
local build, and is never inferred from the tests above:

- Sign-in in the browser, and limits that match what Claude Code shows.
- A trade while sessions run: they continue as the new account without restarting.
- A real limit reply triggering a trade while the usage endpoint is rate-limited.
- The island: Allow, Deny and Always from Claude Code and Codex; answering in the terminal
  instead, which clears the request within a second; Reply waking a finished session; Go and Show terminal reaching the right tab in
  Ghostty, iTerm, Terminal and Warp.
- Notes and stops reaching a working session; health flags on a real stuck or looping session.
- VoiceOver, keyboard-only use, Reduce Motion and Increase Contrast.

Local builds are "Side A Dev" with their own bundle ID and no updater, so testing never disturbs
an installed copy.

## Release verification

These scripts in `scripts/` run during the build and release steps and stop on any mismatch:

- `check-release.py`: the tag matches the version and release notes exist.
- `verify-bundle.py`: the app's Info.plist, architectures, bridge resources, icon and pinned
  Sparkle 2.9.6 framework match the sources; the update feed requires signatures.
- `verify-dmg.py`: mounts the disk image read-only and checks the app, the Applications shortcut
  and the installer layout.
- `notarize-app.sh`: signs with Developer ID, notarizes and staples the app and the disk image,
  and checks both with `codesign` and `spctl`.
- `verify-downloads.py`: the checksum file covers exactly the two downloads.
- `verify-appcast.py`: the feed names one update with the right version, size, download URL,
  signature and minimum macOS.
