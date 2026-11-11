# Side A Remote: push relay and release (spec)

How Side A Remote gets notifications to the phone without the Mac holding Apple's push key, and how
the iOS app ships. Read [remote.md](../remote.md) first (Push, Decisions #1).

Status: built and shipping (Side A 0.5.44). Written as the plan in October 2026; where this differs from the code, the code wins.

Facts checked on 17 October 2026 are marked as such. Everything else is a decision.

## Overview

```
SideA.app ──signed request──▶ push.getsidea.com (Worker) ──HTTP/2 + JWT──▶ APNs ──▶ iPhone
   │  sealed payload            │ one Durable Object per install          │
   │  (ChaCha20-Poly1305)       │ (keys, device tokens, limits)           ▼
   │                            ▼                         Notification Service Extension
   │                     .p8 in Worker secrets            opens the payload with the pairing key
   └──────────── answers, transcripts, everything else: Tailscale, never the relay ──────────┘
```

Three rules:

1. **The relay holds the APNs key and nothing worth reading.** It sees tokens, timing and
   ciphertext. The visible text of an alert is fixed by the relay, not by the Mac. The key itself
   is worth a great deal: APNs keys are team-scoped and this one is shared with another project on
   the same Apple team, so whoever reads the Worker's secrets can push to every app on that team.
   Treat it as the relay's most sensitive secret, and rotate it when anyone with Cloudflare access
   changes. A key of its own for the relay would narrow this; the team is at Apple's key limit
   today, so that means retiring another key first.
2. **The Mac is the relay's only full client.** The phone hands its tokens to the Mac over
   Tailscale; the relay accepts from the phone only token refreshes, token verification and its
   own unpairing, with a narrow credential.
3. **Losing the relay loses notifications, nothing else.** The app keeps working over Tailscale.

## Push relay

A Cloudflare Worker, `sidea-push`, on the custom domain `push.getsidea.com`. Cloudflare already
hosts the domain's DNS (see [distribution.md](../distribution.md#download-website)); a Worker
custom domain adds its own proxied record and leaves the Vercel apex records alone. Source in
`relay/` (TypeScript, Wrangler, Vitest with the Workers pool), deployed with `wrangler deploy`.
A second Worker, `sidea-push-staging` on `push-staging.getsidea.com`, takes development builds.

### Identities

| Who | Identity | Proves it with | Lives in |
|---|---|---|---|
| A Mac (an *install*) | `installId` = base64url of the first 16 bytes of SHA-256(public key) | Ed25519 signature on every request | Private key in the Mac Keychain, ACL limited to SideA.app's signature; never under `runtime/` |
| A phone, per Mac (a *device*) | `deviceId`, random 16 bytes base64url, chosen by the phone at pairing | Bearer `d1.<installId>.<deviceId>.<deviceSecret>`, where `deviceSecret` is 32 raw random bytes in base64url; the relay stores only `secretHash = base64url(SHA-256(raw bytes))`, which the Mac registers | Phone's shared keychain group, readable after first unlock |

Wire formats: public keys are raw 32-byte Ed25519 (install) or X25519 (pairing) keys in base64url;
APNs and Live Activity tokens are hex; every error body is protocol's envelope,
`{"error": {"code", "message", "retryable", "details"}}`.
| The relay to Apple | APNs token-signing key (`.p8`) | ES256 JWT | Worker secrets |

A phone paired with two Macs is two devices with two secrets. A Mac with three phones is one
install with three devices.

### Signed requests (Mac → relay)

```
Authorization: SideA-Sig v=1, install=<installId>, ts=<unix seconds>, nonce=<16 bytes b64url>, sig=<b64url>
signed string:  "SideA-Sig-v1\n" + METHOD + "\n" + pathname + "\n" + ts + "\n" + nonce + "\n" + hex(SHA-256(body))
```

`pathname` is the URL path only, with no query string. Signatures are checked inside the install's
Durable Object. The relay rejects a `ts` more than 120 seconds from its clock (the response
carries `Date`, so the Mac can correct for skew once and retry; the tunnel upgrade, whose body the
Mac can't read, tells the two 401s apart by that `Date`, see tunnel.md, The Mac), and a nonce seen in the last
5 minutes. Nonces, limiter windows and `last_send` are persisted in one `state` row per install
(below), so an evicted object can't be replayed against or have its limits reset. Ed25519 is
standard Web Crypto in Workers (checked: listed in the supported-algorithms table) and
`Curve25519.Signing` in CryptoKit.

### Endpoints

All JSON, all under `/v1`, bodies capped at 8 KB.

**From the Mac (signed with the install key):**

| | |
|---|---|
| `POST /installs` | `{publicKey}`. Creates the install; the request is signed with the key it registers. Returns `installId`. |
| `GET /installs/self` | Device counts, whether sends are paused, and `gone: [{device, reason}]`: the Mac's self-check for Test Connection (setup). |
| `POST /installs/rotate` | `{newPublicKey}`, signed with the old key. The id stays the same; the old key stops working at once. |
| `DELETE /installs` | Remove Side A / Remote turned off: deletes the install and all its devices. |
| `PUT /devices/{deviceId}` | `{apnsToken, environment: "sandbox"\|"production", secretHash, pushToStartToken?, appVersion}`. Creates or replaces a device (`development` is accepted as an alias for `sandbox`). Sent when the phone first reports its tokens (`POST /v1/devices/push`) and whenever they change. A new or changed APNs token starts **unverified** (below). |
| `DELETE /devices/{deviceId}` | Revoke from Settings > Remote. |
| `POST /send` | One push to one or more of this install's devices (below). Returns a result per device. |

**From the phone (Bearer `d1.<installId>.<deviceId>.<deviceSecret>`):**

| | |
|---|---|
| `POST /device/verify` | `{challenge}` (16 bytes, base64url): proves this phone receives pushes at the registered token. |
| `PUT /device/tokens` | `{apnsToken?, pushToStartToken?}` when iOS rotates a token and the Mac is out of reach. A new APNs token starts unverified. |
| `PUT /device/activities/{activityId}` | `{updateToken}`: the per-activity token iOS issues after a push-to-start. |
| `DELETE /device/activities/{activityId}` | The activity ended on the phone. |
| `DELETE /device` | Unpair from the phone while the Mac is unreachable. |

The phone also reports every token to the Mac on its next connection, so the Mac stays the
source of truth; the phone path exists because iOS hands out an activity's update token in a
short background launch, when Tailscale may not be connected.

**Unauthenticated:** `GET /health` (200, no body). No listing, no lookup by token.

**Token verification.** Registering a token proves nothing about who holds it: anyone can create
an install and register a known APNs token belonging to someone else's phone. So a new or changed
APNs token starts unverified, and the relay sends that token one silent push (priority 5,
`apns-push-type: background`):

```json
{ "aps": { "content-available": 1 }, "verify": { "install": "<installId>", "device": "<deviceId>", "challenge": "<16 bytes b64url>" } }
```

The app, woken in the background (or already in the foreground during the notifications step),
posts `POST /v1/device/verify {challenge}` with its `d1.…` bearer. Only a phone that both receives
pushes at that token and holds the device secret can answer. Until it does, a send to that device
returns `unverified` and nothing is delivered. Challenges go out at most once a minute and five
times an hour per device, and expire after an hour; the phone re-triggers one by reporting its
token again on its next connection to the Mac.

### Send

The Mac never sends an `aps` dictionary. It sends what it wants; the relay builds the APNs
request from an allowlist.

```json
{
  "devices": ["<deviceId>", "..."],
  "kind": "alert",
  "category": "REQUEST",
  "collapseId": "<request id>",
  "priority": 10,
  "expiresIn": 3600,
  "sound": true,
  "level": "time-sensitive",
  "sealed": { "<deviceId>": "<base64url envelope for that device>", "...": "..." }
}
```

`sealed` holds one envelope per destination device, because each device has its own key and the
AAD names the device. Categories are an allowlist with fixed fallback `loc-key`s, listed in
[protocol](protocol.md#push-payloads): `REQUEST`, `REQUEST_DESTRUCTIVE`, `QUESTION`, `PLAN`,
`FINISHED`, `LIMIT`, `HEALTH`, `ROTATION` and `TEST` (Test Connection), plus `ANSWERED` for
`kind: "dismiss"`.

The relay turns that into:

```json
{
  "aps": {
    "alert": { "loc-key": "PUSH_REQUEST_FALLBACK" },
    "mutable-content": 1,
    "category": "REQUEST",
    "sound": "default",
    "interruption-level": "time-sensitive"
  },
  "e": "<sealed>"
}
```

with headers `apns-push-type: alert`, `apns-topic: <registration bundleID>` (`com.arnenoori.sidea.remote`, or `.dev` for Debug),
`apns-priority`, `apns-expiration`, `apns-collapse-id`, and `e` set to that device's envelope.
`loc-key` strings (`PUSH_REQUEST_FALLBACK`, `PUSH_QUESTION_FALLBACK`, `PUSH_PLAN_FALLBACK`,
`PUSH_FINISHED_FALLBACK`, `PUSH_LIMIT_FALLBACK`, `PUSH_HEALTH_FALLBACK`, `PUSH_ROTATION_FALLBACK`, `PUSH_TEST_FALLBACK`,
`PUSH_ANSWERED`) live in the
app's `Localizable.strings` ("Side A needs you", "A session finished"), so even the fallback text
is the app's, and a stolen install key can make a phone show only those fixed strings.

`kind: "liveactivity"` takes `{event: "start"|"update"|"end", activityId?, contentState,
staleDate?, dismissalDate?, relevance?}`; the relay sends `apns-push-type: liveactivity`,
`apns-topic: <bundleID>.push-type.liveactivity`, and for `start` the
push-to-start token, `attributes-type: "MacActivityAttributes"`, `attributes: {macID}` (computed
by the relay from the install id, protocol's formula) and the generic alert iOS requires on a
start (`ACTIVITY_START_TITLE`, `ACTIVITY_START_BODY` loc-keys). `contentState` is validated
against protocol's fixed schema (counts, `topRequest` as an opaque id, `soonestReset` as a number
of seconds since 2001, ActivityKit's default `Date` decoding, `tightestPercent` 0 to 100) and
anything else is rejected.

`kind: "dismiss"` takes `{collapseId}` and sends a passive, silent alert with that collapse id and
the `ANSWERED` category: "Answered on Mac" replaces the request on the Lock Screen.

Per-device results: `ok`, `gone` (token unregistered; Mac shows "iPhone stopped receiving
notifications, open Side A Remote"), `retry` (with seconds), `rejected` (with APNs reason, a bug
on our side), `unverified` (the token hasn't answered its challenge yet).

### Storage

**Recommendation: one SQLite-backed Durable Object per install** (`idFromName(installId)`),
plus the Workers Rate Limiting binding for limits keyed by IP.

| | Fits | Doesn't |
|---|---|---|
| KV | Cheap reads | Eventually consistent (a revoke or a 410 can take a minute to stick), one write per second per key, no atomic counters |
| D1 | SQL, one database | One primary region far from most Macs, counters need care, nothing per install to serialize on |
| **Durable Object (SQLite)** | Strongly consistent, single-threaded per install (no races between a send and a revoke), counters and nonces in one persisted row, alarms for cleanup, colocated near the Mac | Each object is isolated: no query across installs (none needed) |

Tables inside each object:

```sql
install(install_id TEXT, public_key BLOB, created INTEGER, rotated INTEGER, last_send INTEGER, empty_since INTEGER)
devices(id TEXT PRIMARY KEY, apns_token TEXT, environment TEXT, secret_hash BLOB,
        push_to_start TEXT, app_version TEXT, token_updated INTEGER, gone_at INTEGER,
        verified INTEGER, challenge_hash BLOB, challenge_sent INTEGER)
activities(id TEXT PRIMARY KEY, device_id TEXT, update_token TEXT, created INTEGER)
state(id INTEGER PRIMARY KEY, data TEXT)   -- one row: nonces, limiter windows, cooldowns
```

Every signed request loads the `state` row, checks and records its nonce and limiter windows, and
writes the row back: about one row write per signed request, so limits and replay protection
survive eviction (Cloudflare drops in-memory state when an object leaves memory). A send also
updates `last_send` (at most once a day). An alarm runs daily: an install with no device for 30
days, or no successful send (`last_send`) for 90, is deleted with `deleteAll()`; an activity older
than 12 hours is dropped (iOS stops updating one after 8 hours and removes it from the Lock Screen
by 12). A send never uses one past 12 hours either: it deletes the expired ones first, so the
privacy page's 12 hours holds between alarms.

The Worker verifies the signature against the key it gets from the object, asks the object
whether the send is allowed and which tokens to use, makes the APNs requests itself (the HTTP/2
behaviour below is observed from Worker `fetch`, not yet from inside a Durable Object), then
reports `gone` tokens back to the object.

### Limits and abuse

| Limit | Value | Enforced by |
|---|---|---|
| New installs per IP (IPv6: per /64) | 10 per minute per location, 50 per day everywhere. A Mac already registered isn't counted or refused | Rate Limiting binding for the minute; the daily count in a `Ledger` Durable Object named by `HMAC(HMAC(RATE_KEY, day), network)`, deleted a day after the day ends |
| Tunnel upgrades per IP (IPv6: per /64) | 120 per minute per location | Rate Limiting binding, before any object wakes |
| Every other signed or bearer request per IP (IPv6: per /64) | 600 per minute per location | Rate Limiting binding, before any object wakes |
| Phone endpoints per device | 30 per minute | Durable Object `state` row |
| Sends per install | 60 per minute, 2,000 per day | Durable Object `state` row |
| Verification challenges per device | 1 per minute, 5 per hour, each valid 1 hour | Durable Object `state` row |
| Live Activity updates per activity | priority 10 at most 1 per 10 s and 60 per hour; beyond that, downgraded to priority 5 | Durable Object |
| Devices per install | 10 | Durable Object |
| Payload | `sealed` at most 3,000 characters; whole APNs payload under 4 KB | Worker |
| Global | `RELAY_PAUSED` variable stops all sends with 503 | Worker |

What a thief can do with an install key: send "Side A needs you" to that install's own verified
phones, within the limits. Registering someone else's known APNs token gets them nothing: the
token stays unverified because only the real phone receives the challenge. They can't write text
and can't read anything. Key rotation (`/installs/rotate`) and Revoke recover from it. App Attest on the phone is
a later hardening for the phone endpoints; the Mac is Developer ID, so it has no equivalent.

### APNs authentication

Token-based auth (required for Live Activity pushes). One key in the Apple Developer account,
team `NV46KL65S9`: if the portal offers environment and topic restrictions, choose
"Sandbox & Production" and leave it Team Scoped (all topics): Debug builds push to `com.arnenoori.sidea.remote.dev`. Secrets:

```sh
wrangler secret put APNS_KEY_P8      # the PEM contents of AuthKey_<KEYID>.p8
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID     # NV46KL65S9
wrangler secret put RATE_KEY         # 32 random bytes: keys the per-IP registration counter
```

Deploy step: set up Observability alerts on the `canary.page` and `apns.token_updates` counters.

Back up the `.p8` in the Personal 1Password vault as `Side A APNs key`; Apple lets you download it
once.

```ts
const der = base64ToBytes(env.APNS_KEY_P8.replace(/-----[^-]+-----|\s/g, ""));
const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
const iat = now - (now % 2400);                       // same iat in every isolate for 40 minutes
const input = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })) + "." +
              b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat }));
const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(input));
const jwt = input + "." + b64url(sig);                // Web Crypto returns raw r||s: already JWS form
```

Apple wants a token refreshed no more than once every 20 minutes and no less than once an hour.
Bucketing `iat` to 40 minutes keeps every isolate on the same token age without a shared cache;
the token is cached in module scope until its bucket ends. `403 ExpiredProviderToken` or
`InvalidProviderToken` re-mints once and retries; `429 TooManyProviderTokenUpdates` means the
bucketing broke and pages us (Observability alert).

### HTTP/2 from Workers

APNs speaks only HTTP/2. Checked 17 October 2026:

- Cloudflare's docs list outbound `fetch()` as HTTP/HTTPS with no protocol version promised.
- A workerd maintainer says (cloudflare/workerd#4841, open): workerd itself has no HTTP/2, but in
  production a Worker's `fetch()` goes through Cloudflare's proxy stack, which speaks HTTP/2 to
  the origin, so APNs from deployed Workers works. Locally (`wrangler dev`) it fails.
- Several published Workers APNs clients (cloudflare-apns2) rely on exactly this.
- `connect()` sockets can't help: they offer TLS but no ALPN, so no `h2` negotiation.

So it works today and isn't contractual. What we do about that:

1. **Canary.** A Cron Trigger every 15 minutes sends a push to a deliberately invalid token in
   each environment and expects `400 BadDeviceToken`. That proves HTTP/2, the JWT and the route
   without waking any phone. Two failures in a row page us.
2. **Local development** uses `wrangler dev --remote`, or a fake APNs in Vitest. Never conclude
   from local runs.
3. **Fallback, written down, not built:** a Cloudflare Container (or any small host) running a
   Go HTTP/2 client behind a service binding; the Worker keeps auth, storage and limits and
   forwards only the final APNs request. Build it only if the canary ever fails for real.

### APNs responses

| Status / reason | Relay does | Mac sees |
|---|---|---|
| 200 | Record `apns-id` in the response only | `ok` |
| 400 `BadDeviceToken` | If the token was registered for the other environment, flip once and retry; else mark gone | `gone` |
| 400 `TopicDisallowed`, `BadTopic`, `PayloadTooLarge`(413) | Nothing | `rejected` |
| 403 provider token errors | Re-mint JWT, retry once | `ok` or `retry` |
| 410 `Unregistered` | Delete the token **only if** it was registered before the 410's `timestamp` (a phone that re-registered since keeps its new token); for an activity token, drop the activity | `gone` |
| 429 `TooManyRequests` (per device) | Nothing | `retry` 60 s |
| 500, 503 | Up to 2 retries with backoff inside `ctx.waitUntil` | `ok` or `retry` |

The Mac drops a `gone` device from its push list until the phone reconnects and reports a token.

### Sandbox and production

The phone reports it, from its **build configuration**, not from a provisioning profile: App
Store builds have no `embedded.mobileprovision` to read. Each configuration's xcconfig sets an
Info.plist key `SideAPushEnvironment` alongside the entitlement it signs with: Debug (Xcode, the
`aps-environment` entitlement is `development`) → `sandbox`; Release, exported for TestFlight and
the App Store (entitlement `production`; TestFlight uses production APNs) → `production`. The
entitlement's `development` maps to the relay's `sandbox` explicitly, and the relay accepts
`development` as an alias. The relay routes each device to `api.sandbox.push.apple.com` or
`api.push.apple.com`; a `BadDeviceToken` flips the environment once as a safety net. One key
serves both. The staging Worker is for changes to the relay, not for sandbox tokens.
Registration is checked separately on a development build, a TestFlight build and the App
Store build before each is released: a test push (`TEST`) must arrive on each.

## Encryption

### Key exchange at pairing

Pairing runs over Side A's own pinned TLS with a one-time code and a six-digit comparison code;
its schema and flow are protocol's [Pairing](protocol.md#pairing-hello-capabilities). The relay
isn't in the pairing path at all. What this file adds is the push key:

1. The phone sends `devicePublicKey` (X25519), `deviceID` and `deviceSecretHash` in `PairRequest`;
   the Mac answers with its own per-device `macPublicKey` (`PairPending`) and, in `PairResponse`,
   `relay: {url, installID, keyID}`.
2. Both compute
   `key = HKDF-SHA256(ikm: X25519(shared), salt: SHA-256(macPub ‖ devicePub ‖ installId ‖ deviceId), info: "SideA Remote push v1", 32 bytes)`
   and a 4-byte `keyId` (first bytes of SHA-256 of the salt).
3. Both throw away their X25519 private keys. Only the symmetric key is kept: on the phone in the
   shared keychain group (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the extension can
   read it on a locked phone and it never syncs or backs up), on the Mac in the Keychain.
4. When the phone first reports its tokens (`POST /v1/devices/push`), the Mac registers the device
   with the relay (`PUT /devices/{deviceId}` with `secretHash`), and the relay's verification push
   confirms the token.

The shared secret never leaves the two devices.

### Envelope

ChaCha20-Poly1305 (`ChaChaPoly` in CryptoKit; constant time without AES hardware and one choice on
both ends). AES-GCM would do as well; we pick one and version it.

```
sealed[deviceId] = base64url( 0x02 ‖ keyId(4) ‖ nonce(12) ‖ ciphertext ‖ tag(16) )
AAD              = 0x02 ‖ keyId ‖ len‖category ‖ len‖collapseId ‖ len‖deviceId
```

Each `len` is a 2-byte big-endian length of the UTF-8 that follows, so no bytes can move between
fields. Version 1 (`0x01`, fields joined bare) is retired: the phone refuses it
(`PushEnvelope.Failure.version`, then the generic text with Open only) and the relay accepts only
v2. Fixtures: `PushVector.request-v2.json` and `Envelope.request-v2.bin` (computed in Node), and
the frozen v1 pair, kept to prove v1 fails closed.

One envelope per device, each under that device's key. The AAD binds the plaintext fields APNs
needs to the ciphertext: the relay can't move a sealed `FINISHED` payload under a `REQUEST`
category (which has an Allow button), or replay it under another request id, or deliver one
device's payload to another.

The plaintext is protocol's `PushPayload` (at most 2,048 bytes before sealing). It carries
everything the notification shows, including a question's options and a plan's text when they
fit; when they don't, the payload says `full: false` and the notification opens the app instead
(protocol, Push payloads). The Mac generates request ids at random (they already are
`Pending.id`), so the plaintext `collapseId` says nothing about the session.

### What stays plaintext

| Field | Why it has to be | What it reveals |
|---|---|---|
| `mutable-content: 1` | Wakes the Notification Service Extension | Nothing |
| `category` | Actions appear even when decrypting fails; the extension could set it, but a failed decrypt would then lose Deny | Kind of event: request, question, plan, finished, limit, health, test |
| `apns-collapse-id` | "Answered on Mac" replaces the request | A random id |
| `alert.loc-key` | Shown if the extension fails or times out | One of the fixed strings |
| `sound`, `interruption-level`, priority, expiry | Delivery behaviour | Urgency |
| `thread-id` | Not sent; the extension sets the thread per project | |

### Notification Service Extension

```
didReceive(request, contentHandler):
  sealed = userInfo["e"]                          → none: deliver as is
  key    = keychain[keyId]                        → missing: "Open Side A Remote to reconnect"
  open ChaChaPoly with AAD from aps + deviceId    → fails: deliver the generic text, Open only
  content.title / subtitle / body  = payload
  content.threadIdentifier         = project
  content.relevanceScore           = needs-you ? 1 : 0.3
  content.userInfo["rid"], ["sid"], ["turnID"] = payload   (actions post with these)
  content.categoryIdentifier       = REQUEST_SAFE if category == REQUEST and payload.gate == lockScreen, else as sent
  content.interruptionLevel        = as sent
  shared.sqlite: store the decrypted payload by request id (Live Activity, Content Extension)
  contentHandler(content)
serviceExtensionTimeWillExpire: deliver whatever is decrypted so far, else the generic text
```

The extension does no networking: the whole message is in the payload, so a notification is
readable with Tailscale off; only its actions need the Mac. The Content Extension reads the
decrypted options from the shared store, so it needs no key. Action handlers that run without the
extension having run (rare) decrypt `e` themselves. Lock-Screen rules for actions (which need
unlock) are ios-app's (5.1).

The extension stays far under its 24 MB memory limit: CryptoKit and one JSON decode.

### Live Activity

A Live Activity push goes straight to ActivityKit. No service extension runs, so whatever is in
`content-state` and the attributes reaches Apple and the relay as plaintext. The rule:
**content-state holds counts, times and opaque ids, never words**, and the attributes hold only
`macID`, a hash of the install id. The schema is protocol's `MacActivityAttributes`
(`working`, `waiting`, `topRequest?`, `soonestReset?`, `tightestPercent?`); the relay validates it.

The words ("Bash in side-a needs you", Allow and Deny on the right request) come from the regular
encrypted alert for the same request: the Notification Service Extension writes the decrypted
request, keyed by its id, to the App Group store, and the widget's view looks `topRequest` up
there. If it isn't there (alert not delivered yet, phone just rebooted), the activity says
"1 needs you" and its buttons open the app. Allow appears only when the cached request's gate is
`lockScreen` (ios-app 5.4). Decrypting inside the widget's view body would also work technically,
but nothing in ActivityKit promises the view code runs with keychain access at render time; the
App Group lookup degrades better.

**Lifecycle**, driven by the Mac:

- **Start:** a push-to-start (iOS 17.2+) when the Mac goes from nothing working or waiting to
  something, if the phone's `NotificationPrefs.liveActivity` is on and it has no live activity
  for this Mac. iOS launches the app in the background with the new activity's update token,
  which it reports to the Mac and to the relay (`PUT /device/activities/{id}`), again on each
  connection, new device token and proof, since the relay drops activities with a device's token. With
  `NotificationPrefs.liveActivity` off the phone ends any activity it has at once.
- **Update whenever any displayed field changes**, not only counts: `working`, `waiting`,
  `topRequest` (request A replaced by request B with one still waiting is an update),
  `soonestReset` and `tightestPercent`. Priority 10 when something starts waiting (within the
  relay's 1 per 10 s and 60 per hour), else priority 5.
- **Expiry.** iOS ends an activity's updates after 8 hours (it can stay on the Lock Screen up to
  12). The Mac tracks each activity's start; at 7 h 45 m, if the Mac is still busy, it ends the old
  one (`end` with an immediate `dismissal-date`) and push-to-starts a replacement, so a Mac that
  is busy all day never shows a frozen activity.
- **Token turnover.** A new update token for the same activity replaces the old one at the Mac and
  the relay; an `Unregistered` 410 for an activity token drops that activity, and the Mac starts a
  new one on the next change.
- **Dismissal.** If the user swipes it away, the app reports `DELETE /device/activities/{id}` (and
  to the Mac); the Mac doesn't start another until the Mac next goes idle and busy again.
- **End:** `end` with `dismissal-date` when nothing has worked or waited for 15 minutes.

`NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates` in the app's Info.plist.

### Key rotation and unpairing

- **Push key.** On a connection where the key is older than 30 days, the phone runs the exchange
  again (`POST /v1/devices/rekey` on the Mac, protocol) and gets a new `keyId`. It keeps the
  previous key for 24 hours for pushes already in flight, then deletes it. No per-message
  ratchet: pushes are dropped and collapsed, so a ratchet would desynchronise, and the
  ciphertext is never stored anywhere we control.
- **Install key.** Rotated with `POST /installs/rotate` on Side A updates that ask for it and from
  a Settings > Remote action; also after a restore to a new Mac (the Keychain item is
  `ThisDeviceOnly`, so a migrated Mac registers a new install and asks the phone to re-pair).
- **Unpair** on either side deletes the push key on both, the device at the relay and the token.
  An app deleted from the phone stops at APNs's 410.

## Privacy

### What the relay can see

| Sees | Doesn't see |
|---|---|
| The Mac's and phone's IP addresses, at Cloudflare's edge, per request (not stored; registrations keep a keyed hash of the IP for up to 24 hours) | Session titles, commands, file paths, project names |
| Install ids and public keys, device ids | Account names or emails |
| APNs and Live Activity tokens, environment, app version | Transcripts, images, answers, replies, prompts |
| When and how often each install pushes, to how many phones | The Mac's name |
| Category of each push, its collapse id (a request or turn id, or for health and limit pushes a session or account id), its size | The pairing key |
| Tunnel metadata: device ids and secret hashes, when and how much crosses, which pushes and sockets go together | Tunnel plaintext: it is the phone's TLS to the Mac |
| Live Activity counts, reset time, tightest percentage | |

Apple sees the same as the relay minus the install key, plus what it always sees as the delivery
network.

### Logging

- Workers Logs on, head sampling at 100%, automatic invocation logs off (the relay's per-request line is the log), and the default retention. Logged per request:
  route, status, APNs reason, latency, and the first 6 characters of the install id. Never the
  body, a token, a secret, an IP address or a header.
- No Logpush, no Analytics Engine with identifiers. Counters (sends, `gone`, rejects, canary) go to
  Analytics Engine without install ids.
- Durable Object point-in-time recovery keeps 30 days of history by design; deleted installs
  disappear from it within 30 days. Say so in the policy.

### Privacy policy section (draft for the site)

The App Store needs a privacy policy URL, so this becomes a page at `getsidea.com/privacy` (see
Site), with the existing website text kept above it.

> **Side A Remote (iPhone app)**
>
> Side A Remote talks to Side A on your Mac directly, over your own Tailscale network. Your
> sessions, transcripts, images, answers and account details go between your phone and your Mac
> and nowhere else. We don't run a server that sees them.
>
> **Notifications.** To notify you when your Mac isn't reachable directly, your Mac sends each
> notification through our push relay to Apple's Push Notification service. Before it leaves
> your Mac, the notification is encrypted with a key that only your Mac and your phone have; our
> relay and Apple can't read it. The relay stores, for each paired phone: a random identifier for
> your Mac and for your phone, your Mac's public key, the push tokens Apple gives the app, and
> whether it's a development or App Store build. It doesn't store your IP address or the
> contents or history of notifications. To stop abuse, the relay keeps a keyed hash of the
> connecting IP address for up to 24 hours; it is never logged or linked to an install. Live Activity updates carry only counts (sessions
> working and waiting), the time of the next limit reset and its percentage, unencrypted, because
> iOS displays them without running app code first.
>
> **Retention.** Unpairing on either device deletes that phone's record at once. Records for
> phones that stop receiving notifications are deleted automatically, and backups of deleted
> records expire within 30 days.
>
> **Analytics.** The app collects no analytics and contains no third-party SDKs. If you choose to
> share crash reports with developers in iOS settings, Apple provides them to us without
> identifying you.
>
> **Processors.** Cloudflare runs the push relay; Apple delivers notifications. Tailscale carries
> your Mac-to-phone traffic under your own Tailscale account and its policy.
>
> Questions: privacy@getsidea.com.

### App Store privacy label

| Question | Answer |
|---|---|
| Do you or your partners collect data from this app? | Yes |
| Identifiers → Device ID | Collected. Use: App Functionality. Not linked to the user's identity. Not used for tracking. (Push tokens and the random device id stored by the relay.) |
| User Content, Contact Info, Location, Usage Data, Diagnostics, Purchases, Financial, Health, Browsing, Search, Contacts, Sensitive Info | Not collected. Notification contents are end-to-end encrypted and the relay can't read them; Live Activity counts are relayed transiently and not stored. |
| Tracking | No |

`PrivacyInfo.xcprivacy` in the app and each extension: `NSPrivacyTracking` false, the Device ID
data type as above, and required-reason entries for `UserDefaults` (CA92.1, plus 1C8F.1 for the
App Group suite) and file timestamps (C617.1). Re-check against the shipped code; add any other
required-reason API it actually calls.

If we ever put words in Live Activity content-state, or add analytics, "User Content" or "Usage
Data" changes to Collected. That's the line to hold.

## App Store distribution

### Bundle ids and capabilities

Minimum iOS 26: the design is Liquid Glass throughout (remote.md, Design), and it drops version
checks for push-to-start.

| Target | Bundle id | Capabilities and entitlements |
|---|---|---|
| App | `com.arnenoori.sidea.remote` | `aps-environment` (Xcode writes `development`; export sets `production`), App Groups, Keychain Sharing, Time Sensitive Notifications (`com.apple.developer.usernotifications.time-sensitive`) |
| Notification Service | `com.arnenoori.sidea.remote.NotificationService` | App Groups, Keychain Sharing |
| Notification Content | `com.arnenoori.sidea.remote.NotificationContent` | App Groups |
| Widgets and Live Activity | `com.arnenoori.sidea.remote.Widgets` | App Groups, Keychain Sharing |

- App Group `group.com.arnenoori.sidea.remote`; keychain group
  `$(AppIdentifierPrefix)com.arnenoori.sidea.remote.shared`.
- There is no separate push-to-start entitlement: push-to-start needs `aps-environment`, the
  Live Activities Info.plist keys and token-based APNs auth.
- Info.plist: `NSFaceIDUsageDescription` (Allow on destructive requests), `NSCameraUsageDescription`
  (scan the pairing QR code, take a photo for a prompt), `NSSupportsLiveActivities`,
  `NSSupportsLiveActivitiesFrequentUpdates`, `ITSAppUsesNonExemptEncryption` (see Open questions),
  `NSLocalNetworkUsageDescription` (Wi-Fi addresses come from the QR code; there's no Bonjour).
- Associated Domains `applinks:getsidea.com`: the app takes `getsidea.com/pair#…` (Site), the form
  the Mac's QR code (format v2) shows since 0.5.47.
- Info.plist `SideAPushEnvironment` per configuration (Sandbox and production).

### App Review

The risk is Guideline 2.1 (completeness): a reviewer has no Mac running Side A and no tailnet,
so every screen is empty and every action fails. Also 5.2.1 (others' trademarks: no Claude or
OpenAI marks in the name, icon or screenshots; say "for Claude Code and Codex" in text only, as
the site does) and 2.3 (the listing must say a Mac with Side A is required).

**Demo mode, built in, visible to everyone.** Not a hidden reviewer switch (hidden features are
themselves a rejection under 2.3.1).

- The first screen has Pair with your Mac and, under it, **Try a demo**.
- The demo swaps the client's transport for `DemoServer`, an in-process implementation of the same
  `SideARemoteKit` client protocol, with a scripted Mac: two accounts with limit rings; a Claude
  session streaming a transcript with tool rows, a diff and an image; a Codex session waiting for
  approval; a question with three options; a plan to approve; a hosted terminal replaying a
  recorded session (predictive echo included).
- Notifications in the demo are local notifications with the real categories, so Allow and Deny
  from the Lock Screen work. The Live Activity is started locally (`Activity.request`), no push.
- A glass pill at the top says "Demo · nothing is connected" and Exit demo. Nothing in the demo
  touches the network.
- The same scripted data drives the App Store screenshots and the site's mock, and the iOS UI
  tests run against it, so it can't rot.

Review notes: what the app is for, that it needs Side A on a Mac, where Try a demo is, and a link
to a 60-second unlisted video of real pairing, an approval from the Lock Screen and a hosted
terminal. No demo account is needed because there are no accounts.

Smaller points: ask for notification permission after pairing (or on the demo's first
notification), not at launch; no sign-in means no account-deletion requirement, but Settings
offers Unpair all and Delete data anyway.

### TestFlight

| Stage | Who | Review |
|---|---|---|
| M0–M3 | Internal testers (team members, up to 100) | None; builds available minutes after processing |
| M4 beta | External group with a public link, posted on the site | Beta App Review for the first build of each version |
| Release | App Store, manual release after approval | Full review |

TestFlight builds use production APNs, so the production relay path is exercised from the first
internal build. Builds expire after 90 days. "What to Test" comes from `releases/ios-vX.Y.Z.md`.

### `scripts/ios-release.sh`

Replaces the `scripts/ios-testflight.sh` named in remote.md's layout. Same shape as
`scripts/ship.sh`: run from an up-to-date `main`, refuse anything else, one command.

```bash
#!/usr/bin/env bash
# Archives Side A Remote and uploads it to App Store Connect (TestFlight). Run from an up-to-date main
# after the version bump and releases/ios-vX.Y.Z.md have merged.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(yq '.settings.base.MARKETING_VERSION' apps/ios/project.yml)
tag="ios-v$version"
build=$(date -u +%Y%m%d%H%M)                      # monotonic, never collides, no file to bump
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Check out an up-to-date main first." >&2; exit 1; }
[[ -f "releases/$tag.md" ]] || { echo "Missing releases/$tag.md." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag is already tagged; bump MARKETING_VERSION." >&2; exit 1; }

# App Store Connect API key: App Manager role with "Access to Cloud Managed Distribution Certificate".
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"   # op run --env-file=scripts/ios-release.env -- ./scripts/ios-release.sh
auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -allowProvisioningUpdates)

(cd apps/ios && xcodegen generate --quiet)
swift test --package-path Packages/SideAProtocol
xcodebuild test -project apps/ios/SideARemote.xcodeproj -scheme SideARemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
out="dist/ios/$tag"; rm -rf "$out"; mkdir -p "$out"
xcodebuild archive -project apps/ios/SideARemote.xcodeproj -scheme SideARemote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/SideARemote.xcarchive" \
  CURRENT_PROJECT_VERSION="$build" "${auth[@]}" -quiet
xcodebuild -exportArchive -archivePath "$out/SideARemote.xcarchive" -exportPath "$out" \
  -exportOptionsPlist apps/ios/ExportOptions.plist "${auth[@]}"    # method app-store-connect, destination upload
git tag "$tag" && git push -q origin "$tag"
echo "Uploaded Side A Remote $version ($build). It appears in TestFlight after processing; add it to the external group there."
```

- Cloud-managed signing: no `.p12` on disk, unlike the Mac's Developer ID flow. The API key is a
  new one, `Side A App Store Connect` in the Personal vault, separate from the notary key in
  [distribution.md](../distribution.md#setup), with its own expiry note.
- Later, the same script runs on the `side-a-release` runner through a manual `ios-release.yml`
  workflow, as the Mac does. Not before the local flow has shipped twice.
- Adding the build to the external TestFlight group and submitting for review stay manual in App
  Store Connect until releases are routine; then one API call each.

### Versions and capabilities

The two apps version independently (the phone starts at 1.0 while the Mac is at 0.5.x). They
agree through the protocol, not through version numbers. `GET /v1/hello` is protocol's `Hello`
(`protocolVersion`, `minProtocol`, `maxProtocol`, `capabilities`, `minClientBuild`, …) with
protocol's capability names; protocol's Versioning section has the rules. What this file adds:

- **Additive change → new capability.** The phone hides what the Mac can't do and says why:
  "Update Side A on your Mac to start sessions from here", with an Update button that calls
  `POST /v1/update/check` (Sparkle's check) when `update.check` is listed.
- **Breaking change → protocol bump.** The Mac serves protocol N and N−1 for at least six months,
  because App Review and slow phone updates put the phone behind.
- **Order:** the Mac ships first (Sparkle reaches users in hours), the phone after review.
- The push envelope (`0x02`; `0x01` retired), the relay API (`/v1`) and the Live Activity content state each carry
  their own version and follow the same rules.

### Site download section

`site/index.html` is a single page with a hero download button and a closing `cta` section; the
privacy text is a dialog. Changes, all within the existing CSP (`img-src 'self' data:`, no third
party scripts):

- **A new section before `trust-strip`:** "Side A Remote", one line ("Answer Claude Code and Codex
  from your iPhone, through your own Tailscale network."), a phone screenshot from the demo data,
  and:
  - Apple's official "Download on the App Store" badge, unmodified, self-hosted as
    `site/public/app-store-badge.svg` (Apple's marketing guidelines: artwork as provided, minimum
    height 40 px), linking to the App Store URL.
  - On desktop (`@media (hover: hover) and (min-width: 720px)`), a QR code to the same URL next to
    the badge, generated at build time into an inline SVG by a small script beside
    `prepare-discovery.mjs`. On a phone the badge is the link and the QR code is hidden.
  - The requirements line, in the style of the existing one: "Requires iOS 26+, Side A on a Mac,
    and Tailscale on both."
  - "New to it? Follow the setup guide." linking the `/remote` guide ([setup](setup.md#website)).
  - Before approval: a TestFlight public link labelled "Join the beta", or "Coming soon" with no
    link, driven by one field in `site/src/release.mjs` so the switch is one line.
- **`/privacy` page:** `site/privacy/index.html`, added to `rollupOptions.input` in
  `vite.config.ts` like `how/index.html`. The footer's Privacy button keeps its dialog and gains a
  link to the full page. App Store Connect gets `https://getsidea.com/privacy`.
- **Machine-readable copies:** a `companions` entry in `site/public/product.json`
  (`{name, platform: "iOS 26+", url, requires}`), a paragraph in `site/public/index.md` and
  `llms.txt`, and the page in `sitemap.xml`.
- **Universal-link pairing.** The Mac's pairing QR code encodes `https://getsidea.com/pair#…`
  (protocol, QR format v2); scanning it with the Camera opens the app when installed and otherwise
  opens `/pair`, which shows the App Store badge and loads no analytics ([setup](setup.md#pair)).
  The fragment never reaches Vercel. Needs `site/public/.well-known/apple-app-site-association`
  with an `application/json` content-type rule in `vercel.json` and `_headers`.

## Cost

Assumptions per active user per day: 40 alert pushes, 60 Live Activity updates, 2 token or
device calls. Each push is one Worker request and two Durable Object requests (the signed check
and plan, then the report of results), about 2 ms of CPU (signature check plus, once per 40
minutes, a JWT signature), and about one row write (the `state` row).

| Active users | Worker requests / month | Workers ($5 plan incl. 10M req, 30M CPU-ms) | Durable Objects (1M req incl., $0.15/M) | Total / month |
|---|---|---|---|---|
| 100 | 0.3M | $5.00 | $0 | **$5** |
| 1,000 | 3.1M | $5.00 | $0.80 | **$6** |
| 10,000 | 31M | $5 + $6.20 req + $0.60 CPU | $9 + $0 rows (inside 50M) | **$21** |
| 50,000 | 153M | $5 + $43 req + $5.50 CPU | $46 + $103 rows | **$203** |

- Durable Object duration stays inside the included 400,000 GB-s (requests of a few ms at
  128 MB); SQLite storage is kilobytes per install against 5 GB included; rows read are free at
  this scale; rows written are about one per signed request (50M included, then $1 per million).
  Persisting nonces and limiter windows, plus the second Durable Object request, adds roughly
  $1.15 per million pushes; that is the price of limits and replay protection that survive
  eviction.
- APNs: free. Apple Developer Program: $99 a year, already paid for Developer ID. Domain and DNS:
  already paid. Canary: about 3,000 invocations a month.
- The Free Workers plan would cover the first hundred users, but it fails hard at its daily
  limits and caps CPU at 10 ms per request; start on the $5 plan.
- Prices from Cloudflare's Workers and Durable Objects pricing pages, checked 17 October 2026.

## Open questions

1. **HTTP/2 isn't documented.** APNs from Workers works because of Cloudflare's proxy behaviour,
   not a promise. Is the canary plus a written fallback enough, or do we ask Cloudflare for a
   statement before shipping publicly?
2. **Export compliance.** The app uses CryptoKit for end-to-end payload encryption, beyond HTTPS.
   Setting `ITSAppUsesNonExemptEncryption` to NO is probably defensible (OS-provided, standard
   algorithms, mass market), but confirm before the first external TestFlight build.
3. **Live Activity broadcast channels.** iOS 18+ can start an activity bound to a broadcast
   channel, which would remove the per-activity update token round trip. Is a channel per install
   within Apple's intended use and limits? If yes, it simplifies the phone path.
4. **Category in the clear.** Encrypting the category too (the extension sets it) hides the kind
   of event from the relay, at the cost of no action buttons when decryption fails. Worth it?
5. **Universal-link pairing.** The site serves the association file and the app takes the link;
   the Mac shows it since 0.5.47. Still to confirm on a phone: a Camera scan opens the app rather
   than Safari when it's installed.
6. **Privacy label edge.** Whether relayed Live Activity counts count as "collected" under Apple's
   definition (transient, not stored). The draft says no; a reviewer could disagree.
7. **Contact address.** `privacy@getsidea.com` doesn't exist yet; Cloudflare Email Routing to the
   existing inbox would do.

## References

- [cloudflare/workerd#4841](https://github.com/cloudflare/workerd/issues/4841): APNs over
  HTTP/2 from Workers works in production, not locally.
- [FiveSheepCo/cloudflare-apns2](https://github.com/FiveSheepCo/cloudflare-apns2): a Workers APNs client.
- Cloudflare: [Protocols](https://developers.cloudflare.com/workers/reference/protocols/),
  [TCP sockets](https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/),
  [Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/),
  [Rate Limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/),
  [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
  [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).
- Apple: [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
  [Establishing a token-based connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns),
  [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns),
  [Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications),
  [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications),
  [App privacy details](https://developer.apple.com/app-store/app-privacy-details/),
  [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
