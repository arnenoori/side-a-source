# Architecture

Side A has two halves: a native SwiftUI app, and a stdlib-only Python bridge the app runs for
anything that touches logins, the CLIs' files or transcripts. A third small script,
`island_hook.py`, runs inside Claude Code and Codex as a hook and talks to the app over a socket.

## Native application

`SideA` is SwiftUI on macOS 14+. One observable `AccountStore` backs the `MenuBarExtra`, the
Settings window (Accounts, Usage, Sessions, Autopilot, Setup, General), the Dynamic Island and the
optional 3D player. It runs the Autopilot loop: read usage, trade logins, start idle windows,
check status.claude.com every five minutes, and send weekly-limit notifications.

`SideACore` has no AppKit dependencies and is unit-tested:

- `Models.swift`: Codable models, private atomic persistence, and the `Planner` (account choice,
  Move at, Fable-share trades, the five-minute pause before a trade that isn't urgent, window
  priming). The planner is pure.
- `Island.swift`: decodes hook messages into requests, assesses risk (destructive commands and
  credentials files), and builds VoiceOver announcements.
- `Pricing.swift`: Anthropic API list prices for "Worth at API prices" (LiteLLM's published list,
  fetched daily into `runtime/prices.json`, with a built-in October 2026 table as fallback), and the
  parser for status.claude.com's `summary.json` that keeps only incidents touching Claude Code or
  the API.
- `Diagnostics.swift`: the diagnostic summary and the opt-in analytics payloads.
- `KeepAwake.swift`: whether to hold the keep-awake power assertion and turn sleep off (working
  agents, the two-minute grace, power source and battery), counting working sessions without
  spawning anything: Claude Code's registry (`busy`, or `shell` while a background Bash job runs),
  with a three-hour stale cutoff over the main and subagent transcripts, found by session id when
  Claude Code shortened the project folder name; and Codex rollouts in the last 14 dated folders.
  It also decides when a closed MacBook should be put to sleep after sleep comes back.

`KeepAwakeController` applies those decisions every 30 seconds while the setting is on: an IOKit
`PreventUserIdleSystemSleep` assertion, and for the lid-closed option, requests to the
`SideAKeepAwake` helper. Everything that touches the Mac sits behind a `SleepSystem` protocol, so
tests run it against a fake.

`SideAKeepAwake` is a separate executable embedded as `Contents/MacOS/SideAKeepAwake` and
registered with `SMAppService.daemon` from `Contents/Library/LaunchDaemons/com.sidea.keepawake.plist`
(source: `scripts/com.sidea.keepawake.plist`). It runs as root, answers one XPC call over the Mach
service `com.sidea.keepawake`, and runs only `pmset`. `SideAKeepAwakeCore`, shared by the app, the
helper and the tests, holds the XPC protocol, the code-signing requirements each side checks, and
`LidSleepState`, the helper's pure policy: sleep stays off only while a connected Side A asks, a
30-second handover after a dropped connection lets an update's relaunch take over, and the helper
restores at launch only what it recorded as its own. `scripts/sign-helper.sh` signs it before the
app (see [security](../SECURITY.md#keep-awake)).

`DiscmanView` (the optional 3D player) reads evaluated geometry exported by Blender, builds
SceneKit meshes, and renders on demand. Accessibility elements attach to the model buttons, and
Reduce Motion disables the lid and button animations.

## Bridge

`bridge/sidea_bridge.py` is a stdlib-only command runner the app calls per action:

| Command | Does |
| --- | --- |
| `login`, `logout`, `status`, `adopt` | Sign an account in or out, check it, add the Mac's own login |
| `usage`, `renew`, `prime` | Read limits, renew an expired login, start a 5-hour window |
| `pool-token` | The access token pool mode sends for an account, renewed first if it expired |
| `active`, `activate`, `swap` | Which login each running session reads; choose an account; trade two logins |
| `report` | Token totals by day, project and model from transcripts (and iCloud sync) |
| `shell`, `live`, `hook`, `island` | Turn the `~/.zshrc` line, statusline wrapper, limit hook or island hooks on, off, or report status |
| `host-terminal` | Turn the second `~/.zshrc` line (hosting `claude` and `codex` typed in a terminal) on, off, or report status |
| `hosting` | `install` writes `runtime/tmux.conf` and `runtime/sidea-tmux` and finds tmux; `codex-env` gives a hosted Codex session its account's home |
| `sessions` | Index, search and show conversations; list live sessions with their step and flags |
| `cleanup` | Disk use of transcripts; archive or restore old ones; list and remove clean git worktrees |

Claude profile Keychain slots follow the CLI's naming: `Claude Code-credentials-` plus the first
8 hex digits of the SHA-256 of the NFC profile path. Logins are written only to renew one or to
trade two (see [security](../SECURITY.md)). A trade is journaled in the Keychain first and always
completed forward, even after a crash.

`bridge/setup.py` backs the Setup tab, read-only: CLI paths and versions, MCP servers (user,
project and Codex scopes, key names only), hooks with Side A's own marked, skills and agents.
`setup mcp-health` runs `claude mcp list` only when asked.

`bridge/sessions.py` builds the SQLite search index from `~/.claude/projects` and Codex's
sessions (`~/.codex/sessions` and the profiles' shared `codex-conversations/sessions`), and reads
Claude Code's session registry (`~/.claude/sessions`) for live sessions. For
each one it reads the tail of its transcript to name the current step and raise at most one flag:
`stuck` (busy, no transcript change for 10 minutes), `loop` (the same tool call 3 times among the
last 6), `failing` (4 failed tool results in a row) or `bloated` (context of 150k tokens or more).
Running Codex sessions are found from `ps`, mapped to their open rollout with one `lsof`, and given
a status from the rollout's tail (`unknown` when no turn event is in reach). A session under Side
A's own tmux server (`tmux -L sidea`) is marked `hosted`.

The same pass indexes every image in every transcript by where its base64 starts in the file
(SHA-1, size, dimensions, offsets), never the bytes. `sessions show --format remote` pages a
conversation with cursors (`<generation>.<seq>.<rev>`), tool results, diffs and image references;
`sessions message` returns one message uncut, `sessions image` an image's location and
`sessions images` a conversation's images. Claude's thinking and Codex's reasoning summaries are
`thinking` rows with `duration_ms`: Codex records when reasoning started and ended; for Claude it is
the time from the line before to the thinking block's own line. The viewer's default `show` keeps
its shape and leaves thinking out: runs of tool calls are one line, and commands under a Codex
`exec` stay folded into it.

`sessions turn-diff <id> [--turn <prompt uuid>]` returns what one Claude turn changed: the diff of every
file-tool edit that went through (Edit, MultiEdit, Write), in order, from the turn's prompt to the
next. Edits to one file stay separate, each numbered as that edit saw the file; a change made through the shell
isn't seen, which the result's `note` says. A live Claude row's `turnID` is its newest prompt's uuid and
`compactedAt` the time of its last compaction, both from the transcript's tail.

Two Codex rules come from real rollouts rather than a format guarantee. A finished command item
belongs to the `exec` call still waiting for its output, or, when it is written just after that
output, to the last `exec` in the newest row. An `McpToolCall` item that repeats a running
`function_call` of the same tool name is dropped, since the call and its output are already shown.

Indexing a file for the first time costs more when it holds images, because each one is decoded
and hashed once: about 1.1 s for a 385 MB transcript with 600 images, against 0.6 s without the
image index. Later passes read only new lines.

## Pool mode

Off by default (Autopilot > Pool mode). `PoolProxy` listens on `127.0.0.1:47317` (any free port if
that one is taken) and writes `runtime/pool`: its URL, the key in `runtime/pool-key` and the app's
pid. The shell line reads that file before each command: while the pid is alive and the terminal
isn't pinned with `sidea use`, a command that runs `claude` (as typed or alias-expanded) gets
`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `SIDE_A_POOL=1` without the login selector; any
other command gets none of them, and a base URL or token the user exported is left alone.

A session keeps the base URL it started with, so the pool must outlive the app. `SideAPool`, embedded
as `Contents/MacOS/SideAPool` and registered with `SMAppService.agent` from
`Contents/Library/LaunchAgents/com.sidea.pool.plist` (`com.sidea.pool.dev.plist` in a local build, so
the two never replace each other) while pool mode is on, serves the same port and key whenever the
app's process is gone (`PoolHelper`, `PoolFiles`). The app names itself in `runtime/pool-app` (pid and
process start time, so a reused pid doesn't count) before it opens the port, and the helper, checking
every second, lets the port go within a second of seeing it; the app waits up to 10 s. While serving,
the helper writes `runtime/pool` with its own pid, so new commands use the pool too. It picks accounts
by `runtime/pool-plan.json`, which the app rewrites as accounts, usage and login health change:
members in priority order with their last usage (a window past its reset stops counting), Autopilot's
threshold, and the Python and bridge paths for `pool-token`. A 429 benches an account until its
reset, as in the app. It doesn't serve the Tailscale share; other Macs fall back to their own logins
while this app is closed. The helper never leaves on its own while pool mode is on: turning it off
unregisters the agent. When its executable is replaced (an update or rebuild) it hands back, waits ten
minutes for replies still streaming, and leaves with status 75, which launchd restarts with the new
binary. Its log is `~/Library/Logs/SideA/pool-helper.log`. Without the helper (a build run outside
its bundle), the app removes `runtime/pool` when it quits, so commands use logins again at once.

The proxy answers only Claude Code's user agent and forwards only `/v1/` routes to
`api.anthropic.com` (`Pool.upstream`). Behind it Claude Code takes itself for an API-key caller and
asks for five-minute cache breakpoints; `Pool.hourLongCache` makes them hour-long, as it does for a
subscriber, so a pause over five minutes doesn't write the conversation to cache again. A 401 asks
the bridge to renew that exact token (`pool-token --refused`) unless a session already has; a
token that can't be read for a moment benches the account for two minutes, and only "sign in
again" marks it.

Each request's conversation is Claude Code's session id (its header, else `metadata.user_id`).
`PoolRouter` keeps a conversation on its account for an hour after its last request, because a
prompt cache belongs to one account; a new conversation, or one whose account is full, gets
`Planner.best`. A 429 blocks that account until the reply's reset and sends the request to the
next account before anything reaches Claude Code; a 401 asks for a sign-in once. The reply streams
back as it arrives, and its `anthropic-ratelimit-unified-*` headers update that account's limits.
`slot_processes` skips `SIDE_A_POOL` sessions, so trades never wait for them.

Share with my other Macs opens a second listener on this Mac's Tailscale IPv4 address with its own
key (`PoolGate`); `PoolPeers` admits a peer only when `tailscale whois --json` names this Mac's own
Tailscale login, cached ten minutes per address. Settings shows `sidea pool join <url> <key>`; on
another Mac that writes `runtime/pool-remote`, and its shell line uses that pool for `claude` when
its own isn't running and the host answers within a second (`nc -z -G 1`), else its own logins.

## Dynamic Island

Turning on Settings > General > Dynamic Island runs `island on`, which:

1. copies `island_hook.py` to `runtime/island_hook.py` and writes two launchers,
   `runtime/island-hook.sh` and `runtime/island-mail.sh`, that run it with the Python Side A
   found, in isolated mode (`-I -S`). If that Python is gone, they exit and the CLI behaves as if
   no hook were there;
2. adds hooks marked `side-a-island` beside the user's own:

| CLI | File | Hooks |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | `PermissionRequest` (waits up to 24 h), `Stop` (`asyncRewake`, waits up to 1 h), `PreToolUse`, `PostToolUse` and `PostToolUseFailure` (mail, 5 s), `PostModelSwitch` (30 s, only when every `claude` found is 2.1.251 or later) |
| Codex | `~/.codex/hooks.json` (or `$CODEX_HOME`) | `PermissionRequest`, `Stop` (5 s) |

The Codex hooks are a separate toggle, and Codex runs them only after the user trusts them once
with `/hooks`. The hook commands never name a Python version, so Codex keeps trusting them across
updates; on each launch Side A rewrites the launchers so they follow Python and app updates.
Turning the island off, or Remove Side A, removes every `side-a-island` hook and leaves the
user's hooks as they were.

**The socket.** The app listens on `runtime/island.sock` (mode 0600) and accepts only connections
whose peer uid is the current user's. Each hook sends one JSON line: agent, session pid, the
Keychain slot the session reads (to name the account), whether it is headless (`claude -p` or an
SDK run), and the CLI's hook input.

**Permission requests.** The hook waits for one line back: allow (optionally with Claude Code's
suggested rule, or an edited input that carries an answer to a question or a plan decision),
deny, or "ask in the terminal". Claude Code keeps its own prompt open meanwhile, and when the
user answers there it leaves the hook running (checked against 2.1.300). So the app watches Claude
Code's registry (`~/.claude/sessions/<pid>.json`): once the session leaves `waiting` after the
request arrived, and stays out for half a second, or its process is gone, the app answers "ask"
so the hook exits, and drops the request. A finished turn from the same session drops it too.
A hook that closes its socket (the session quit) drops its request at once. Codex
shows its prompt only after the hook returns, so a Codex request (and a headless one) is handed
back after two minutes unanswered. Rules are never sent to Codex, which fails closed on them.

**Calls the CLI decides itself.** Codex runs PermissionRequest hooks before anything else: before its
auto-reviewer, its own "for this session" approvals and its `approval_policy = never` refusals
(Codex 0.162, `core/src/tools/approvals.rs`). So the hook steps aside, and Codex goes on as if it
weren't there, when the request says `permission_mode: bypassPermissions`, when the newest
`turn_context` or `thread_settings_applied` in the rollout names a reviewer other than `user`
("Approve for me" is `auto_review`), when a `request_permissions` grant in the running turn asked
for `strict_auto_review`, when `[apps.<app>]` or `[apps._default]` in `config.toml` gives a Codex
Apps tool another reviewer (an app's own reviewer, `user` included, wins over the thread's; the hook's
tool name has no connector id, so an app matches when the name is its key or starts with its key and
`_`), or when the administrator's requirements (`/etc/codex/requirements.toml` or the
`com.openai.codex` managed preferences) don't allow the user to review or require review for the
model. The `config.toml` and requirements checks need Python 3.11's `tomllib`; without it the island
asks as before. A hook can't send Codex "for this session", so the island offers it for a patch that
deletes nothing, and the hook keeps it in `runtime/state/codex-approved/<thread>.json` for 12 hours:
a later patch touching only covered files (resolved in the turn's folder) is allowed without asking.
Commands are never kept: the hook gets the turn's folder, not the command's `workdir` or sandbox
permissions, and Codex sends a network approval as the same `Bash` command with a
`network-access <target>` description. A patch with a header that isn't written plainly (Codex
trims indentation) always asks. Approvals given in Codex's own prompt stay Codex's; the rollout
doesn't record them. Claude Code runs the hook only when it would prompt (auto mode's classifier comes
first, checked against 2.1.310), but an SDK host's own callback runs alongside it and a background
subagent has no prompt, so for Claude the hook watches the transcript (a subagent's own under
`subagents/`) and closes its request once the call has its `tool_result`; a subagent's request is
also handed back after two minutes.

**Finished sessions and Reply.** Claude Code's `Stop` hook runs in the background with
`asyncRewake`. It tells the app the session is done and waits. Reply answers it with the user's
text; the hook prints it to stderr and exits with code 2, which wakes the idle session with that
text as its next instruction. If the session is given work in the terminal, or an hour passes,
the wait is released. A turn waiting on background tasks doesn't count as finished; the turn a
follow-up woke does, so the session can be answered again. Codex's `Stop` hook only reports that the session is done.

**Notes and stops (mail).** Sessions > Running writes `runtime/mail/<pid>.json` with
`{"kind": "note", "text": …}` or `{"kind": "stop"}`. The mail launcher tests for that file and
exits at once when there is none, so the hooks cost one file test per tool call. `PostToolUse`
(or `PostToolUseFailure`, when the tool failed) claims a note by renaming it, reads what it
claimed, and returns it as `additionalContext`. `PreToolUse` answers a
stop with `continue: false` and a deny, and keeps denying for 10 seconds so parallel tool calls
in the same response stop too. The app deletes mail for sessions that ended.

**Session settings.** A running Claude row carries the session's model, effort, fast mode, context
percent, cost, permission mode and background tasks. The statusline wrapper keeps each session's
input in `runtime/live/s/<session id>.json` (model, effort, fast mode, `context_window.used_percentage`,
`cost.total_cost_usd`). Every Claude hook that runs Python saves what its input says in
`runtime/state/<session id>.<kind>.json`: `hook` (`permission_mode`, `effort.level`), `model` (`SessionStart`,
`PostModelSwitch`) and `tasks` (the `background_tasks` of the last `Stop`); a subagent's hooks save nothing.
The mode is also read from the transcript's tail, where Claude Code writes a `permission-mode` record at each
change and stamps every prompt. `live` takes the newest reading of each field, drops files a week old, and drops the background tasks of a
session that is no longer running.
An island answer with a `mode` adds `{type: "setMode", mode, destination: "session"}` to Claude Code's
`updatedPermissions` (Allow and switch mode).

**Terminal tabs.** `TerminalFocus` finds the terminal app hosting a session's pid and brings its
tab forward with Apple Events in Terminal and iTerm (by tty) and Ghostty (by folder and title).
`WarpFocus` opens the `WARP_FOCUS_URL` link Warp gives each shell, read from the session's own
environment (`KERN_PROCARGS2`), which lands on the exact tab and split. Warp builds without that link
fall back to its session database (`warp.sqlite` in Warp's group container, read-only), matching the
window through Accessibility and pressing Warp's ⌘1–9 tab shortcuts; that path needs Accessibility
permission and only knows a tab's folder as of its last finished command.

**Shortcuts.** `HotKeys` registers the ⌃⌥ shortcuts globally only while a request or a finished
session is waiting, and releases them otherwise.

## Local storage

All managed data lives under `~/Library/Application Support/SideA/`:

```text
config.json                    Accounts and app-wide choices (Autopilot, sync, menu bar)
preferences.json               Settings every copy of Side A shares (see below)
machine-id                     Hashed id for this Mac in the iCloud sync folder
profiles/<uuid>/               An account's own Claude config dir (clean settings) and slot
conversations/                 Transcripts of Claude runs under account profiles (priming)
codex-conversations/           Shared Codex history for Codex profiles
runtime/claude-selector        Profile path new claude commands use (empty: Mac login)
runtime/accounts/              One file per account for `sidea use <name>`
runtime/homes.json             Which Keychain slot holds which account after trades
runtime/live/                  Limits saved by the statusline wrapper; s/ holds each session's input
runtime/state/                 Mode, effort, model switch and background tasks from each session's hooks
runtime/statusline.sh          The statusline wrapper
runtime/sessions.db            Session search index, viewer cache and image index (SQLite)
runtime/thumbs/                Image thumbnails; unused ones swept hourly, capped at 200 MB
archive/                       Archived transcripts, under their path relative to the home folder
runtime/island.sock            Socket the island hooks connect to
runtime/island_hook.py         Copy of the hook script, and its two launchers
runtime/mail/<pid>.json        A note or stop waiting for a working session
runtime/*.lock                 Serialize selection, renewal, settings and index writes
runtime/tmux.conf              Config of Side A's tmux server (tmux -L sidea), rewritten at launch
runtime/tmux-path              The tmux binary every hosted client runs
runtime/sidea-tmux             Launcher for every hosted start and attach
runtime/hosted/<name>/         A hosted session's launch file, first prompt, and last screen
runtime/host-terminal          Present while Host terminal sessions is on
```

Directories are private (0700) and files 0600. App and bridge write separate files atomically.
A corrupt account configuration fails closed and is never replaced with an empty library.

### Shared preferences

UserDefaults belongs to a bundle id, so the release and dev builds would each keep their own settings. `PreferencesMirror`
keeps the keys in `PreferencesMirror.shared` in `preferences.json`, each as `{value, at, by}`, and leaves `@AppStorage` alone:

- **Launch.** `AccountStore.init`, right after `AppCopies.claimLaunch`, applies the file to UserDefaults. Stored values beat
  what a copy held. A key the file lacks is adopted from what `persistentDomain(forName:)` says was explicitly set in either
  copy's domain (read-only), marked `imported` and timed by that plist's date; defaults never count.
- **Changes.** `UserDefaults.didChangeNotification` is compared against the last values seen. A difference is stamped and
  written after 300 ms, or at quit. Values the mirror applied match, so they don't come back as changes.
- **Conflicts.** Per key, a real change beats an imported value, then the newest `at` wins, then `by`, so every Mac settles
  alike. A local change always stamps past the entry it replaces, and an `at` over a day ahead doesn't count.
- **Sync.** With Sync on, each Mac writes only the shared keys to `iCloud Drive/Side A/preferences/<machine-id>.json` and reads
  everyone's, off the main thread, at launch, on FSEvents and after each usage report. iCloud never holds one file two Macs write.
- **Other versions.** It's a separate file because an older `Configuration` drops fields it doesn't know. Unknown fields and keys
  survive here. A corrupt file is rebuilt from set values; a higher `version` is neither applied nor overwritten. A change made
  by a build older than this file is overwritten at the next launch of a newer one.
- **Side effects.** Keys whose effective value changed wait in `sharedPreferencesPendingEffects` until the first tick with
  Python, when the bridge has reported the hooks and Remote its phones, then run `AccountStore.applyPreferences` once: the
  island toggle's hook rule (`islandChange`), keep-awake's `setEnabled`, the notification permission and `startNotifications`.
  Other settings, sounds included, are read when used.

The demo has no mirror. Remove Side A deletes `preferences.json` and this Mac's iCloud file.

## Codex provider

`codex_bridge.py` prepares a separate `CODEX_HOME` per profile and delegates sign-in to
`codex login`, with file credential storage. The Mac's own Codex login stays in `~/.codex`; Side A
reads its id_token only to name the account. Limits come from the app-server's
`account/rateLimits/read`, and windows are labeled by duration. Codex accounts are read and
primed, never switched: OpenAI revokes a login whose refresh token is used twice.

Official references:

- [App-server protocol and account API](https://learn.chatgpt.com/docs/app-server)
- [Authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)

### Codex in pool mode

Codex takes no base URL from the environment under a ChatGPT login, so a pooled `codex` runs with `CODEX_HOME=runtime/codex-pool`: the user's `~/.codex` by symlink, their config plus a `sidea` model provider, and no `auth.json`. It sends the pool key from `SIDE_A_POOL_KEY`. The proxy swaps in the chosen account's access token and `chatgpt-account-id` and forwards `/codex/*` to `chatgpt.com/backend-api`. Tokens come from `codex-pool-token`, which reads the account's own `auth.json` and has Codex renew it with `account/read`, so Side A never writes a Codex login. Inside a pooled session, features that need a local login (Codex cloud, connectors) aren't available, and settings Codex saves to its config last until `~/.codex/config.toml` next changes.
