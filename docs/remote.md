# Side A Remote (plan)

A native iOS companion for Side A: see, answer and start Claude Code and Codex sessions on the
always-on Mac from a phone, whichever account each session is running under.

Status: built and shipping (Side A 0.5.44). Written as the plan in October 2026; where this differs from the code, the code wins. The specs under
[`remote/`](remote/) fill this in: [protocol](remote/protocol.md) (every wire shape; it wins over
this file), [mac-server](remote/mac-server.md), [bridge](remote/bridge.md),
[hosting](remote/hosting.md), [ios-app](remote/ios-app.md),
[relay-and-release](remote/relay-and-release.md) and [setup](remote/setup.md).

## Why

Claude Code Remote Control and Codex in the ChatGPT app both go through the vendor's relay and
register each session to the account that is logged in. Side A trades logins under running
sessions all day, so those sessions vanish from the phone the moment Autopilot moves them. Side A
already sees every session on the Mac, which account it runs on, and every permission prompt
through its hooks. Remote puts that on the phone.

## What it does

- **Sessions.** Every live Claude Code and Codex session across all accounts, "Needs you" pinned
  on top, then by project. Each row: title, project · account · current step, status glyph.
- **Transcript.** Streaming markdown, tool calls as quiet one-line rows that expand, runs of steps
  folded under an elapsed time, native diffs, and the images the agent looked at (Read results,
  MCP and browser screenshots, pasted images, Codex screenshots) with zoom, Copy, Save and Share.
- **Answer.** Allow, Deny, Always allow; questions one at a time; plan approval with or without
  accept edits. From the app, from actionable notifications, and from the Dynamic Island. From a
  locked phone only the safe ones (reads of plain files and searches inside the project); edits,
  commands, MCP tools and anything that widens permissions need the phone unlocked; destructive requests need
  Face ID in the app.
- **Talk.** Reply, follow up on a finished session, add a note to a working one, interrupt,
  attach a photo, `/model` and `/effort`.
- **Start.** New session from the phone: project, Claude or Codex, model, worktree, account,
  first prompt. It runs in tmux, so it can be attached from the Mac terminal or the phone.
- **Terminal.** A native terminal (SwiftTerm) attached to any hosted session, with predictive
  echo so typing feels instant.
- **Accounts.** Each account's 5-hour and weekly limits as rings, reset times, the one in use.
- **Glanceable.** One Live Activity for the whole Mac, Lock Screen and Home Screen widgets.

## Only in Side A

Other remotes show a chat. Side A already knows things about every session on the Mac that no
one else does, and Remote should carry all of it:

- **History.** Search every Claude Code and Codex conversation (asks, replies, commands), pins,
  renames, archive, branches under the conversation they forked from. Open any old session and
  **Resume** or **Fork** it, hosted, straight from the phone.
- **Health.** The flags from Running: no progress for 10 minutes, the same step 3 times, 4 failed
  steps in a row, a 150k-token idle context. Shown on the row and as a push when it starts.
- **Restart fresh.** For a session that is stuck, looping or heavily compacted: Side A writes a
  handoff (goal, branch, what failed, next steps, last messages), ends the session and starts a
  new hosted one in the same folder with that handoff as its first prompt. This is the
  reboot-sessions workflow as one button, with the handoff shown for editing before it runs.
- **Steer without typing.** Send a Note (read after the current step), Stop Before Its Next Step,
  Take Back. Works on every session, hosted or not.
- **Ports and servers.** Each session's listening ports and memory. **Preview** a dev server on
  the phone, proxied through Side A's own pinned listener (never a Tailscale Serve path, which
  would expose it to the whole tailnet); Stop Server; Quit Session; Quit Idle; the memory-pressure
  warning.
- **Accounts.** Limits, resets, which account each session runs on, Autopilot's moves with the
  reason for each, Move Now, worth at API prices, Claude incidents.
- **The Mac itself.** Keep awake while agents work, cleanup (stale worktrees, old dev servers),
  and whether the Mac is on power.

Most of these are existing bridge commands or `SessionStore` actions, so they become endpoints,
not new features. Each one's endpoint, capability and milestone is in protocol's
[Only in Side A endpoints](remote/protocol.md#only-in-side-a-endpoints).

## Architecture

```
iPhone (SwiftUI) ──WireGuard (Tailscale)──▶ https://100.x.y.z:47800  (REST + WebSocket, one port)
                 ──Wi-Fi (LAN mode, M4)───▶ https://192.168.x.y:47800 (same key, same code)
                                       │  TLS terminated by Side A, self-signed key pinned by the phone
                                       ▼
                              SideA.app ── RemoteServer
                               ├─ Island         (pending requests, Stop waiters, queue)
                               ├─ SessionStore   (live sessions, mail, accounts per session)
                               ├─ AccountStore   (limits)
                               ├─ SessionBridge  ──▶ sessions.py (transcripts, images)
                               ├─ HostedSessions ──▶ tmux -L sidea (launch, attach, keys)
                               └─ Push           ──▶ APNs (alerts, Live Activity)
```

### Server inside SideA.app

Pending requests, Stop-hook waiters, the follow-up queue, usage and live sessions are all held in
memory on the main actor, so the server lives in the app (`Sources/SideA/Remote/`), not in a
helper or the Python bridge. `NWListener` bound to the Mac's Tailscale address (and optionally its
LAN address), TLS 1.3 with Side A's own identity, a small HTTP/1.1 handler, and a hand-rolled
WebSocket upgrade on the same connection, routed by path. The app is a login item and already
keeps the Mac awake while agents work; clients reconnect after a relaunch and resume from a
sequence number.

### Transport and pairing

- **Side A terminates TLS itself; Tailscale is only the network.** One port (47800) serves REST
  and both WebSockets. The listener presents a self-signed P-256 identity kept in Side A's
  Keychain, and the phone pins its public-key hash from pairing in a `URLSession` server-trust
  delegate. No Tailscale Serve, no `ts.net` certificate, no MagicDNS or HTTPS-certificate
  requirement. A process that grabs the port after Side A quits can't present the pinned key, so
  the phone never hands it a token. LAN mode is the same listener on another address with the
  same key.
- **Device tokens are the real auth.** Anything on the tailnet or the LAN can reach the port.
  Every call carries `Authorization: Bearer sa1_…`; the Mac keeps only token hashes, in its
  Keychain (never under `runtime/`), and lists paired devices with Revoke.
- **What Remote defends and what it can't.** It can't defend against a same-user agent with full
  filesystem access: that agent could already replace Side A's hook and approve itself. It
  defends against other tailnet and LAN devices, browsers and DNS rebinding, a replacement
  listener, a lost phone that was never paired (or was revoked), and an agent that reads the
  screen during pairing. Details in [mac-server](remote/mac-server.md#threat-model).
- **Pairing:** Settings > Remote shows a QR code (a `sidea-remote://pair#…` link with the address, the key hash,
  the Mac's name and an 8-character one-time code). The phone posts the code; both devices then
  show the same six-digit comparison code derived from the key exchange, and the Mac's
  confirmation names that exact attempt. Only after Pair does the phone get its token. The phone
  keeps the token in a shared keychain group readable after first unlock, so the notification
  actions the Lock Screen allows work on a locked phone. Schema in
  [protocol](remote/protocol.md#pairing-hello-capabilities); journey and copy in
  [setup](remote/setup.md).

### API

A new package, `Packages/SideAProtocol` (macOS 14, iOS 17, no Sparkle), holds Codable wire types
shared by both apps. `IslandAction`, `IslandQuestion`, `IslandRisk` and the usage models move there
and `SideACore` re-exports them. `Pending` and `IslandRequest` get wire versions; `Pending.id`
becomes the stable request id.

The endpoints, events, errors and terminal framing are [protocol](remote/protocol.md)'s, which
replaced the table that stood here. In outline: REST under `/v1` (hello, pairing, state, sessions,
transcripts with opaque revision-aware cursors, requests and answers, replies by a single
state-dependent delivery table, uploads that return ids, hosted sessions, accounts, search,
options, and the Only in Side A endpoints); `/v1/ws/events` with sequence replay or a snapshot;
`/v1/ws/term/{name}` with numbered, acked input. Every mutation carries an idempotency key whose
record survives a relaunch; an action whose outcome a crash made uncertain is never retried
automatically. Transcripts follow Paseo's model: the stream is for speed, the paged fetch is the
truth.

### Transcripts and images (bridge changes)

`read_messages` in `bridge/sessions.py` skips every `toolUseResult` line before parsing, keeps
only text blocks (so pasted images become `[Image #1]`), and cuts text at 6,000 characters. For
Remote:

- Add an `after` cursor to `show`, and a way to fetch one message in full.
- Keep Edit and Write results: `structuredPatch` already has hunks with line numbers for a
  native diff. Codex file changes come as `item_completed` `FileChange` items with a unified diff
  per file.
- Index images in the same pass. Claude: `{type:"image", source:{type:"base64"}}` blocks in tool
  results (Read, MCP screenshots) and in user messages (pasted). Read results carry the same
  bytes twice; skip `api-request-blob` lines. Codex: `input_image` data URLs in `*_call_output`,
  and `ImageView` / `local_image` items that point at files. Spot images with a byte check before
  parsing. Store `(session, message uuid, tool, line offset, length, block index, type, size,
  sha1)` in an `images` table, never the base64. Serve by seeking to the line; thumbnails (640 px
  JPEG) cached once under `runtime/thumbs/<sha1>.jpg`. The sha1 also drops the duplicates.

The transcript is the only copy of most of these images; nothing is written to disk elsewhere.

### Push

- **APNs through a relay.** A Cloudflare Worker holds the `.p8` key and forwards opaque payloads;
  the Mac encrypts each payload per phone with a key exchanged at pairing and the Notification
  Service Extension decrypts it. The Mac authenticates to the relay with a per-install key, the
  relay rate-limits per install, and a phone's push token only receives sends after the phone
  answers a challenge pushed to it.
- **Categories:** `REQUEST`, `REQUEST_DESTRUCTIVE`, `QUESTION`, `PLAN`, `FINISHED`, `LIMIT`,
  `HEALTH`, `TEST`. Which actions run from a locked phone follows the request's gate, an explicit
  allowlist the Mac computes (reads of plain files and searches inside the project); risk heuristics only
  label. A question or plan too large for the payload opens the app instead of showing part of
  it. Shapes in [protocol](remote/protocol.md#push-payloads), actions in
  [ios-app](remote/ios-app.md#51-categories-and-actions).
- Actions post the answer with the request id, so a retry is safe. `apns-collapse-id` = request id,
  so a prompt answered on the Mac turns into "Answered on Mac".
- No push while the app is open on that session, as Paseo does.
- **Live Activity:** one for the Mac, started by push when the first session starts working,
  updated whenever anything it shows changes, replaced before iOS's 8-hour limit. Its push
  payload holds counts, times and an opaque request id only (`working`, `waiting`, `topRequest`,
  `soonestReset`, `tightestPercent`, attributes `{macID}` as a hash); every word on it comes from
  the phone's decrypted local cache.

Neither Happy nor Paseo has actionable notifications; approving from the Lock Screen is ours.

### Hosted sessions (tmux)

- Own server and config: `tmux -L sidea -f runtime/tmux.conf` with `escape-time 0`,
  `history-limit 50000`, `status off`, true colour. The user's own tmux is untouched.
- Names `sa-<project>-<4hex>`; metadata in tmux user options (`@sidea_agent`, `@sidea_cwd`,
  `@sidea_worktree`), so tmux is the source of truth across app restarts.
- **Launch:** `new-session -d -s NAME -c CWD -e SIDE_A_HOSTED=NAME 'zsh -l'`, then type the
  command. The login shell runs Side A's `.zshrc` line, so account trades keep working exactly as
  in a terminal tab. Worktrees under `<repo>/.sidea-worktrees/<name>` on branch `sidea/<name>`.
- `sidea attach <name>` from the `.zshrc` line; "Show on Mac" opens a terminal tab running it.
- Codex accounts launch through `codex_bridge.invocation` (the account's own home, the shared
  conversation index), exactly as Side A launches them today.
- Live sessions are matched to panes by process ancestry, so hosted sessions show up in the same
  list with a terminal badge.
- **Input:** text goes in as a bracketed paste through a named buffer, then Enter separately about
  60 ms later; single characters as keys (a pasted "3" doesn't pick an option). Port Codeman's
  check that presses Enter again when the prompt is still sitting in the composer, made strict:
  only when the composer shows exactly what Side A pasted and nothing else touched it.
- Structured requests stay on hooks, which fire the same inside tmux. tmux adds replying at any
  time, interrupting with Esc, and a longer hold for Codex requests from hosted sessions (nobody
  is at that terminal).
- **Terminal view:** each phone viewer gets its own tmux client in a PTY the app owns; bytes go
  out in WebSocket binary frames, coalesced for about 4 ms. Port Codeman's predictive echo to
  SwiftTerm: guess glyphs on the prompt row only, confirm against the parsed screen, drop wrong
  guesses after a second mismatch or one second. Port its numbered, acked input so nothing is lost
  on a dropped socket; after a Side A restart, unacked keys are discarded with a notice, never
  replayed. The Mac wins window size while it is active.

### Codex

- **Live tracking:** find `codex` processes, map each to the rollout it has open under
  `CODEX_HOME/sessions`, tail it for turn start, completion and approvals. New `live_codex` in
  `sessions.py`, merged into `live`.
- Approvals keep using the Codex `PermissionRequest` hook (it needs one-time `/hooks` trust;
  onboarding should say so).
- Hosted in tmux like Claude, so replies, interrupt and the terminal work the same way.

### Side A changes first

- Remote needs its own switch: hooks installed and Stop waiters kept while a device is paired,
  even with the notch or its Finished panel off. Today `Island.finished` releases every waiter
  when Finished is off.
- `live` should report each session's account; the slot is in the process environment
  (`CLAUDE_SECURESTORAGE_CONFIG_DIR`), which `WarpFocus` already reads through `KERN_PROCARGS2`.

## Design

System first, glass only for what floats, content on plain backgrounds.

- **Structure:** NavigationStack with large titles; floating Liquid Glass tab bar: Sessions,
  Accounts, Search. Inset grouped lists. No custom chrome.
- **Type:** SF Pro for the interface; SF Mono for commands, paths, the step line and numbers;
  `.monospacedDigit()` on every percentage and countdown.
- **Colour:** one amber accent for "needs you", green for done, red for destructive. Claude and
  Codex differ by a small glyph, not colour.
- **Motion:** steps unfold with a spring, new rows fade in; Reduce Motion gives plain fades.
  Haptics: warning when a request arrives in the foreground, success on Allow, rigid on Deny,
  selection between questions, nothing while text streams.
- **Side A identity, lightly:** the app icon, a spinning disc in the Dynamic Island while
  something works, and the LCD-style monospaced readout for the tightest limit. No 3D player.
- Side A's rules carry over: one fact per line, real numbers only (a stale reading says how old
  it is), nothing destructive is ever an "Always", rows don't move under a finger.

References (Mobbin):

| Screen | From |
|---|---|
| Sessions | ChatGPT Codex (Mac with a green dot, projects as folders, "Awaiting approval"), Linear status glyphs and grouping sheet, Perplexity's mono metadata line |
| Transcript | v0's one-line tool rows, Copilot's grouped steps with elapsed time, Claude iOS composer with a model pill and limit banner, Codex's "18 previous messages" fold, Perplexity's full-screen code sheet |
| Questions | Claude iOS question card ("2 of 2", numbered options, write your own) |
| Approval | Medium-detent sheet: command in mono, project and account, Allow / Deny, Always allow only when not destructive |
| New session | Linear new issue: prompt field, chips above the keyboard for Project, Agent, Model, Worktree, Account; recent projects as suggestions |
| Terminal | Blink and Prompt (not on Mobbin): full bleed, SF Mono 13, glass key bar (esc, ctrl, tab, arrows, ⌃C), "Back to chat" pill |
| Accounts | Fitness rings, two per account (5-hour inside, weekly outside); Jomo-style widgets |

Live Activity: compact shows the disc and the working count, or a dot when something needs you;
expanded shows the waiting request with Allow and Deny as App Intent buttons; Lock Screen shows
"3 working · 1 needs you" and the tightest limit as a thin bar.

## What we take from others

| From | Take | Leave |
|---|---|---|
| Codeman (MIT) | predictive echo and buffer-until-Enter; acked input; paste-buffer submit sequence and the Enter re-press; one tmux socket, `remain-on-exit`, resize rules; Codex dialog regex as an alert-only signal; QR pairing | its web UI, Web Push, approving by typing `1`/Esc, Basic auth |
| Paseo (Apache-2.0) | stream plus paged authoritative timeline with gap repair; 60 ms delta merging and paced text reveal; normalized tool-call details; images pulled out of tool results; idempotent session creation; skipping push while the app is watching | its relay and UI |
| Happy (MIT) | the event envelope shape (text, tool start/end, file, turn start/end, subagent); its Swift `SyncEngine` and outbox; MIME sniffing for photos from iOS; permission choices; kill-and-resume "take over from phone" as an option | its server, end-to-end crypto (WireGuard covers us), UIKit views |

Ported code keeps its copyright and licence notice (Paseo: also mark changed files). The app gets
an Acknowledgements screen. None of their names or branding.

## Layout

```
Packages/SideAProtocol/        SideAProtocol (shared wire types), SideARemoteKit (iOS client)
apps/ios/project.yml           XcodeGen spec; the generated .xcodeproj is gitignored
apps/ios/SideARemote/          the app
apps/ios/NotificationService/
apps/ios/NotificationContent/  question options in the notification
apps/ios/Widgets/              Live Activity and widgets
scripts/ios-testflight.sh      archive and upload with an App Store Connect key
```

The root `Package.swift` depends on `Packages/SideAProtocol`. The iOS app adds SwiftTerm. Bundle
id `com.arnenoori.sidea.remote`; an App Group and keychain group shared with the extensions.

## Milestones

| | Ships |
|---|---|
| **M0 · Look** | Protocol package, RemoteServer with pinned TLS, pairing with the comparison code, setup checklist and Test Connection, sessions with accounts, transcripts (polling), accounts. The SwiftUI shell at full design quality. Internal TestFlight. |
| **M1 · Answer** | Remote switch, events WebSocket, answer / reply / note / interrupt, questions and plans, streaming transcripts, images and diffs (bridge changes). |
| **M2 · Notify** | Push relay (Worker), encrypted payloads, categories, Content Extension, collapse on answer, Live Activity, widgets. |
| **M3 · Start** | tmux hosting for everything Side A opens, project picker, worktrees, terminal view with predictive echo, photo uploads, Continue on phone, History and Search, Restart Fresh, ports with Preview, Quit, the Mac's state. |
| **M4 · Codex and offline** | Codex live tracking, Host terminal sessions wrappers, LAN mode, a log of remote approvals, Autopilot, worth, incidents, Clean Up, App Store release and the site's download section. |

## Decisions

1. **Shippable, not personal.** Remote is a public download next to Side A (App Store, linked from
   the site; TestFlight first). So push goes through a relay from day one: a Cloudflare Worker
   holds the APNs key, the Mac sends it payloads encrypted with a key exchanged at pairing, and the
   Notification Service Extension decrypts them. The relay sees device tokens, ciphertext and
   Live Activity counts only. Session traffic never touches it; that stays Mac ↔ phone over
   Tailscale, on Side A's own pinned TLS.
2. **Claude Code and Codex only.** No adapter layer for other agents.
3. **One model for both agents: hosted in tmux.** Codex runs in tmux like Claude. Its status comes
   from tailing its rollout file (structured events, not screen scraping) and its approvals from
   the `PermissionRequest` hook. The app-server mode is dropped: it would give Codex a second,
   unattachable kind of session for little gain.
4. **Every session should be hosted; takeover is the exception.**
   - Everything Side A opens (New session, Resume, Fork, from the phone or the Mac) starts inside
     `tmux -L sidea` and the Mac terminal tab simply attaches to it.
   - An opt-in setting, **Host terminal sessions**, adds `claude` and `codex` wrappers to Side A's
     `.zshrc` line: run in an interactive terminal outside tmux, they start the session hosted and
     attach the current tab. Typing `claude` in Warp looks the same, but the phone gets full input.
   - Sessions that aren't hosted keep everything the hooks give (approve, questions, plans,
     follow-up when finished, note, stop) plus a read-only transcript.
   - For those, **Continue on phone** is an explicit action, offered only while the session is
     idle or waiting: Side A ends it and resumes the same session id in tmux. It is never automatic,
     because it closes the Mac tab, drops any turn in progress, and loses the prompt cache (the
     same cost Autopilot already avoids).
   - No keystroke injection into other terminals: TIOCSTI is off on macOS, and Warp and Ghostty
     have no input API.
5. **Window size:** the Mac wins while it has typed in the last minute; otherwise the phone's
   size applies, and the Mac redraws when it types again.

## Open questions

1. **tmux inside Warp.** Warp's blocks and scrollback behave differently inside tmux. Check how
   hosted sessions feel in Warp, Ghostty and Terminal before Host terminal sessions is offered.
2. **Tailscale as a requirement for a public app.** Fine for the first release; LAN mode (same
   pinned TLS) is the fallback. A relayed transport is a later question, if users without
   Tailscale ask.

## Risks

- Claude Code's session registry and hook behaviour are undocumented and change between versions.
- Notification actions fail when the phone's Tailscale is off or the Mac is asleep (turning Remote
  on offers to turn on Keep awake).
- Remote is only as safe as the hook channel it sits on: a same-user agent with full filesystem
  access can approve itself through the hooks without Remote.
- A pasted image path becoming an attachment in the Claude and Codex TUIs is untested; the
  fallback is a path in the text for the agent to Read.
- Recent Claude Code ignores Enter for 30 to 50 seconds after the composer first appears
  (Codeman's notes), so the Enter re-press check is needed from the start.

## Changes from review

A Codex review of the specs (October 2026) found 29 problems; the coordinator decided the fixes
and the lanes' results were folded back in. What changed, per document:

- **remote.md.** Pinned TLS terminated by Side A on one port replaces Tailscale Serve (architecture,
  transport); the threat model is narrowed to what Remote can defend; pairing gains the six-digit
  comparison code; Lock Screen approval follows an explicit allowlist; the Live Activity carries
  counts only; the API table now points at protocol; milestones gain the Only in Side A work and
  setup; Preview no longer uses a Serve path.
- **protocol.md** (canonical for every wire shape). Transport, URLs and a "what this defends
  against" list; one pairing and hello schema (`PairRequest` with X25519 key, device id and secret
  hash, `PairPending`, the wait call, `PairResponse` with `RelayInfo`, QR format v2, `replaces`,
  `Hello.endpoints` and `keyID`, the comparison code, `sa1_` tokens, the 8-character code); one
  answer schema with its refusal table and one state-dependent delivery table (auto, followUp,
  note, keys × working, idle, finished × hosted or not); `FinishedSession.turnID` required on
  follow-ups (`turn_changed`); `AllowGate` (`lockScreen`, `unlock`, `biometric`; missing is unlock,
  unknown is biometric; the phone reads `allowGate`); persisted idempotency with `outcome_unknown`
  and no automatic retry of ambiguous executions; revision-aware opaque cursors in pages, deltas
  and subscriptions, with `replaced`, `reset` and `agentID` on `TranscriptPage`; the global `seq`
  moves only through contiguous events or a full snapshot; row, event and snapshot size bounds;
  the one terminal framing, with discarded input and a notice after an epoch change; push payloads
  (envelope key `e`, per-device `sealed`, categories and loc-keys including `HEALTH` and `TEST`,
  `full: false` fallback, the counts-only Live Activity schema, the token verification push); the
  outbox and widget snapshot in a cross-process SQLite store honouring `retryable`; endpoint
  contracts and capabilities for every Only in Side A feature, `GET /v1/options`,
  `GET /v1/setup`, the diagnostics push and `NotificationPrefs` in push registration; transcript
  additions (`thinking` role, `durationMS`, `agentID`, `todos`, `plan`, `group`, `parent`,
  `ImageRef.seq`); `{"type","data"}` framing for every union and sorted arrays for sets.
- **mac-server.md.** One TLS listener per Tailscale (and LAN) address with a hand-rolled WebSocket
  upgrade on the same connection, routed by path; listeners run while Remote is on, paired or not;
  Tailscale is read-only (no Serve set-up, teardown, MagicDNS or HTTPS checks); the threat model
  states what is out of scope and what is defended; pairing with attempts, the comparison code,
  Codes Don't Match and code renewal; protocol's error envelope and answer schema everywhere;
  `IdempotencyStore`; Make New Key; event recording and the live loop run whenever Remote is
  active, not only with a client connected; turning Remote on offers Keep awake; the Codex trust
  signal; tests and live checks to match.
- **bridge.md.** The remote format is a DTO adapted in Swift; tools squeezed under 96 KiB and runs
  split every 8; opaque cursors with `replaced` semantics; `unknown` instead of `idle` when the
  Codex tail has no turn evidence; every Codex home indexed, deduplicated by realpath; thinking
  rows; open questions 1, 6 and 7 settled.
- **hosting.md.** The resume guard uses a complete live index (idle included) serialized with the
  launch in `HostedSessions`; Codex accounts launch through `codex_bridge.invocation`; the
  SubmitVerifier presses Enter only on an exact match, cancels on any other input and raises
  `unsent` on ambiguity; the terminal wire format is protocol's, and input after a restart is
  discarded with a notice; uploads return `Upload` and image paths are pasted single-quoted; live
  checks on Claude Code 2.1.302, Codex 0.156.1, tmux 3.7c, Warp 2026.09.16 and Terminal 488 settle
  the composer glyphs, dim placeholders, ready marks, trust dialogs, prompt arguments and Esc lag
  (open questions 1 to 3 and half of 4 closed).
- **ios-app.md.** Pinned TLS on every connection; `SyncEngine.updates: AsyncStream<RemoteState>`
  feeds the stores; backoff to 30 s; onboarding follows setup with the comparison code and the
  8-character code everywhere; notification categories, Live Activity buttons and intents follow
  `AllowGate` (`REQUEST_SAFE` set locally by the Service Extension; plan approval and Reply need
  unlock); the Live Activity shows counts on the wire and words from the local cache; the shared
  store is SQLite; composer modes, model lists and attachments come from protocol; 4.15's table
  moved to protocol; Preview proxies through Side A; settings send `NotificationPrefs`.
- **relay-and-release.md.** Token verification by a challenge push (`POST /device/verify`,
  `unverified` results) so a known APNs token can't be registered by another install; nonces,
  limiter windows and `last_send` persisted in a `state` row, with the cost table updated; the
  per-IP registration counter keyed by `RATE_KEY`, and its privacy line; the signed path is the
  pathname; per-device `sealed`; `HEALTH` and `TEST` categories; `GET /installs/self`; the APNs
  environment from the build configuration with `development` as an alias for `sandbox`; Live
  Activity updates on any displayed change, replacement before 8 hours, token turnover and
  dismissal; `soonestReset` as seconds since 2001 and `ACTIVITY_START_*` loc-keys; hello and
  pairing now point at protocol.
- **setup.md** (written alongside the review): consistency fixes only, the comparison code's
  derivation and the wait call, and the coordinator's decisions on its open questions.
