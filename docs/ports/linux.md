# Side A on Linux (`sidead`)

`sidead` is a headless daemon: the Side A Remote iPhone app is its only interface. It pairs with the phone, lists and
reads the Claude Code and Codex sessions on this computer, answers replies, starts sessions inside tmux, and reads each
Claude account's limits. It is the Swift core of the Mac app (`Sources/SideACore`, `Packages/SideAProtocol`) on SwiftNIO,
with the Mac's Python bridge (`bridge/`) for transcripts and hosting. Plan and reasons: [the PRD](windows-linux-prd.md);
what was measured first: [phase 0](phase-0.md). For Windows see [windows.md](windows.md).

## What you need

- Linux on x86-64 or arm64 with glibc 2.39 or newer (the binary is built on Ubuntu 24.04). Sessions have run on Ubuntu 24.04 (arm64 in Docker, x86-64 on a Synology NAS in a Docker container, kernel 4.4). On Fedora 40 and 41 the binary prints `--version` (their libcurl is already there); on Debian 13 (glibc 2.41) the only thing it lacked was `libcurl4t64`. Nothing more has been tried on them. Ubuntu 22.04 and Debian 12 are too old (glibc 2.35 and 2.36), and `install.sh` says so.
- **tmux 3.4 or newer** for hosted sessions (Ubuntu 24.04 and Debian 13 ship it, and are what the binary needs anyway; older systems would need
  a source build of this daemon and a newer tmux). Without it, sessions are listed and read but cannot be started or typed into.
- **libcurl** (`sudo apt install libcurl4t64`; `install.sh` says so if it is missing). The `.deb` pulls it in.
- **python3 3.9 or newer** (the bridge uses only the standard library).
- An iPhone with Side A Remote, and a way for it to reach this computer: Tailscale on both (the default), the same
  network (`--lan`), or Side A's relay (on by default, below).

## Install

The one line, from [getsidea.com/linux](https://getsidea.com/linux/). It picks the package for this computer, checks its
SHA-256 sum against the release's, refuses a system that is not Linux, not x86-64 or arm64, or has an older glibc, and runs
the package's `install.sh`:

```
curl -fsSL https://getsidea.com/install.sh | sh
curl -fsSL https://getsidea.com/install.sh | sh -s -- --no-service    # what follows -- goes to install.sh
```

`SIDEAD_VERSION=0.1.0` picks another version. Or by hand, from the tarball (no root; installs under `~/.local`):

```
tar xzf side-a-daemon-<version>-linux-<arch>.tar.gz
cd side-a-daemon-<version>-linux-<arch>
./install.sh                 # also sets up and starts a systemd user service
./install.sh --no-service    # files only; start it yourself with: sidead run
```

From the `.deb` (needs tmux >= 3.4 and python3 as dependencies):

```
sudo apt install ./side-a-daemon_<version>_<arch>.deb
systemctl --user enable --now sidead
```

Both come from `scripts/package-sidead.sh` (Docker; `--arch amd64|arm64|both`). To keep the service running when you are
logged out: `sudo loginctl enable-linger $USER`. Remove it with `~/.local/share/side-a/uninstall.sh` (`--purge` also deletes
the pairings and keys in `~/.local/state/side-a`), or `sudo apt remove side-a-daemon` for the `.deb`.
`scripts/ship-sidead.sh` builds both architectures, installs each package in a clean container, and writes the sums the
release carries.

Options for the service go in `~/.config/side-a/sidead.env` as one line, `SIDEAD_ARGS=...`:

| Option | Meaning |
| --- | --- |
| `--lan` | Also listen on this network's addresses. Without it only the tailnet and loopback are used. |
| `--project DIR` | A folder the phone may start sessions in; repeat for more. The home folder is the default. |
| `--relay URL` | Another relay than the default `https://push.getsidea.com` (below). `SIDEAD_RELAY_URL` does the same. |
| `--no-relay` | No relay at all: only the addresses the phone can reach itself. `SIDEAD_RELAY_URL=off` does the same. |
| `--no-tunnel` | With a relay, push notifications only. |
| `--allow-host NAME` | Also answer a phone that dials this address or name, which is not one of this computer's own: a port forward or a container's published port. Repeat for more. The code `sidead pair` shows still names the daemon's own addresses, so a phone has to be given the forwarded one. |
| `--port N`, `--listen ADDRESS`, `--name NAME`, `--state-dir DIR` | As named. `SIDEAD_HOME` also moves the state. |
| `--account-selector configdir\|securestorage` | See [Accounts](#accounts). |

`SIDEAD_CLAUDE` and `SIDEAD_CODEX` name the agent programs to start (default `claude` and `codex` on the login shell's
PATH); `SIDEAD_PYTHON` and `SIDEAD_BRIDGE` override where Python and the bridge are found.

## Pair the phone

```
sidead pair
```

shows a QR code, a code and a link. In Side A Remote choose Add a computer and scan it. The phone and `sidead pair`
each show six digits; check they match and answer on the computer (`y`). The phone then has a device token, kept hashed
in `~/.local/state/side-a`; `sidead devices` lists phones and `sidead revoke ID` removes one. `sidead status` prints
the address, the key fingerprint and the relay state; `sidead --version` prints the version. Run `sidead pair` and `sidead
status` in a login shell (over ssh or at the console), where `XDG_RUNTIME_DIR` is set: the service finds its control socket there,
and a shell without it (`su alex`, a bare `docker exec`) says `sidead isn't running`. Running the installer again upgrades and restarts the service.

## What works

Seen end to end (`scripts/linux-e2e.sh` and the NAS run [below](#a-real-machine-a-synology-nas), which use `Daemon/Probe`,
a client built on `SideARemoteKit`, the library the iPhone app uses, with a stand-in for Claude Code): pairing with the
comparison digits, hello, the accounts list, folders, starting a hosted session, its transcript, a typed reply, new messages
arriving on the events socket, ending the session, and the pairing surviving a restart of the daemon. The same run through
a relay tunnel with no direct address is below.

- Sessions: the running Claude Code and Codex sessions on this computer, their transcripts (paged and streamed), status,
  project and cost, as the Mac shows them. Rows come from `~/.claude/sessions` and each account's folder.
- Reply and interrupt: a reply is typed into the session's tmux pane; confirming signatures (`confirm.signed`) are checked
  the way the Mac checks them, and Face ID is needed unless the session is known to be in a non-raising mode.
- Hosted sessions: start (with a prompt), list, end. They run in tmux on Side A's own socket, so they survive the daemon.
- Accounts and limits: [below](#accounts).
- Away from home: the relay tunnel and push, [below](#relay-tunnel-and-push).

## What does not work yet

Not offered by the daemon (the phone hides them because the capability is absent): permission requests and the Allow/Deny
notifications (they need the Claude hook the island uses), questions and plans, worktrees, forking, photo attachments,
Show on Mac, notes, queued follow-ups, trust dialogs, the terminal view, preview of local servers, screen sharing,
dictation, Live Activities, Autopilot and trades, and pull requests. There is no tray icon, island or settings window.
The finished-turn push says "Ready for your next message." rather than quoting the reply.

## Accounts

Each account is a folder Claude Code keeps its login in, started with `CLAUDE_CONFIG_DIR=<folder>` (documented by
Anthropic). It holds that account's `.credentials.json`, settings, history and plugins, so accounts do not share anything.

```
sidead accounts add work     # makes ~/.local/share/side-a/accounts/work and prints the sign-in command
CLAUDE_CONFIG_DIR=~/.local/share/side-a/accounts/work claude auth login      # you run this; sidead never signs in for you
sidead accounts adopt main   # registers the login already in ~/.claude (--dir for another folder)
sidead accounts              # each account, whether it is signed in, and its 5-hour and weekly limits
sidead accounts remove work  # takes it off the list; its folder and login stay
```

The phone lists the same (`GET /v1/accounts`, the snapshot's accounts, `usage.update` events) and can pick an account when it
starts a hosted session; the session then runs with that account's `CLAUDE_CONFIG_DIR`, and the daemon reads sessions
and transcripts from every account's folder. Limits come from one request per account to Anthropic's usage endpoint with
that account's own token, at most once a minute. **`sidead` never refreshes a login**: a refresh token is spent when
used, and doing it outside Claude Code risks signing the account out. An expired token shows "sign in again" and the
last reading, marked old, until a session of that account runs and renews it.

`--account-selector securestorage` sets `CLAUDE_SECURESTORAGE_CONFIG_DIR` (what the Mac uses to move only the login)
instead. Anthropic does not document it and whether it moves the file on Linux is unknown, so it is off by default.

**Not built, and why.** The Mac trades logins between running sessions (Autopilot). On Linux that would mean copying a
`.credentials.json` over a running Claude's. Whether a running Claude Code re-reads the file when it changes is the open
test in [phase 0](phase-0.md) (two accounts, three outcomes). If it re-reads on refresh or on a 401, trades work as on
the Mac with a lazy hand-over; if it never re-reads, trades would be dangerous and stay off. Until that test is run on
a real login, the daemon does not advertise `accounts.use`, and one session keeps one account for its life.

## Relay tunnel and push

Unless you pass `--no-relay`, the daemon uses Side A's relay at `https://push.getsidea.com` (the Cloudflare Worker in
`relay/`, the one the Mac app uses; `--relay URL` names another) and registers itself as a relay install with its own Ed25519 key (kept in the
state folder), keeps one outbound WebSocket to it, and lets a phone in from anywhere: the phone's TLS still ends at the
daemon, pinned to the same key, so the relay moves bytes it cannot read. `sidead pair` then also puts the relay and a
one-time ticket in the QR. Push uses the same relay: the phone registers its APNs token, and the daemon sends a sealed
payload (ChaCha20-Poly1305, a key only the phone and daemon hold) when a hosted or live session finishes a turn. The relay
is not changed for any of this.

## Files and network

`sidead` writes only: its state folder (`~/.local/state/side-a`, or `$XDG_STATE_HOME/side-a`, mode 0700, secrets in 0600
files), `~/.local/share/side-a/accounts` for accounts you add, the bridge's runtime under the state folder (a `tmux.conf`
and per-session launch scripts), and the service's env file. It does not edit `~/.bashrc`, `~/.zshrc`, `~/.claude`
or `~/.codex`. Network: the TLS listener (default port 47800) on the addresses you chose, the relay (`push.getsidea.com`
unless `--no-relay` or `--relay URL`), and `api.anthropic.com` for each account's limits. `install.sh` from the site asks
`api.github.com` for the latest release and downloads one tarball. See [SECURITY.md](../../SECURITY.md).

## Checking it

| What | Command | Where |
| --- | --- | --- |
| Portable core and daemon tests, and start the binary | `scripts/linux-check.sh` (`--amd64`, `--here`) | Docker on a Mac, or a Linux host |
| End to end with a phone-side client | `scripts/linux-e2e.sh` (`SIDEA_E2E_RELAY=...` adds the relay run) | Mac with Docker |
| Install from the package in a clean container | `scripts/package-sidead.sh && scripts/linux-e2e.sh --package dist/linux/<tarball>` | Mac with Docker |

## A real machine: a Synology NAS

Run on a Synology DS1522+ (x86-64, DSM 7.2.1, **kernel 4.4.302**, 32 GB), whose own glibc is too old, so inside an
`ubuntu:24.04` container (Docker 24 on that NAS), unprivileged, with a systemd-enabled image and a published port. Nothing
else on the NAS was touched, and the containers, image, and folder were removed afterwards.

- **The tarball**, as the steps above say: `tar xzf`, `./install.sh` with tmux and python3 not yet installed (it warned,
  and said what to install), `sudo apt install tmux python3` (tmux 3.4, Python 3.12), `./install.sh` again. systemd ran in the
  container unprivileged on the 4.4 kernel (`systemctl is-system-running` said `running`; `loginctl enable-linger`). The user
  unit started, came back after `kill -9` (`Restart=on-failure`, `NRestarts=1`), and came back after the whole container was
  restarted, with the same key and the paired phones.
- **The `.deb`**: `uninstall.sh` removed the tarball install (state kept), then `sudo apt install ./side-a-daemon_..._amd64.deb`
  pulled in nothing missing, and `systemctl --user enable --now sidead` ran it.
- **`Daemon/Probe`, on a Mac, over the network** (`--lan`, Tailscale to the NAS, the NAS's port published and named with
  `--allow-host`): every step held for both installs: pair with the digits, hello and its capabilities, the accounts list, a
  hosted session under tmux with the stand-in agent, a typed reply, the transcript on the events socket, ending the session, and
  `--resume` after a daemon restart.
- **Through a relay**, with the relay's own code (`wrangler dev --local`, which ran on the 4.4 kernel too) in a second container
  on the NAS, and the daemon pointed at it with `--relay`: it registered (201) and opened its tunnel (101), and a second probe
  paired and ran the same steps with no direct address. The deployed relay was not used.
- **The real `claude` CLI** (2.1.332, installed with npm, never signed in, no credentials copied in): `sidead accounts add work`
  listed it `not signed in`; a hosted session started, the pane showed Claude's own first-run screen ("Let's get started",
  text style), and `sidead` stayed up. The daemon does not read the CLI's version; it only starts what `SIDEAD_CLAUDE` names.
- **Measured** (`sidead` 0.1.0): idle, 36 MB resident and 0.10 % of one core over 60 seconds, 12 threads; 40 MB with a hosted
  session running; the binary is 74 MB (the Swift runtime linked in, stripped), the tarball 28 MB, the `.deb` 21 MB; started by
  systemd it answered `sidead status` in 0.5 s (6 s the first time, with the disk busy).
- **Kernel**: no failure came from the 4.4 kernel, so no minimum was found; 4.4 is what is known to work. glibc 2.39
  itself needs 3.2.
- **Found and fixed on the way**: the daemon answers only Host names that are its own addresses, so a published port failed
  (`--allow-host`); `sidead status` did not print the relay; `uninstall.sh` was lost with the unpacked folder (the installer now
  keeps it); installing over a running service left the old binary running (it restarts now); the probe could not use the relay
  after the pairing ticket was spent.

What only a real machine confirms and is **not** proven: a real iPhone pairing and reading a real Claude session; a real
distribution other than Ubuntu 24.04 running sessions (Fedora 40 and 41 print the version, Debian 13 was only checked for what it lacks); a signed-in Claude (its limits from Anthropic's endpoint, a session that answers); push reaching a phone through
Apple; the deployed relay (the daemon was run against the relay's code, locally); the credentials re-read test above.

