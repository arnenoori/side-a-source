# Daemon (`sidead`)

The headless Linux daemon, still a spike (`docs/ports/phase-0.md`, plan in `docs/ports/windows-linux-prd.md`). A separate package so SwiftNIO, NIOSSL and swift-certificates stay out of the Mac and iOS dependency graphs.

- It reaches the repository root through the symlink `Daemon/Dependencies/side-a`. Do not replace it with a path of another name: a path dependency's identity is its directory name, which differs in every worktree.
- Check on Linux with `scripts/linux-check.sh` (Docker; `--here` on a Linux host). It builds the protocol package, `SideACore` and this package, runs their tests and starts `sidead`. `swift test --package-path Daemon` also works on a Mac.
- Reuse, do not rewrite: HTTP parsing and responses are `SideACore`'s `HTTPParser` and `HTTPResponse` (not NIOHTTP1), wire types are `SideAProtocol`, and the key pin is `SPKI.hash` from the protocol package. Routes live in `Sources/SideADaemonKit/Routes.swift`; a route answers only what its capability says.
- Tests start the server on port 0 and pin the key like the phone does. Never use a fixed port in a test, and do not read or write the real `~/.claude` or `~/.codex`.
- Anything platform-specific (secrets, power, processes, autostart) goes behind a small protocol so the Mac app can share the code later; see the plan in `docs/structure.md`.
