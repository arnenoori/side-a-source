# Bridge (Python)

The command runner the app calls for logins, transcripts, hosting and island hooks. Commands and files are listed in `docs/architecture.md` and `docs/remote/bridge.md`.

- **Standard library only, Python 3.9 compatible** (macOS's own `/usr/bin/python3`): `from __future__ import annotations`, no `match`, no `X | Y` at runtime, no third-party imports. `tomllib` exists only on 3.11+, so guard it.
- `bridge/*.py` is the source. `Sources/SideA/Resources/*.py` is a generated copy: run `scripts/sync-bridge.sh` (builds and `swift test` do) and never edit the copy.
- Tests: `scripts/test-bridge.sh` (runs on `python3` and on 3.9 when present). They use temporary folders and fake CLIs; never touch a real login, `~/.claude` or `~/.codex`, or a real Keychain.
- Hooks (`island_hook.py`) run on every tool call inside Claude Code and Codex: keep them cheap and never block the CLI when Side A is not running.
- Output is read by Swift decoders (`Sources/SideA`, `Sources/SideACore`); keep keys stable, add rather than change, and never send bridge snake_case straight onto the wire (`docs/remote/protocol.md`).
- Anything Darwin-specific (the `security` CLI, `~/.zshrc`, `fcntl`, `ps` and `lsof`) is the work of the Linux and Windows ports (`docs/ports/windows-linux-prd.md`): isolate it behind small functions rather than spreading it.
- Lint with `scripts/lint-python.sh` (ruff, config in `ruff.toml`).
