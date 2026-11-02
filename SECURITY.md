# Security and privacy

Side A never copies a login. It writes logins in two cases: a renewal, when a Claude login's
short-lived access token has expired, and a trade, when Autopilot moves running sessions off an
account near its limit. A trade the account doesn't need yet waits until its sessions have been
quiet for five minutes, because the move costs them their prompt cache.

- **How a trade stays safe.** Two Claude logins swap Keychain items: the full account's login
  goes to the item of an account no session is using, and that account's login goes to the item
  your sessions read, which they pick up within about 30 seconds. Both logins' Claude Code refresh
  locks are held and both owners are verified first. A journal of the trade (the Keychain item
  "Side A swap journal") is saved before any write; if a write fails or Side A stops midway, the
  next run finishes the trade from it, always forward. Each refresh token stays in exactly one item, so none is ever spent twice. MCP logins stay
  with their item. A Fable-share trade swaps two logins that both have running sessions, under the
  same locks and checks. Because a half-finished trade there would leave both sessions on one login,
  Side A first rewrites both items as they are (a Keychain that refuses writes stops the trade
  before anything moves), retries for about 20 seconds, and if the trade still can't finish, puts
  both logins back and drops the journal. If even that fails, Side A leaves both refresh locks in
  place, so neither session refreshes the shared login until the locks go stale a minute later,
  and finishes the trade from the journal on its next run.

- **When a session undoes a trade.** A session that kept the login a trade moved away can renew
  it and save it back into its item, over the login the trade moved in. That account then has no
  login and would ask you to sign in. For an hour after each trade, Side A keeps the two logins it
  moved in a Keychain item named "Side A trade watch …", used only for this, and follows them as
  they renew. If one account turns up in both items, and the copy the session saved is newer than
  the one the trade left, Side A puts the overwritten login back into the item it came from,
  undoing the trade, and tells you. It never replaces a copy that was renewed since the trade,
  and waits while a session runs on that item or a sign-in writes it. The copy is deleted at
  Side A's first check after the hour, or by the next trade of either item.

- **When a login is overwritten.** A `/login` typed in a session, or a session saving an old
  login back, replaces whatever its Keychain item held. On every check and before every sign-in
  Side A looks up who owns each item and points each account at the item holding its login, so
  no two accounts share one and an account with none gets an empty item to sign in to. It keeps
  each account's newest login in a Keychain item named "Side A login backup …", never used to
  sign in and never renewed, and puts it back only when no item (nor a trade's saved copy) holds
  that login any more, so it is never a second live copy. A signed-out account is left signed
  out; signing out, removing an account and uninstalling delete its backup. A spare copy of a
  login another item holds, which no running session reads, is deleted, since the first refresh
  of either copy would end the other.

- **Pool mode (off by default).** Side A listens on `127.0.0.1` only, and accepts a request only
  with the random 256-bit key it keeps in `runtime/pool-key` (readable only by you), which the
  shell line passes as `ANTHROPIC_AUTH_TOKEN` only to `claude` commands (the Anthropic SDKs read
  the same variables, so other commands never get it), and never over a base URL or token you set
  yourself. It answers only Claude Code (by its user agent) and forwards only `/v1/` routes, to
  `api.anthropic.com` and nowhere else, with the access token of the account it picked, read from
  that account's item through the bridge and renewed there under Claude Code's lock; tokens stay
  in memory and are never written elsewhere or logged. Claude Code's prompt-cache breakpoints are
  sent hour-long, as Claude Code itself sends them for a subscriber.

- **Sharing the pool with your other Macs (off by default).** Side A then also listens on this
  Mac's Tailscale address only, behind a second random key (`runtime/pool-share-key`, replaced
  with New Key), and serves a connection only when `tailscale whois` says the peer is signed in to
  Tailscale as the same user as this Mac, so a shared node or someone else on the tailnet is
  refused. That check runs when a connection opens, before anything is read, and its answer is kept
  for a minute at most. A caller without the key can send 64 KiB; every request has two minutes to
  arrive. A Mac signed in with a tag has no user to compare (every tagged node shares one identity),
  so sharing is refused there. Tailscale encrypts the traffic. Logins never leave this Mac; another Mac that ran
  `sidea pool join` keeps only the URL and key, in a file readable only by you. Anthropic does not support routing a subscription
  through a proxy, and the setting says so.

- **How renewal stays safe.** It takes Claude Code's own refresh lock for that login, re-reads
  the stored login inside the lock (if a session renewed it first, that one is used), sends the
  same request to the same endpoint with Claude Code's client id, and saves the result the way
  Claude Code does. Only the Claude login is replaced; MCP logins in the same item are kept. A
  refresh token is never spent twice.
- **Live limits.** Side A wraps the Claude Code statusline command. The wrapper saves the
  statusline input (limits, model, working folder, context and cost) to `~/Library/Application Support/SideA/runtime/live`,
  one file per account and one per session,
  readable only by you, then runs your own command with the same input. No login passes through it.

- **Logins stay in their CLI's Keychain items.** Claude logins live in Claude Code's default
  item and Side A's profile items; a trade can move one to another of these items. Codex logins stay in
  `~/.codex` or the account's profile.
- **What it reads:** each account's access token, to call the usage and profile endpoints
  the CLIs use, and the Codex id_token, to name the account. Every read checks that the
  token belongs to that account and refuses one it cannot verify. The Setup tab reads
  `~/.claude.json`, `.mcp.json` in folders you ran sessions in, `~/.codex/config.toml`, hook
  settings, skills and agents, read-only; MCP env and header values are dropped in the bridge
  (only their names are shown), as are arguments: URLs leave as `scheme://host[:port]`, and server,
  hook and statusLine commands as the program's name (plus the script an interpreter runs). **Check connections**
  runs `claude mcp list` from your home folder, which starts each configured server once.
- **What it writes:** its own folder in `~/Library/Application Support/SideA`, plus these
  changes to files you own (the live-limits statusline is on by default; the rest are opt-in).
  Each is marked, sits beside your own entries, can be turned
  off in Settings, and is removed cleanly by turning it off or by **Remove Side A**:

  | Setting | File | Change |
  | --- | --- | --- |
  | Switch in Terminal | `~/.zshrc` | One line marked `# side-a shell integration` |
  | Host terminal sessions | `~/.zshrc` | A second line marked `# side-a host terminal sessions`: `claude` and `codex` functions that start interactive runs in Side A's tmux server |
  | Live limits from Claude Code | `~/.claude/settings.json` | `statusLine` wrapped; your own command is kept and restored exactly |
  | React the moment a limit hits | `~/.claude/settings.json` | A `StopFailure` hook marked `side-a-limit` |
  | Dynamic Island (Claude Code) | `~/.claude/settings.json` | `PermissionRequest`, `Stop`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` and `PostModelSwitch` hooks marked `side-a-island` |
  | Codex permission requests | `~/.codex/hooks.json` (or `$CODEX_HOME`) | `PermissionRequest` and `Stop` hooks marked `side-a-island` |

- **Hosted sessions.** Sessions Side A resumes or forks run in its own tmux server (`tmux -L
  sidea`, socket `/private/tmp/tmux-<uid>/sidea`, config `runtime/tmux.conf`; your own tmux and
  `~/.tmux.conf` are untouched) and the terminal tab attaches to them. The tmux is the build
  signed with the app at `Contents/Helpers/tmux`; development builds fall back to Homebrew's
  tmux 3.4 or later. The server starts with a fixed environment, so variables of the tab that
  started it never reach other sessions. Each session's launch file and first prompt live in
  `runtime/hosted/<name>/` (0700; the prompt is deleted as the session reads it, the last screen
  is kept as `last.txt` for 7 days). Text typed into a session goes through tmux's stdin, never
  its command line, with control characters removed. Side A presses Enter again only while the
  prompt still holds exactly the text it pasted, and never types over a draft. A session started
  with a worktree gets `<repo>/.sidea-worktrees/<name>` on a new local branch `sidea/<name>`
  (no upstream), one `/.sidea-worktrees/` line in the repository's `.git/info/exclude`, and copies
  of the checkout's gitignored `.env*` files (listed in `runtime/hosted/<name>/copied.txt`). When
  the session ends, copies still identical to their source are deleted, then the worktree and
  branch are removed only if git and Cleanup's checks allow it; nothing is forced. Hosted Codex
  sessions start with `check_for_update_on_startup=false`, so no update prompt waits unseen.
- **Clean up (on request only).** Archiving moves conversations older than the chosen age from
  `~/.claude/projects` and `~/.codex/sessions` into `archive/` in Side A's folder, keeping their
  relative paths; nothing is deleted, pinned and running sessions stay, and **Restore archived** moves
  them back. Removing a worktree runs `git worktree remove` without `--force`, so git refuses one
  with changes or untracked files. Side A also refuses, checked again at removal, one any process
  has as its working folder, one whose HEAD is on no branch, tag or remote, and one with ignored
  files other than build output (`node_modules`, `.build`, `dist` and the like). Listing worktrees
  runs read-only git commands in the repositories your sessions ran in, and `lsof` for working folders.
- **Quitting sessions and servers (on request only).** Quit Session and Quit Idle send the
  session's process a quit signal (SIGTERM), which also stops what it started; Stop Server
  signals only the process listening on that port. Each asks first. Right before signalling, Side A
  lists again and checks it is the same process (pid and start time), that a session is still idle
  and a server still belongs to that session; it never signals pid 0, launchd or itself. Memory and
  ports come from `ps` and `lsof`, read-only. Running Codex sessions are found the same way (one
  `lsof` names each one's open rollout), and `tmux -L sidea list-panes` says which run under Side A's
  own tmux server.
- **Images stay in the transcripts.** The session index records where each image's base64 sits in
  a transcript (offset, length, SHA-1, size), never the bytes, and the bridge never prints them. An
  image Codex keeps in its own file is read only if it starts with an image signature.
- **Tokens are never logged, printed or uploaded.** The identity cache stores a hash prefix of
  each token, never the token. Side A saves a renewed login to the Keychain through `security`'s
  standard input, so it stays out of process lists. A login too long for that goes to `security`
  as a command-line argument, which is what Claude Code itself does, and for that moment it is
  visible to other processes running as you.
- **Dynamic Island hooks.** The hooks run a small stdlib script with Python in isolated mode (`-I -S`), so nothing
  from the session's folder is imported. It talks to Side A over a Unix socket at
  `~/Library/Application Support/SideA/runtime/island.sock` (mode 0600); Side A accepts a
  connection only from a process of the same macOS user (peer uid check). The hook sends the
  request (tool, command or diff, folder, session id) and gets back allow, deny, an "always"
  rule, or "ask in the terminal". If Side A is closed or anything fails, the hook exits quietly
  and the CLI asks in the terminal as usual. No login passes through it.
- **Destructive requests need a click.** Commands such as `rm -rf`, force pushes, `git reset
  --hard`, disk writes, database drops, reads or edits of credentials, and writes to what runs by
  itself later (shell startup files, launch agents, git hooks, agent settings) are flagged. Neither
  a shortcut nor Always approves them. Always adds the rule Claude Code itself suggests; Codex never
  receives rules. This guard is advisory: it reads commands word by word as a shell would, but a
  program can do anything once it runs, so it catches mistakes and obvious tricks and is no sandbox.
  A command it can't read rates higher, never lower. Bidi, zero-width and control characters are
  shown as `⟦U+202E⟧` and rate at least Unlock, as do many blank lines or spaces; what runs is unchanged.
- **Notes and stops.** Sending a note or a stop to a working session writes
  `runtime/mail/<pid>.json` (folder mode 0700). The `PreToolUse`, `PostToolUse` and `PostToolUseFailure` hooks check for
  that file with one shell test per tool call and start Python only when it exists. A note is
  added to the session's context after its next tool call; a stop ends the turn before the next
  tool runs. Mail for sessions that ended is deleted.
- **Reply** wakes a finished Claude Code session through its `Stop` hook (`asyncRewake`): the
  hook waits in the background for up to an hour and hands your text to Claude Code as the
  session's next instruction. Nothing is typed into your terminal.
- **Opening terminal tabs.** Go and Show terminal use Apple Events to bring forward the tab in
  Terminal, iTerm or Ghostty (macOS asks once). For Warp, Side A reads Warp's own session
  database read-only and, with Accessibility permission you grant, raises the window and picks
  the tab with Warp's ⌘1–9 shortcuts.
- **Starting a 5-hour window** runs the CLI with one short Haiku message; the CLI refreshes
  its own login if it needs to.
- **Network.** Side A calls the Anthropic and OpenAI endpoints the CLIs use (usage, profile,
  login renewal), the signed update feed, and every five minutes the public
  `status.claude.com/api/v2/summary.json`, to tell you when an incident affects Claude Code or
  the API, and once a day LiteLLM's public price list on GitHub
  (`raw.githubusercontent.com/BerriAI/litellm/…/model_prices_and_context_window.json`) for
  "Worth at API prices". Neither request carries account data.
- **Sync with your other Macs** also writes `preferences/<machine id>.json` to the Side A folder in your iCloud Drive: island,
  keep-awake, sound, banner, player and resume-terminal settings, with when each was set and the hashed id of the Mac that set
  it. Logins, Remote settings, pairing, lid-closed keep-awake and session names never go there. Files from other Macs are
  treated as untrusted: a broken one is skipped, and a value is applied only for a listed setting of the right type and range.
  A setting that arrives can install or remove the island's hooks, as its toggle would. Lid-closed keep-awake and Remote always
  need approval on each Mac.
- **Analytics** are off unless you opt in, and never include account data.
- **Updates** are Ed25519-signed (Sparkle), and installers are Developer ID signed and
  Apple notarized.

## Keep awake

**Keep awake while agents work** (Settings > General, off by default) needs no privileges. While
a Claude Code session is busy in its registry (`~/.claude/sessions`, read-only), or its status is
`shell` (the turn ended but a background Bash job still runs), or a Codex rollout in the last 14
dated folders of `~/.codex/sessions` (read by modification time only) was written in the last 90
seconds, Side A holds one `PreventUserIdleSystemSleep` power assertion named like "Side A: 3
agents working" (`pmset -g assertions` lists it), and releases it two minutes after the last one
stops, or when you quit. A busy session counts as stuck, not working, once neither its transcript
nor its subagents' transcripts have changed for three hours.

**Also with the lid closed** needs root, because macOS sleeps a closed MacBook regardless of
assertions. Side A asks for no password and writes nothing to `/etc` or `/Library`. It registers
a small helper that ships inside the signed app through Apple's `SMAppService.daemon`, and you
approve it once in System Settings > General > Login Items, where it stays listed under Side A
and can be switched off at any time. Its launchd job,
`Side A.app/Contents/Library/LaunchDaemons/com.sidea.keepawake.plist`, is exactly:

```xml
<key>Label</key>                       <string>com.sidea.keepawake</string>
<key>BundleProgram</key>               <string>Contents/MacOS/SideAKeepAwake</string>
<key>MachServices</key>                <dict><key>com.sidea.keepawake</key><true/></dict>
<key>AssociatedBundleIdentifiers</key> <array><string>com.arnenoori.sidea</string></array>
<key>RunAtLoad</key>                   <true/>
<key>KeepAlive</key>                   <dict><key>PathState</key><dict><key>/private/var/db/com.sidea.keepawake</key><true/></dict></dict>
```

The helper (`SideAKeepAwake`, identifier `com.sidea.keepawake`, signed with Side A's Developer ID
team and the hardened runtime) runs as root and answers one XPC call, `setLidSleepDisabled(Bool)`.
Through `NSXPCListener.setConnectionCodeSigningRequirement` it accepts only callers that satisfy
`anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "<its own team>" and (identifier
"com.arnenoori.sidea" or identifier "com.arnenoori.sidea.dev")`. An ad-hoc or unsigned build has
no team, so its helper accepts no one. Side A, in turn, only talks to a helper with that
identifier from its own team. The helper runs nothing but `/usr/bin/pmset -g`, to read the
current setting, and `/usr/bin/pmset -a disablesleep 1` or `0`.

It never leaves sleep off without a running Side A asking for it:

- It turns sleep off only while a connected Side A asks, and gives it back when Side A asks,
  quits or turns the option off.
- If Side A's connection drops without giving sleep back (a crash, a force quit, or an update's
  relaunch), the helper waits 30 seconds for a new Side A to ask, then restores sleep.
- Before it turns sleep off, it records that the setting is its own in
  `/private/var/db/com.sidea.keepawake` (an empty root-owned file), and removes the file once sleep
  is back. When it starts (at every boot, through `RunAtLoad`) and finds that file, it restores
  sleep first. On `SIGTERM` (unregistering, shutdown) it restores sleep before it exits.
- If you turned sleep off yourself (`pmset -a disablesleep 1`), it leaves your setting alone.
- With nothing to do, it exits after 10 seconds; launchd starts it again when Side A asks. While
  that file exists, launchd keeps it running, so a helper that crashes while it owns sleep comes
  straight back and restores it.

Side A asks only while agents work (and for the same two-minute grace), on power unless **Also
on battery** is on, and never below 20% battery. When sleep comes back while the lid is closed and
no external display is in use, Side A also releases its assertion and, if the lid is still closed
30 seconds later, runs `/usr/bin/pmset sleepnow` (no privileges needed), so a closed MacBook in a
bag doesn't stay awake until it is opened again.

Turning **Also with the lid closed** off, or **Remove Side A**, gives sleep back and unregisters
the helper (`SMAppService.unregister`). Deleting the app removes it too, and so does switching it
off in Login Items. The demo (`--demo`) holds no assertion, registers nothing and runs no `pmset`.

## Side A Remote

**Remote** (Settings > Remote, off by default) lets paired iPhones see sessions, answer requests,
reply and watch hosted sessions. Turning it on makes Side A listen on one port (47800; 47900 for
development builds) on the Mac's Tailscale address, plus the Wi-Fi address if you turn on Wi-Fi
(off by default, since Tailscale and the tunnel already reach the Mac), and opens the relay tunnel
below. A plain socket on that address hands each connection to a TLS 1.3 listener bound
to `127.0.0.1`; REST and WebSockets share it. The TLS key is a self-signed P-256 identity in your
Keychain. The pairing QR code carries the SHA-256 of its public key, and the phone refuses any
connection that presents another key, so nothing else on the network can stand in for the Mac.

- **Pairing** needs the Pair iPhone sheet open. It shows a one-time code (five minutes, single
  use, renewed at most six times while the sheet stays open). Both the phone and the Mac then
  show a six-digit comparison code computed from that code, both sides' nonces and keys, and
  the TLS key the phone saw. You approve that exact attempt on the Mac. If a second device uses
  the same code, both attempts are voided. A code must name the Mac's id, and the phone stops if the Mac that answers has
  another id, so a link can't quietly take over a paired Mac's token, keys and pin. A code with a different key from a paired
  Mac's, or a paired Mac's name on a different id, gets a warning and Pair Anyway. Agent text and terminals can't open pairing
  links, in either form. App Review's demo link asks first when a Mac is paired, since it disconnects them.
- **The relay tunnel** (Reach this Mac from anywhere, on by default while Remote is on; turn it off
  in Settings > Remote) keeps a connection open from the Mac to `push.getsidea.com`, which carries
  phones' connections to the Mac. The TLS above runs through it end to end, under the same pinned
  key, so the relay sees neither tokens nor content. It does see your install id, device ids, both
  ends' IP addresses, and when and how much data moved. It can refuse or drop connections. A stolen
  relay credential gets a TLS stream to the Mac and nothing else. Failed-attempt limits count all
  tunnel streams as one source, so opening new streams earns no new tries.
- **Tokens.** A paired phone gets a random token once. The Mac keeps only its SHA-256, in a
  Keychain item (`AfterFirstUnlockThisDeviceOnly`), never in a file. Revoking a phone closes its
  sockets at once. Unauthenticated requests are limited to a burst of 5, then 10 a minute, with a
  one-minute lockout; each phone is limited too.
- **A stolen token can read.** A stolen device token can read transcripts, images and search without
  a signature, until the phone is revoked. `Remove Device` on the Mac is how.
- **A token alone can't run anything.** The calls below that run or change something also need a signature from a key in the phone's Secure
  Enclave: the unlock key (usable while the phone is unlocked) or the confirm key (Face ID or Touch
  ID). The Mac checks every signature against the exact call, within two minutes, once. "Once" is kept in
  memory: a header captured in the last two minutes could be sent again right after the Mac app relaunches. See the table
  under "What each call needs". A phone too old to sign is told to update (426).
- **What a phone can do** is what the Mac's island can do, within those rules. Photos from the phone are re-encoded
  without metadata (location included), stored at mode 0600 under
  `runtime/uploads/` and deleted after 7 days. Hosted sessions start only in folders your
  recent sessions used. A phone's terminal view is its own tmux client, and it can never resize
  the window by itself. Replies with an idempotency key are recorded in
  `remote/idempotency.sqlite`, so a retry never runs twice. A first prompt starting with `-` is
  refused, and prompts follow `--` on the agent's command line, so a prompt is never read as a flag.
  Model and effort must be one plain word.
- **Answering by itself.** With Autopilot's answers on, a question whose every part has an option
  marked recommended is answered after a minute. The agent writes that mark itself, so plans are
  never approved this way, and the answer tells the agent you haven't seen the question.
- **The log.** `remote.log` is readable only by you, holds one line per event, and shows a paired
  device's name with its control characters escaped.
- **Previews.** Previewing a session's dev server makes Side A forward requests to that one port on
  `127.0.0.1`, through its own pinned listener, never Tailscale Serve. Each preview has a random
  credential in its URL, which becomes a `Secure; HttpOnly; SameSite=Strict` cookie. The
  credential opens only that port, never Remote's API. Requests from other sites' pages are
  refused. A preview ends after 30 minutes, when the session stops listening, when the phone
  closes it, or when the phone is revoked.
- **The relay tunnel** is on by default wherever the Mac has a relay. When LAN and Tailscale don't
  reach the Mac, the phone connects through the same Worker, and what crosses is the phone's pinned
  TLS to the Mac, so the relay can't read it. Each direction is rate-limited, and each install has a
  daily allowance.
- **Notifications** go through Side A's push relay (`push.getsidea.com`, a Cloudflare Worker that
  holds the APNs key):
  - Each request is signed with an Ed25519 key kept in your Keychain.
  - Each notification is sealed for one phone with ChaCha20-Poly1305, under a key the phone and
    the Mac derived at pairing (X25519 and HKDF). The relay never sees that key.
  - The relay sees push tokens, timing, the kind of notification, a collapse id and ciphertext.
    Collapse ids are request and turn ids, except that health and limit notifications use session
    and account ids. A short id is sent as it is, so the relay can read those.
  - Live Activity updates carry only counts, times and a random request id, because iOS shows
    them without decrypting anything.
  - The relay accepts a phone's token only after that phone proves it receives pushes there. Apple
    offers no such proof for Live Activity tokens, so each one stays with the first proven phone to
    use it, and sends from any other phone's registration are refused.
  - For the tunnel, the relay sees the install id, device ids, each phone's secret hash, when and how
    much crosses, and at Cloudflare's edge both ends' IP addresses.
  - A push that didn't come from the Mac can still show its own words on the Lock Screen, since iOS runs the Service
    Extension only when the push asks. It can't be acted on: buttons work only when the notification's title, subtitle, body
    and category are exactly what the phone derives from the sealed payload it opened, and the long-press card shows only that
    payload. The signature names the request, not its words, so this check is on the phone.
- **On the phone.** The app lock sits in its own window above every sheet, and a locked app signs and answers nothing; a
  notification's answer relies on iOS's own unlock instead. The app switcher sees a cover, not a transcript. Requests show
  bidi, zero-width and control characters as visible escapes, whatever the Mac sent, and one with any loses its swipe and Lock
  Screen Allow.
- **Remove Side A** deletes the paired phones, the TLS key, the relay key, the idempotency
  records and the Mac's registration at the relay.
- **Rotation from the phone.** Every route below needs a paired device's token, and a removed device's token and keys stop working at once.
  `GET /v1/usage/outlook` needs the token alone: it reads the same usage the account list does, summed, with no email, token or session in it.
  `POST /v1/accounts/{id}/priority`, `POST /v1/accounts/{id}/auto`, `POST /v1/rotation/swap-at` and `POST /v1/rotation/follow-fable` also need a signature from the
  phone's Face ID key. The signature covers this Mac, this device, the purpose `rotation`, the exact change and the time. It lasts two minutes and works once, and
  the phone's other key isn't accepted. A token alone changes nothing. Each is written to `autopilot.log`, without any session's words. `POST /v1/rotation/pool` is
  always refused: Pool mode changes only on the Mac, because it decides where every `claude` command in Terminal sends its token.
  Rotation pushes hold account names and a limit's numbers, sealed per device, so the relay sees only the category `ROTATION` and a fixed collapse id. `runtime/rotation.json`, readable only by you, holds account names, folder names and session ids, no titles or prompts.
- **The demo** (`--demo`) keeps Remote's keys and phones in memory and uses no relay unless
  `SIDEA_RELAY_URL` names one.

### What each call needs

The Mac enforces this. "Unlock" means a signature by the unlock key or the confirm key; "Face ID"
means the confirm key only.

| Call | Needs |
| --- | --- |
| Deny a request, or hand it back to the terminal | Token |
| Allow a read inside a project of prose, a picture or source, outside hidden folders and not named for settings or secrets; a Glob, or a Grep that doesn't show matching lines, there | Token, so it can be answered from the Lock Screen |
| Allow any other read, any edit, patch or new file, a Grep showing lines, any command, MCP tool, web fetch, unknown tool, or a request with hidden characters or padding | Unlock |
| Allow anything flagged destructive; trust a folder; move the Mac's login; turn Autopilot or its answers on or off; open a terminal | Face ID |
| Allow while switching mode, or Always | Unlock; Face ID if it enters a permissive mode |
| Change a session's settings | Unlock; Face ID if it enters a permissive mode (`bypassPermissions`, `auto`, `dontAsk`, or any mode Side A doesn't know) |
| Reply, restart or continue | Unlock; Face ID if the session is permissive or Side A can't read its mode |
| Reply starting with `!` | Face ID |
| Keystrokes (`keys`) | Face ID, always |
| Start a session | Unlock; Face ID for a permissive mode or a prompt starting with `!` |
| Quit, quit idle, end a hosted session, stop a server, open a preview, compact, review, Mac settings, archive, restore, remove a worktree, move now, rekey push | Unlock |

These need only the token, and why:

- **Reads** (sessions, transcripts, images, search, usage, setup, diagnostics): a phone's Lock Screen
  widgets and background refresh read them. A stolen token exposes all of it until you revoke the
  phone with `Remove Device`.
- **Uploads:** a photo runs nothing until a signed reply or start refers to it. Each phone holds at
  most 500 MB until its photos expire after 7 days, then gets a clear refusal.
- **Interrupt and delete a queued note:** they only stop or withdraw, and must work at once.
- **Pin, rename or archive a past conversation, draft a handoff:** bookkeeping that can be undone. A
  draft runs nothing until a signed restart uses it.
- **Close a preview, push diagnostics, check for an update, remove this device:** each changes only
  the phone's own link, and runs nothing.
- **Register push:** the phone sends this on every connection, including background refresh on a locked
  phone, where its unlock key can't sign. So a stolen token can silence that phone's notifications or
  change what it wants to hear about, until you revoke it. It runs nothing and reads nothing.

Report a vulnerability privately through GitHub's security advisories on
[arnenoori/side-a-source](https://github.com/arnenoori/side-a-source/security/advisories/new).

Pool mode also carries Codex when Codex accounts are included. Side A then reads each account's Codex access token (never its refresh token) from that account's own `auth.json`, sends it only to `chatgpt.com`, and leaves renewing to Codex. The pool-only `CODEX_HOME` holds no login.
