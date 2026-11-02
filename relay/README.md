# sidea-push

The push relay for Side A Remote: a Cloudflare Worker that holds the APNs key and nothing worth
reading. The design is in `docs/remote/relay-and-release.md`. This file covers what the code
settles that the spec leaves open, and how to run it.

```sh
npm ci
npm test            # Vitest in the Workers runtime, with a fake APNs; never calls Apple
npm run typecheck
npm run check       # builds both environments with --dry-run; uploads nothing
```

`wrangler dev` can't reach APNs (workerd has no HTTP/2), so local runs only prove routing and
storage. `node scripts/smoke.mjs <url>` checks a running relay short of APNs. Deploying and
secrets are in `DEPLOY.md`, in the private repository.

## Wire details

- **Keys.** `publicKey` and `newPublicKey` are raw 32-byte Ed25519 keys (CryptoKit
  `rawRepresentation`) in base64url. Signatures are the raw 64 bytes. `installId` is base64url of
  the first 16 bytes of SHA-256(publicKey). `deviceId`s and nonces are 16 random bytes in base64url.
- **Device secret.** 32 random bytes. The phone's bearer is `d1.<installId>.<deviceId>.<base64url
  secret>`, and the Mac registers `secretHash` = base64url(SHA-256(raw secret bytes)).
- **Tokens** are hex. Each registration also says which app and which APNs host the token
  belongs to, with the phone's `PushRegistration` names: `bundleID` (default
  `com.arnenoori.sidea.remote`) and `apnsEnvironment`, which is `sandbox`, `production` or
  `development` (the entitlement's name, stored as sandbox). The older key `environment` is read
  when `apnsEnvironment` is missing, and production is the default. `PUT /v1/devices/{id}` and the
  phone's `PUT /v1/device/tokens` and `PUT /v1/device/activities/{id}` all take both. An activity
  that names neither uses its device's.
- **Routing.** A device's alert, background and push-to-start tokens go to `apns-topic: <bundleID>`
  (`<bundleID>.push-type.liveactivity` for Live Activities) at `api.sandbox.push.apple.com` or
  `api.push.apple.com`. One .p8 key signs for both. `bundleID` must be on `APNS_BUNDLES` (a var,
  comma-separated; by default the App Store app and `com.arnenoori.sidea.remote.dev`), and anything
  else is a 400.
- **Errors** look like the Mac's API: `{"error": {"code", "message", "retryable"}}`, plus
  `Retry-After` on 429 and 503. A clock more than 120 s off gets 401 `clock_skew`; use the
  response's `Date` to correct it.

## Checking an install

`GET /v1/installs/self`, signed like any Mac request, answers

```json
{ "registered": true, "devices": 2, "verified": 1, "activities": 0,
  "gone": [{ "device": "<id>", "reason": "DeviceTokenNotForTopic" }], "paused": false }
```

or 404 `not_found` for an install the relay doesn't know (never registered, deleted, or cleaned
up). `verified` counts devices that have proved their token and that APNs hasn't called gone.
`gone` lists devices whose token APNs dropped, with
APNs's reason (`Unregistered`, `BadDeviceToken` after trying the other host, or
`DeviceTokenNotForTopic`, which usually means a dev build's token registered under the App Store
`bundleID`, or the other way round). A device leaves the list when it brings a new token.
`paused` means sends are answering 503 `paused`. It spends a nonce, like any signed request.

## Verifying a device

Knowing a token isn't enough to get pushes onto it. `PUT /v1/devices/{id}` with a token the relay
hasn't seen for that device answers `{"verified": false}` and sends a silent push to the token:

```json
{ "aps": { "content-available": 1 }, "verify": { "install": "<installId>", "device": "<deviceId>", "challenge": "<16 bytes b64url>" } }
```

The app posts the challenge back with its bearer, `POST /v1/device/verify {"challenge"}` (204, or
403 `bad_challenge`). It should ignore a challenge for an install it isn't paired with. Until the
device is verified, sends to it return `unverified`. A new `apnsToken`, `bundleID` or environment from either side
needs a new proof. The outstanding challenge is dropped with the old token, and a proof only counts for
the token, app and host its challenge went to. Challenges last an hour and go out at most once a minute and 5 times an hour per
device; `PUT /v1/devices/{id}` again resends one.

## Send

`sealed` is an object from device id to envelope, because the AAD binds each envelope to one
device:

```json
{ "devices": ["<id>", "<id>"], "kind": "alert", "category": "REQUEST", "collapseId": "<request id>",
  "priority": 10, "expiresIn": 3600, "sound": true, "level": "time-sensitive",
  "sealed": { "<id>": "<envelope>", "<id>": "<envelope>" } }
```

Anything else in the body is a 400. Categories and the loc-key each one shows when the
Notification Service Extension can't run:

| Category | `loc-key` |
|---|---|
| `REQUEST`, `REQUEST_DESTRUCTIVE` | `PUSH_REQUEST_FALLBACK` |
| `QUESTION` | `PUSH_QUESTION_FALLBACK` |
| `PLAN` | `PUSH_PLAN_FALLBACK` |
| `FINISHED` | `PUSH_FINISHED_FALLBACK` |
| `LIMIT` | `PUSH_LIMIT_FALLBACK` |
| `HEALTH` (always passive) | `PUSH_HEALTH_FALLBACK` |
| `TEST` (always passive, 5 an hour per install) | `PUSH_TEST_FALLBACK` |
| `ANSWERED` (from `kind: "dismiss"`) | `PUSH_ANSWERED` |
| Live Activity start (title, body) | `ACTIVITY_START_TITLE`, `ACTIVITY_START_BODY` |

Live Activity `contentState` is exactly `{working, waiting, topRequest?, soonestReset?,
tightestPercent?}`. `soonestReset` is passed through as a number, so the Mac encodes it the way
ActivityKit's default `JSONDecoder` reads a `Date` (seconds since 2001-01-01). The start
attributes are `{macID}`, a hash of the install id. An `end` that APNs accepts forgets the
activity's token.

Per-device results: `ok` (with `apnsId`), `gone` (with APNs's `reason` when it just said so), `unverified`, `retry` (with `after` seconds), and
`rejected` (with APNs's `reason`).

## State and limits

Each install is one SQLite Durable Object. Nonces (5 minutes) and every rate-limit window live in
a single `state` row, so they survive eviction for one row write per signed request. A request does
all its awaiting (signature, hashing) before it reads that row, then reads, changes and writes it
without yielding, so concurrent requests can't both spend one nonce or overwrite each other's
counts. The last
successful send is written at most once a day. `POST /installs` is limited to 10 a minute per
network and location by the Rate Limiting binding, and to 50 new installs a day per network by a
`Ledger` Durable Object, which holds everywhere. A network is an IPv4 address or an IPv6 /64. Its
key is HMAC(HMAC(`RATE_KEY`, day), network), so it can't be reversed to an address, and the object
deletes itself a day later. A Mac already registered isn't counted or refused.

## Live Activity tokens

APNs can't challenge a push-to-start or update token, and nothing from Apple links one to a device
token. So a `Ledger` object per token (named by its hash) records the hash of the proven device
token that first used it, and a send to it from any other device answers `rejected` with reason
`TokenHeldByAnotherDevice`. A phone paired with two Macs has one device token, so both work. A claim
lapses after 14 days unused, so a phone whose device token changed gets back in. A new device token
or a re-pairing also drops the device's activity tokens, and a new device token drops its
push-to-start token until the Mac registers it again. `PUT /v1/device/activities/{id}` answers 403
`unverified` until the device has proved its own token.

What this can't do: someone who learned a token before its phone's first Live Activity can claim it
first. They'd reach that Lock Screen with counts until the claim lapses unused.

## Observability

One JSON log line per request: route (ids replaced by `:id`), status, error code, latency, and
the first 6 characters of the install id. Analytics Engine counts `send.<result>`,
`challenge.<result>` and `canary.ok|fail`, without ids. Alert on `canary.page` (the second
canary failure in a row in one environment) and `apns.token_updates` (APNs
`TooManyProviderTokenUpdates`, meaning the 40-minute JWT bucketing broke).
