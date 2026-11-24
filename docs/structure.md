# Repository structure and duplication audit

Status: audit and plan. Step 0 and the "Done now" items are in the tree; everything else is a proposal. Taken from the
tree after the Linux spike merged (`docs/ports/phase-0.md`). Counts are lines of Swift unless stated.

One repository ships six things: the Mac app, Side A Remote (iOS), the push relay, the website, and, coming, the Linux
daemon and the Windows port. Work is done mostly by coding agents in parallel worktrees, so the structure has two jobs
beyond tidiness: an agent should find the one place a rule or a constant lives, and two agents working on different
platforms should rarely touch the same file.

## 1. Where the code is today

```
Package.swift            root package: SideA (app), SideAPool, SideAKeepAwake(+Core), CSideAPTY, SideACore (library); host-conditional manifest
Sources/SideA            17,896 lines: SwiftUI/AppKit app AND the Remote server, routes and stores (Sources/SideA/Remote: 53 files, 12,408)
Sources/SideACore        4,331 lines + Remote/ 2,678: portable logic (planner, island risk, codecs, pairing, policy); fenced for Linux
Packages/SideAProtocol   wire types, frozen fixtures, SideARemoteKit (phone client; Apple only); host-conditional manifest
apps/ios                 xcodegen project over Packages/SideAProtocol
Daemon                   separate package; reaches the root through the symlink Daemon/Dependencies/side-a -> ../..
bridge                   Python; copied into Sources/SideA/Resources by scripts/sync-bridge.sh
relay, site              TypeScript, own package.json each
Tests/SideATests (38 entries), Tests/SideACoreTests (22), Packages/SideAProtocol/Tests, apps/ios/Tests, bridge/tests, relay/test, site/tests, scripts/tests
```

Of the 53 files in `Sources/SideA/Remote`, 30 (5,066 lines) import nothing Apple-specific and 23 (7,342 lines) import
AppKit, Network, Security, IOKit, ScreenCaptureKit, CoreImage, `os` and the like. The 30 are not yet portable, because
73 `@MainActor` annotations sit in the folder, but they are where the move starts.

## 2. Duplication audit

Ordered by risk of drifting. "Cheapest source" is the smallest change that makes drift impossible or loud.

### (a) Mac app and the Linux daemon

| What | Where | Size | Drift risk | Cheapest source |
| --- | --- | --- | --- | --- |
| Request handling is welded to the listener. `RemoteServer` holds the device table, stranger rate limit, idempotency, confirm gate, preview proxy and WebSocket upgrade (`Sources/SideA/Remote/RemoteServer.swift:247-640`) in the same class as `NWListener` and `NWConnection` (`NWListener` and `NWConnection` in 12 places, the rest of the file does not need them). The daemon's `Server.swift` (96 lines) has only the TLS and codec glue, so every route and rule it needs is missing, not duplicated yet. | `RemoteServer.swift` (947), `SocketFront.swift` (204) vs `Daemon/Sources/SideADaemonKit/Server.swift` | about 400 lines of handler logic to separate | Certain: the first daemon route copies logic from here | Split into `RemoteCore` (handle, auth, limits, idempotency, confirm, previews) and a listener protocol with an Apple (`NWListener`) and a NIO implementation |
| Self-signed P-256 TLS identity, written twice | `Sources/SideACore/Remote/SelfSignedCertificate.swift` (Security) vs `Daemon/Sources/SideADaemonKit/Identity.swift:28` (swift-certificates) | 72 + 52 | Low (both pinned by SPKI hash) | One implementation on swift-certificates in a portable target; phase-0 already fences the Apple test |
| Hello and host identity (`MacInfo`, capabilities, `minClientBuild`) | `Sources/SideACore/Remote/RemotePolicy.swift:10`, `Daemon/Sources/SideADaemonKit/Routes.swift:8` | small | Medium: a capability added for the Mac must be consciously omitted by the daemon | A `Capabilities` provider per host; one table of capability to platform in `RemoteCore` |
| Stores that the routes call (`AccountStore` 2,412 lines in 6 files, `SessionStore` 1,393, `HostedSessions` 1,165, `Island` 2,330) are `@MainActor` classes in the app target | `Sources/SideA/AccountStore*.swift`, `SessionStore*.swift`, `HostedSessions*.swift`, `Island*.swift` | about 7,300 | Blocks the daemon outright | `SessionCore` behind actors and platform protocols (step 11) |
| Platform calls with no seam: Keychain (`RemoteKeychain.swift`, 286), IOKit assertions, `ps`/`lsof`, `forkpty` (`TerminalHub.swift`), Tailscale CLI (`TailscaleStatus+CLI.swift`) | 23 Remote files | 7,342 | Each is a rewrite on the other OS | The `SideAPlatform` protocols (step 8). `KeepAwakeController` already does it for sleep (`SleepSystem` in `docs/architecture.md`): copy that pattern |

### (b) Mac app and iOS app

| What | Where | Drift risk | Cheapest source |
| --- | --- | --- | --- |
| Reset time: "in 2h 10m" within a day, weekday and hour after (Mac) vs "2:14", "Thu", "Oct 24" (phone) | `Sources/SideA/MenuPlayer.swift:330` `UsageBar.format`, `apps/ios/Shared/Formatting/Formatting.swift:42` `reset` | Intended to differ, but unwritten | A `SideAFormat` target in `Packages/SideAProtocol` holding each rule once, with a flag for the compact style |
| Token counts ("1.4M" vs "162k"), memory ("1.4 GB"), percent: the phone's comments say "as on the Mac" | `MenuPlayer.swift:344` `TokenCount.short` vs `Formatting.tokens`; `Sources/SideACore/Memory.swift:25` `gigabytes` vs `Formatting.memory`; `Formatting.percent` | High: two near-identical rounding rules, no test ties them | Same target; one test table both import |
| Elapsed and duration: "1h 5m" | `MenuPlayer.swift:306` `AccountUsageRow.duration`, `Sources/SideA/Remote/Transcription.swift:208` `elapsed`, `Formatting.swift:6` `elapsed(since:)`, `:19` `duration` | Medium | Same target |
| Window labels and "5-hour" / "Weekly X" naming | `Sources/SideACore/Models.swift:110-114` is the source; `Sources/SideA/SettingsView.swift:474-484`, `Sources/SideA/MenuPlayer.swift:230` and `Sources/SideA/AccountStore.swift:1164` strip the "Weekly " prefix again; `apps/ios/SideARemote/Demo/DemoData.swift:206` and `DemoSecond.swift:40` spell them as strings | Medium: a renamed window breaks three prefix strips | `UsageWindow.shortName` in `SideAProtocol`; demos build windows through the same init |
| Demo data: Mac `--demo` (`SetupView.swift:24`, `CleanupView.swift:104`, `SessionStore.swift:647`, and `AccountStore`'s `--demo` init) and iOS (`apps/ios/SideARemote/Demo`, 765 lines, six files) invent the same fictional accounts and sessions twice | | Medium: new wire fields get demo values on one side only | Demo fixtures as JSON in `SideAProtocolFixtures` that both decode; the phone demo then exercises the real wire types |
| Host noun ("Mac" vs "computer") | Done once in `Packages/SideAProtocol/Sources/SideAProtocol/HostNoun.swift`; the phone has about 117 literal "Mac" strings the PRD counted | Medium | Route them through `HostOS`; add a lint regex to `.swiftlint.yml` for a literal "Mac" in `apps/ios/SideARemote` once the sweep is done |
| Redaction | One place: `Sources/SideACore/Redact.swift`; `apps/ios/Shared/Formatting/RequestText.swift` is a different job (invisible characters), not a duplicate | None | Keep |

### (c) Swift and the Python bridge

| What | Where | Drift risk | Cheapest source |
| --- | --- | --- | --- |
| Claude Code's live-session registry (`~/.claude/sessions/<pid>.json`, `status` of `busy` or `shell`) parsed twice | Swift `Sources/SideACore/KeepAwake.swift:98-106` (stale after 10,800 s, line 84) and Python `bridge/sessions.py:2338`, `:2680` (stuck after `STUCK_AFTER = 600`, line 2116) | High, and the thresholds already differ for a good reason (keep-awake must not spawn Python every 30 s) | Keep both, but one directory of registry samples with expected results, run by `bridge/tests` and `Tests/SideACoreTests` |
| tmux hosting: server name `-L sidea`, `SIDE_A_TMUX_SOCKET`, the launcher script | `bridge/hosting.py:1,74-76,294`, `Sources/SideA/HostedSessions.swift:101,1040` | Medium | Constants in one JSON the bridge reads and a Swift test asserts equal |
| Screen scraping of the CLIs' prompts (composer, trust question, model picker) | Swift `Sources/SideACore/Hosting.swift` (423 lines: `composer`, `trust`, `ready`, `modelPicker`) and the fake agents `Tests/SideATests/Fixtures/FakeAgents` | Medium: a CLI release changes a prompt in one place | Keep Swift as the parser; the fake agents are the test oracle (already) |
| Hook risk rules (destructive command grammar) | Swift only (`Sources/SideACore/Island.swift`); the hook just forwards | None today | The PRD's PowerShell work must extend this one file, not the hook |
| Darwin-only calls spread through the bridge (`security`, `~/.zshrc`, `fcntl`, `ps`, `lsof`) | `bridge/sidea_bridge.py` (2,789), `bridge/sessions.py` (3,093) | Rewrite risk for Linux and Windows | Gather them into `bridge/platform.py` (one module, per-OS functions) before the Linux phase |

### (d) Relay (TypeScript) and the Swift relay client

| What | Where | Drift risk | Cheapest source |
| --- | --- | --- | --- |
| Push categories and loc-keys, three copies: the relay map, the Swift enum, and the phone's strings | `relay/src/send.ts:18-29` (`FALLBACK`), `Packages/SideAProtocol/Sources/SideAProtocol/Push.swift:38-49` (`locKey`), 12 `PUSH_` keys in `apps/ios/SideARemote/Resources/en.lproj/Localizable.strings`. A renamed key is a silent plain notification. | High | One fixture `PushCategories.json` (appended to `MANIFEST`) that a Swift test and `relay/test` both load. The relay already imports `PushVector.request-v2.json` from the package (`relay/test/vector.test.ts:6`), so the mechanism exists |
| Tunnel frame kinds `open=1 data=2 fin=3 reset=4 credit=5` | `relay/src/tunnel.ts:7`, `Packages/SideAProtocol/Sources/SideAProtocol/Tunnel.swift:6` | High (a wrong byte breaks every tunnel) | Same fixture mechanism: `TunnelFrames.json` |
| Quiet-Mac constants: `MAC_QUIET`, `PUSH_MAC_QUIET/ASLEEP/BACK`, `watch`, `goodbye` words, the ten-minute rule | `relay/src/send.ts:32-34`, `relay/src/tunnel.ts:37-43`, `Push.swift:26`, `Tunnel.swift:75-90` | Medium | Same fixture |
| App identifiers: the iOS bundle id appears in seven Swift files, `relay/wrangler.jsonc`, the apple-app-site-association file, `apps/ios/project.yml`, and many docs | grep `com.…sidea.remote` | Low (rarely changes) | Leave; a test already checks the AASA (`site/tests/remote.test.mjs`) |

### (e) Versions and release metadata

| What | Where | Drift risk | Cheapest source |
| --- | --- | --- | --- |
| Mac version and build | `scripts/Info.plist` is the single source (0.5.57, build 65); read by `scripts/check-release.py`, `ship.sh`, `build-app.sh`, `publish-appcast.py` and 8 more scripts | Low. Good | Keep |
| Changelog and release notes must agree with it | `CHANGELOG.md` section, `releases/vX.Y.Z.md` (58 files) | Low: `check-release.py` refuses a mismatch | Keep |
| iOS version and build | `apps/ios/project.yml` `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, rewritten by `scripts/ios-archive.sh` with `sed` | Medium: a second, different scheme, and the `sed` couples the script to the YAML's spelling | Move both into `apps/ios/Config/Shared.xcconfig`; the script edits a one-line file; `scripts/check-release.py` learns an iOS mode |
| Site package version | `site/package.json` says 0.5.7; the app is 0.5.57; the page reads the GitHub release (`site/src/release.mjs`) | A stale number that means nothing | Delete the field or set it to `0.0.0` |
| Wire compatibility numbers | `minClientBuild = 12` (`Sources/SideACore/Remote/RemotePolicy.swift:10`) is an iOS build number; `Daemon/Sources/SideADaemonKit/Routes.swift:8` has its own `0.0.0-phase0`; `relay/test/compat.test.ts` names builds 0.5.43 and 11 in a comment | Medium | A `docs/remote/compat.md` table or a fixture listing shipped builds that the relay compat test reads |
| Third-party pins: Sparkle 2.9.6 in `Package.swift:8`, `scripts/verify-bundle.py:72` and four docs; swift-crypto `from: 3.15.1` in three manifests; Node 24 in `.github/workflows/ci.yml:25` vs "Node 22 or newer" in `relay/DEPLOY.md:14`; `swift:6.2-noble` in `scripts/linux-check.sh:24` and `.github/workflows/linux.yml:23` | | Medium | A test that greps each pair and fails on a mismatch (the same trick as `scripts/tests/test_sync_bridge.py`); `scripts/toolchain.env` later |

### (f) Build and test scripts

| Repeated step | Where | Status |
| --- | --- | --- |
| Bridge tests plus the Python 3.9 rerun | `scripts/check.sh`, `scripts/local-ci.sh`, `.github/workflows/ci.yml` | Done: `scripts/test-bridge.sh` |
| actionlint and shellcheck | `check.sh`, `local-ci.sh` (it omitted `.githooks/*`), `ci.yml` (own `go run`, also omits `.githooks`) | Done for the first two: `scripts/lint-scripts.sh`; `ci.yml` keeps its pinned `go run` |
| Copy the bridge into resources | `ci.yml` had its own `rm`/`cp` | Done: calls `scripts/sync-bridge.sh` |
| `local-ci.sh` is a hand-kept subset of `check.sh --all`: it lacks `swift test --package-path Packages/SideAProtocol`, the iOS tests, the relay gate and the public-source scan, so the release gate is weaker than the merge gate | `scripts/local-ci.sh`, `scripts/check.sh` | Open (step 2): make `local-ci.sh` call `check.sh --all`, then build |
| The Linux check is not in `check.sh`; a change to `Sources/SideACore` or `Packages/SideAProtocol` can break Linux and merge | `scripts/linux-check.sh`, `.github/workflows/linux.yml` (manual) | Open (step 3) |
| Site gate (`npm ci`, lint, test, build) in three places | `check.sh`, `local-ci.sh`, `vercel.json` build command | Open; falls out of step 2 |
| "Build an archive of HEAD and scan it" | `check.sh` (public scan), `ship.sh`, `publish-source.sh` | Intended: each scans the thing it publishes |

## 3. Target layout

Principles: a platform-neutral core is a SwiftPM package that builds on every OS; a platform shell is as thin as its UI;
anything that talks to the OS sits behind a protocol in `SideAPlatform` and has one implementation per OS; tests live
beside the code they test.

```
Package.swift                  root package, Mac app shell only: SideA, SideAPool, SideAKeepAwake(+Core), CSideAPTY, SideATests
Sources/SideA                  SwiftUI/AppKit views and the Apple platform glue; no routes, no stores
Packages/
  SideAProtocol/               wire, fixtures, SideAFormat (shared formatting), SideARemoteKit (Apple only)      [exists]
  SideACore/                   planner, island risk, pricing, codecs, pairing, policy                             [moved from Sources/SideACore]
  SideAPlatform/               the protocols only: SecretStore, PowerManager, ProcessTable, PtyHost, Notifier,
                               Listener, ScreenSource, InputSink, Autostart, Paths. No dependencies.
  SideARemoteCore/             server logic, routes, device and event stores, push, tunnel                        [from Sources/SideA/Remote]
  SideASessionCore/            accounts, sessions, hosted sessions, island queue, keep-awake policy               [from Sources/SideA stores]
  SideAPlatformApple/          Keychain, NWListener, IOKit, ScreenCaptureKit, UserNotifications, tmux/pty
  SideAPlatformLinux/          0600 files and Secret Service, logind, /proc, forkpty, NIO listener
  SideAPlatformWindows/        later: DPAPI, power requests, ConPTY, named pipes
Daemon/                        sidead and the sidea CLI: depends on Packages/*, owns SwiftNIO and swift-certificates
apps/ios/                      unchanged; depends on Packages/SideAProtocol only
bridge/                        Python; OS differences gathered in bridge/platform.py
relay/  site/                  unchanged
scripts/  docs/  releases/  design/  .github/
```

Where tests live: each package has `Tests/` for its own code (`Packages/SideACore/Tests`, ...). The root `Tests/SideATests`
keeps only what needs the app target. `Tests/SideACoreTests` moves with `SideACore`. Cross-platform behaviour is proved by
fixtures in `SideAProtocolFixtures`, which every host's tests load.

### Keep the Daemon a separate package, and remove the symlink by moving the core under `Packages/`

The spike made `Daemon/` separate so SwiftNIO stays out of the Mac and iOS graphs, and reached the root through a symlink
because a path dependency's identity is its directory name, which is different in every worktree and CI checkout.

Folding `Daemon/` into the root package with platform conditions would remove the symlink, but costs more than it gives:

- `swift build` and `swift test` at the root would compile SwiftNIO, NIOSSL and swift-certificates on the Mac for every
  agent in every worktree, to test code that Mac work never touches. That is the dominant loop in this repository.
- The root `Package.resolved` would grow by a server stack the app does not link.
- Target dependencies can be conditional on a platform, but package dependencies cannot, so the manifest would stay
  host-conditional with `#if os(macOS)`, which is the part that is already fragile.

Instead, make the identity problem disappear: a local package under `Packages/` has a fixed directory name in every
checkout. Once `SideACore` and the new cores live in `Packages/*`, the daemon depends on `../Packages/SideACore` and the
symlink is deleted. The root package then only builds the Mac app and no longer needs to build on Linux, so its
`#if os(macOS)` manifest split can go; `Packages/SideAProtocol` keeps its split because iOS must not resolve swift-crypto.
The Windows daemon can be a second package beside `Daemon/` or a `windows` target in the same one, whichever the
Swift-on-Windows spike prefers.

### What each move breaks

| Move | What breaks and must be fixed in the same change |
| --- | --- |
| `Sources/SideACore` to `Packages/SideACore` | `Package.swift` targets and products; `Daemon/Package.swift` and the symlink; `scripts/linux-check.sh` paths; `.swiftlint.yml` `included`; **`.swiftlint-baseline.json` paths** (every baselined line keyed by file, and the pinned line counts, so rebaseline in the same commit and check the diff only renames); `scripts/check.sh` `touches` regexes; `.vercelignore` (`/Sources/**`); docs paths; `git mv` to keep history |
| `Sources/SideA/Remote` to `Packages/SideARemoteCore` | The `@MainActor` stores it calls must have their protocols first (step 8); `internal` becomes `public` across the boundary; `Tests/SideATests/Remote` splits; the Remote harness (`scripts/remote-harness.sh`) finds its test bundle by name |
| Stores out of `Sources/SideA` | tests using `@testable import SideA` need the package's own `@testable import`; `@MainActor` isolation changes; the baselined `file_length` entries for `AccountStore.swift`, `SessionStore.swift` and others vanish with the files, which is welcome |
| `apps/ios` | Nothing, unless the phone adopts `SideAFormat`: then `apps/ios/project.yml` gains no new package (it is a target of `SideAProtocol`) |
| `bridge/platform.py` | `scripts/sync-bridge.sh` copies `bridge/*.py`, so a new module is picked up; `Package.swift` resource list is `Resources` as a folder, fine |
| xcodegen, release scripts | Untouched by all of the above: the Mac app is still built by `scripts/build-app.sh` from product names, and the iOS project from `project.yml` |

## 4. Migration

Sizes: S under a day, M one to three days, L a week or more. "Parallel" means safe beside other steps and beside the
work in flight today (comment sweep, iOS design pass, screen sharing, release files).

| # | Step | Size | Files | Parallel | Status |
| --- | --- | --- | --- | --- | --- |
| 0 | Agent guidance and its rot test | S | `AGENTS.md`, `CLAUDE.md`, nested `AGENTS.md`, `scripts/tests/test_agent_guidance.py` | yes | **Done** |
| 1 | Dedupe scripts: `test-bridge.sh`, `lint-scripts.sh`, `ci.yml` uses `sync-bridge.sh` | S | `scripts/check.sh`, `local-ci.sh`, `.github/workflows/ci.yml`, two new scripts, two test fixtures | yes | **Done** |
| 2 | `local-ci.sh` calls `check.sh --all`, then builds both architectures; add a test that the release gate runs every gate the merge gate does | S | `scripts/local-ci.sh`, `scripts/tests` | yes (touches the release path: needs the owner's yes) | Proposed |
| 3 | Linux in the gate: `check.sh` runs `scripts/linux-check.sh` when `Sources/SideACore`, `Packages/SideAProtocol` or `Daemon` change and Docker is present; `SIDEA_LINUX_TESTS=skip` skips loudly like the iOS escape | S | `scripts/check.sh`, `scripts/tests/test_local_check.py` | yes | Proposed |
| 4 | Pin-pair tests: Sparkle version, swift image, Node version, site version field removed | S | `scripts/tests`, `site/package.json` | yes, except `site/package.json` (release files in flight) | Proposed |
| 5 | Wire constants as fixtures: `PushCategories.json`, `TunnelFrames.json`, quiet-Mac words, appended to `MANIFEST`; Swift tests and `relay/test` both assert against them | S | `Packages/SideAProtocol/Sources/SideAProtocolFixtures/Fixtures/v1`, `relay/test`, `Packages/SideAProtocol/Tests` | with care: protocol lane and relay lane | Proposed |
| 6 | Registry and hosting samples shared by Python and Swift tests | S | `bridge/tests`, `Tests/SideACoreTests` | yes | Proposed |
| 7 | `SideAFormat` target in `SideAProtocol`: move `Formatting` (phone) and the Mac's token, memory, duration helpers; one test table | M | `apps/ios/Shared/Formatting/Formatting.swift`, `Sources/SideA/MenuPlayer.swift`, `Sources/SideACore/Memory.swift` | no: wait for the iOS design pass and the comment sweep | Proposed |
| 8 | Platform protocols in place (no file moves): `SecretStore`, `PowerManager`, `ProcessTable`, `PtyHost`, `Listener`, `Notifier`, one pull request each, with the Apple code behind them | L | `Sources/SideA/Remote/RemoteKeychain.swift`, `KeepAwakeController.swift`, `TerminalHub.swift`, `RemoteServer.swift`, ... | each protocol in parallel with the others; not with the screen-sharing work | Proposed |
| 9 | Move `SideACore` to `Packages/SideACore`; delete the `Daemon/Dependencies` symlink; simplify the root manifest | M | `Sources/SideACore`, `Tests/SideACoreTests`, `Package.swift`, `Daemon/Package.swift`, `.swiftlint.yml`, baseline, `scripts/check.sh`, `linux-check.sh`, `.vercelignore` | **no**: quiet window, after the comment sweep merges | Proposed |
| 10 | Split `RemoteServer` into listener and handler; create `SideARemoteCore` with the 30 import-free files (5,066 lines), then the rest as protocols land | L | `Sources/SideA/Remote`, `Tests/SideATests/Remote` | no (touches the screen-sharing files last) | Proposed |
| 11 | `SideASessionCore`: stores off `@MainActor` behind actors | L | `AccountStore*`, `SessionStore*`, `HostedSessions*`, `Island*` | no | Proposed |
| 12 | Daemon on the shared core: NIO `Listener`, Linux platform implementations, fake-agent tests on Linux | L | `Daemon`, `Packages/SideAPlatformLinux` | after 8, 9, 10 | Proposed |
| 13 | `bridge/platform.py` | M | `bridge/sidea_bridge.py`, `bridge/sessions.py`, `bridge/island_hook.py` | in parallel with 12; not with bridge feature work | Proposed |
| 14 | Windows CI job and spike (`windows-2025`, core targets only) | M | `.github/workflows`, `Packages/SideAPlatformWindows` | after 9 | Proposed |

Steps 0 and 1 are the only ones done. Order that matters: 8 before 10 (a route cannot move until what it calls is behind a
protocol), 9 before 10 and 12, 3 before 9 (so the move is checked on Linux), 5 and 7 any time the owning lane is quiet.

## 5. Done now

- `AGENTS.md` at the root and in `apps/ios`, `Packages/SideAProtocol`, `relay`, `bridge`, `Daemon` and `site`; `CLAUDE.md` is
  the one line `@AGENTS.md`.
- `scripts/tests/test_agent_guidance.py` fails when any `AGENTS.md` names a path or script that does not exist, when
  `CLAUDE.md` stops being the import, or when the root file grows past 150 lines.
- `scripts/test-bridge.sh` (bridge tests on `python3` and on 3.9) and `scripts/lint-scripts.sh` (actionlint and shellcheck
  over `scripts/` and `.githooks/`) replace copies in `check.sh`, `local-ci.sh` and `.github/workflows/ci.yml`; the
  release gate now also shellchecks `.githooks/*`, which it skipped before.
