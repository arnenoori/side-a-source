# Architecture

## Native application

`SideA` is SwiftUI on macOS 14+. A single observable account store backs the window,
settings, and `MenuBarExtra`. `SideACore` contains Codable models, validation,
private atomic persistence, and shell-argument escaping without AppKit dependencies.

`DiscmanView` reads evaluated geometry exported by Blender, builds SceneKit meshes,
and uses physical materials and studio lighting. The LCD is a native texture
showing account and session state; the lid rotates around its modeled hinge.
The standalone window is transparent and has no visible chrome or separate controls.
Dragging the housing moves the window. Stable accessibility elements attach directly
to the model buttons, with projected screen bounds and main-thread callbacks.
Reduced Motion disables both lid and button animations. The renderer is on-demand rather than an always-running animation loop.

## Bridge

`bridge/sidea_bridge.py` is a stdlib-only command runner the app calls per action:
`login`, `logout`, `status`, `usage`, `active`, `activate`, `adopt`, `prime`, `report`,
`hook` and `shell`.
Claude profile Keychain slots follow the CLI's naming: `Claude Code-credentials-` plus
the first 8 hex digits of the SHA-256 of the NFC profile path. The bridge only reads
logins; switching writes one selector file under `runtime/selection.lock`. The planner (`Planner` in `SideACore`) is pure and unit-tested.

## Local storage

All managed data lives under `~/Library/Application Support/SideA/`:

```text
config.json                  App-owned profile metadata and preferences
profiles/<uuid>/             Claude-owned account config and fallback credentials
profiles/<uuid>/projects -> ../../conversations
conversations/               Managed conversation history shared across profiles
runtime/claude-selector      Profile path new claude commands use (empty: Mac login)
runtime/selection.lock       Serializes selector writes
```

Directories are private (0700); app/bridge JSON and launch files use 0600/0700.
App and bridge write separate files atomically. Corrupt account configuration fails
closed and is not replaced with an empty library.

## Codex provider

`codex_bridge.py` prepares separate `CODEX_HOME` profiles and delegates OAuth to
`codex login`, with file credential storage. The Mac's own Codex login stays in
`~/.codex`; Side A reads its id_token only to name the account and never copies it.
Codex accounts are tracked and primed, never switched: OpenAI revokes a login whose
refresh token is used twice.

Usage reads `account/rateLimits/read`; windows are labeled by their duration.

Provider discrimination defaults missing v1 account fields to Claude and promotes
the library to schema v2. Older releases reject this version instead of dropping
Codex provider fields on save. Automatic
candidates are restricted to the current provider; manual cross-provider requests
are rejected in both the app and bridge. Changing agent starts a separate session.

The Accounts utility panel is independently movable and placed beside the player,
shifting the player within its display if needed. This avoids SwiftUI sheet dimming
on the transparent model window. On displays too narrow for both windows, placement
is clamped to the display and users can move the windows independently.

Official contracts checked against installed Codex 0.148.0 on 2026-09-06:

- [App-server protocol, native TUI and account API](https://learn.chatgpt.com/docs/app-server)
- [Authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Configuration reference including sqlite_home](https://learn.chatgpt.com/docs/config-file/config-reference)

The adapter remains experimental: live switching between two authenticated Codex
subscriptions is a release acceptance check, separate from protocol fixture tests
and unsigned-in real-binary storage/transport probes.
