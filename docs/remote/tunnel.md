# Side A Remote: reach the Mac from anywhere (spec)

How the phone reaches the Mac when neither the LAN nor Tailscale does: an end-to-end encrypted
tunnel through the push relay's Durable Object, chosen and dropped on the fly. Read
[protocol](protocol.md) (Conventions, Pairing) and [relay-and-release](relay-and-release.md) (Push
relay) first.

Status: built and shipping (Side A 0.5.44). Written as the plan in October 2026; where this differs from the code, the code wins.

## Summary

- The Mac keeps **one outbound WebSocket** to `wss://<relay>/v1/tunnel/mac`, signed with the
  install key (SideA-Sig). No inbound port.
- The phone opens `wss://<relay>/v1/tunnel/phone` with its relay credential
  `d1.<installID>.<deviceID>.<secret>`. The install's Durable Object pairs the two sockets and
  forwards opaque frames. It never sees plaintext and stores nothing new beyond a device list
  (id and secret hash, the same as push already keeps).
- What crosses the tunnel is **the same pinned TLS 1.3 byte stream** the phone sends to
  `https://<mac>:47800` today. On the Mac it ends at `RemoteServer`'s loopback TLS listener, the
  same one `SocketFront` feeds. Same key, same SPKI pin, same Host, Origin, token, rate-limit and
  idempotency checks. The protocol doesn't change, and there is one protocol and one pin.
- On the phone, every connection to the Mac is **`NWTransport`**: HTTP/1.1 and WebSocket on
  Network.framework, with the SPKI pin in `sec_protocol_options_set_verify_block`. So ATS needs no
  exception for the self-signed, IP-addressed certificate. On the relay path it dials an
  **in-process loopback listener** (`RelayBridge`) that carries each connection as a tunnel
  stream. REST, both sockets, image fetches and notification answers all go through it unchanged.
- A **path router** in SideARemoteKit (`Paths`, `RoutedTransport`) races LAN, Tailscale and the
  relay happy-eyeballs style, keeps the relay warm, and migrates when the network changes. Every
  `RemoteClient` made without an explicit transport uses it: the app, both notification
  extensions, the widget and Test Connection. The UI never offers a choice. Test Connection shows a
  quiet "via relay".

## What others do (research, October 2026)

| Project | Transport | E2E | Path switching | Worth taking |
|---|---|---|---|---|
| Codex Remote Control | Host dials `wss://chatgpt.com/.../remote/control/server`, one socket per account | No | Reconnects | Outbound-only host socket |
| Claude Code Remote Control | Same shape via the Anthropic API | No | Reconnects | Same |
| Happy | CLI and app dial happy-server (HTTP + Socket.IO), Postgres store | Yes: AES-256-GCM per-session keys, NaCl box wrap, QR pairing | Re-fetch from a per-user `seq` | Durable events with `seq`, kept apart from ephemeral ones |
| Paseo | Daemon dials the relay over WS. Control socket per server, data socket per client. Was a DO with hibernation tags, now Elixir | Yes: X25519 from the QR, NaCl box, random nonces (no in-session replay counter) | Direct, Tailscale or relay | Bounded queues: an 8 MiB high-water mark kills the slow socket. Paseo left DOs over flow control, so ours must be explicit |
| Codeman | Local web server via `tailscale serve` or `cloudflared` | No (TLS ends at the tunnel) | n/a | `(clientId, seq)` input dedupe. A tunnel makes everything look like 127.0.0.1, so localhost exemptions leak |
| Omnara | Daemon dials a backend WS | No | Heartbeats, `presence_replaced` | Typed ack outcomes |
| Claude Code UI | Local `ws`, bring your own tunnel | No | Replay buffer by `seq` | Same as ours |
| VibeTunnel | One multiplexed binary WS (`'VT' ver type sid len`) | No | Snapshot resync | Resync from a snapshot, not a backlog |
| Tailscale DERP | TCP via HTTP upgrade, 5-byte frames, 64 KiB packets, carries WireGuard ciphertext | Yes (WireGuard) | Sticky home DERP. Disco pings promote to direct, which is trusted 6.5 s and re-pinged every 3 s | The relay always works while direct paths are probed. Hysteresis |
| iroh | QUIC multipath. The relay is just another path (datagrams in WS frames) | Yes (QUIC TLS 1.3 keyed to endpoint ids) | Lowest biased RTT wins, the relay is a backup path, switches need a 5 ms gain | Paths change under one crypto session |

Also checked: ngrok TLS endpoints, frp `stcp`, wstunnel and websockify are byte pipes, so TLS
inside them is end-to-end. Cloudflare Tunnel ends HTTP TLS at the edge, so it isn't.

## Decision: tunnel the pinned TLS stream (a), not a Noise layer (b)

(a) wins:

1. **No new crypto, one pin.** The phone already pins the Mac's SPKI and the Mac already checks
   device tokens inside that TLS. A Noise session would be a second key schedule, a second replay
   window and a second set of fixtures for L1, and every route would need a message-level shim on
   both sides.
2. **The Mac is already shaped for it.** TLS ends on a loopback `NWListener` behind a byte splice
   (`SocketFront`). The tunnel is another splice into the same listener.
3. **The phone keeps one TLS client.** The usual objection is that iOS can't run TLS over an
   arbitrary byte stream. A loopback hop answers it: `NWTransport` runs its pinned TLS to
   `127.0.0.1:<bridge>` exactly as it would to the Mac, and the bridge moves the bytes. The first
   build used URLSession through the same bridge as an HTTP CONNECT proxy
   (`proxyConfigurations`). The bridge still accepts a CONNECT, but nothing uses it since the move
   off URLSession, which ATS forced.
4. **TLS 1.3 without 0-RTT** gives the relay nothing to replay. Records are AEAD-sealed with
   implicit sequence numbers, so a relay that drops, reorders or replays bytes breaks the stream.
   That is stronger than Paseo's random-nonce box, which has no in-session counter.

What (a) costs, and why we accept it:

- **A path switch is a new TLS connection**, not a migrated session (iroh's advantage). It costs
  one RTT of TLS 1.3 handshake plus one of HTTP on the new path. Resume is already cursor-based:
  the events socket reconnects with `epoch`/`lastSeq` and the ring replays. The terminal resends
  unacked numbered input. Outbox items carry an `Idempotency-Key`, so a re-send after a switch is
  replayed by the Mac's idempotency store, never run twice. We switch make-before-break (below), so
  the user doesn't see the gap.
- **Head-of-line blocking:** every stream to one phone shares one relay WebSocket. Per-stream
  credit (below) keeps a big download from starving the events socket's window. This is
  stream-in-stream, not TCP-over-TCP: the inner TLS never retransmits, so there's no meltdown.
- **Loopback on the phone:** another app on the same iPhone could connect to the bridge's
  ephemeral port while ours runs. It would get a TLS stream to the Mac without a Mac token, the
  same as standing on the Mac's LAN. The bridge listens only on 127.0.0.1 on a random port, only
  while the process runs, and rate-limits connections. The relay credential never leaves the
  process.

## Wire

### Endpoints (relay Worker)

| Route | Who | Auth |
|---|---|---|
| `GET /v1/tunnel/mac` (WebSocket upgrade) | Mac | `Authorization: SideA-Sig …` over `GET\n/v1/tunnel/mac` and an empty body. Nonce and ±120 s, as every Mac request. Install must be registered |
| `GET /v1/tunnel/phone` (WebSocket upgrade) | Paired phone | `Authorization: Bearer d1.<installID>.<deviceID>.<secret>`. The device must be in the install's tunnel device list |
| `GET /v1/tunnel/phone` (WebSocket upgrade) | Phone mid-pairing | `Authorization: SideA-Pair <installID>.<ticket>`. Accepted only while the Mac has a pairing ticket open (below) |

The Worker parses and rate-limits, then hands the upgrade to the install's Durable Object, which
checks the signature, nonce or secret against its own storage and accepts the socket with
hibernation tags (`mac`, `phone:<deviceID>`, `pair`).

### Frames

Each binary WebSocket message is one frame: `type u8 | stream u32 big-endian | payload`.

| Type | Name | Payload | Meaning |
|---|---|---|---|
| 1 | OPEN | phone→relay: none. relay→Mac: JSON `{"device": "<id>"}` or `{"pairing": true}` | A new byte stream. The phone may send DATA right after OPEN without waiting |
| 2 | DATA | ≤ 32 KiB of bytes | TLS bytes, in order |
| 3 | FIN | none | This end closed. What was already sent is delivered, then the other end closes too. Neither URLSession nor the Mac's server half-closes, so there is no half-open state to carry |
| 4 | RESET | UTF-8 reason, ≤ 64 bytes | The stream is over in both directions |
| 5 | CREDIT | u32 bytes | The receiver wrote this many more bytes out locally |

Stream ids: the phone numbers its streams 1…65535 (wrapping, skipping live ones). The relay gives
each phone socket a slot 1…65535 (kept in its hibernation attachment) and shows the Mac
`slot << 16 | stream`. The relay keeps no per-stream state: it rewrites ids and forwards.

Text messages are control messages, JSON `{"type": …}`:

| From → to | Message |
|---|---|
| Mac → relay | `{"type":"devices","devices":[{"id","secretHash"}]}` on connect and on every pair or revoke: the full list. Sockets of devices not listed close 4401 |
| Mac → relay | `{"type":"pairing","ticketHash":"<b64url SHA-256>","expiresAt":<s>}`, or `{"type":"pairing"}` to close the window |
| relay → Mac | `{"type":"gone","slot":n}`: that phone socket closed, so drop its streams |
| relay → phone | `{"type":"mac","online":bool}` on connect and on every change |
| either → relay | `ping` (plain text). The DO's `setWebSocketAutoResponse` answers `pong` without waking |

### Flow control

Each direction of each stream starts with 256 KiB of credit. A sender stops reading its local
socket when the credit runs out, so backpressure goes back to TCP: to URLSession on the phone, and
to `HTTPConnection` on the Mac. The receiver returns CREDIT as its local writes complete
(`contentProcessed`), batched at 32 KiB. The window is 8 times the batch, so a sender can't stall
waiting on credit the receiver is still holding back, and a quiet stream sends no credit frames
at all. The existing
policies stay in force above the tunnel. A `WebSocketPeer` with more than 1 MiB queued closes 4008,
and the phone reconnects from `lastSeq` (events) or resyncs the screen (terminal). The tunnel
never queues without a bound: at most window × streams per device.

Coalescing (`TunnelMux.Tuning`): in each 16 ms window, the first two frames of a stream go at
once. After that, reads wait out the window or until 8 KiB has gathered, then go as one frame. A
keystroke, or a request and its answer, never waits. A burst of small TLS records (terminal
output, transcript deltas) costs at most about 3 frames per 16 ms per stream, about 190 a second.
The first version held any read within 16 ms of the last frame. That added 16 ms to every round
trip faster than the window (measured: p50 18.7 ms on the local relay against 1.6 ms now).

### Limits (relay, enforced per install DO)

| What | Limit | Over it |
|---|---|---|
| Frame size | 32 KiB payload + 5 header | Socket closes 1009 |
| Mac sockets | 1. A new one replaces the old | Old closes 4409 `replaced` |
| Phone sockets per device | 2 | Oldest closes 4409 |
| Devices online at once | 8 | 4429 |
| Pairing sockets | 2 per ticket, only while it is open, 4 streams, 2 MiB total. A socket whose ticket is no longer the open one gets 60 s to finish, less if the open ticket needs its place | 4429, or 4403 when no window or its grace ends |
| Bytes per phone socket | 8 MiB/s sustained, 32 MiB burst (token bucket in memory) | 4429. The phone backs off |
| Frames per phone socket | 2,000/s | 4429 |
| Mac socket | 16 MiB/s sustained, 64 MiB burst, 4,000 frames/s, burst 8,000 | 4429. The Mac backs off and reconnects |
| Each install, both directions | 64 GiB and 30 million frames per UTC day (SQLite, written at most every 16 MiB, 20,000 frames or minute) | Every socket closes 4429, and upgrades get 429 until the day ends |
| Upgrades per IP (IPv6: per /64) | 120 per minute per location, in the Worker, before any object wakes | 429 |
| Streams per phone slot | 8, and 24 across all phones (enforced on the Mac, inside `RemoteServer`'s 64 connections, so relay phones can't crowd out LAN or tailnet ones) | RESET `too_many_streams` |
| Wrong pairing tickets | Refused with 403, no lockout. A ticket is 128 random bits, so guessing gets nowhere, while a lockout would let anyone who knows the install id stop its pairing | |

The DO keeps no payloads, no logs of payloads, and no IP addresses. Analytics Engine counts each
upgrade as `tunnel.mac` or `tunnel.phone` with its HTTP status; bytes, frames and close codes
aren't counted.

### Close codes (relay sockets)

4401 not paired or revoked (the phone stops using the relay until the next hello says otherwise),
4403 no pairing window, 4409 replaced, 4429 over a limit (retry after 10 s), 1001 relay
restarting, 1009 frame too big.

## The Mac

`TunnelClient` (`Sources/SideA/Remote/TunnelClient.swift`, new), owned by `RemoteController`:

- Runs while Remote is on, **Reach this Mac from anywhere** is on (default on whenever a relay URL
  is configured) and the install key exists. First it makes sure the install is registered
  (`RelayClient.register`, idempotent).
- One `URLSessionWebSocketTask`, re-signed on every connect. Backoff 1 s doubling to 60 s with
  jitter. `NWPathMonitor` and `didWake` trigger an immediate reconnect. Pings every 25 s, and a
  pong missing after 10 s means the socket is dead.
- Each OPEN connects to `RemoteServer`'s loopback TLS port and splices, with credit. The inner
  listener stays up while the tunnel runs, even with no LAN or tailnet address to serve.
  `RemoteServer` gets `tunnelPort()`, which starts the inner listener if it isn't up.
- The Mac accepts the relay path's Host: the phone's relay URL is
  `https://sidea-relay.invalid`, which can't resolve in any browser. `RemoteController` adds
  `sidea-relay.invalid` to the server's names while the tunnel runs. The Host check still
  refuses everything else, and Origin and `Sec-Fetch-Site` are still refused.
- Unauthenticated requests (hello, the pairing routes) keep sharing the server's single
  unauthenticated bucket (10 a minute, burst 5) whichever path they arrive by. A relay pairing
  therefore can't open a second budget. The relay's pairing ticket and its 2-socket cap sit in
  front of that bucket.
- Each relay stream is its own inner `HTTPConnection`. FIN or RESET cancels it, so
  `closed(id)` still fires per connection, and a pairing wait whose phone vanished is voided after
  3 s as on the direct path.
- It sends the device list (id, `secretHash` from `DeviceStore`) on connect and after every pair or
  revoke, so revoking closes the device's relay sockets at the relay and its TLS sockets on the
  Mac.
- Settings > Remote: **Reach this Mac from anywhere**, with "Your iPhone can reach this Mac through
  Side A's relay when it isn't on the same network. Everything stays end-to-end encrypted: the
  relay only passes on bytes it can't read." Its status reads "Connected to the relay" / "Can't
  reach the relay" in Copy Diagnostics only.

## The phone

### RelayBridge (`SideARemoteKit/RelayBridge.swift`, new)

- An `NWListener` on `127.0.0.1:0`. A connection that starts with a TLS record (`0x16`) is the
  stream itself: OPEN, then the bytes, spliced with credit. One that starts `CONNECT … HTTP/1.1` is
  answered `200 Connection Established` (or `503` when the relay says the Mac is offline) and then
  spliced the same way.
- One relay WebSocket per Mac per process (`URLSessionWebSocketTask`, system trust to Cloudflare;
  the inner TLS is the one that matters). It opens on first use and stays open while the process
  is in the foreground. That is the warm fallback, cheap because the DO hibernates. It closes after
  2 minutes without streams in the background.
- `{"type":"mac","online":false}` makes the bridge refuse new connections and drop live streams, so
  the TLS client fails at once and the router moves on.

### Paths and RoutedTransport (`SideARemoteKit/Paths.swift`, new)

`Endpoint` gains an optional `relay: RelayRoute` (`url`, `installID`, `deviceID`). It is Codable and
optional, so older stored records decode. The relay secret is read through the `CredentialStore`
(new requirement with a default of nil, so existing stores keep compiling).

`RoutedTransport` implements `Transport` and holds one pinned `NWTransport` per path kind. Direct
dials the URL's host. Relay dials the bridge, with URL host `sidea-relay.invalid`, which is also
sent as `Host`. It rewrites each request's scheme, host and port to the current path, whichever of
the Mac's addresses the caller used. Probes always open a fresh connection: a kept-alive one can
outlive the network it was made on and answer for a path that's gone. That was found in the
end-to-end test, where URLSession's pool kept "winning" on a stopped listener.

Choosing a path, with `Paths` as one actor per Mac per process:

1. **Race** `GET /v1/hello` on every direct address and on the relay at once. The first direct
   answer wins outright. If the relay answers first, keep waiting up to 300 ms for a direct one,
   then take the relay. A direct probe times out at 2.5 s, the relay at 8 s. A connection that
   goes to `waiting` fails at once (refused, no route), except for a Local Network prompt, which
   is waited out up to the timeout and then throws `LocalNetworkDenied` (TN3179). An address that
   refuses is tried on the Mac's other ports (47800 to 47809, or 47900 to 47909 for Side A Dev),
   since a Mac whose port was taken moves up; the pinned key decides whether what answers is the Mac.
2. **Keep the relay warm** (bridge socket open, no TLS stream) while on a direct path.
3. **Re-race** on an `NWPathMonitor` change (interface added or lost, Wi-Fi ↔ cellular), on a
   connection-level failure of the current path, and every 30 s while on the relay. Promotion has
   hysteresis: a direct path must answer two probes in a row before it replaces the relay. That is
   DERP's rule in miniature. A relay that doesn't answer sits out races for 30 s, doubling to 5 min,
   except within 10 s of a network change: then its probe is tried once more and a miss doesn't
   count, since the bridge socket may still have been on the interface that went.
4. **Migrate make-before-break:** the new path has answered a pinned hello before anything moves.
   New requests go to it at once, in-flight REST calls finish where they are, and sockets opened on
   the old path close with `SocketClosed(4008, "path changed")`. `SyncEngine` already treats 4008 as
   "reconnect now". Its state stays `.live` across that reconnect, so the UI shows no change. The
   events socket resumes with `lastSeq`, the terminal with its acked input.
5. **Retry once across a switch:** a request that fails with a connection-level error (lost,
   timed out, can't connect, not connected) and is a GET or carries an `Idempotency-Key` (every
   Mac POST and DELETE does) is retried once on the re-raced path. Notification actions answering
   from an extension get this too.

`SyncEngine` keeps its address rotation for transports that aren't routed. With `RoutedTransport`
the rotation is harmless, because every address routes to the chosen path. Test Connection asks
`Paths.retest()` for the path and names it ("through the relay"), and checks the relay on its own with
`Paths.checkRelay()`: the bridge says whether the Mac is on the relay, then a pinned hello goes through
it, so a broken relay shows while a direct path still carries everything. The path in use doesn't move.

### Path-agnostic everywhere

| Caller | Before | After |
|---|---|---|
| `SyncEngine` events socket | Rotates `endpoint.addresses`, chosen at connect | `RoutedTransport`. Migrates on path change (4008) |
| Terminal socket (`TerminalSession`) | The address the engine had | Same transport. Closes 4008 on migration and resumes with acked input |
| Images (`RemoteClient.image`) | `client.address` | Routed, and retried once across a switch |
| Notification answers (`Linked/NotificationAnswer.swift`) | `endpoint.baseURL` only | Routed: races every path in the extension, relay included |
| Widget refresh (`WidgetPublisher`, widget timeline) | The app's last state | Unchanged: the app writes snapshots. Any widget fetch uses the default transport |
| Test Connection | `.at(address)` per address | Routed, and a Relay row of its own: `Paths.checkRelay()` |
| Pairing | `a`, then each `l` | Adds the relay as the last candidate when the QR carries `i` and `r` |

## Pairing over the relay

The QR (v2) gains `&i=<installID>&r=<relay origin>&p=<ticket>`, where the ticket is 16 random bytes
made per pairing sheet. `a` may be absent when the Mac has no direct address. The Mac sends
`{"type":"pairing","ticketHash","expiresAt"}` when the sheet opens and again with every 25 s ping.
`expiresAt` is 120 s ahead, and the relay caps it at 10 minutes. Closing the sheet clears the
ticket at once, so a ticket is good only while its sheet is open, plus at most 2 minutes if the Mac
vanishes with the sheet still up.

Brute force: the ticket is 128 bits, and the relay keeps only its SHA-256. A wrong ticket gets 403
`no_pairing` and nothing else: there is no lockout, since guessing 128 bits gets nowhere and a
lockout would let anyone who knows the install id stop its pairing. Upgrades are also limited per
network before any object wakes. Behind the ticket, the Mac's own pairing limits still apply: the shared
unauthenticated bucket, five tries per code, single-use codes and the SAS. The phone tries `a` and each
`l`, then the relay with `SideA-Pair <installID>.<ticket>`, under the same `fp` pin. The SAS and code
rules are unchanged. They are what make pairing safe; the ticket only keeps strangers who know an
install id off the Mac's pairing routes. A typed pairing (no QR) is direct-only. After Pair, the
Mac pushes its device list, so the phone's `d1` credential works on the relay at once.

## Security: no weaker than direct

- Same TLS 1.3 handshake, same pinned SPKI, same `Authorization: Bearer sa1_…` checked by the Mac.
  The relay sees neither the token nor any plaintext.
- What the relay learns: install id, device ids, when and how much, and both ends' IP addresses
  (Cloudflare sees these anyway). That is the same class as push metadata, listed in
  relay-and-release "What the relay can see".
- A stolen relay credential (`d1…`) gets a TLS stream to the Mac and nothing more, with no token.
  Revoke on the Mac removes it from the device list.
- A compromised relay can drop or delay traffic (as can any network) but can't read, alter or
  replay it. It can't pair a device either: QR pin plus SAS.
- Install cleanup: the DO's 90-day "silent install" rule also counts tunnel use (`last_tunnel`), so
  a push-less install that tunnels daily isn't erased.

## Latency

Expected: one extra hop through the nearest Cloudflare PoP to the DO, which lives near where the
Mac first created it. Same metro: +5–20 ms RTT. Cross-region: +30–80 ms. A new stream costs a
TLS 1.3 handshake (1 RTT) before its first request. `NWTransport` keeps up to four connections per
path alive for 20 s (the Mac's idle timeout is 30 s), so steady state is 1 RTT per request.

Measured 18 October 2026 with a one-off latency run (since removed from the test suite): the real `RemoteServer`, the
real `TunnelClient`, the relay Worker and DO under local `wrangler dev`, and `Paths` with
`NWTransport`, all on one Mac. These numbers are the tunnel's own overhead. A deployed relay adds
the network RTT to the nearest PoP on top.

| | p50 | p90 |
|---|---|---|
| `GET /v1/hello`, direct (loopback) | 0.4 ms | 0.6 ms |
| `GET /v1/hello`, relay | 1.6 ms | 18.0 ms* |
| Keystroke echo on the events socket, relay | 1.6 ms | 17.5 ms* |
| First request on a cold relay (relay WebSocket, OPEN, TLS 1.3, hello) | 381 ms | |
| 512 KiB there and back on one socket, relay | 130 ms (about 8 MB/s) | |

\* A back-to-back loop on loopback is faster than the 16 ms window, so every third frame waits.
Over a real network the RTT is longer than the window, so this tail doesn't appear.

The cold start is mostly the relay WebSocket's own handshake to local workerd. That's why the
relay is kept warm while a direct path is in use.

## Pieces and owners

| Piece | Where | Owner |
|---|---|---|
| Tunnel routes, DO sockets, frames, limits, device list | `relay/src/tunnel.ts` (new), small hooks in `index.ts` and `install.ts` | L9, sha to L6 |
| Frame codec (Swift) | `SideAProtocol/Tunnel.swift` (new) | L9, sha to L1 |
| `TunnelClient`, setting, device list, pairing ticket | `Sources/SideA/Remote/TunnelClient.swift` (new). `tunnelPort()` in `RemoteServer`. Wiring in `RemoteController` and `RemoteSettings` | L9, sha to L2 |
| `RelayBridge`, `Paths`, `RoutedTransport`, `Endpoint.relay` | `SideARemoteKit` (new files, one default in `RemoteClient`) | L9, sha to L5 |
| QR fields, pairing relay candidate, Test Connection row, LiveLink path hook | `Pairing.swift`, iOS app | L9 small changes, sha to L5 |

Build order: frames and DO first (vitest-pool-workers), then the Mac `TunnelClient` against
`wrangler dev`, then `RelayBridge` + `Paths` in SideARemoteKit tests against the real Mac harness
through the local relay, then the iOS app in the simulator.

## Open questions

1. The relay hostname: `push.getsidea.com` serves both (simplest; one Worker), or a separate
   `relay.getsidea.com` route on the same Worker so tunnel traffic can be paused separately
   (`RELAY_TUNNEL_PAUSED`). Proposed: same Worker, its own pause switch, same hostname.
2. Cost, settled below.

## Cost

Cloudflare's Durable Object pricing (Workers Paid, October 2026): incoming WebSocket messages
count as requests at 20:1, at $0.15 per million requests after the included million. Duration is
$12.50 per million GB-s at 128 MB, billed only while the object is awake (hibernation sleeps it
between messages, and auto-response pings don't wake it). Outgoing messages and bandwidth cost
nothing extra.

A heavy day for one user: 2 hours of a busy terminal, transcripts streaming through a working day,
20 images and one 20 MiB upload.

| Traffic | Frames into the object | Bytes |
|---|---|---|
| Terminal output, coalesced at 16 ms: worst case 62/s for 2 h | 446k | ~100 MB |
| Keystrokes and terminal credit | ~10k | <1 MB |
| Events socket: transcript deltas, state, presence (8 h) | ~60k | ~30 MB |
| Images (20 × 200 KB) and an upload (20 MiB) | ~1.3k | ~25 MB |
| Pings: Mac and phone, every 25 s (auto-answered) | ~7k | — |
| **Total** | **~525k messages ≈ 26k billed requests** | **~160 MB** |

That's about $0.004 a day in requests. Duration is 3 h awake × 0.125 GB ≈ 1,350 GB-s ≈ $0.017 a
day. All in, about **$0.02 per heavy user per day, roughly $0.65 a month**, before the included
allowances. A typical user (no terminal, transcripts and a few answers) is two orders of magnitude
less. The measured counts from the harness runs are below. Watch `tunnel.*` in Analytics Engine
before opening the tunnel to everyone.
