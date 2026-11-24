# Side A on Windows and Linux (PRD)

Status: proposal, nothing built. Owner decisions needed are in [Before work starts](#before-work-starts) and
[Open questions](#open-questions-for-the-owner).

## Recommendation

Build a **headless Side A daemon for Linux first, written in Swift on the same core as the Mac app**, with the
phone and a `sidea` command as its only interfaces. Then put a tray UI on top of it, then do Windows: first by
running the same Linux daemon inside WSL 2, then natively.

The reasons, in order of weight:

1. **The protocol moves daily.** The 50 commits between `main` (8ecd79f) and the branch tip this was written
   against (4f328ba) changed reply delivery, Stop, queues, screen close codes and handoffs. A second server in
   another language would have to repeat every one of those changes. One Swift server, shared by the Mac and the
   daemon, does not.
2. **The phone is already a complete UI.** Sessions, approvals, replies, accounts, Autopilot, terminals, usage and
   push all run through Side A Remote. A daemon that serves it is useful on day one without any desktop UI, and it
   is the only form that works on the Linux machines where many agents actually run: servers reached over SSH.
3. **Linux is closest to macOS where it matters.** POSIX processes, `forkpty`, Unix sockets with peer credentials,
   tmux, `/proc` and the Python bridge all carry over, and Claude Code stores Linux logins in a file, which makes
   account switching simpler than the Keychain. Windows lacks tmux, Unix-socket hooks in stdlib Python and `SIGTERM`,
   and splits every user into native and WSL halves.
4. **The desktop shells are the expensive, fragmented part** (tray, island overlay, screen capture under Wayland,
   global shortcuts, notifications). Doing them after the daemon means they are thin clients, and the hardest of
   them can wait or be dropped without blocking anyone.

The main cost is a refactor of the Mac app: the Remote server, its routes and the stores they call live in the
`SideA` app target today and use AppKit, `@MainActor` stores and Network.framework. They have to move into
platform-neutral targets behind small platform protocols before any other OS can run them. That refactor is phase 1
and ships as an ordinary Mac release.

## Scope of this document

Inventory taken from the tree at **4f328ba** (`worktree-agent-ad1aeae3827a8c94a`), which is 50 commits ahead of
`main`. Paths marked † exist on that branch and not yet on `main`: screen sharing, dictation, pull requests,
snoozes, handoffs and the fake agents.

Facts about Claude Code and Codex come from their documentation as of 2026-11-23
([Claude Code authentication](https://code.claude.com/docs/en/iam), [setup](https://code.claude.com/docs/en/setup),
[Codex authentication](https://learn.chatgpt.com/docs/auth)). Anything marked **(verify)** is a belief that has not
been checked against a running system or official documentation and must be confirmed before the phase that needs it.

## 1. Goal, users and non-goals

### Goal

Someone who runs Claude Code or Codex on a Linux or Windows machine gets what a Mac user gets from Side A today:
several accounts with their limits in view, sessions moved off an account before it runs out, the machine kept
awake while agents work, and every session answerable from the phone.

### Who it is for

| User | Machine | What they need first |
| --- | --- | --- |
| A developer with a Linux server or cloud VM running agents over SSH or tmux | Headless Linux, x86_64 or arm64 | Phone approvals and replies, account switching, sessions that survive a dropped SSH connection |
| A Mac user who also runs agents on a Linux box | Mac plus headless Linux | The same phone app showing both machines |
| A Linux desktop developer | Ubuntu, Fedora, Arch; GNOME or KDE; Wayland by default | All of the above, plus a tray icon, notifications and keep-awake |
| A Windows developer using WSL 2 | Windows 11, agents inside WSL | The Linux daemon running in WSL, reachable from the phone |
| A Windows developer using native Claude Code or Codex | Windows 10/11, PowerShell or Git Bash | Native daemon, ConPTY-hosted sessions, tray |

### Minimum lovable version (Linux, day one)

Install one package, run `sidea setup`, and:

- add Claude and Codex accounts (browser sign-in, or adopt the login the machine already has);
- see every account's 5-hour and weekly limits with `sidea status` and on the phone;
- Autopilot moves running Claude sessions to an account with room, as on the Mac;
- `sidea use <name>` and `sidea auto` work in bash, zsh and fish;
- pair the phone by scanning a QR code printed in the terminal, with the six-digit comparison code confirmed in the
  terminal;
- from the phone: see sessions and transcripts, answer permission requests, questions and plans, reply to finished
  sessions, start and watch hosted sessions in tmux, receive push notifications through the relay;
- the machine does not idle-sleep while agents work (desktop Linux);
- the daemon starts at login or boot as a systemd user unit and survives SSH disconnects.

Not in the minimum: tray icon, island overlay, desktop notifications, global shortcuts, screen view and control,
pool mode, iCloud-style sync, the 3D player, terminal tab focus.

### Parity

Parity means every row of the [inventory](#2-feature-inventory) rated other than "cannot be done" works on the
platform, with documented reductions where the platform forbids something (Wayland window placement, Windows
terminal tab focus). Parity is not a release target; it is the end of the plan.

### Non-goals

- A port of the SwiftUI app. No SwiftUI exists off Apple platforms; the desktop UI is new code either way.
- The 3D Discman player (SceneKit, `Sources/SideA/DiscmanView.swift`).
- iCloud Drive sync of preferences off macOS. A generic "sync folder" option can come later.
- Driving terminal apps the Mac way (Apple Events, Accessibility) on Windows or Linux. Hosted sessions replace it.
- Android. The phone app stays iOS; nothing here depends on that changing.
- Running Side A inside Flatpak, Snap or MSIX sandboxes with their restrictions on (see [packaging](#packaging-signing-and-updates)).
- BSDs and Linux on 32-bit or musl in the first releases.

## 2. Feature inventory

Ratings, per OS: **as is** (portable as is), **layer** (needs a platform layer: same design, different OS calls),
**redesign** (the Mac design does not carry over), **cannot** (no reasonable equivalent; drop or replace).

### 2.1 Accounts, limits and Autopilot

| Capability | How it works on macOS | Windows equivalent | Linux equivalent | Win | Linux |
| --- | --- | --- | --- | --- | --- |
| Account limits and reset times | Bridge `usage` calls `api.anthropic.com/api/oauth/usage` with the account's token (`bridge/sidea_bridge.py`), Codex via app-server `account/rateLimits/read` (`bridge/codex_bridge.py`) | Same HTTP; token read from the credentials file | Same | layer | layer |
| Where Claude logins live | Keychain items `Claude Code-credentials` and `Claude Code-credentials-<8 hex>` per profile, through the `security` CLI (`sidea_bridge.py` `GLOBAL_SERVICE`, `slot_service`) | `%USERPROFILE%\.claude\.credentials.json`, protected by the profile folder's ACL; under `CLAUDE_CONFIG_DIR` when set | `~/.claude/.credentials.json`, mode 0600; under `CLAUDE_CONFIG_DIR` when set | layer | layer |
| Where Codex logins live | `auth.json` under each `CODEX_HOME`, forced with `cli_auth_credentials_store="file"` (`codex_bridge.py`) | Same; `keyring` mode would use Credential Manager | Same; `keyring` mode would use the Secret Service | as is | as is |
| Account selection per command | `CLAUDE_SECURESTORAGE_CONFIG_DIR` keys only the Keychain item, so settings and history stay in `~/.claude` (`README.md` "How switching works") | Unknown whether this variable moves `.credentials.json` without moving settings **(verify)**. If not, `CLAUDE_CONFIG_DIR` per account moves settings and history too | Same **(verify)** | redesign if not | redesign if not |
| Login renewal | Claude Code's mkdir lock `.oauth_refresh.lock` plus legacy `<folder>.lock` (`sidea_bridge.py` `claude_refresh_lock`), then the token endpoint | mkdir locks work on NTFS; same endpoint | Same | as is | as is |
| Trades (move running sessions) | Swap two Keychain items under both refresh locks, journal in a Keychain item, sessions re-read their item about every 30 s (`SECURITY.md`) | Swap two `.credentials.json` files; journal as a file. Needs Claude Code to re-read the file mid-session **(verify)** | Same **(verify)** | layer | layer |
| Trade watch and login backups | Keychain items "Side A trade watch …", "Side A login backup …" (`SECURITY.md`) | Files encrypted with DPAPI (`CryptProtectData`) | Secret Service where present, else 0600 files | layer | layer |
| Autopilot planner | Pure Swift `Planner` (`Sources/SideACore/Models.swift`) | Same code | Same code | as is | as is |
| Window priming | Runs the CLI with one Haiku message (`bridge` `prime`) | Same, with `claude.exe` | Same | as is | as is |
| Live limits from the statusline | `runtime/statusline.sh` wraps the user's `statusLine` in `~/.claude/settings.json` | Needs a non-shell wrapper (Python launcher or small `.exe`); how Claude Code runs `statusLine` commands on native Windows **(verify)** | Same shell script | layer | as is |
| Switch in Terminal, `sidea use/auto/attach/ls` | One marked line in `~/.zshrc` defining a zsh `sidea` function and the selector (`sidea_bridge.py` `rewrite_zshrc`) | PowerShell `$PROFILE`, Git Bash `~/.bashrc`; `cmd.exe` has no rc file. A `claude` shim earlier on `PATH` is more reliable | `~/.bashrc`, `~/.zshrc`, `~/.config/fish/conf.d/` | redesign | layer |
| Claude incidents | `status.claude.com/api/v2/summary.json` every 5 min (`Sources/SideACore/Pricing.swift`) | Same | Same | as is | as is |
| Worth at API prices, usage reports | LiteLLM price list, bridge `report` over transcripts | Same | Same | as is | as is |
| Weekly-limit notifications | `UserNotifications` | Toast notifications | `org.freedesktop.Notifications` | layer | layer |
| Pool mode | `PoolProxy` on `127.0.0.1:47317` (Network.framework, `Sources/SideACore/PoolProxy.swift`), `SideAPool` launchd agent via `SMAppService.agent` (`AccountStore+Pool.swift`) | SwiftNIO listener; helper as a per-user scheduled task or a child the daemon outlives | SwiftNIO; systemd user unit with `Restart=` | layer | layer |
| Pool sharing over Tailscale | Second listener on the tailnet address, `tailscale whois --json` (`PoolPeers`) | `tailscale.exe` has the same CLI | Same | layer | layer |
| Codex in pool mode | `CODEX_HOME=runtime/codex-pool` with symlink to `~/.codex` (`docs/architecture.md`) | Symlinks need Developer Mode or admin on Windows; use a junction or copy **(verify)** | Same | layer | as is |

### 2.2 Sessions and the island

| Capability | How it works on macOS | Windows equivalent | Linux equivalent | Win | Linux |
| --- | --- | --- | --- | --- | --- |
| Session search and viewer | Bridge `sessions` builds SQLite from `~/.claude/projects` and `~/.codex/sessions` (`bridge/sessions.py`) | Same, from `%USERPROFILE%` paths; WSL sessions live in the distro's home, a separate tree | Same | layer | as is |
| Running sessions, step, flags | Claude Code's registry `~/.claude/sessions/<pid>.json` plus transcript tails (`sessions.py`) | Same registry if Claude Code writes it on Windows **(verify)** | Same | layer | as is |
| Running Codex sessions | `ps`, then one `lsof` to find each process's open rollout (`sessions.py` `lsof_open`) | No cheap way to list another process's open files; use rollout modification times and Codex's app server | `/proc/<pid>/fd` | redesign | layer |
| Ports and memory per session | `ps -axo …` and `lsof -iTCP -sTCP:LISTEN` (`sessions.py`), `libproc` (`Sources/SideACore/Processes.swift`, `Memory.swift`) | `GetExtendedTcpTable`, Toolhelp snapshots, `GetProcessMemoryInfo` | `/proc/net/tcp*` inode to pid, `/proc/<pid>/status` | layer | layer |
| Quit Session, Quit Idle, Stop Server | `SIGTERM` after re-checking pid and start time (`SECURITY.md`) | No `SIGTERM`. Graceful stop of a console process needs `GenerateConsoleCtrlEvent` from a process attached to its console; `TerminateProcess` is a kill | `SIGTERM` | redesign | as is |
| Memory-pressure warning | Darwin memory-pressure source | `CreateMemoryResourceNotification` | PSI, `/proc/pressure/memory` | layer | layer |
| Island hooks | `island on` writes `runtime/island-hook.sh` and `island-mail.sh`, which run `island_hook.py` with `-I -S`; hooks marked `side-a-island` in `~/.claude/settings.json` and `~/.codex/hooks.json` (`docs/architecture.md`) | Launchers as `.cmd` or a direct `python.exe` command line; which shell Claude Code uses for hook commands on native Windows **(verify)** | Same shell launchers | layer | as is |
| Hook to app socket | `runtime/island.sock`, mode 0600, peer uid check (`Sources/SideA/IslandServer.swift`, `bridge/island_hook.py` `AF_UNIX`) | CPython does not offer `AF_UNIX` on Windows **(verify for the shipped Python)**; use a named pipe with a DACL for the user's SID (`multiprocessing.connection` with `AF_PIPE` is stdlib) | `AF_UNIX` with `SO_PEERCRED` | layer | as is |
| Permission requests, questions, plans, Always | `Island` decodes and answers; risk rules in `Sources/SideACore/Island.swift` | Same logic, but Claude Code's PowerShell tool sends PowerShell commands, which the shell-word risk rules do not parse (`Remove-Item -Recurse -Force`, `iwr | iex`) | Same | layer | as is |
| Notes, stops (mail) | `runtime/mail/<pid>.json`, claimed by hooks | Same files; launcher test written for `cmd` or Python | Same | layer | as is |
| Reply to a finished session | `Stop` hook with `asyncRewake`, exit code 2 | Same if the hook runs | Same | as is | as is |
| The island overlay | `NSPanel` at the notch or under the menu bar (`IslandView.swift`, `Island.swift`) | Top-most borderless window near the tray or top centre | X11: override-redirect or always-on-top window. Wayland: an app cannot place its own window or keep it on top; `wlr-layer-shell` works on KDE and wlroots compositors, not GNOME | redesign | redesign (GNOME Wayland: cannot) |
| Global shortcuts ⌃⌥Y/N/A… | Carbon `RegisterEventHotKey`, only while something waits (`HotKeys.swift`) | `RegisterHotKey` | X11 `XGrabKey`; Wayland `org.freedesktop.portal.GlobalShortcuts` (KDE yes; GNOME support **(verify)**) | layer | layer / partly cannot |
| Notification Allow and Deny buttons | `UserNotifications` actions (`Island.swift`, `WaitingNotifier.swift`) | Toasts with buttons and a text box; an unpackaged app needs an AppUserModelID on a Start-menu shortcut | Notification actions on GNOME and KDE; inline reply text is not portable | layer | layer |
| Go and Show terminal | Apple Events to Terminal, iTerm, Ghostty by tty; Warp by `WARP_FOCUS_URL` or its database plus Accessibility (`TerminalFocus.swift`, `WarpFocus.swift`) | Windows Terminal exposes no "tab for this pid" lookup; `wt.exe` can open a new tab | Per-terminal (kitty, WezTerm remote control); GNOME Terminal has none; Wayland blocks raising another app's window without an activation token | cannot (replace with "open a tab attached to the hosted session") | cannot in general (same replacement) |
| Typing into an unhosted terminal | `TerminalTyping.swift`: the user's own tmux pane, or Ghostty scripting | User's tmux under WSL only | User's own tmux pane | cannot (native) | layer (tmux only) |
| Codex replies through its shared server | WebSocket over the Codex app-server's Unix socket (`Sources/SideACore/Remote/AppServerClient.swift`, Network.framework) | Whether Codex runs a shared app-server daemon on native Windows, and over what transport **(verify)** | Same Unix socket | redesign / verify | layer |
| Pull request status | `gh` at Homebrew paths (`Sources/SideA/Remote/PullRequests.swift` †) | `gh.exe` on `PATH` | `gh` on `PATH` | layer | layer |
| Clean Up (archive, worktrees) | `bridge/cleanup.py`, `git worktree remove` without `--force`, `lsof` for working folders | Another process's working folder is not readable without reading its PEB; refuse removal when unsure | `/proc/<pid>/cwd` | redesign | layer |
| Setup tab | `bridge/setup.py` reads `~/.claude.json`, `.mcp.json`, `~/.codex/config.toml`; Codex managed prefs at `/Library/Managed Preferences` (`island_hook.py`) | Same user files; managed settings and requirements paths differ **(verify)** | Same; `/etc/codex/requirements.toml` already handled | layer | as is |

### 2.3 Hosting and terminals

| Capability | How it works on macOS | Windows equivalent | Linux equivalent | Win | Linux |
| --- | --- | --- | --- | --- | --- |
| Hosted sessions | Bundled tmux at `Contents/Helpers/tmux` (`scripts/build-tmux.sh`), server `tmux -L sidea`, zsh launcher `runtime/sidea-tmux` (`bridge/hosting.py`, `Sources/SideA/HostedSessions.swift`, `docs/remote/hosting.md`) | No tmux. Either agents in WSL use WSL's tmux, or the daemon owns ConPTY sessions itself | Distro tmux 3.4+ or a bundled static build; the zsh launcher becomes POSIX sh or is folded into the daemon | redesign | layer |
| Reading a hosted screen (ready, composer, take-back) | `tmux capture-pane` text parsed by `Hosting` | ConPTY gives a VT byte stream, not a screen; the daemon needs a terminal emulator model to produce one | `capture-pane` | redesign | as is |
| Phone terminal stream | One tmux client per viewer on a PTY from `sidea_pty_spawn` (`Sources/CSideAPTY/pty.c`, `TerminalHub.swift`) | ConPTY per viewer, or the daemon fans out one ConPTY's output | `forkpty` as is | redesign | as is |
| `sidea attach` | tmux attach in the current terminal | A console client that connects to the daemon over a named pipe and relays bytes and resizes | tmux attach | redesign | as is |
| Worktrees for hosted sessions | `git worktree add`, `.git/info/exclude`, `.env*` copies (`SECURITY.md`) | Same git commands | Same | as is | as is |

### 2.4 Side A Remote (the phone)

| Capability | How it works on macOS | Windows equivalent | Linux equivalent | Win | Linux |
| --- | --- | --- | --- | --- | --- |
| HTTPS and WebSocket server | `NWListener` with TLS 1.3, own HTTP/1.1 parser and WebSocket framing (`Sources/SideA/Remote/RemoteServer.swift`, `SocketFront.swift`; pure parts in `Sources/SideACore/Remote/HTTP.swift`, `WebSocketCodec.swift`) | Network.framework does not exist. SwiftNIO with NIOSSL; NIO's Windows support **(verify)** | SwiftNIO with NIOSSL | layer (large) | layer (large) |
| TLS identity | P-256 key made with `/usr/bin/openssl`, imported to the Keychain (`docs/remote/mac-server.md` "Listeners") | Generate in-process (swift-certificates); key in DPAPI | Same; key in Secret Service or a 0600 file | layer | layer |
| Device tokens, relay key, transcription key | Keychain (`DeviceStore.swift`, `RemoteKeychain.swift`) | DPAPI-protected file or Credential Manager | Secret Service or 0600 file | layer | layer |
| Pairing, signed confirms, rate limits | Pure logic in `Sources/SideACore/Remote/` (`PairingCode.swift`, `ConfirmGate.swift`, `RemotePolicy.swift`) using CryptoKit | swift-crypto (`Crypto`, API-compatible) | swift-crypto | as is (after import swap) | as is (after import swap) |
| Pairing UI | Pair iPhone sheet with QR and comparison code | Tray window, or QR in the terminal (`sidea pair`) | Same | layer | layer |
| Relay tunnel | `TunnelClient.swift` and protocol `Tunnel.swift` use `NWConnection` | SwiftNIO or URLSession WebSocket (FoundationNetworking's WebSocket support on Windows **(verify)**) | Same | layer | layer |
| Push through the relay | Ed25519-signed requests, sealed payloads (`RelayClient.swift`, `RemotePush.swift`); relay is a Cloudflare Worker (`relay/src`) | Client code is Foundation plus crypto; relay unchanged | Same | as is | as is |
| Tailscale address and status | `tailscale status --json`, cross-checked with a `utun` interface in `100.64.0.0/10` (`TailscaleStatus+CLI.swift`, `RemoteAddresses.swift`) | `tailscale.exe`; the adapter is named "Tailscale"; inside WSL 2 the tailnet is not visible unless Tailscale runs in the distro or networking is mirrored | `tailscale0` | layer | layer |
| Firewall check | `socketfilterfw` (`Sources/SideACore/Remote/FirewallStatus.swift`) | Windows Defender Firewall via `INetFwPolicy2`; first listen on a non-loopback address may prompt, and adding a rule needs admin **(verify)** | ufw, firewalld, nftables: report best effort only | layer | layer |
| Transcripts, images, diffs, search, uploads, file mentions | Bridge pages and image index (`docs/remote/bridge.md`), `RemoteUploads.swift`, `FileMentions.swift` | Same with Windows paths | Same | layer | as is |
| Dev-server previews | Forward to one port on `127.0.0.1` with a cookie credential (`RemotePreview.swift`) | Same; check the port's owner | Same, and check the listening socket belongs to the user (multi-user hosts) | layer | layer |
| Screen view † | ScreenCaptureKit plus VideoToolbox H.264 (`ScreenCapture.swift` †, `ScreenShareHub.swift` †), Screen Recording permission | Windows.Graphics.Capture or DXGI Desktop Duplication, Media Foundation H.264 encoder | X11: XShm or XComposite. Wayland: `org.freedesktop.portal.ScreenCast` with PipeWire, one prompt per session unless a restore token is kept. Encoder: VA-API, or OpenH264 (patent and packaging issues on Fedora) | layer (large) | redesign |
| Screen control † | `CGEvent` posting, Accessibility permission, lock check (`ScreenInput.swift` †) | `SendInput`; cannot reach elevated windows (UIPI) or the secure desktop (UAC, lock screen) | X11: XTest. Wayland: `org.freedesktop.portal.RemoteDesktop` or libei | layer | redesign |
| Display assertion while watching † | IOKit `PreventUserIdleDisplaySleep` (`ScreenShareHub.swift` †) | `ES_DISPLAY_REQUIRED` | logind or `org.freedesktop.ScreenSaver.Inhibit` | layer | layer |
| Dictation † | Phone audio sent to the Mac, which calls `api.openai.com/v1/audio/transcriptions` with a key it keeps (`Transcription.swift` †); AVFoundation only for the Mac's own test phrase | HTTP as is; drop or replace the test phrase | Same | layer | layer |
| Autopilot and rotation from the phone, snoozes †, handoffs † | Routes in `RemoteRoutes+Rotation.swift`, `RemoteRoutes+Snooze.swift` †, `RemoteRoutes+Handoffs.swift` † over app stores | Same once routes are platform-neutral | Same | layer | layer |

### 2.5 Keep awake, lifecycle, distribution

| Capability | How it works on macOS | Windows equivalent | Linux equivalent | Win | Linux |
| --- | --- | --- | --- | --- | --- |
| Keep awake while agents work | IOKit `PreventUserIdleSystemSleep` assertion named "Side A: 3 agents working" (`KeepAwakeController.swift`, policy in `Sources/SideACore/KeepAwake.swift`) | `PowerCreateRequest` + `PowerSetRequest(PowerRequestSystemRequired)` with a reason string (shows in `powercfg /requests`), or `SetThreadExecutionState` | logind `Inhibit("idle:sleep", …)` over D-Bus, same as `systemd-inhibit` | layer | layer |
| Also with the lid closed | Root helper `SideAKeepAwake` via `SMAppService.daemon`, XPC with code-signing requirement, runs only `pmset disablesleep` (`Sources/SideAKeepAwake`, `SECURITY.md` "Keep awake") | The lid action is a power-scheme setting (`powercfg … LIDACTION`), system-wide, admin to change **(verify)**; Modern Standby machines may sleep regardless of requests **(verify)** | logind `handle-lid-switch` inhibitor, no root; whether polkit allows it for the active local user by default and whether GNOME's own lid handling respects it **(verify)** | redesign / maybe cannot | layer |
| Battery and power source | `IOPSCopyPowerSourcesInfo` | `GetSystemPowerStatus` | UPower over D-Bus, or `/sys/class/power_supply` | layer | layer |
| Who is at the machine (quiet updates) | `CGEventSource` idle time, `CGSessionCopyCurrentDictionary` lock (`UserPresence.swift`) | `GetLastInputInfo`, WTS session lock notifications | logind `IdleHint` and `LockedHint`; Wayland `ext-idle-notify-v1` | layer | layer |
| Open at login | `SMAppService.mainApp` (`AccountStore.swift`) | `HKCU\…\Run` value, or `StartupTask` in an MSIX package | systemd user unit (headless and desktop) or XDG autostart `.desktop` (desktop UI) | layer | layer |
| One copy running | `AppCopies.claimLaunch` | Named mutex | Lock file under `$XDG_RUNTIME_DIR` | layer | layer |
| Local storage | `~/Library/Application Support/SideA/` (`docs/architecture.md` "Local storage") | `%LOCALAPPDATA%\SideA\` (not `Roaming`: holds per-machine state and sockets) | `$XDG_STATE_HOME/side-a` or `$XDG_DATA_HOME/side-a`; sockets in `$XDG_RUNTIME_DIR`; logs under `$XDG_STATE_HOME` | layer | layer |
| Shared preferences | `UserDefaults` plus `preferences.json` (`PreferencesMirror.swift`) | `preferences.json` alone | Same | layer | layer |
| Sync with other machines | iCloud Drive folder `Library/Mobile Documents/com~apple~CloudDocs` (`AccountStore.swift`) | iCloud for Windows has a folder, unsupported here | None | cannot (now) | cannot (now) |
| Updates | Sparkle 2.9.6, Ed25519 appcast at `getsidea.com/appcast.xml`, quiet install (`docs/updates.md`, `Updates.swift`) | WinSparkle reads Sparkle appcasts (EdDSA support **(verify)**), or MSIX App Installer, or winget | apt and dnf repositories (Claude Code does this), AppImage with zsync, tarball | redesign | redesign |
| Signing | Developer ID, hardened runtime, notarization (`docs/distribution.md`, `scripts/notarize-app.sh`) | Authenticode; SmartScreen reputation | GPG-signed repositories; binaries themselves unsigned | redesign | redesign |
| Remove Side A | Undo shell line, statusline, hooks, helper; move app to Trash (`README.md` "General") | Same undo; uninstaller entry | Same undo; package removal leaves user files, so `sidea uninstall` first | layer | layer |
| Diagnostics, analytics | `Diagnostics.swift` (pure), PostHog over HTTP | Same | Same | as is | as is |
| Sounds | `NSSound` (`Sounds.swift`) | `PlaySound` | libcanberra or skip | layer | layer |
| 3D player | SceneKit (`DiscmanView.swift`) | — | — | cannot (non-goal) | cannot (non-goal) |
| Menu bar, Settings, Sessions windows | SwiftUI `MenuBarExtra` and windows (`SideAApp.swift`, `SettingsView.swift`, `SessionsView.swift`) | Notification-area icon and new windows | StatusNotifierItem (AppIndicator) and new windows; stock GNOME shows no tray without an extension | redesign | redesign |

### 2.6 How each CLI stores credentials, per OS

| | macOS | Linux | Windows native | Windows, agent in WSL 2 |
| --- | --- | --- | --- | --- |
| Claude Code login | Keychain item `Claude Code-credentials` (falls back to `~/.claude/.credentials.json` when the Keychain refuses) | `~/.claude/.credentials.json`, 0600 | `%USERPROFILE%\.claude\.credentials.json`, profile-folder ACL | `~/.claude/.credentials.json` inside the distro, separate from the Windows one |
| With `CLAUDE_CONFIG_DIR` | Keychain item keyed to that folder | `.credentials.json` in that folder | Same | Same |
| Claude settings, hooks, sessions | `~/.claude/`, `~/.claude.json` | Same | `%USERPROFILE%\.claude\`, `%USERPROFILE%\.claude.json` | Distro home |
| Codex login | `auth.json` in `CODEX_HOME` (`~/.codex`), or the OS store with `keyring` | Same; `keyring` uses the Secret Service | Same; `keyring` uses Credential Manager | Distro home |
| Codex default store | Not stated in the docs; Side A forces `file` for its profiles | Same | Same | Same |

Consequence: on Linux and Windows, every Claude login Side A manages is a plain file readable by any process of the
same user. Side A does not make that worse for one account, but it multiplies it by the number of accounts. See
[security](#6-security-and-privacy).

## 3. Architecture

### What is already platform-neutral

| Part | State | Notes |
| --- | --- | --- |
| `Packages/SideAProtocol` `SideAProtocol` target (wire types) | Nearly | Foundation plus CryptoKit (`Pairing.swift`, `Confirm.swift`, `Push.swift`, `WebSocketFrames.swift`) and Network.framework in `Tunnel.swift`. Swap CryptoKit for swift-crypto and move `Tunnel`'s `NWConnection` plumbing out |
| `SideAProtocolFixtures` | Yes | JSON fixtures; usable as a conformance suite for any server |
| `SideARemoteKit` (phone client) | No, and it need not be | `NWTransport.swift`, `NWSocket.swift`, `RelayBridge.swift` use Network.framework. It only matters off Apple platforms if a desktop UI reuses it |
| `SideACore` pure logic | Mostly | Planner, island risk, pricing, diagnostics, keep-awake policy, HTTP and WebSocket codecs, pairing, policy. Non-portable files: `PoolProxy.swift` and `Remote/AppServerClient.swift` (Network), `Processes.swift`, `Memory.swift`, `ProcessEnvironment.swift`, `KeepAwake.swift`, `Remote/RemoteAddresses.swift` (Darwin) |
| `SideAKeepAwakeCore` | No | XPC and code-signing requirements; Mac only by nature |
| `Sources/SideA` (about 30k lines with Remote) | No | AppKit, SwiftUI, Network, Security, IOKit, ScreenCaptureKit, Carbon. Holds the Remote server, all routes, `AccountStore`, `SessionStore`, `Island`, `HostedSessions` |
| Python bridge (`bridge/*.py`, about 8k lines, stdlib only) | Mostly | Darwin-specific: `security` CLI, `~/.zshrc`, `ps`/`lsof`, zsh launchers, `fcntl` (absent on Windows), `AF_UNIX` in the hook, `/Library/Managed Preferences` |
| Relay (`relay/`, Cloudflare Worker) | Yes | No change. Each new install adds tunnel and push load; see open questions |
| `Sources/CSideAPTY` | POSIX | `forkpty`-style spawn works on Linux; Windows needs ConPTY |

### What the iOS app needs

No change: `SideARemoteKit` (transport, sync engine, outbox, reconciler, relay bridge, pinned TLS), pairing and the
comparison code, push decryption in the Notification Service Extension, Live Activities, widgets, the transcript and
terminal views (SwiftTerm), the confirm and unlock keys.

Small changes:

- **Host kind.** `Hello.mac` is `MacInfo{id, name}` (`Packages/SideAProtocol/Sources/SideAProtocol/Pairing.swift`).
  Add an optional `os` (open enum: `macos`, `linux`, `windows`, `wsl`) and a `headless` flag. Additive, so older
  phones keep working.
- **Copy.** About 117 string literals in `apps/ios` say "Mac". They need a host noun ("your computer", or the
  host's name) where the host is not a Mac. "Show on Mac", "Mac's Screen" and Mac settings paths in help text
  become per-OS.
- **Screen control key bar** offers ⌘ ⌥ ⌃ ⇧ (`Features/Screen/ScreenCanvas.swift`). On Windows and Linux it should
  offer Ctrl, Alt, Super/Win, Shift, mapped on the host. The wire `key{modifiers}` names (`command`, `option`) stay;
  the host maps them.
- **Refusal words** for screen sharing (`ScreenRefusal` in the protocol package) name Screen Recording and
  Accessibility. The host sends its own words already; the phone should show what it receives.
- **Capabilities** do the rest: a headless daemon simply omits `screen`, `screen.on`, `mac` and other
  capabilities it does not serve, and the phone already hides what the Mac doesn't offer.

### Options

| | (a) Swift core, native shells | (b) Core in Python bridge or a Rust/Go daemon, thin UIs | (c) Tauri or Electron shell over a shared core | (d) Headless daemon first, then tray UI |
| --- | --- | --- | --- | --- |
| What it is | Move the Remote server, routes and stores into platform-neutral Swift; run it on Linux and Windows; write a UI per OS (WinUI/C# or Win32; GTK) | Rewrite the server and stores in Python, Rust or Go; Mac keeps Swift or migrates | One web-tech UI for Windows and Linux, over whichever core | A daemon plus `sidea` CLI, with the phone as the main UI; a tray UI later as a client of the daemon |
| Reuse | Planner, risk rules, codecs, pairing, protocol types, fixtures, tests | Fixtures only; Python reuses the bridge | Depends on core choice | Same as (a) for the core |
| Protocol changes | Once, in Swift, for every OS | Twice forever (Swift on Mac, new language elsewhere) unless the Mac also moves | Depends on core | Once |
| Swift on Linux | Mature for servers (SwiftNIO, swift-crypto, Foundation) | — | — | Same as (a) |
| Swift on Windows | Toolchain and Foundation work; SwiftNIO on Windows and FoundationNetworking WebSockets are the risk **(verify)** | Rust and Go are strong on Windows (ConPTY crates, `windows-rs`, named pipes) | — | Same risk as (a), deferred to a later phase |
| Python as core | — | Stdlib cannot generate certificates, has no H.264, needs an interpreter shipped on Windows; fine for data work it already does | — | Keeps Python for the data work only |
| Desktop UI cost | Two native UIs (C#/WinUI, GTK), plus the Mac's | Thin UIs, still per OS or web | One UI for two OSes; Tauri has tray support on both (Linux via AppIndicator); Electron is heavy for a tray app | Deferred; then (c) or native, decided with real usage |
| Time to first usable release | Long (UI first) | Longest (rewrite) | Long (core still needed) | Shortest |
| Fit for headless Linux servers | Poor until headless mode exists | Good | Poor | Good |
| Main risk | UI scope; Windows Swift networking | Rewrite size (about 17k lines of Swift logic and its tests) and permanent double maintenance | Bundle size and a second toolchain | Refactor of the Mac app's stores off `@MainActor` and AppKit |

**Recommendation: (d), with the core in Swift as in (a).** The tray UI, when it comes, is a client of the daemon's
local API, and Tauri is the default choice for it on both OSes, to be confirmed after the daemon ships (see open
questions). A Rust or Go core is the fallback for Windows only if the phase-0 spike shows Swift networking on Windows
is not workable; it would then cover Windows alone, not replace the Mac or Linux core.

### Target shape

```
            iPhone (unchanged)            sidea CLI            tray UI (later)
                  │  TLS 1.3, pinned          │  local socket       │  local socket
                  ▼                           ▼                     ▼
  ┌──────────────────────── sidead (Swift) ─────────────────────────────────────┐
  │  RemoteCore: HTTP/WS server (SwiftNIO), routes, events, pairing, push       │
  │  SessionCore: accounts, planner, island queue, hosted sessions, keep-awake  │
  │  Platform protocols: SecretStore, PowerManager, ProcessTable, Pty/Host,     │
  │    Notifier, ScreenSource, InputSink, Autostart, Paths                      │
  └──────────┬──────────────────────────────┬──────────────────────────────────┘
             │ runs per action              │ hooks over AF_UNIX / named pipe
        Python bridge (stdlib)        island_hook.py inside Claude Code / Codex
```

On the Mac the same `RemoteCore` and `SessionCore` run inside SideA.app with the AppKit implementations of the
platform protocols, so the Mac and the daemon share every route.

## 4. Platform specifics that are easy to get wrong

### Windows has no tmux

- **Native agents.** Claude Code runs natively on Windows 10 1809+ from PowerShell or CMD; with Git for Windows it
  uses Git Bash for its Bash tool, otherwise its PowerShell tool. Its files are in `%USERPROFILE%\.claude`. Codex
  also runs natively with its own Windows sandbox; third-party guides disagree on the sandbox names and defaults, and
  OpenAI labelled Windows support experimental earlier in 2026 **(verify current state)**.
- **WSL agents.** Inside WSL 2, both CLIs are Linux programs with Linux paths in the distro's home. A user can have
  both: a native `claude` with one login and a WSL `claude` with another. Side A has to treat each WSL distro as a
  separate host, with its own accounts, sessions and hooks.
- **Hosting natively** means owning ConPTY sessions in the daemon: create the pseudo console, keep it alive when no
  one watches, feed every viewer (a `sidea attach` console client, the phone) its output, and keep a VT screen model
  so `Hosting`'s screen reads (ready, composer, take-back) work. That is a small tmux. Windows Terminal is only a
  viewer; it cannot keep a session alive after its tab closes.
- **Hosting in WSL** uses WSL's tmux and the Linux daemon unchanged.
- **Reaching WSL.** WSL 2 uses NAT by default; a daemon inside it is not reachable on the LAN or tailnet unless
  networking is mirrored (Windows 11) or Tailscale runs inside the distro. The relay tunnel is outbound, so the
  phone reaches it either way.
- **WSL and power.** A daemon inside WSL cannot hold a Windows power request itself; it would call a small Windows
  helper through interop (`powershell.exe` or a bundled `.exe`) **(verify that interop works from a systemd unit in WSL)**.
- **Windows paths in transcripts** (`C:\…`, case-insensitive, `\\?\` long paths) break code that assumes `/`. The
  bridge's project grouping and worktree matching need Windows path rules.

### Linux tray and desktop fragmentation

- **Tray.** KDE, Xfce, Cinnamon and Ubuntu's GNOME show StatusNotifierItem icons. Stock GNOME (Fedora, Debian GNOME)
  shows none without the AppIndicator extension. The daemon must be fully usable with no tray, which (d) guarantees.
- **Wayland versus X11.** Wayland is the default on current GNOME, KDE and Ubuntu. Under Wayland an app cannot place
  its own window, keep it above others, read the screen or inject input without a portal. X11 allows all of it, for
  every client, with no permission.
- **Screen capture** on Wayland goes through `xdg-desktop-portal` ScreenCast and a PipeWire stream. The user picks
  a screen or window in a system dialog. Portal version 4+ can return a restore token so later sessions skip the
  dialog where the backend supports it **(verify per backend: GNOME, KDE, wlroots)**. A headless server has no
  screen to share; the capability is simply absent.
- **Input** on Wayland goes through the RemoteDesktop portal (with libei on newer stacks), also behind a dialog.
- **H.264** encoders: VA-API is hardware-dependent; OpenH264 from Cisco is the usual licensed software path; Fedora
  ships no H.264 encoder in its base repositories. Decide whether to bundle OpenH264 or download Cisco's binary at
  first use **(verify licensing terms)**.
- **Notifications** with actions work on GNOME and KDE; inline text reply is not portable. Reply stays on the phone.
- **Global shortcuts** on Wayland need the GlobalShortcuts portal; support varies by desktop **(verify GNOME)**.

### Credential storage

- **Claude and Codex logins are files** on Linux and Windows (section 2.6). Side A swaps files under the same mkdir
  locks it already uses. Whether a running Claude Code session re-reads `.credentials.json` within about 30 seconds,
  as it re-reads its Keychain item on the Mac, decides whether trades work at all. **Verify before phase 2.**
- **Side A's own secrets** (device token hashes, TLS key, relay Ed25519 key, transcription key, trade journal,
  backups):
  - Windows: DPAPI (`CryptProtectData`, user scope) for files of any size. Credential Manager blobs are capped at
    2,560 bytes (`CRED_MAX_CREDENTIAL_BLOB_SIZE`), smaller than some Claude credential files with MCP tokens, so do
    not put logins there.
  - Linux desktop: Secret Service over D-Bus (gnome-keyring; KWallet implements it on current KDE **(verify version)**).
    The bridge is stdlib-only, so it would call `secret-tool` or `busctl`, or ask the daemon.
  - Headless Linux: no Secret Service, often no D-Bus session. Fall back to 0600 files under the state directory and
    say so in `sidea status`. Do not start a keyring daemon on the user's behalf.
- **Python on Windows** has no `fcntl`; the bridge's `flock` locks need `msvcrt.locking` or the same mkdir locks.

### Keep awake

- Windows: `PowerCreateRequest`/`PowerSetRequest(PowerRequestSystemRequired)` gives a named, inspectable request
  (`powercfg /requests`); `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` is the older form. Neither
  stops a lid close. Changing the lid action edits the power scheme and needs admin **(verify)**; on Modern Standby
  hardware the behaviour with the lid closed may differ again **(verify)**. Recommend no lid-closed option on Windows.
- Linux: hold a logind inhibitor (`Inhibit("idle:sleep", "Side A", "3 agents working", "block")`) for as long as the
  returned file descriptor stays open; closing it (or the daemon dying) releases it, which is the crash safety the
  Mac helper builds by hand. `handle-lid-switch` is a separate inhibitor type and needs no root helper if polkit
  allows it **(verify)**. Headless servers usually never idle-sleep; the inhibitor is harmless there.

### Autostart and background helpers

- Linux: a systemd user unit for the daemon (`sidead.service`, `Restart=on-failure`), started at login; on servers,
  `loginctl enable-linger` keeps it running without a login, which the user must choose (it needs no root on most
  distros, but policy can forbid it **(verify)**). XDG autostart (`~/.config/autostart/*.desktop`) for the tray UI.
  The pool helper becomes a second user unit.
- Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` for the tray UI; the daemon either runs as a child
  the tray starts, or as a per-user Task Scheduler task at logon. No Windows service: services run in session 0 and
  cannot reach the user's ConPTY consoles, notifications or screen.

### Packaging, signing and updates

- **Linux formats.** `.deb` and `.rpm` from a signed apt and dnf repository (what Claude Code itself does), plus a
  tarball for everyone else. AppImage is possible for the desktop UI later. Ship x86_64 and arm64.
- **Flatpak and Snap do not fit.** Side A must run the user's `claude` and `codex`, read and write `~/.claude`,
  `~/.codex` and shell rc files, list and signal host processes, run tmux and own PTYs. In Flatpak that means
  `--filesystem=home` and `flatpak-spawn --host`, which removes the sandbox; Flathub review is unlikely to accept it
  **(verify current Flathub policy)**. Snap classic confinement needs manual approval.
- **Windows formats.** An MSIX package gives clean install, uninstall, `StartupTask` and App Installer updates, and
  is required for some toast features without a shortcut; but MSIX file-system virtualization of `AppData` writes
  needs care, since Side A writes into `%USERPROFILE%\.claude` **(verify which writes MSIX redirects)**. A signed
  MSI or Inno Setup installer plus a winget manifest is the conservative alternative.
- **Windows signing.** Authenticode for every `.exe` and the installer. SmartScreen warns on new publishers until
  reputation builds; EV certificates no longer skip that **(verify)**. Microsoft's cloud signing service is the cheap
  route; eligibility for individuals by country **(verify)**.
- **Updates.** Linux: the package repository is the updater; the daemon only tells the phone a newer version exists.
  Windows: WinSparkle (reads the same appcast format; EdDSA verification **(verify)**) or MSIX App Installer. Keep
  the "install only when quiet" rules from `docs/updates.md`; a package manager upgrade can restart the daemon at any
  time, so the daemon must hand over like the Mac's `willRelaunch` path on `SIGTERM`.
- **Python.** Linux distributions ship Python 3.9+; the bridge already prefers 3.11+ for `tomllib`. Windows has no
  system Python (the Store stub opens the Store); ship the official embeddable Python in the installer.
- **tmux.** Debian 12 ships tmux 3.3a; Side A requires 3.4+ (`bridge/hosting.py`). Bundle a static tmux in the Linux
  packages, as the Mac bundles one, or depend on the distro version where it is new enough.

## 5. Phased plan

Order: Linux before Windows. Linux reuses the most (POSIX, tmux, `forkpty`, the bridge), serves the headless
servers no other Side A form can, costs the least in CI, and has no signing gate. Windows first via WSL 2, because
that is the Linux build.

| Phase | Ships | Size | Main risks |
| --- | --- | --- | --- |
| 0. Decide and spike | Answers, not features: the verify items below, a SwiftNIO TLS server plus the protocol package building on Linux and Windows, `os` added to `MacInfo` | S | Claude Code may not re-read `.credentials.json` mid-session, which would turn trades into restarts |
| 1. Shared core | A normal Mac release built on new `RemoteCore`/`SessionCore` targets with Mac implementations of the platform protocols; no user-visible change | L | Moving `AccountStore`, `SessionStore`, `Island`, `HostedSessions` and routes off `@MainActor`/AppKit without regressions; the protocol keeps moving meanwhile |
| 2. Linux headless daemon (minimum lovable) | `sidead` + `sidea` CLI as `.deb`/`.rpm`/tarball; accounts, limits, Autopilot trades, hooks to the phone, hosted tmux sessions, terminal stream, pairing in the terminal, relay and push, keep-awake inhibitor, systemd user unit; phone update with host kind and copy | L | Credential-file trades; shell integration across bash, zsh and fish; relay load from new installs |
| 3. Linux desktop | Tray (SNI) with limits and a waiting count, settings and pairing window, notifications with Allow/Deny, screen view and control on X11 and through Wayland portals, pool mode, lid-closed inhibitor | M (L with screen) | Wayland portals and H.264 encoder licensing; GNOME without a tray |
| 4. Windows via WSL 2 | The Linux daemon installed in a WSL distro, a small Windows helper for power requests and toasts, docs for mirrored networking or Tailscale in WSL | S–M | Interop from systemd units in WSL; two homes for one user |
| 5. Windows native daemon | Swift daemon on Windows: ConPTY host with a VT screen model, named-pipe hooks, DPAPI, power requests, Task Scheduler autostart, PowerShell profile or `PATH` shim, signed installer and winget | L | Swift networking on Windows; ConPTY hosting is the size of a small tmux; graceful stop without `SIGTERM`; SmartScreen |
| 6. Windows desktop | Tray, toasts with actions, top-most island window, global shortcuts, screen view and control (Graphics Capture + Media Foundation + `SendInput`) | M–L | UIPI and secure desktop limits for control; packaging for toast activation |
| Later | Island overlay on Linux X11/KDE, generic sync folder, Codex native Windows reply path once verified | — | — |

### Before work starts

1. Is this a product goal, and for which user first (headless Linux servers or desktops)? The plan assumes servers.
2. Accept the phase-1 refactor of the Mac app as the price of one implementation.
3. Swift for the daemon, with a phase-0 exit criterion for Windows.
4. Whether pool mode ports at all (Anthropic does not support routing a subscription through a proxy; `SECURITY.md`).
5. The phone's host-kind field and copy change, and an App Store release to carry it before phase 2 ships.
6. Distribution: Linux binaries are public once published while the source stays private; confirm that is acceptable.
7. Budget for Windows signing and for relay load.

## 6. Security and privacy

What changes in `SECURITY.md`'s model:

| Area | macOS today | Linux | Windows |
| --- | --- | --- | --- |
| Managed logins | Keychain items; reads go through `security` and the Keychain's ACL | 0600 files; any process of the same user can read every managed account's login. State this in the README and Settings | Files under the profile ACL; same exposure. DPAPI does not help, because Claude Code must read the active login in plain form |
| Idle accounts' logins | Keychain profile items | Could be kept in the Secret Service and written to a file only when a session needs them; adds a second copy during moves, which the "never two live copies" rule forbids. Recommend plain files with the same rules as the Mac, and say so | Same |
| Side A's own secrets | Keychain (`AfterFirstUnlockThisDeviceOnly` for device token hashes) | Secret Service when present, else 0600 files; headless servers get files | DPAPI user scope |
| Hook socket | `AF_UNIX`, 0600, peer uid | Same with `SO_PEERCRED` | Named pipe, DACL for the user's SID, client process id checked; no network exposure |
| Pool proxy and previews on loopback | Single-user Macs in practice | Loopback is shared by every user on a multi-user server. The pool key already gates the proxy; previews must also check that the target port's socket belongs to the same uid, or another user's dev server could be proxied to the phone | Same check via the TCP table's owning pid |
| Root helper | `SideAKeepAwake` runs as root behind an XPC code-signing check | Not needed: logind inhibitors are per user. The privileged component disappears | Lid control would need admin; recommend none |
| Screen recording and input | macOS TCC: the person at the Mac grants Screen Recording and Accessibility | X11: no gate, any client can capture and inject, so Side A's own switch is the only gate. Wayland: the portal dialog is a gate per session | No OS gate for capture or `SendInput`. Side A's switch, set only at the machine (never from the phone), plus a visible "being watched" indicator, is the whole gate |
| Code-signing trust | Helper and app check each other's Team ID | No equivalent; rely on file ownership and modes | Authenticode can be checked for the pipe client but is not required for the MVP |
| Update integrity | Ed25519 appcast plus Developer ID and notarization | Repository GPG signatures; the daemon never downloads and runs code itself | Authenticode plus the feed's signature |
| Process signalling | Never pid 0, `launchd` or itself | Never pid 1 or the daemon; re-check pid and start time from `/proc` | No `SIGTERM`; a quit is a console control event or a kill, and the confirm text must say which |
| Destructive-command flags | Shell grammar (`Sources/SideACore/Island.swift`) | Same | Must learn PowerShell and `cmd` forms; until then, any PowerShell command rates at least Unlock on the phone |
| Relay | Sees install id, device ids, IPs, timing, sizes | Same | Same |
| Remove Side A | Removes hooks, shell lines, helper, keys, relay registration | `sidea uninstall` before package removal; package scripts cannot reach the user's home safely | Uninstaller runs the same undo for the installing user only |

Nothing about the phone's side of the model changes: pinned TLS, signed confirms, the lock-screen allowlist, sealed
pushes and per-device revocation are host-independent.

## 7. Testing without owning every distro

### CI matrix

Hosted CI runs on manual dispatch only today (`docs/updates.md` "Local release"); Linux runners cost the least, so
the Linux jobs can run more often than the Mac ones.

| Job | Runner | Runs |
| --- | --- | --- |
| Protocol and core | `ubuntu-24.04`, `ubuntu-24.04-arm` | `swift test` for `SideAProtocol` and the new core targets; fixture conformance |
| Bridge | Containers: Debian 12, Ubuntu 22.04 and 24.04, Fedora current, Arch | `python3 -m unittest discover -s bridge/tests` with the oldest and newest supported Python |
| Daemon integration | `ubuntu-24.04` | Daemon against fake agents in tmux, hooks over the socket, and a test client speaking the protocol from the fixtures (`SideARemoteKit` itself uses Network.framework and won't build on Linux) |
| Packages | Containers per distro | Install the `.deb`/`.rpm`, start the user unit under `systemd --user` (needs a container with systemd), run `sidea status` |
| Windows | `windows-2022` or `windows-2025` | Swift build of core targets, bridge tests under the embeddable Python, ConPTY host tests (phase 5) |
| Mac | Existing jobs | Must stay green through phase 1 |

### Fake agents

`Tests/SideATests/Fixtures/FakeAgents/fake-claude.py` † and `fake-codex.py` † draw Claude Code's and Codex's prompts
in a tmux pane and record what they receive; `Tests/SideATests/FakeAgentTests.swift` † drives them through
`HostedSessions`. They need only Python and a POSIX tty, so they run unchanged on Linux once the test target no
longer requires the Mac-only `SideA` target, and once the test's tmux lookup (hard-coded to `/opt/homebrew/bin` and
`/usr/local/bin`) also searches `PATH`. On Windows they cannot run as written (`tty.setraw`, `select` on stdin);
phase 5 needs a variant that reads console input through `msvcrt` inside a ConPTY. Extend the fakes, not real CLIs,
for hooks: a fake `claude` that runs the configured `PermissionRequest` and `Stop` hook commands with recorded inputs
would cover the island path end to end without an account.

### What needs a real machine

- Real Claude Code and Codex logins: renewals, trades and the mid-session re-read of `.credentials.json`. Never in CI.
- GNOME and KDE on Wayland: tray presence, notifications with actions, portal dialogs for screen and input,
  restore tokens.
- Laptops: idle sleep and lid close with the inhibitors held; Windows Modern Standby.
- Windows: SmartScreen on a fresh machine, the firewall prompt, toast activation from an installed package, WSL
  mirrored networking, native Codex.
- The phone against each host over LAN, Tailscale and the relay, including push.

A small fixed set of machines is enough: one Ubuntu LTS desktop (GNOME, Wayland), one Fedora KDE, one headless
Debian server or VM, one Windows 11 laptop with WSL 2.

## 8. Open questions for the owner

Ranked by how much they change the plan.

1. **Is the first target the headless Linux server or the Linux desktop?** Recommended: the server. It is the
   case no other Side A form covers, the phone already is its UI, and the desktop pieces are where most of the
   fragmentation is.
2. **Accept a phase-1 refactor that moves the Remote server and stores out of the Mac app target?** Recommended:
   yes. Without it every protocol change is made twice. Schedule it in a quiet week for the protocol, since the
   branch moves fast.
3. **Swift for the daemon on Windows, or a Rust/Go daemon there?** Recommended: Swift, with a phase-0 gate: if a
   SwiftNIO TLS 1.3 server with the protocol package does not build and pass the fixture suite on Windows within the
   spike, decide again before phase 5, not before phase 2.
4. **Do trades work with file credentials?** This is a fact to establish, not a preference, but the answer decides
   whether Autopilot on Linux moves running sessions or only picks accounts for new ones. Recommended: test it in
   phase 0 with two real accounts; if Claude Code does not re-read the file, ship Linux with "new sessions follow
   Autopilot, running ones finish where they are" and say so.
5. **Port pool mode?** Recommended: not in the minimum; reconsider after phase 3. It routes subscriptions through a
   proxy, which Anthropic does not support, and it adds a long-lived listener on multi-user machines.
6. **How should the phone name a host that isn't a Mac?** Recommended: add `os` and `headless` to `MacInfo`, keep
   the type name for wire compatibility, use the host's name in copy, and ship that phone update before phase 2.
7. **One phone, several hosts?** The phone already stores Macs by id. Recommended: confirm the iOS app handles a
   Mac and a Linux server paired at once without new UI; if not, that is phone work for phase 2.
8. **Relay cost and limits for more installs.** Headless servers keep tunnels open all day. Recommended: keep the
   per-install daily allowance as is and watch Durable Object usage during a Linux beta before a public release.
9. **Windows lid-closed keep-awake.** Recommended: do not offer it. It needs admin to change a system-wide power
   setting, and Modern Standby makes the result unreliable.
10. **Screen sharing on Linux: X11 only, or Wayland too?** Recommended: Wayland through portals from the start of
    that work (it is the default everywhere), X11 as the simpler fallback; skip screen control under GNOME if its
    RemoteDesktop portal proves unreliable.
11. **Package formats.** Recommended: Linux `.deb` and `.rpm` from a signed repository plus a tarball; no Flatpak or
    Snap. Windows: signed installer plus winget first, MSIX only if toast activation demands it.
12. **Tray toolkit when the time comes.** Recommended: Tauri as a client of the daemon's local API for both Windows
    and Linux, decided after phase 2 with real usage; native WinUI and GTK only if Tauri's tray support falls short
    on GNOME.
