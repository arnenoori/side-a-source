# Side A

Side A is a macOS menu-bar app that keeps several Claude Code and Codex accounts within their limits (Autopilot trades logins between sessions), answers agent permission requests from the notch ("island"), and hosts sessions in tmux. Side A Remote is its iPhone companion: it reaches the Mac over TLS (LAN, Tailscale or a relay tunnel) and gets push through a Cloudflare relay. A headless Linux daemon and a Windows port are being added from the same Swift core (`docs/ports/windows-linux-prd.md`, `docs/ports/phase-0.md`).

Many agents work in parallel git worktrees and one coordinator merges them. Stay in your worktree and your area, commit on your branch, and do not push or open pull requests unless told to. `CLAUDE.md` only imports this file; edit this one. Area rules live in the nested `AGENTS.md` files and load when you work there.

## Map

| Path | What it is | Ships to |
| --- | --- | --- |
| `Sources/SideA` | SwiftUI/AppKit app, Remote server and routes in `Sources/SideA/Remote` | macOS |
| `Sources/SideACore` | Platform-neutral logic: planner, island risk, pricing, HTTP/WebSocket codecs, pairing | macOS, Linux |
| `Sources/SideAKeepAwake`, `Sources/SideAKeepAwakeCore`, `Sources/SideAPool`, `Sources/CSideAPTY` | Root keep-awake helper and its XPC contract, pool proxy helper, C PTY shim | macOS |
| `Packages/SideAProtocol` | The wire (`SideAProtocol`), frozen fixtures, `SideARemoteKit` (phone client, Apple only) | macOS, iOS, Linux (not the client) |
| `apps/ios` | Side A Remote: app, notification extensions, widgets | iOS |
| `Daemon` | `sidead`, the Linux daemon spike (own package) | Linux |
| `bridge` | Stdlib-only Python the app runs for logins, transcripts, hosting, island hooks | macOS, later Linux |
| `relay` | Cloudflare Worker: push and tunnel relay | Cloudflare |
| `site` | Download page and docs site (Vite, TypeScript) | Vercel |
| `scripts` | Build, check, release scripts; `scripts/tests` tests them | maintainers |
| `Tests` | `Tests/SideATests` (app), `Tests/SideACoreTests` | not shipped |
| `docs`, `releases`, `design` | Design docs, public release notes, Blender and icon sources | |

Read first: `docs/architecture.md`, `docs/remote/protocol.md` (wire), `SECURITY.md` (what Side A touches), `CONTRIBUTING.md`.

## Commands

Run everything below, and every check, lint and test, outside any command sandbox: tests start tmux and read `ps`, which a sandbox refuses.

| Part | Command |
| --- | --- |
| Mac app: build and run your checkout | `scripts/dev.sh` (debug build; puts the installed Side A back on quit) |
| Mac app: build only | `scripts/build-app.sh debug` (output in `dist`) |
| Mac app and core tests | `scripts/sync-bridge.sh && swift test` |
| Protocol package tests | `swift test --package-path Packages/SideAProtocol` |
| iOS | `cd apps/ios && xcodegen --quiet && xcodebuild test -project SideARemote.xcodeproj -scheme SideARemote -destination "id=<simulator udid>" -derivedDataPath build/check -parallel-testing-enabled NO -quiet` |
| Bridge | `scripts/test-bridge.sh` (also runs on `/usr/bin/python3` when that is 3.9, the oldest supported) |
| Relay | `cd relay && npm run typecheck && npm run lint && npm test` |
| Site | `npm --prefix site ci && npm --prefix site run lint && npm --prefix site test && npm --prefix site run build` |
| Linux (Docker) | `scripts/linux-check.sh` (`--amd64` for x86_64, `--here` on a Linux host) |
| Daemon | `swift test --package-path Daemon` |
| Script tests | `python3 -m unittest discover -s scripts/tests` |
| Lint | `scripts/lint-swift.sh`, `scripts/lint-python.sh`, `scripts/lint-scripts.sh` |
| Scan for private data | `git archive HEAD \| tar -x -C <empty dir> && python3 scripts/scan-public-source.py <empty dir>` |

## The gate

- `scripts/check.sh` runs the gates the changed files need (against `origin/main`; `--all` runs every one). The pre-push hook (`.githooks/pre-push`) runs it; `scripts/setup-hooks.sh` installs the hook and `dev.sh` and `check.sh` call it. Hosted CI runs only on manual dispatch.
- A pass on a clean tree with nothing skipped posts a `local-check` status on the commit. `scripts/merge-pr.sh <number>` refuses a pull request without it and squash-merges. Merge only that way, squash only, and never use `--no-verify` or `gh pr merge`.
- A `Packages/` change also runs the iOS tests, since `apps/ios` builds against `Packages/SideAProtocol`. A skipped gate means no pass is recorded.
- The owner's yes is required for: releases (`scripts/ship.sh`), App Store and TestFlight submissions, relay deploys, and any push to the public source repository.

## Rules the code does not show

- **Lint baseline.** `.swiftlint-baseline.json` matches violations by line text and by message. Files with a `file_length` or `type_body_length` entry have their exact length in it, so adding or removing a line there creates a new violation. Put new code in a new extension file, keep baselined lines byte-identical, and never run `--rebaseline` to hide something you wrote. A fixed sleep, an unbounded wait loop, a bare `try?`, `print`, `UserDefaults.standard` and `DispatchQueue.main.async` are lint errors (`.swiftlint.yml`).
- **Wire.** A new optional `Bool` on a wire type needs `// swiftlint:disable:next discouraged_optional_boolean -- reason` (absent means something specific). Changes are additive and optional, a capability gates new behaviour, and optional fields are omitted, never `null`. Fixtures are frozen by SHA-256 in `Fixtures/v1/MANIFEST`: never edit one, append new ones and add them to the manifest.
- **Tests.** Wait for a condition with `eventually` (`Tests/SideATests/Eventually.swift`), never with a fixed sleep. Use port 0, not a fixed port. Never launch or type into the real `claude` or `codex` from a test: use the fake agents in `Tests/SideATests/Fixtures/FakeAgents`, and give any Codex probe a temporary `CODEX_HOME`. Never use a real login or a paid model call.
- **Processes.** Do not kill processes, or use simulators or ports, that you did not start. Do not call Keychain APIs that change an item's access control outside tests.
- **Public source.** `scripts/scan-public-source.py` refuses anything that looks like a key, a home path or a tailnet name, in code, tests and docs alike. Use made-up names such as `you` or `alex`.
- **Files Side A adds to the user's** (`~/.zshrc`, `~/.claude/settings.json`, `~/.codex/hooks.json`) carry a marker, are removed by their toggle and by Remove Side A, and leave the CLI working when Side A is off (`CONTRIBUTING.md`). Update `SECURITY.md` when files touched or network requests change.
- **Generated, do not edit:** `Sources/SideA/Resources/*.py` (copied from `bridge` by `scripts/sync-bridge.sh`), `site/src/generated`, `apps/ios/SideARemote.xcodeproj`.
- **UI.** Apple-native look. Text only when it is actionable: no subtitles or footers that explain a feature. Honour Reduce Motion and give actions a keyboard and VoiceOver path. Try changes with `--demo`, which never writes outside its temporary folder.
- **Changelog.** A change a Mac user would notice adds plain user-facing sentences under `## Unreleased` in `CHANGELOG.md`. Version and release metadata are edited only when releasing (`docs/updates.md`).
- **Linux.** `Packages/SideAProtocol` (without `SideARemoteKit`), `Sources/SideACore` and `Daemon` must keep building on Linux. Fence Apple-only code with `#if canImport(Network)` or `#if canImport(Darwin)`, and import CryptoKit only through `#if canImport(CryptoKit)` with `Crypto` as the fallback. `scripts/linux-check.sh` proves it.
- **Comments** say why, not what. Do not add dependencies the platform or standard library can cover.
