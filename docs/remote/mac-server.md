# Side A Remote: the Mac side

What changes inside SideA.app so the iOS companion can see and answer sessions. The product plan
and its decisions are in [remote](../remote.md); this is how the Mac half is built. Line numbers
refer to `main` at b6748e1 (0.5.36).

Scope: the server and its TLS, the island changes, accounts per session, pairing and auth,
Tailscale status, the LAN fallback, Settings > Remote, event fan-out, tests and live checks. Wire
types live in `Packages/SideAProtocol` and are defined in [protocol](protocol.md); this document
names them but doesn't define them. The setup journey and its copy are [setup](setup.md)'s.

## Overview

```
iPhone ──WireGuard (Tailscale)──▶ 100.x.y.z:47800 ─┐
iPhone ──Wi-Fi (LAN mode, M4)───▶ 192.168.x.y:47800 ┤  RemoteServer: one NWListener per address,
                                                    │  TLS 1.3 with Side A's pinned identity,
                                                    │  HTTP/1.1 (our parser) and WebSocket upgrade
                                                    │  on the same connection, routed by path
                         queue "com.arnenoori.sidea.remote"
                                  │  await MainActor.run { … } only for app state
                                  ▼
             RemoteController (@MainActor) ── Island · SessionStore · AccountStore
                                  ▲
             RemoteEvents (@MainActor) ── emits from Island, SessionStore, AccountStore
```

Tailscale is only the network: Side A doesn't configure `tailscale serve`, needs no MagicDNS or
HTTPS certificates on the tailnet, and the phone trusts Side A's own key, not a `ts.net`
certificate. Wire shapes, errors and URLs are [protocol](protocol.md)'s; this document names them
and doesn't restate them.

New files:

| File | Holds |
| --- | --- |
| `Sources/SideA/Remote/RemoteController.swift` | `@MainActor @Observable`. The Remote switch, pairing state, devices, Tailscale status; owns the server; answers routes that need app state |
| `Sources/SideA/Remote/RemoteServer.swift` | The listeners, TLS, connections, the queue, timeouts, limits |
| `Sources/SideA/Remote/TLSIdentity.swift` | The self-signed identity in the Keychain: create, load, SPKI hash, Make New Key |
| `Sources/SideA/Remote/HTTPConnection.swift` | One TLS connection: read, parse, route, write, keep-alive, WebSocket upgrade |
| `Sources/SideA/Remote/WebSocketConnection.swift` | RFC 6455 framing after the upgrade: masking, fragmentation, ping/pong, close codes |
| `Sources/SideA/Remote/EventHub.swift` | WebSocket clients, the ring buffer, replay and snapshots |
| `Sources/SideA/Remote/RemoteRoutes.swift` | The route table and handlers |
| `Sources/SideA/Remote/IdempotencyStore.swift` | Persisted idempotency records (protocol, Rules for every endpoint) |
| `Sources/SideA/Remote/RemoteEvents.swift` | `@MainActor` emitter: diffs live sessions, usage and the island into events |
| `Sources/SideA/Remote/DeviceStore.swift` | Device records and token hashes in the Keychain |
| `Sources/SideA/Remote/Pairing.swift` | Codes, the QR payload, attempts, the comparison code, the Mac-side confirmation |
| `Sources/SideA/Remote/TailscaleStatus+CLI.swift` | CLI discovery, `status --json`, the tailnet address, diagnostics |
| `Sources/SideA/Remote/Island+Remote.swift` | Answering, replying and queueing from the phone |
| `Sources/SideA/Remote/RemoteSettings.swift` | Settings > Remote |
| `Sources/SideACore/Remote/HTTP.swift` | Pure request parser and response encoder |
| `Sources/SideACore/Remote/WebSocketFrame.swift` | Pure RFC 6455 frame parser and encoder, the `Sec-WebSocket-Accept` key |
| `Sources/SideACore/Remote/RemotePolicy.swift` | Host and Origin checks, token buckets |
| `Sources/SideACore/Remote/EventRing.swift` | Sequence numbers, ring buffer, replay-or-snapshot decision |
| `Sources/SideACore/Remote/PairingCode.swift` | Code generation, expiry, attempts, token format and hashing, the comparison code |
| `Sources/SideACore/Remote/RemoteAnswer.swift` | Wire answer → `IslandAnswer`, with every refusal (protocol's RemoteAnswer table) |
| `Sources/SideACore/Remote/AllowGate.swift` | The lock-screen allowlist (protocol, `AllowGate`) |
| `Sources/SideACore/Remote/TailscaleStatus.swift` | Parses `tailscale status --json` |
| `Sources/SideACore/ProcessEnvironment.swift` | `KERN_PROCARGS2` read and parse (moved from `WarpFocus`), slot and Codex home rules |
| `Sources/SideACore/IslandHold.swift` | When a request goes back to the terminal |

Everything in `SideACore/Remote` is pure and unit-tested like `Island.swift` and the planner.

## RemoteServer

### Listeners

One port, TLS terminated by Side A, REST and WebSocket on the same connections:

```swift
let tls = NWProtocolTLS.Options()
sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)   // TLSIdentity
sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
let params = NWParameters(tls: tls, tcp: .init())
params.requiredLocalEndpoint = .hostPort(host: tailnetAddress, port: 47800)     // 100.x.y.z
params.allowLocalEndpointReuse = true          // rebinding right after a relaunch
```

- **Bound addresses.** One listener on the Mac's Tailscale IPv4 address (from `tailscale status
  --json`, `Self.TailscaleIPs`, cross-checked against the `utun` interface holding a
  `100.64.0.0/10` address), and its `fd7a:115c:a1e0::/48` IPv6 address when present. With LAN mode
  on (M4), one more on each LAN interface address. Never `0.0.0.0`, never loopback. Every listener
  uses the same identity, router, auth and limits; LAN mode is the same code with another address.
- **TLS identity.** `TLSIdentity`: a P-256 key and self-signed certificate, made once with
  `/usr/bin/openssl` (LibreSSL ships with macOS) into a temporary folder, imported as a PKCS#12
  identity into Side A's Keychain with the same protection as the device item (data protection
  keychain when available, else an ACL trusting only Side A's designated requirement), the files
  deleted. Valid 10 years. Its SPKI SHA-256 is the `fp` in the QR code and `Hello.keyID`'s source.
  **Make New Key** (Settings > Remote) replaces it and revokes every device, since their pins no
  longer match. A process that binds the port after Side A quits can't present this key, so a
  paired phone never sends it a token.
- **One connection type.** `HTTPConnection` parses HTTP/1.1 itself. A request for
  `/v1/ws/events` or `/v1/ws/term/{name}` with `Upgrade: websocket`, `Connection: Upgrade`,
  `Sec-WebSocket-Version: 13` and a key passes the same Host, Origin, rate-limit and token checks
  as REST, then gets `101 Switching Protocols` with `Sec-WebSocket-Accept` (SHA-1 of the key and
  the RFC 6455 GUID) and the connection becomes a `WebSocketConnection` (about 250 lines: client
  frames must be masked, fragments reassembled, messages capped at 1 MiB, ping answered with pong,
  close codes per protocol). The path picks the channel; there is no channel field in `hello`.
  `NWProtocolWebSocket` is not used: it can't share a port with plain HTTP and doesn't give the
  server the request path.

Release builds use 47800; "Side A Dev" (`AppCopies.isRelease == false`) uses 47900 so a dev build
and an installed copy never fight over a port. If the port stays busy for 10 seconds (the
previous copy still exiting), the next one up to +9 is tried; the chosen port is saved in
`UserDefaults` (`remotePort`) and goes into the QR code and `Hello.endpoints`.

The listeners run while Remote is on, paired or not, so `GET /v1/hello` can tell the phone
"Remote is on, click Pair iPhone" apart from "Side A is closed" (connection refused). With nothing
paired, every route but `hello` and an open pairing sheet's `/v1/pair` answers 401 or 404. If the
Tailscale address changes (re-login to another tailnet), the listener is rebuilt on the new one
and `Hello.endpoints` changes.

### Threading

- One serial queue, `com.arnenoori.sidea.remote`, for every listener, every connection, parsing,
  auth, rate limits, the ring buffer and writes. Like `IslandServer` (`IslandServer.swift:10`),
  `RemoteServer` is `final class … @unchecked Sendable` and touches its state only on that queue.
- Handlers are `@Sendable (Request, Device) async -> Response`. Those that read or change app
  state hop with `await MainActor.run { … }` and return `Sendable` wire values (SideAProtocol
  types), never `Pending` or `LiveSession` themselves. Encoding JSON happens back off the main
  actor.
- Transcript and image routes call a third `SessionBridge` (`remoteReader`, an actor), so a phone
  paging a long transcript never queues behind the Mac's Sessions window or its search.
- Events start on the main actor (`RemoteEvents`) and cross to the queue as `Sendable` values; the
  queue assigns sequence numbers. Order is preserved because the main actor enqueues in order and
  the queue is serial.
- The main actor is never blocked: no `queue.sync` from it except `start()`/`stop()`, as
  `IslandServer` does.

### HTTP/1.1 parser (`SideACore/Remote/HTTP.swift`)

A push parser: `mutating func feed(_ bytes: Data) -> [Result<Request, HTTPError>]`, keeping
leftover bytes for the next request.

| Limit | Value | On breach |
| --- | --- | --- |
| Request line | 8 KiB | 414 |
| Request line + headers | 16 KiB, 64 headers | 431 |
| Body | 1 MiB; `POST /v1/uploads` 20 MiB, streamed to a temp file (M3) | 413 |
| Header time | 10 s from the first byte | close |
| Idle keep-alive | 30 s | close |
| Requests per connection | 1,000 | `Connection: close` on the last |
| Connections | 64 open; the oldest idle one is closed first | 503 |

- Methods: GET, POST, DELETE. Others 405 with `Allow`.
- Bodies by `Content-Length` only. A request with `Transfer-Encoding` is refused with 411 and
  closed; URLSession sends a length for these bodies. Obsolete line folding,
  duplicate `Content-Length`, bare CR and non-ASCII header names are 400 and close.
- Responses always carry `Content-Length` and are written whole; no chunked encoding. Images are
  at most a few MB and served from memory or a file read.
- Keep-alive is the default; `Connection: close` is honoured. Pipelined requests are parsed but
  answered strictly in order: the next one starts only after the last response is written.
- `Expect: 100-continue` gets `100 Continue` once auth has passed, else the final error.
- Query strings are percent-decoded; paths are matched on decoded segments, and a segment of `..`
  or containing `/` after decoding is 400.

### Routing

`RemoteRoutes` is a static table of `(method, pattern, auth, handler)`; patterns are segment lists
with `{param}` placeholders. Unknown path 404, wrong method 405. Every error body is protocol's
envelope, `{"error": {"code", "message", "retryable", "details"}}`, with protocol's codes; nothing
in this document defines another shape.

Every request goes through the same steps, in this order, on the queue:

1. Host check (421), Origin check (403), see [DNS rebinding](#host-and-origin).
2. Rate limit (429 with `Retry-After`).
3. Auth: `Authorization: Bearer sa1_…` (the token is `"sa1_" + base64url(32 random bytes)`),
   except `GET /v1/hello` and the `/v1/pair` routes (401 `unauthorized` with
   `WWW-Authenticate: Bearer`).
4. Idempotency for mutations (`IdempotencyStore`, below).
5. Route and handler.

M0 routes: `hello`, `pair`, `pair/{attemptID}/wait`, `state`, `sessions`,
`sessions/{id}/transcript`, `sessions/{id}/messages/{seq}`, `accounts`, `setup`, `devices/self`.
M1 adds `requests`, `requests/{rid}/answer`, `sessions/{id}/reply`, `interrupt`, `mail`,
`options` and the events socket. The rest follow protocol's endpoint table and its milestones.

### Idempotency records (`IdempotencyStore`)

Protocol's rule, built on SQLite at `~/Library/Application Support/SideA/remote/idempotency.sqlite`
(folder 0700, file 0600, WAL), on the server queue:

- Table `records(device, key, method, path, body_hash, state, status, response, created)`,
  primary key `(device, key)`. Trimmed to 24 hours and 1,000 per device at launch and hourly.
- A mutating handler first inserts `started` and commits (with `synchronous=FULL` for this one
  write), then causes its effect (types into tmux, starts a session, answers the island, signals
  a pid), then updates the row to `done` with the encoded response. Handlers that only change
  Side A's own memory (answering an island request) still record, so a retry replays.
- A `started` row found from an earlier process is answered 409 `outcome_unknown` and never run
  again. Startup doesn't try to resolve them; the phone decides with the user.

### Lifecycle

| Moment | What happens |
| --- | --- |
| Launch | `SideAApp.swift:17`, after `store.island.start()`: `store.remote.start()`. Reads the switch, devices and identity; starts the listeners if Remote is on; re-checks Tailscale in the background |
| Sparkle relaunch | `SideAApp.swift:12`: `willRelaunch` also calls `store.remote.handOff()`, which sends `bye{reason: "update"}` and close code 1001 (protocol) to every WebSocket so the phone reconnects quietly with back-off instead of showing an error |
| Quit | Listeners are cancelled with the process. The phone's connect is refused and it says "Side A isn't running on <Mac>", not "offline". Nothing is left configured anywhere else |
| Relaunch | New `epoch` (random `UInt64` per launch). The phone's `hello{epoch, lastSeq}` with an old epoch gets a snapshot. Open requests didn't survive (their hooks saw the socket close and asked in the terminal), so the snapshot has none of them. Idempotency records did survive; any left `started` answer `outcome_unknown` |
| Sleep | `NSWorkspace.willSleepNotification`: nothing to do; connections may die |
| Wake | `didWakeNotification`: if a listener's state is `.failed` or `.cancelled`, restart it; refresh Tailscale status; WebSockets that didn't survive are reconnected by the phone |
| Network change | `NWPathMonitor`: if the Tailscale address appeared, vanished or changed, rebuild the listener on the new address; LAN listeners follow their interfaces |
| Remote off | Listeners stop; all WebSockets closed with 1000 |
| Last device revoked | Listeners keep running while Remote is on (`hello` answers); event recording stops |
| Remove Side A | `AccountStore.uninstall` (`AccountStore.swift:841`, next to `setIsland(nil, "off")` at 845): delete the Keychain device item, the TLS identity and the idempotency database; delete the relay install |

Demo mode (`--demo`) and `swift run` (no `.app`) never start Remote, as with hooks
(`AccountStore.swift:240`) and notifications (`AccountStore.swift:114`).

## Island changes

### The Remote switch

Today one setting, `Island.on` (`Island.swift:72`), means three things: hooks installed, the
notch shown, and Stop waiters kept (only with Finished on). Remote splits them:

```swift
// RemoteController
static var active: Bool { enabled && hasDevices }      // "remote" in UserDefaults, plus a device
// Island
static var notch: Bool { on }                          // Island.on keeps its meaning: the notch
static var keepsWaiters: Bool { on && setting(finishedKey) || RemoteController.active }
```

Edit points:

| Where | Today | Change |
| --- | --- | --- |
| `Island.swift:71` `visible` | `!pending.isEmpty \|\| event != nil \|\| !ready.isEmpty` | `Self.on && (…)`. With the notch off, requests that arrive for Remote never open the panel (`IslandView.swift:22` keys off `visible`) |
| `Island.swift:122-123` in `add` | always `Sounds.play(.nudge)` and `announce` | only when `Self.on`. `WaitingNotifier.deliver` (124) keeps its own setting |
| `Island.swift:402-413` `changed()` | registers ⌃⌥ keys whenever something is pending | `wanted = .none` when `!Self.on`; no global shortcuts for a notch that isn't shown |
| `Island.swift:251` in `finished` | `if Self.on { show(.track, …) }` | unchanged; also emits `finished.resolve(reason: .sentQueued)` |
| `Island.swift:256-259` in `finished` | `guard Self.on, Self.setting(Self.finishedKey) else { release; return }` | `guard Self.keepsWaiters else { release; return }`. Then always insert into `ready` (260-264). The chime, the `.finished` event and the announcement (265-276) run only when `Self.on && Self.setting(Self.finishedKey)` |
| `Island.swift:223` in `show` | `guard Self.on, …` | unchanged: `show` is only the notch's transient events. `RemoteEvents` doesn't depend on it; limits and trades reach the phone as `usage.update` |
| `SettingsView.swift:829-833` the Dynamic Island toggle | off runs `setIsland(nil, "off")` | off runs `setIsland(nil, "off")` only when `!RemoteController.active`; otherwise hooks stay and only the notch goes |
| `SettingsView.swift:838-845` hook toggles | shown only when `on` | also shown in Settings > Remote (same bindings), so Codex requests can be turned on without the notch |
| `WaitingNotifier.swift:21` | `guard Self.enabled \|\| Island.on, …` | `guard Self.enabled \|\| Island.on \|\| RemoteController.active, …`. Without it, nothing calls `island.sync`, and requests answered in the terminal would stay open on the phone |
| `SessionStore.swift:522-523` `send` | "Turn on the Dynamic Island in Settings…" | "Turn on the Dynamic Island or Remote in Settings to send notes to working sessions." |
| `RemoteController` on switch-off / last revoke | — | `setIsland(nil, "off")` only when `!Island.on` |
| `RemoteController` on first pairing | — | `setIsland(.claude, "on")` when Claude hooks aren't installed |

With Remote active and the notch off, `ready` also fills the Finished section of Sessions >
Running (`SessionStore.swift:45-48`). That's intended: the Mac shows the same list the phone does.

### Stable request ids

`Pending.id` (`Island.swift:10`) is already a `UUID` fixed for the request's life; it becomes the
wire `rid` (lowercase string). Ready rows use `Ready.id` (`Island.swift:31`) as `FinishedSession.turnID`. Ids don't
survive a relaunch, and don't need to: the hooks behind them don't either.

Island keeps the outcome of the last 256 resolved requests and finished rows, so a late answer gets
a precise 409 instead of a 404:

```swift
enum Resolution: Sendable { case mac, notification, remote(device: String), terminal, finished, handedBack, gone }
@ObservationIgnored private var resolved: [Pending.ID: (Resolution, kind: String, at: Date)] = [:]   // LRU, 256
```

`remove(_:)` (`Island.swift:213-220`) becomes `remove(_:by:)`, the one place a request leaves.
Callers and the reason each passes:

| Caller | Line | Resolution |
| --- | --- | --- |
| `answer` from the panel or shortcuts | 155 | `.mac` |
| `answer` from a Mac notification (`WaitingNotifier.swift:188`) | 155 | `.notification` |
| `answer` from the phone | 155 | `.remote(device)` |
| `handedBack` (hook's socket closed) | 138 | `.gone` |
| `sync` verdict `.answered` (answered in the terminal, or process gone) | 345 | `.terminal` |
| `finished` (the same session finished its turn) | 241 | `.finished` |
| Codex/headless hold elapsed | 129 | `.handedBack` |

To carry the reason, `answer(_:_:quietly:)` (141) gains `by: Resolution = .mac`, and the internal
calls at 129, 241 and 345 pass theirs. `remove` emits `request.resolve{rid, by}` through
`RemoteEvents`, after `pending` changes. `add` (115) emits `request.add{WireRequest}` after the
append.

### Answering from the phone (`Island+Remote.swift`)

```swift
enum RemoteOutcome: Sendable { case done(RequestResolution), conflict(RequestResolution), unknown, refused(reason: String) }
func remoteAnswer(_ rid: UUID, _ wire: RemoteAnswer, device: String) -> RemoteOutcome
```

The answer schema, its refusals and the response bodies are protocol's (RemoteAnswer table,
`RequestResolution`, the error envelope); this is where they're implemented.

1. `rid` in `pending`: translate with `RemoteAnswer.resolve(item.request, wire)` (pure, in
   SideACore), which implements protocol's RemoteAnswer table row for row, including the
   `AllowGate` check (`.biometric` needs `confirmDestructive: true`). A refusal is 422
   `invalid_answer` with its `details.reason`. Success is 200 with the `RequestResolution`.
2. Not pending but in `resolved`: 409 `already_resolved` with `details.by` and `details.answer`.
   A retried notification action never gets here twice: its `Idempotency-Key`
   (`<rid>:<kind>`) replays the first 200 from the persisted record with `Idempotent-Replay: true`.
3. Unknown: 404 `request_not_found`, which the phone treats like a 409 with no detail.

`RemoteAnswer.resolve` builds the `IslandAnswer` from the Mac's copy of the request; the phone
never sends rule JSON or tool input. `.always` looks up the suggestion by its id (first 16 hex of
SHA-256 of the rule JSON), not by index.

This closes two gaps the Mac paths don't have to worry about today: `answer` only blocks a
destructive Allow when `id == nil` (`Island.swift:149`), and only `always()` (168) checks risk, so
a caller passing an id could do both. `confirmDestructive` is set by the phone only after Face ID
in the app (never from a notification action); the Mac can't verify that and trusts the token.
`AllowGate` itself is computed here (`SideACore/Remote/AllowGate.swift`) from the request,
the session's cwd and git root, and `IslandRisk`; risk only ever raises a gate.

After a remote answer the panel drops the card as for any answer; with the notch on, the island
announces "Answered on <device>." instead of the usual tick (`Island.swift:156-164`).

Replies follow protocol's delivery table; the island parts are:

- `.followUp`: a new `remoteReply(session, turnID, text) -> RemoteOutcome` uses the waiter path of
  `reply` (`Island.swift:306-313`) only, after checking `turnID == ready.id` for that session
  (else 409 `turn_changed`). The Mac-only fallback (315-318: clipboard, bring the terminal
  forward) is never used from the phone; without a waiter the table's 409 `cannot_deliver`
  applies.
- `.queued`: `queue` (`Island.swift:322-326`), capped at 5 per session, delivered at 246-252,
  emitting `finished.resolve(reason: .sentQueued)`.
- `.note` and stop mail (`interrupt` `when: now` unhosted, and every `when: nextStep`) write mail
  through `SessionStore.send` (`SessionStore.swift:521`), with its new `throws`/result instead of
  setting `error`.
- `.typed` and `keys` go to `HostedSessions` (hosting, Input).

### Collapsing when answered in the terminal

Nothing new decides this: `Island.sync` (341-364) with `IslandSession.verdict` already drops a
Claude request once the registry says the session left `waiting`. Remote needs only:

- `WaitingNotifier` running while Remote is active (the guard above), so `sync` is called;
- `remove(…, by: .terminal)` emitting `request.resolve`, which the phone turns into "Answered in
  the terminal" and, from M2, a push with the request's `apns-collapse-id`;
- `resumed` (366-375) and `sync`'s dead-process sweep (351-357) emitting `finished.resolve`
  through the `ready` diff (see fan-out).

### Codex hold for hosted sessions

`Island.codexHold` (`Island.swift:47`) hands every Codex and headless request back after two
minutes (111), because Codex shows its own prompt only after the hook returns. A hosted session
(tmux, `SIDE_A_HOSTED` set) has nobody at its terminal, so handing back only hides it.

`SideACore/IslandHold.swift`:

```swift
public enum IslandHold {
    public static let terminal: TimeInterval = 120
    /// Under the hook's own 24 h timeout (sidea_bridge.py:1626), so Side A answers first.
    public static let hosted: TimeInterval = 86_400 - 120
    public static func handBack(agent: IslandAgent, headless: Bool, hosted: Bool) -> TimeInterval? {
        if headless { return terminal }
        if hosted { return agent == .codex ? Self.hosted : nil }
        return agent == .codex ? terminal : nil
    }
}
```

`Island.swift:111` becomes `handBackAt: IslandHold.handBack(…).map { Date().addingTimeInterval($0) }`.
`hosted` comes from a new hook field (below), else from the session's environment at receive time
(`ProcessEnvironment.read(pid:)["SIDE_A_HOSTED"]`; the hook's parent is alive while the hook runs).
The Codex toggle's copy (`SettingsView.swift:844`) adds: "Sessions Side A hosts wait for you
instead."

**Codex trust signal** (setup's Codex rows and `SetupStatus.codexHooks`): `Island` records
`lastCodexHookAt` whenever any Codex hook message arrives, persisted in `UserDefaults`, and resets
it when Side A rewrites the Codex hooks. "unconfirmed" means hooks installed but never heard from.

Hook change, `bridge/island_hook.py:172-176`: add `"hosted": os.environ.get("SIDE_A_HOSTED")` and,
for Codex, `"home": os.environ.get("CODEX_HOME")`. `IslandRequest.init?(message:)`
(`SideACore/Island.swift:72-88`) reads both. Bridge test: the hook forwards both fields.

## Accounts per session

The plan's "`live` should report each session's account" is done in Swift, not `sessions.py`, by
reusing `WarpFocus`'s environment reader.

**Move the reader** (`WarpFocus.swift:57-80`, and `started` at 142-149) to
`SideACore/ProcessEnvironment.swift`:

```swift
public enum ProcessEnvironment {
    public static func read(pid: pid_t) -> [String: String]?      // sysctl KERN_PROCARGS2
    public static func parse(_ procargs: Data) -> [String: String]  // today's WarpFocus.environment
    public static func started(pid: pid_t) -> Double?              // kinfo_proc p_starttime
    /// Claude Code's rule, as island_hook.py:23-28 and sidea_bridge.py:944-946 apply it.
    public static func claudeSlot(_ env: [String: String]) -> String
    public enum CodexHome: Equatable { case mac, profile(String), other(String) }
    public static func codexHome(_ env: [String: String], root: String, home: String) -> CodexHome
}
```

- `claudeSlot`: `CLAUDE_SECURESTORAGE_CONFIG_DIR`, else `CLAUDE_CONFIG_DIR`; empty or absent is
  `"mac"`; otherwise the last path component (a profile UUID).
- `codexHome`: unset, or `~/.codex` → `.mac`; `<root>/profiles/<uuid>` → `.profile(uuid)`;
  anything else → `.other(path)`.
- `WarpFocus.focusURL` keeps its body but calls `ProcessEnvironment.read`. The two tests in
  `Tests/SideATests/WarpFocusTests.swift:16-20` move to `SideACoreTests`.

**Map slot to account.** Claude slots trade logins, so a slot isn't an account. The owner of each
running slot is already known: `busyLogins` (`AccountStore.swift:770`, from `active`'s `busy`),
read through `accountName(inSlot:)` (234-236). Add `accountID(inSlot:)` next to it. Codex logins
are never traded, so `.profile(uuid)` is that account, and `.mac` is `activeIDs[.codex]`
(`AccountStore.swift:28`).

**Where it runs.** `SessionStore.live`'s `didSet` (`SessionStore.swift:24-42`) fills a cache
`[pid: (started, slot)]`, read once per `(pid, started)` (a pid reused by a later process has a
different start time). The account is looked up at emit time, not cached, because a trade changes
the owner without changing the environment. A process whose environment can't be read (exited,
or another user's) has `slot: nil, account: nil`; the phone shows no account rather than a guess.

**Island.** `Island.swift:108-109` names the account for Codex from `activeIDs[.codex]`, which is
wrong for sessions running under a Codex profile. It becomes: Claude by `request.slot` as today;
Codex by `request.home` (new hook field) through `codexHome`, falling back to the environment of
`request.pid`, then to `activeIDs[.codex]`.

## Pairing and auth

### Threat model

**Out of scope: a same-user agent with full filesystem access.** Anything running as the user can
already approve its own requests without Remote: the hook scripts Side A copies into `runtime/`
are user-writable (`sidea_bridge.py:1672`), the hook trusts whatever answers on the Unix socket
(`island_hook.py:61`, accepting its `allow` at 31), and the island server checks only the peer's
UID (`IslandServer.swift:89`). Remote can't be stronger than that channel, and doesn't claim to.
Closing it would need OS-enforced isolation of hook execution, configuration and server identity,
which is outside this spec.

**Defended:**

| Threat | How |
| --- | --- |
| Another device on the tailnet, or on the LAN in LAN mode | Every call needs a device token; tokens come only from a pairing approved on the Mac; the Mac keeps only their hashes, in the Keychain |
| A browser page (DNS rebinding, CSRF) | Host allowlist, any `Origin`/`Sec-Fetch-Site` refused, no CORS, bearer tokens never in cookies |
| A process that binds the port after Side A quits or crashes | It can't present the pinned TLS key, so the phone aborts before sending its token |
| A lost phone that was never paired, or was revoked | No token, or a token the Mac rejects; a paired lost phone is Revoked, and its Lock Screen can only approve `AllowGate.lockScreen` requests |
| An agent reading the screen during pairing (Screen Recording) | It can submit the code, but its attempt shows a different comparison code from the user's phone; two attempts on one code void it; the Mac click names the exact attempt |
| Someone on the network between phone and Mac during pairing | The phone pins `fp` from the QR code before sending anything; a substituted key fails that check and changes the comparison code |

What an in-scope attacker on the Mac can still do is limited by the Keychain: it can't read
Side A's Keychain items (device hashes, TLS key, push keys) without a prompt naming it, and can't
click in Side A without Accessibility.

### Pairing

Protocol's Pairing section is the schema and flow (`PairRequest`, `PairPending`, `PairResponse`,
the comparison code, QR format v2, the error codes); [setup](setup.md#pairing-sheet) has the
sheet's copy. The Mac side:

1. Settings > Remote > **Pair iPhone** opens a sheet and makes a code: 8 Crockford base32
   characters (40 bits), such as `K7Q2-9XMD`, valid five minutes, five tries, single use, renewed
   automatically up to six times while the sheet stays open. Only one code exists at a time;
   closing the sheet voids it. While no sheet is open, the `/v1/pair` routes are 404 `no_pairing`.
2. The sheet shows the QR code (v2: tailnet address and port, LAN address when on, `fp`, Mac name,
   Mac id, tailnet name, code) and no code or address to type: pairing is QR-only.
3. A right code creates one **attempt**: `attemptID`, a 16-byte `nonce`, a fresh X25519 key pair
   for this device, the phone's `DeviceInfo`, `devicePublicKey`, `deviceSecretHash`,
   `serverKeyHash` and optional `replaces`. A second right-code attempt while one is pending voids
   the code and both (409 `code_busy`). A wrong code counts a try; the fifth voids the code and
   the sheet says "Too many wrong codes. Start again."
4. The sheet names that attempt with its comparison code: **Pair “Arne’s iPhone”** · iPhone 17 Pro
   · "Check that your iPhone shows **482 913**." with **Codes Don't Match** and **Pair** (not the
   default button, no shortcut). If the attempt's `serverKeyHash` isn't the Mac's own key hash, the
   sheet doesn't offer Pair at all: "This iPhone saw a different security key. Pairing stopped."
   (403 `sas_mismatch`). The phone's `wait` call is held up to 60 seconds.
5. On Pair: the token is `"sa1_" + base64url(32 random bytes from SecRandomCopyBytes)`, sent once.
   The Mac stores `SHA-256(token)`, `deviceSecretHash` and the push key derived from its X25519
   private key (then discarded) with the device record, removes the `replaces` record if any, and
   answers 201 `PairResponse`. Codes Don't Match: 403 `sas_mismatch`. Cancel: 403 `declined`. No
   click in 60 s: 408 `confirm_timeout`.

A token carries 256 bits of entropy, so a plain SHA-256 is enough (no slow hash). Verification
hashes the presented token and compares against every record with a constant-time compare.

### Devices in the Keychain (`DeviceStore`)

- One generic password item: service `<bundle id>.remote` (so Side A Dev has its own), account
  `devices`, data = JSON `[{id, name, model, hash, secretHash, pushKey, keyID, created, lastSeen,
  push?}]`. Never a file under `runtime/`, which agents read and could write a hash into. The TLS
  identity is a second item with the same protection.
- Created with `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  when the signed app can use the data protection keychain, so other processes can't see it at
  all. Otherwise (open question 3) a login-keychain item whose ACL trusts only Side A's designated
  requirement; `security find-generic-password` from an agent then raises a prompt naming the
  tool. Sparkle updates keep the same designated requirement, so the ACL survives them.
- If the item exists but can't be read, Remote fails closed: no device is accepted and the tab
  says "Paired devices couldn't be read. Pair again." It is never replaced silently.
- `lastSeen` is kept in memory and written at most every 10 minutes, and on quit.
- **Revoke** removes the record, then closes that device's WebSockets (4401; each connection
  remembers its device id), drops its push token and deletes the device at the relay.

### Rate limits (`RemotePolicy.TokenBucket`)

Limits are by token, plus one global bucket for anything unauthenticated:

| Bucket | Allowance |
| --- | --- |
| Unauthenticated (hello, pair, failed auth) | 10 per minute, burst 5; then 429 for 60 s |
| Pairing tries | 5 per code (above) |
| Per device, all routes | 20 per second, burst 60 |
| Per device, answers and replies | 30 per minute |
| WebSocket connections per device | 4 |

### Host and Origin

`RemotePolicy.check(host:origin:fetchSite:)`, applied to REST and to the WebSocket upgrade:

- `Host` must be one of the Mac's own listening addresses with the port: the Tailscale IPv4 or
  IPv6 address, the MagicDNS name when there is one (from `status --json`), or in LAN mode the LAN
  address or `<name>.local`. Anything else is 421 `bad_host`. This defeats DNS rebinding: a page
  on `evil.example` resolving to the Mac's address still sends `Host: evil.example` (and couldn't
  pass the TLS pin anyway, since a browser has no pin to skip but also no token).
- Any `Origin` header, or `Sec-Fetch-Site`, is 403 `forbidden_origin`. The native app sends
  neither; browsers always send one on the requests that matter. No CORS headers are ever sent.
- Tailscale identity headers aren't involved: nothing proxies to Side A any more, and they were
  forgeable by local processes anyway.

## Tailscale

Side A only reads Tailscale's state; it changes nothing in tailscaled.

### Finding the CLI

Checked in order; the first that runs `version` wins and is remembered:

| Path | Install |
| --- | --- |
| `/Applications/Tailscale.app/Contents/MacOS/Tailscale` | App Store and standalone app; the app binary is the CLI when given arguments |
| `/usr/local/bin/tailscale` | Standalone app's "Install CLI" link |
| `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale` (Intel Homebrew) | Open-source `tailscaled` from Homebrew |
| `zsh -lc 'command -v tailscale'` | Anything else on the user's PATH |

Every call goes through `Process` with a 10-second timeout, arguments as an array (no shell),
stdout and stderr captured. Calls run off the main actor.

### Status

`tailscale status --json`, parsed by `TailscaleStatus` into one state, plus the tailnet address,
MagicDNS name (optional), tailnet name and iOS peers:

| State | From | Tab says |
| --- | --- | --- |
| `notInstalled` | no CLI | "Tailscale isn't installed on this Mac." [Get Tailscale ↗] |
| `stopped` | `BackendState` ≠ `Running` | "Tailscale is off." [Open Tailscale ↗] |
| `needsLogin` | `NeedsLogin` | "Sign in to Tailscale." [Open Tailscale ↗] |
| `noAddress` | running, `Self.TailscaleIPs` empty | "Tailscale hasn't given this Mac an address yet." |
| `ready(address, name?)` | otherwise | "This Mac is 100.101.12.4 on your tailnet" |

MagicDNS and HTTPS certificates are no longer checked or required. Peers (`Peer[*].OS`,
`HostName`, `Online`) feed the advice-only "iPhone on your tailnet" row; it never gates the
switch. Re-checked when the tab opens, every 30 s while it's open, on wake, and before showing a
QR code. The full checklist, its rows and copy are [setup](setup.md#the-mac-checklist).

### Diagnostics

The **Connection** section and **Test Connection** are specified in
[setup](setup.md#test-connection-mac). Mac-side data they use: CLI path and version, the state
above, the listener's bound addresses and port, the identity's key id, `socketfilterfw
--getglobalstate` and `--getappblocked <path>` (read-only), the relay's signed
`GET /v1/installs/self`, and the last 20 server errors. **Copy diagnostics** puts those on the
clipboard (no tokens, no hashes, no keys); the same lines go into `store.saveDiagnostics`
(`SideAApp.swift:32`).

## LAN fallback (M4)

For phones without Tailscale. Off by default, under an "Also on this network" switch.

- More listeners, one per LAN interface address, on the same port with the **same TLS identity,
  router, auth, Host checks and rate limits**: it is the same code bound to another address.
  Not advertised: phones get addresses from the QR code.
- The QR code adds `l=<LAN address:port>`; the phone pins the same `fp`, so the key is the same on
  both paths and a phone paired over Tailscale also trusts the LAN address.
- Pairing over LAN needs the same comparison code and Mac click.

## Settings > Remote

`SettingsView.swift:6` gains `case remote`; a tab between Setup and General
(`SettingsView.swift:22-25`):
`RemoteSettings(store: store).tabItem { Label("Remote", systemImage: "iphone") }.tag(SettingsTab.remote)`.
The 520×560 frame (28) stays. `docs/design.md` (Settings) gets a Remote bullet.

Copy follows [design](../design.md): one fact per line, no promotion, real states only. The
checklist above the switch, the pairing sheet's full copy and Test Connection are
[setup](setup.md)'s; this is the tab's frame.

```
┌ Remote ─────────────────────────────────────────────────────────┐
│ [●] Side A Remote                                                │
│     See and answer your sessions from your iPhone, over          │
│     Tailscale.                                                   │
│     Claude Code permission requests              [●]             │
│     Codex permission requests                    [ ]             │
│                                                                  │
│ iPhones                                                          │
│     Arne’s iPhone · iPhone 17 Pro                                │
│     Connected now                                  [Revoke]      │
│     Old iPhone · last seen 12 days ago             [Revoke]      │
│     [Pair iPhone…]                                               │
│                                                                  │
│ Connection                                                       │
│     ✓ Tailscale 1.90.2 · signed in as arne@…                     │
│     ✓ Listening on 100.101.12.4:47800                            │
│     ✓ Security key 3f9a1c2e…                                     │
│     ✓ Reachable · checked just now                               │
│     [Test Connection]  [Copy diagnostics]      [Make New Key…]   │
│ footer: Requests stay open in the terminal too. Whichever        │
│ answers first wins.                                              │
└──────────────────────────────────────────────────────────────────┘
```

States:

| State | Shows |
| --- | --- |
| Tailscale missing or not ready | The switch disabled, the one Connection line that needs fixing with its button; nothing else |
| Off, ready | The switch and "Listens on your tailnet at 100.101.12.4." under it. Turning it on asks once, in the same confirmation, whether to turn on Keep awake too (a sleeping Mac is the likeliest "it doesn't work") |
| On, nothing paired | iPhones: "No iPhone yet." and Pair iPhone |
| Pairing sheet | QR code, "Expires in 4:32" (`.monospacedDigit()`), the instruction from setup. Then "Pair “Arne’s iPhone”?", "Check that your iPhone shows 482 913." with Codes Don't Match and Pair (neither default); then "Paired." and the sheet closes when the phone connects |
| On, paired | The list. Revoke asks: "Revoke Arne’s iPhone? It disconnects now and has to pair again." |
| Notch off, Remote on | Under the switch: "Hooks stay installed for Remote while the Dynamic Island is off." |
| Make New Key… | Confirmation: "Make a new security key? Every iPhone has to pair again." Replaces the identity and revokes all devices |
| Error | One red footer line with the cause: "Port 47800 is in use by another app.", "Side A's security key couldn't be read.", "Paired devices couldn't be read. Pair again." |

VoiceOver: the QR image is labelled "Pairing code K, 7, Q, 2, 9, X, M, D, expires in 4 minutes";
the comparison code is read digit by digit. Every Revoke button names its device.

## Event fan-out

### Ring buffer (`EventRing`, pure)

```swift
public struct EventRing<Event> {
    public let epoch: UInt64
    public private(set) var seq: UInt64
    public init(epoch: UInt64, capacity: Int = 500)
    public mutating func append(_ make: (UInt64) -> Event) -> Event
    /// Events after `lastSeq`, or nil when the client must take a snapshot (other epoch, or a gap).
    public func replay(epoch: UInt64, after lastSeq: UInt64) -> [Event]?
}
```

The hub stores events already encoded (`Data`) with their sequence, so a replay to several phones
encodes once. `transcript.append` goes only to clients subscribed to that session and is kept out
of the ring (the paged fetch is the truth); the others go to every events client.

On `hello{epoch, lastSeq}`: replay if possible, else a `StateSnapshot` built in one
`MainActor.run` and stamped with the sequence at that moment (sent over REST instead when it's
over 512 KiB, per protocol), then live events from there. Subscriptions arrive separately as
`subscribe{sessions: {key: cursor}}`. A client whose outbound queue passes 1 MiB is closed with
4008; it reconnects and replays or snapshots.

### Sources

`RemoteEvents` (`@MainActor`) is owned by `RemoteController` and **records while Remote is enabled
and at least one device is paired** (`RemoteController.active`), whether or not any client is
connected or push is configured. Replay and push both depend on changes being recorded while the
phone is away, so presence never gates recording. Side A with Remote off, or with nothing paired,
pays nothing.

| Event | From | Hook point |
| --- | --- | --- |
| `request.add` / `request.resolve` | Island | `add` (`Island.swift:115-133`) and the new `remove(_:by:)` (213) |
| `finished.add` / `finished.resolve` | Island `ready` | a `didSet` on `ready` (`Island.swift:54`) diffing ids; it catches every site (260-264, 282, 296, 308, 354, 373) without touching each. Reasons come from a `lastReadyReason` the sites set before mutating, defaulting to `.gone` |
| `session.upsert` / `session.remove` | `SessionStore.live` | its `didSet` (`SessionStore.swift:24`): diff by `(pid, started)`; upsert when status, step, flag, title, account or `since` changed; memory and ports are left out so they don't fire every refresh |
| `usage.update` | `AccountStore.usage` (64), `readAt`, `activeIDs` (28), `issues` | `didSet`s calling `RemoteEvents.usageChanged()`, coalesced to one event per second |
| `transcript.append` / `.replace` | FSEvents on `.jsonl` | `SessionStore.filesChanged` (`SessionStore.swift:286-291`): for subscribed session ids, at most every 250 ms per session, the server calls `show --format remote --after <the subscription's cursor>` and sends `messages` as `transcript.append` and `replaced` as `transcript.replace`, each with the new cursor |
| `hosted.*` | M3 | — |

**Keeping the live list fresh.** Today the live loop runs only while Sessions is open
(`SessionsView.swift:9-10` → `SessionStore.appear`/`disappear`, `SessionStore.swift:250-284`),
every 20 s plus FSEvents. Split `appear` into `retainLive(_ owner: String)` and
`releaseLive(_ owner: String)` with a set of owners (`"window"`, `"remote"`): the watcher and loop
start with the first owner and stop with the last. `RemoteController` retains `"remote"` for as
long as `RemoteController.active` holds (Remote on and a device paired), including M0's REST-only
phones and the hours a phone is away with push configured, and releases only when Remote is
turned off or the last device is revoked. Registry changes already trigger `refreshLive` within
300 ms through `filesChanged`, so status changes reach the phone in about half a second. If the
loop ever stops while active (bridge crash), the ring is invalidated (new `epoch`), so every phone
takes a snapshot instead of trusting a replay with a hole in it.

## Tests

`swift test`, in the style of `IslandTests` and the planner tests: pure inputs, no sockets except
where stated.

**SideACoreTests**

- `RemoteHTTPTests`: a request split at every byte boundary parses the same; two pipelined
  requests come out in order with the leftover kept; `Transfer-Encoding` is 411; 16 KiB of headers
  is 431 and one byte less isn't; duplicate `Content-Length` and folded headers are 400; `..` in a
  decoded segment is 400; responses always carry `Content-Length`.
- `WebSocketFrameTests`: the RFC 6455 accept key for the RFC's sample key; unmasked client frames
  refused; fragments reassembled; a 1 MiB + 1 message refused with 1009; ping answered; close
  codes round-trip.
- `RemotePolicyTests`: Host allowlist (Tailscale IPv4 and IPv6 with port, MagicDNS name, `.local`
  in LAN mode, a rebinding name refused, loopback refused); any Origin refused; token buckets
  refill on a fake clock and lock out after the unauthenticated burst.
- `PairingCodeTests`: Crockford alphabet without I, L, O, U; expiry at five minutes; six renewals;
  the fifth wrong try voids the code; a second right-code attempt voids both; a used code fails;
  token format `sa1_` plus 43 characters; the comparison code matches protocol's
  `PairingTranscript` fixtures; verify by hash is constant-time over the list (no early exit) and
  rejects a near-miss.
- `EventRingTests`: replay after a known sequence; a sequence older than the buffer, a future one
  or another epoch returns nil; capacity is respected.
- `RemoteAnswerTests`: each row of protocol's RemoteAnswer table, including a `.biometric` Allow
  without confirm, Always on a destructive request, an unknown suggestion id, a question that
  isn't in the request, two labels on a single-select question, and that the input sent back is
  the request's, not the phone's.
- `AllowGateTests`: each row of protocol's gate table: a Read inside the project is
  `.lockScreen`, outside or of a secret path is `.unlock`/`.biometric`; an Edit of
  `~/.claude/settings.json` is `.biometric`; any Bash, MCP, fetch or unknown kind is `.unlock`;
  `python3 -c 'import shutil; shutil.rmtree(…)'` (which `IslandRisk` calls normal) is `.unlock`,
  never `.lockScreen`.
- `ProcessEnvironmentTests`: the moved Warp cases; `claudeSlot` for secure storage, config dir,
  empty and absent; `codexHome` for unset, `~/.codex`, a profile and another folder.
- `IslandHoldTests`: Claude terminal never; Codex terminal two minutes; headless two minutes even
  when hosted; Codex hosted under 24 h; Claude hosted never.
- `TailscaleStatusTests`: fixtures for each state (`Running` with and without `TailscaleIPs`,
  `NeedsLogin`, `Stopped`), MagicDNS on and off (both `ready`), iOS peers online and offline.
- `IslandTests` additions: `IslandRequest` reads `hosted` and `home` from the hook message.

**SideATests**

- `RemoteServerTests` (real TLS sockets on an ephemeral port bound to `127.0.0.1` for the test
  only, a test identity, a fake `DeviceStore`): a client pinning the test key connects, one
  pinning another key fails the handshake; hello without a token; 401 without one on
  `/v1/sessions`; 421 for `Host: evil.example`; 403 with an Origin; keep-alive serves two requests
  on one connection; the WebSocket upgrade on the same port routes by path, and without a token
  is refused before `101`; `hello` with an old epoch gets a snapshot and with a current one a
  replay; revoking closes the device's socket with 4401.
- `IdempotencyStoreTests`: a `done` record replays after a new store on the same file; a
  `started` record from a previous store gives `outcome_unknown` and the handler isn't called;
  another body under the same key is `idempotency_mismatch`; trimming at 24 h and 1,000.
- `IslandRemoteTests` (`@MainActor`, island with no server): a remote answer removes the request
  and records `.remote(device)`; a second answer gets `conflict` with the first resolution; an
  unknown id is `unknown`; a follow-up with the current `turnID` wakes the waiter and one with an
  old `turnID` is `turn_changed`; `finished` keeps the waiter with the notch off and Remote
  active, and releases it with both off.
- `RunningListTests`: `retainLive`/`releaseLive` start and stop the loop by owner; `"remote"` stays
  retained with no client connected while Remote is active.

**Bridge tests**: `island_hook.py` forwards `hosted` and `home`.

`scripts/local-ci.sh` needs no new gate.

## Live checks

Added to [validation](../validation.md#live-checks), on a local build ("Side A Dev", port 47900)
with real sessions. Setup's own live checks (the checklist, the pairing journey, Test Connection)
are in [setup](setup.md#live-checks).

- Settings > Remote with Tailscale absent, stopped and signed out: each shows its one line and its
  fix; the switch is disabled. MagicDNS and HTTPS certificates off on the tailnet: Remote works.
- Turning Remote on binds only the Tailscale address (`lsof -nP -iTCP:47900 -sTCP:LISTEN` shows
  `100.x.y.z`, not `*`); `tailscale serve status` is untouched.
- Pairing: the QR code opens the app; both devices show the same comparison code; a wrong code
  five times voids it; a second phone using the same code voids it; Codes Don't Match, Cancel and
  60 s of nothing each stop it with their error; the token works and the Keychain item holds only
  hashes (`security find-generic-password` from Terminal prompts or finds nothing).
- From another process on the Mac: `curl -k https://100.x.y.z:47900/v1/sessions` is 401;
  `-H 'Host: evil.example' …/v1/hello` is 421; `-H 'Origin: http://x'` is 403;
  `curl -k -X POST …/v1/pair` with no sheet open is 404.
- Replacement listener: quit Side A, run `openssl s_server` with another key on the same address
  and port; the phone refuses the connection ("This isn't the Mac you paired with") and sends no
  token (checked in the server's log).
- With the notch off and Remote on: a Claude request appears on the phone and not in the notch;
  no ⌃⌥ shortcuts are registered; Allow on the phone runs the tool.
- Answering in the terminal clears the phone's request within a second; answering on the Mac
  first makes the phone's Allow return 409 `already_resolved`; a retried notification action
  returns the first 200 with `Idempotent-Replay`.
- Kill Side A (`kill -9`) right after a hosted reply is typed; relaunch; the phone's retry gets
  `outcome_unknown` and nothing is typed twice.
- A destructive request: Allow without confirmation is refused; Always is never offered.
- A finished session with Finished off and Remote on: it appears on the phone, and a reply wakes
  it; a session given work in the terminal leaves the list; a reply carrying an older turn's id is
  refused.
- With the phone away for an hour (app killed, push on): every request and finish in that hour is
  in the replay or snapshot when it reconnects.
- Codex: a terminal session's request goes back to Codex after two minutes; a hosted one waits.
- Each session's account on the phone matches Side A's menu, before and after a trade.
- A Sparkle update while the phone is connected: it reconnects within seconds and gets a snapshot.
  Quitting Side A: the phone says Side A isn't running. Sleep and wake: the listener comes back.
  Tailscale off and on: the listener rebinds.
- Revoke: the phone disconnects at once and can't reconnect with its token.
- VoiceOver through the tab and the pairing sheet; the QR code and the comparison code read their
  characters.

## As built (L2, branch `remote/l2-mac-server`)

These override anything above that says otherwise.

- **TLS identity:** no openssl and no PKCS#12. A P-256 key is created non-extractable in the
  Keychain with `SecKeyCreateRandomKey`; Side A builds the self-signed certificate DER itself
  (`SelfSignedCertificate` in SideACore, tested against CryptoKit's SPKI) and signs it with
  `SecKeyCreateSignature`. The key never touches a file. The identity is found by the key's
  application tag, because the Keychain renames a certificate's label to its subject.
- **Keychain:** the login keychain, with items whose ACL trusts only Side A. The data protection
  keychain needs entitlements and a provisioning profile that a Developer ID app doesn't have
  (-34018). Open question 2 stays open.
- **Listener topology:** TLS terminates on one `NWListener` bound to `127.0.0.1` at an ephemeral
  port. Each address a phone can reach (tailnet, and LAN in LAN mode) gets a BSD listening socket
  (`SocketFront`) that splices bytes untouched to it. Reason: with Tailscale 1.104.1, connections
  from a real remote tailnet peer to an `NWListener` on the 100.x address stay in `.preparing` on
  utun and time out, whatever the parameters; BSD sockets on the same address answer at once
  (verified from a second tailnet Mac). Each direction has its own queue with backpressure, a
  write stalled 60 s ends the pair, 64 pairs per front, half-close passes through. The inner port
  is reachable by local processes, which is no new exposure (they can reach the 100.x port too)
  and gets the same TLS, Host and token checks; a process that took it over can't present the
  pinned key. Tests under `swift test` are network-isolated, so tailnet checks use a standalone
  binary.
- **`Expect: 100-continue`** gets 417; URLSession never sends it.
- **101 response** includes `Connection: Upgrade` (URLSession refuses the socket without it).
- **Terminal backpressure:** the PTY pauses at 768 KiB queued and resumes under half, so the
  1 MiB socket close never fires. Exit reasons are `ended`, `killed` (a DELETE) and `lost`.
- **installID:** base64url(SHA-256(install public key)[0..<16]), computed on the Mac; the relay
  registers it on first use and again after a 401. Relay state comes from `GET /v1/installs/self`,
  checked at most once a minute.
- **Preview:** plain HTTP request/response proxying through Side A's own listener (a
  credentialed `/v1/preview/<credential>/` URL plus a Secure, HttpOnly, SameSite=Strict cookie for
  absolute links), bodies capped at 64 MiB, 30-minute lifetime. WebSocket HMR isn't proxied in
  v1, so a page needs a manual reload.
- **Efforts:** offered per model. Claude by model id (xhigh and max not on claude-3-*,
  opus-4-0/4-1/4-5, sonnet-4-0); organization or settings caps aren't read yet. Codex from
  `codex debug models` with the account's `CODEX_HOME`, cached 10 minutes; none and minimal never
  offered. An unsupported effort gets 422 `invalid_option`.
- **Continue on phone:** when the agent isn't back under the new pane within 20 s, 502
  `not_resumed` with `{hosted, command, hint: "tryAgain"}`. An already hosted session answers 200
  with its `HostedSession`, so a retry is harmless. The dead pane isn't kept for the phone
  (`last.txt` keeps the screen). Headless means a registry `kind` other than `interactive`.
- **Rate limit:** 20 requests per second per device.
- **Comparison code:** SHA-256 over the ASCII label `sidea-pair-v1`, then each field (code as
  normalized UTF-8, nonce, Mac public key, phone public key, TLS SPKI hash) as a 2-byte big-endian
  length and its bytes. The 6 digits are the first 8 bytes as a big-endian UInt64 mod 10^6,
  zero-padded. Known-answer fixtures live in SideAProtocol (`PairingTranscript`).

## Open questions

1. **Binding the Tailscale address.** Confirm a sandboxless Developer ID app can bind an
   `NWListener` to the `utun` address with each Tailscale flavour (App Store system extension,
   standalone, open-source `tailscaled`), and that the macOS firewall prompt names Side A.
2. **Keychain protection.** Can a Developer ID app without a provisioning profile use the data
   protection keychain? If not, can an agent delete and replace a login-keychain item it can't
   read without a prompt? That decides whether a device list or the TLS identity could be swapped
   under Side A (within the threat model's limits).
3. **Ready list with the notch's Finished off.** With Remote active, finished sessions now appear
   in Sessions > Running on the Mac too. Wanted, or should the Mac list follow the notch setting?
4. **Destructive approvals from the phone.** The Mac trusts `confirmDestructive` from a valid token.
   Is Face ID in the app enough, or should destructive requests stay Mac-only until the remote
   approval log (M4) exists?
5. **Hook fields vs environment.** `hosted` and `home` in the hook message are simplest and survive
   a Codex parent shell that exits; reading the environment needs no hook change. Do both, or only
   the hook?
6. **Pairing link domain.** `getsidea.com/pair` needs an `apple-app-site-association` entry on the
   site before the first TestFlight; until then the QR code carries a `sidea-remote://` scheme.
7. **Always-on recording cost.** The live loop now runs whenever Remote is active, not only while
   Sessions is open. Measure its CPU and energy on battery with no phone connected; if it shows,
   slow the 20 s poll (FSEvents still drives most changes), never stop recording.
