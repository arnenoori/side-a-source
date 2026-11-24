# Phase 0 results: Side A on Linux

Status: the Swift spike the [PRD](windows-linux-prd.md) asks for is done for Linux. Everything below was run on
2026-11-23/24 with `swift:6.2-noble` (Swift 6.2.4) in Docker on an Apple-silicon Mac (linux/arm64 native; see
[Architectures](#architectures) for amd64) and on macOS with Xcode's Swift 6. Nothing here was run on Windows.

## What builds and passes on Linux

One command runs all of it, in Docker from a Mac or with `--here` on a Linux box (what CI does):

```
scripts/linux-check.sh            # Docker, this machine's architecture
scripts/linux-check.sh --amd64    # Docker, linux/amd64 under emulation
scripts/linux-check.sh --here     # on Linux with Swift 6 installed
```

| Step | Command (inside the container) | Linux | macOS, same code |
| --- | --- | --- | --- |
| Protocol package, fixture conformance included | `swift test --package-path Packages/SideAProtocol` (targets `SideAProtocol`, `SideAProtocolFixtures`) | 69 tests pass | 76 pass; the 7 extra are the tunnel mux tests, which need Network.framework. `SideARemoteKitTests` add 198 on macOS only |
| SideACore | `swift test` at the root (`SideACoreTests`) | 188 tests pass | 217 pass |
| `sidead` spike | `swift test --package-path Daemon` | 5 tests pass | 5 pass |
| `sidead` binary | `swift build --package-path Daemon` then run it | starts, stays up, prints its pin | same |

The fixture suite (`FixtureTests`, `fixturesAreFrozen`, and every `Wire*`, `Push`, `Confirm` and `Rotation` test that
reads `SideAProtocolFixtures`) is the conformance proof: the same JSON, MANIFEST hashes, ECDSA and ChaCha vectors decode
and verify on Linux through swift-crypto exactly as on macOS through CryptoKit.

### What changed to get there

- **`Packages/SideAProtocol`**: `import CryptoKit` became `#if canImport(CryptoKit) … #else @preconcurrency import Crypto
  #endif` in `Pairing`, `Confirm`, `Push`, `WebSocketFrames` and four test files. `Tunnel.swift` keeps the portable
  `TunnelFrame` and `TunnelControl`; `TunnelMux` (NWConnection) moved to `TunnelMux.swift` under `#if canImport(Network)`,
  and its seven tests with it. The manifest is split by host: on a Mac it is unchanged (no new dependency, no
  `Package.resolved` change, the iOS app's graph is unchanged: checked in `apps/ios/.../Package.resolved`); on any other
  host it adds swift-crypto and drops `SideARemoteKit` and its tests.
- **Root `Package.swift`**: same split. On a Mac, exactly what it declared before plus a `SideACore` library product
  (needed by `Daemon/`). On Linux: `SideACore` with swift-crypto, and `SideACoreTests`. Sparkle, the helpers, `CSideAPTY`
  and `SideATests` are Mac-only.
- **SideACore fences** (not rewritten):

  | File | Fence | Left to port |
  | --- | --- | --- |
  | `PoolProxy.swift`, `PoolProxy+Retry.swift` | `canImport(Network)` | NWListener proxy: SwiftNIO |
  | `PoolHelper.swift` (`PoolFiles`, `PoolFallback`, `PoolHelper`), `PoolTokenCache.swift` | `canImport(Network)` | follow the proxy. `PoolPlan` and `PoolBridge` (process spawn) stay portable |
  | `Remote/AppServerClient.swift` | `canImport(Network)`; `AppServerFailure` moved out so `CodexAppServer`'s parser compiles | WebSocket over the Codex app-server's Unix socket: NIO |
  | `Processes.swift` (`ProcessCheck`) | `canImport(Darwin)`; `BridgeDeadline` stays | `/proc/<pid>/stat` start time |
  | `Memory.swift`, `ProcessEnvironment.swift` | `canImport(Darwin)` | `/proc` |
  | `Remote/RemoteAddresses.swift` | only `current()` (getifaddrs with `sa_len`) is `canImport(Darwin)`; `classify`, `isTailnet` stay | Linux interface names (`tailscale0`, `eth*`/`en*`) and `sa_family`-based length |
  | `KeepAwake.swift` | none: only `kill`/`errno` needed; `import Darwin` is now conditional | logind inhibitor (D-Bus) |

  Small real changes: `Secret.bytes` uses `SystemRandomNumberGenerator` off Apple (was `SecRandomCopyBytes`);
  `Processes.swift` `sysconf(Int32(_SC_NPROCESSORS_ONLN))` (Int32 on Darwin, Int on Glibc);
  `Hosting.swift`'s effort-picker closure was split because the Linux type checker timed out on it.
- **SideACore tests fenced**: `KeepAwakeHelperTests` (`SideAKeepAwakeCore`, Mac-only), `MemoryTests`, `ProcessCheckTests`,
  `ProcessEnvironmentTests`, `PoolHelperTests`, one test in `HostingPromptTests` (PoolProxy), and
  `SelfSignedCertificateTests` (uses `SecCertificate`; it needs a Linux re-expression with swift-certificates, which the
  daemon's identity code already uses). That is 29 fewer tests than macOS.
- **Compiler differences** worth knowing: `Data([0x82, 0x80 | 127, …])` needs `as [UInt8]` on Linux (two test files);
  swift-crypto's `SymmetricKey` is not `Sendable`, hence `@preconcurrency import Crypto`; `stdout` is a Swift 6 global
  error on Linux, so the daemon writes with `FileHandle`.

### Not done at the package boundary

`SideACore` is still missing on Linux: the pool proxy, the Codex app-server client, process and memory listing, address
enumeration, the keep-awake inhibitor. `Sources/SideA` (the app, about 30k lines) and `SideARemoteKit` are not touched;
phase 1 (the shared-core refactor) is where the Remote server and routes leave the app target. `CSideAPTY` has not been
tried on Linux (`forkpty` needs `-lutil` on older glibc).

## The spike: `sidead`

`Daemon/` is a separate package (`SideADaemon`: library `SideADaemonKit`, executable `sidead`, tests). It is separate on
purpose: SwiftNIO, NIOSSL and swift-certificates are in no Mac or iOS dependency graph, and `swift build` at the root
never sees them. It reaches the repository root through `Daemon/Dependencies/side-a`, a symlink to `../..`: a path
dependency's identity is its directory name, which differs in every worktree and CI checkout, and `.product(package:)` is
mandatory. SideACore re-exports SideAProtocol, so the protocol package arrives with it.

- `GET /v1/hello` answers a `Hello` from the protocol package with `MacInfo` as it is today (id: first 8 bytes of
  SHA-256 of `/etc/machine-id`, else of the host name; name: host name), no capabilities, `minClientBuild` from
  `RemotePolicy`, `keyID` from `SPKI`. When `MacInfo` gains `os` and `headless`, `Routes.swift` is the one place to set them.
- **HTTP codec: SideACore's `HTTPParser` / `HTTPResponse` (Sources/SideACore/Remote/HTTP.swift), not NIOHTTP1.** It is
  pure, it already carries the protocol's refusals (no chunked bodies, no `Expect`, no folded headers, `..` segments,
  request and head limits, `Content-Length` only, `GET/POST/DELETE`), and it is the code the Mac's `NWListener` front
  runs, so a request parses the same way on both servers. A test asserts the refusals reach the wire (411, 400, 404).
  NIOHTTP1 would be a second parser to keep identical and it accepts what the protocol forbids. The cost was a 40-line
  `ChannelInboundHandler` that feeds `Data` to the parser. WebSocket upgrade will need the same treatment with
  `WebSocketCodec` (not spiked).
- **TLS**: NIOSSL, `minimumTLSVersion = .tlsv13`, ALPN `http/1.1`. Identity: P-256 key from swift-crypto and a self-signed
  X.509 v3 certificate from swift-certificates, made in-process in a few milliseconds (no `openssl`, no Keychain). The
  pin is `SPKI.hash(publicKey)` from the protocol package, the QR code's `fp`.
- **Tests** (`Daemon/Tests/SideADaemonTests/HelloTests.swift`) start the server on port 0 and use a NIO client that
  ignores the chain and host name and accepts only the pinned SPKI hash, as the phone does:
  hello over TLS decodes as `Hello`; a client pinning another key is refused; a TLS 1.2-only client is refused;
  unknown route 404, `Transfer-Encoding` 411, `/v1/../hello` 400; the key id equals the certificate's key hash.
  They pass on Linux arm64 and on macOS.
- The binary prints its pin and stays up: `sidead --port 47831` →
  `sidead 0.0.0-phase0 listening on https://127.0.0.1:47831 key 68fe7d5eac7d0d69 fp aP59…`.

Verdict for the PRD's phase-0 exit criterion: a SwiftNIO TLS 1.3 server with the protocol package builds and passes the
fixture suite on Linux. The Windows half of the gate is still open (below).

## Dependency versions

From `Daemon/Package.resolved` (macOS resolution; Linux resolves the same ranges and `Daemon/Package.resolved` is
copied into the container, so the daemon's pins are shared):

| Package | Range in manifest | Resolved |
| --- | --- | --- |
| swift-nio | from 2.80.0 | 2.105.1 |
| swift-nio-ssl | from 2.29.0 | 2.37.7 |
| swift-certificates | from 1.6.0 | 1.21.2 |
| swift-asn1 | from 1.3.0 | 1.7.5 |
| swift-crypto | from 3.15.1 | 3.15.1 |
| swift-atomics / -collections / -system | transitive | 1.3.1 / 1.7.6 / 1.9.0 |

`Packages/SideAProtocol` and the root package declare swift-crypto from 3.15.1 on non-Mac hosts only. They have no
committed pins for it: the container works on a copy so `Package.resolved` is never written into the checkout. Pin them
(commit a Linux-generated `Package.resolved` for each) when a release depends on it.

Toolchain: Swift 6.2.4, `swift:6.2-noble` (Ubuntu 24.04). Tools version 6.0 in all manifests, Swift 6 language mode,
no warnings suppressed beyond the `@preconcurrency` imports.

## Architectures

linux/arm64 (native): everything above passes. linux/amd64, under Docker's emulation on the Apple-silicon Mac:
the protocol package (69 tests) and SideACore (188 tests) build and pass, identical counts. The `Daemon` build did not
finish there, twice: SwiftPM stopped with `failed parsing the Swift compiler output: unexpected JSON message` while
compiling swift-collections, which is an emulation fault in the toolchain's parallel build output, not a source error.
The daemon is therefore untested on x86_64 until the `ubuntu-24.04` job in `linux.yml` runs on real hardware.
Try `swift build -j 1` in the container if the emulated run is needed.

## PRD "(verify)" items

Settled from official documentation (read 2026-11-23) or by running something:

| PRD item | Result | Source |
| --- | --- | --- |
| Where Claude Code keeps logins on Linux and Windows | Linux: `~/.claude/.credentials.json`, mode 0600. Windows: `%USERPROFILE%\.claude\.credentials.json`, inheriting the profile folder's ACL. macOS: Keychain, falling back to the same file when the Keychain rejects the write | [Authentication, Credential management](https://code.claude.com/docs/en/iam) |
| Does `CLAUDE_CONFIG_DIR` move `.credentials.json`? | **Yes.** "If you've set the `CLAUDE_CONFIG_DIR` environment variable, Claude Code keeps the `.credentials.json` file under that directory instead", and keys the macOS Keychain entry to that directory too. The directory also holds "settings, session history, and plugins" | same; [Environment variables](https://code.claude.com/docs/en/env-vars) |
| Does `CLAUDE_SECURESTORAGE_CONFIG_DIR` move the file without moving settings? | **Not documented.** The name appears in neither half of the env-vars page nor in the authentication page. Treat it as an undocumented macOS-Keychain implementation detail; do not rely on it on Linux. The supported multi-account mechanism is one `CLAUDE_CONFIG_DIR` per account, which gives each account its own settings, history and plugins, so Linux account selection is the "redesign" outcome the PRD feared (hooks, settings and sessions per account directory, or symlinks of the shared parts) | same |
| How Claude Code runs `statusLine` commands on native Windows | Through Git Bash when installed, else PowerShell. Backslashes in the command path are eaten by Git Bash (use forward slashes). `powershell -NoProfile -File C:/Users/…/statusline.ps1` works under either | [Status line, Windows configuration](https://code.claude.com/docs/en/statusline) |
| Which shell runs hook commands on native Windows | `sh -c` on macOS and Linux; Git Bash on Windows, PowerShell when Git Bash is missing. A per-hook `shell` field takes `"bash"` or `"powershell"`. An `args` form runs an executable with no shell (a real `.exe`; `.cmd` shims need shell form) | [Hooks](https://code.claude.com/docs/en/hooks) |
| Codex login storage | `~/.codex/auth.json` under `CODEX_HOME` for `file`; `keyring` and `auto` (OS store, else file) and `ephemeral` also exist. The page does not state the default and says nothing about Windows storage, so Side A forcing `file` stays right | [Codex authentication](https://learn.chatgpt.com/docs/auth) |
| tmux 3.4+ on distros | Debian 12: 3.3a (too old). Ubuntu 22.04: 3.2a (too old). Ubuntu 24.04: 3.4 (ok). Confirmed with `apt-cache policy tmux` in the stock images, so the PRD's "bundle a static tmux" holds | run in `debian:12`, `ubuntu:22.04`, `ubuntu:24.04` |
| Python for the bridge | Debian 12: 3.11.2, Ubuntu 22.04: 3.10.6, Ubuntu 24.04: 3.12.3 (all have `tomllib` except 22.04's 3.10, which is below the bridge's preferred 3.11). The swift:noble image itself has no Python | same |
| swift-crypto is API-compatible for the pure parts | Yes for everything in `SideAProtocol` and `SideACore` (HKDF, ChaChaPoly, AES-GCM, SHA-256, P-256 and Ed25519 signing, `SymmetricKey`), as the fixture suite shows. The one difference is that `SymmetricKey` is not `Sendable` | tests |
| Swift Foundation on Linux for the pure parts | `Foundation` is enough for the whole protocol package and for SideACore. No `FoundationNetworking` import was needed: URLSession types appear only in fenced pool code | build |
| SwiftNIO on Windows | **Not settled.** The swift-nio README says it "aims to support all of the platforms where Swift is supported" and is "developed and tested on macOS and Linux"; Windows is not named. Needs the spike run on a Windows runner | [swift-nio README](https://github.com/apple/swift-nio) |

Not settled, and why (nothing here could be checked from documentation or in the container): session registry
`~/.claude/sessions/<pid>.json` on Windows; Codex's shared app-server on native Windows; `AF_UNIX` in CPython on Windows;
logind lid-switch inhibitors and polkit on desktops; GNOME GlobalShortcuts and restore tokens; OpenH264 licensing and
Flathub policy; MSIX redirection, SmartScreen, WinSparkle EdDSA; WSL interop from systemd; Windows power requests and
Modern Standby; FoundationNetworking WebSockets on Windows; KWallet's Secret Service on current KDE.

### The one that needs two real accounts: does a running Claude Code re-read `.credentials.json`?

Nothing in the documentation says whether a running session notices a changed `.credentials.json`. The docs describe
`/login`, `/logout` and automatic refresh of the stored login, and `CLAUDE_CODE_OAUTH_TOKEN` switching "the current
session to the new login" when `/login` runs, but not an external file change. On macOS Side A relies on sessions
re-reading their Keychain item about every 30 s. If the Linux CLI does not re-read the file, trades become "new sessions
follow Autopilot, running ones finish where they are" (PRD, open question 4). This is the test, to run by hand.

**Manual test (about 15 minutes, a throwaway Linux machine or container, two accounts you can sign out of)**

Use accounts A and B that hold no work, and a user with an empty `~/.claude`. Do not run it where Side A, or any other
tool, also manages these logins.

1. Install Claude Code. Make sure `echo $CLAUDE_CONFIG_DIR` is empty. Log in as **A**: `claude auth login`. Check
   `ls -l ~/.claude/.credentials.json` (mode `-rw-------`) and `claude auth status --text` shows A's account.
2. Log in as **B** into a separate directory: `CLAUDE_CONFIG_DIR=$HOME/b claude auth login`. Check
   `$HOME/b/.credentials.json` exists and `CLAUDE_CONFIG_DIR=$HOME/b claude auth status --text` shows B.
3. Start the session under test, in tmux so you can leave it: `tmux new -s t`, then `claude` in an empty directory. Run
   `/status` and write down the Email/Organization row (A). Send one short message so a request has happened. Leave it
   idle at the prompt.
4. In another shell, swap the files, do not copy (a copy leaves two live copies of a rotating refresh token):
   ```
   cd ~ && mv .claude/.credentials.json swap-a.json && mv b/.credentials.json .claude/.credentials.json && mv swap-a.json b/.credentials.json
   chmod 600 .claude/.credentials.json b/.credentials.json
   stat -c '%y %n' .claude/.credentials.json
   ```
5. Control: `claude auth status --text` in the other shell must now say B (a fresh process reads the file).
6. Watch the session. In the tmux session run `/status` at 10 s, 40 s, 90 s and 5 min after the swap, and write down
   the account each time. Then send a short message and run `/status` again. Note any new prompt, `/login` request or
   error.
7. Also record: did the file's mtime change (`stat`) without you touching it, meaning the session refreshed and wrote
   back; and did the session's account match the file's, or did it write A's login back over B's.
8. Put it back: swap again, or `/logout` and log in again. Sign out of both accounts on the machine when done.

Reading the result:

| Observation | Meaning for Side A |
| --- | --- |
| `/status` shows B within about a minute, no prompt | Trades work as on the Mac. Keep the 30 s polling assumption but record the observed delay |
| Shows A until the session restarts or a request fails and then B | Re-read happens on 401 or refresh only. Trades work lazily; say "takes effect on the next refresh" and measure the worst case |
| Shows A throughout, and the file reverts to A or is rewritten from memory | No re-read, and the session can overwrite a swap. Trades move nothing and are dangerous: ship Autopilot for new sessions only |

## Local environment notes

- Docker comes from OrbStack. `docker volume ls` shows `sidea-linux-work-arm64` and `-amd64`, the build caches for
  `scripts/linux-check.sh`; remove them with `docker volume rm`. Containers are `--rm`.
- `.github/workflows/linux.yml` is manual (`workflow_dispatch`) and runs the same script in a `swift:6.2-noble`
  container on `ubuntu-24.04` and `ubuntu-24.04-arm`. It has not run on GitHub; it passed `actionlint`, and the script
  passed `shellcheck`.
