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
  tmux 3.4 can leave the agent of a pane that stays after it exits unreaped (a zombie) until another of its children ends;
  the bridge and the daemon read `/proc/<pid>/stat`, so such an agent counts as ended, not running.
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
| `--port N`, `--listen ADDRESS`, `--name NAME`, `--state-dir DIR` | As named. `SIDEAD_HOME` also moves the state. With `--no-discover`, the addresses given with `--listen` are the ones `sidead pair` and hello name (loopback only when that is all it listens on). |
| `--account-selector configdir\|securestorage` | See [Accounts](#accounts). |
| `--landing DIR` | Where a session moved here from another computer is cloned when this one doesn't have its repository. Default `~/Side A`; `SIDEAD_LANDING` does the same. |

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
arriving on the events socket, ending the session, a permission request answered Allow and Deny with the hook returning each
(and failing open with the daemon stopped), and the pairing surviving a restart of the daemon. The same run through
a relay tunnel with no direct address is below.

- Sessions: the running Claude Code and Codex sessions on this computer, their transcripts (paged and streamed), status,
  project and cost, as the Mac shows them. Rows come from `~/.claude/sessions` and each account's folder.
- Reply and interrupt: a reply is typed into the session's tmux pane; confirming signatures (`confirm.signed`) are checked
  the way the Mac checks them, and Face ID is needed unless the session is known to be in a non-raising mode.
- Hosted sessions: start (with a prompt), list, end. They run in tmux on Side A's own socket, so they survive the daemon.
- Permission requests from Claude Code, once you run `sidead hooks on`: [below](#permission-requests).
- Accounts and limits: [below](#accounts).
- Moving a hosted session to a linked computer and receiving one: [below](#moving-sessions).
- Away from home: the relay tunnel and push, [below](#relay-tunnel-and-push).

## What does not work yet

Not offered by the daemon (the phone hides them because the capability is absent): questions and plans (Claude Code asks
them in its own terminal), permission requests from Codex, worktrees, forking, photo attachments,
Show on Mac, notes, queued follow-ups, trust dialogs, the terminal view, preview of local servers, screen sharing,
dictation, Live Activities, Autopilot and trades, and pull requests. There is no tray icon, island or settings window.
The finished-turn push says "Ready for your next message." rather than quoting the reply.

## Permission requests

Claude Code asks permission through a hook, so the daemon has to run one, as the Mac's island does (`bridge/island_hook.py`).
It is off until you turn it on, because it adds a hook to Claude Code's own settings:

```
sidead hooks on       # adds one PermissionRequest hook marked side-a-island to settings.json, beside yours
sidead hooks status   # which folders have it
sidead hooks off      # removes every hook with that mark; uninstall.sh does this first (for a .deb, run it before apt remove)
```

It goes into `$CLAUDE_CONFIG_DIR/settings.json` (else `~/.claude/settings.json`) and into the folder of every account you added
with `sidead accounts`, since a session started with that account reads its hooks from there. Run `sidead hooks on` again after
adding an account or upgrading `sidead` (it rewrites the launcher in the state folder, which names the Python it found), and
restart sessions that were already open. The hook talks to the daemon over a socket in the state folder
(`root/runtime/island.sock`, so `--state-dir` has to be short enough for a socket path, about 100 bytes).

With the daemon running, a request shows on the paired phone as it does for a Mac: in the list and the state snapshot, as a
`request.add` event, and as a push (a time-sensitive alert sealed so the relay cannot read it, left out for a phone that is open
on the app and sent to it once it is not, taken away from the other phones when one answers). Allow takes the unlock or Face ID
signature the Mac asks for, by the same rules (`AllowGate`, `RemoteAnswers`): a plain read inside the project from the Lock Screen,
a command or an edit unlocked, anything destructive or any secret with Face ID. Deny and "ask in the terminal" need nothing. The
phone's "Always allow" rules and "Allow and accept edits" come from the same code and work as on the Mac.

With the daemon stopped, or anything wrong, the hook prints nothing and exits at once, and Claude Code asks in its own terminal.
The daemon hands a request back to the terminal when the session stops waiting (answered at the keyboard), the Claude process
ends, the daemon stops, a headless run (`claude -p`) goes two minutes unanswered, or more than a hundred wait at once; and a hook
that quits first takes its request away with "the session ended". A question or a plan (`AskUserQuestion`, `ExitPlanMode`) is
handed back at once: the phone has no capability to answer them from here yet.

No capability gates this: the phone shows whatever `requests` holds, so it works with the Side A Remote already in the App Store.
`scripts/linux-e2e.sh` runs it end to end in a container: a stand-in agent runs the hook as Claude Code does, the probe sees each
request on the events socket, answers Allow and then Deny, and checks what the hook returned, with the daemon stopped and after
`sidead hooks off`. Not yet tried against a real Claude Code on Linux or a real phone's notification.

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

## Moving sessions

A hosted session that has finished its turn can move between this computer and a Mac or another `sidead` you linked
([moving-sessions-prd.md](../moving-sessions-prd.md), wire in [protocol.md](../remote/protocol.md), "Moves"). It stops on
one and continues on the other: the same conversation, in a checkout of the same work with its uncommitted changes and
untracked files. The daemon advertises `moves` and offers the `move` ability on hosted idle sessions once a computer is
linked, so the phone's Move to… works as with a Mac (Face ID).

A computer links to this one by pairing with it as a computer, as a phone pairs (`sidead pair` here, Link a Computer in
the Mac's Remote settings there, the digits confirmed here), and then sending the way back. Then:

```
sidead computers                    # the linked computers
sidead move sa-app-1a2b build-box   # send a hosted, idle session (its tmux name or conversation id); waits until it runs there
sidead move --all build-box         # send every hosted, idle session there, one at a time, and say which stayed and why
sidead moves                        # what this computer sent: moving, away, or unknown, with each move's id
sidead move --run-here mv-1a2b3c    # start a move left unknown here again; asks first (--yes skips the question)
sidead unlink build-box             # forget it here, and tell it to forget this computer
```

The Mac's three switches under Remote > Computers are `sidead config`, kept in `moves-settings.json` in the state folder
(0600) and read each time one is needed, so a change applies to the next move without a restart:

```
sidead config                         # the three, as they are
sidead config accept-sessions off     # refuse sessions and checkpoints from linked computers (on by default)
sidead config include-env on          # send a project's ignored .env files with a session (off by default)
sidead config standby build-box       # keep checkpoints of this computer's hosted sessions there; `off` deletes them there
```

With the daemon stopped it writes the file directly. A file it can't read counts as accepting nothing and sending nothing to
a standby, and says so in the log.

Receiving:
- The move routes and `POST`/`DELETE /v1/computers` answer only a device that paired as a computer (403 `not_computer` to a
  phone). An offer must name the computer its token is linked as, ids must be `mv-` and lowercase hex, and a device may link
  only as the computer it first named.
- With Accept Sessions off an offer is refused with the Mac's sentence, "spare-box isn't accepting sessions.", followed by
  "Turn that on there with sidead config accept-sessions on." where the Mac says "in its Remote settings".
- The work lands beside a repository this computer has (one a session here ran in, or a `--project` folder) as a worktree in
  `<repository>/.sidea-worktrees/<name>` on a `sidea/<name>` branch, else as a new clone under `~/Side A` (`--landing`). The
  transcript goes where the CLI reads it: the account's `projects` folder (`$CLAUDE_CONFIG_DIR/projects`, else
  `~/.claude/projects`), or `~/.codex/sessions`.
- It starts only on the sender's commit, once, under tmux with `--resume`, on the model and effort it had. Claude Code's
  `default`, `plan` and `acceptEdits` keep their mode; anything else arrives in `default`. Until it really runs, the state is
  `starting`, and a second commit meanwhile gets 503 `in_progress`. One left `starting` when the daemon stopped is checked at
  the next start: it counts as started if it runs, and otherwise everything it brought is removed.
- Accounts: the sender is told `here` when an account here is signed in with the session's email, `wanted` when another
  Claude account is signed in, else `missing`. For Codex it is `here` only when `~/.codex/auth.json` belongs to that email.
  A Claude login that comes with the session is stored as `.credentials.json` (0600) in a new account folder under
  `~/.local/share/side-a/accounts` (or an account with that email that has no login file), never in `~/.claude`, and the
  session starts on it. A Codex login is taken only into `~/.codex/auth.json`, and only when there is none. If the session then
  doesn't start, the login is deleted again, and a new account with it.

Sending:
- Over the link's direct addresses (tailnet, then LAN), pinned TLS to the key the link names. When none answers and the link
  names the other computer's relay, through its relay tunnel: this computer is a device of the other one, so it dials
  `/v1/tunnel/phone` with that device's id and secret, as the phone does, and the same pinned TLS and token run inside one
  stream per request (one WebSocket, at most eight streams). The relay can't read it and is not changed for it. After the relay
  answered where the addresses did not, it is tried first for a minute. Pieces of up to 512 KiB, each request with an
  idempotency key made from the move, so one sent twice is answered once.
- A project's ignored `.env` files go too with `sidead config include-env on`: the bridge's `env` capture, as on the Mac. The
  other computer writes them into the new checkout, never over a file that is there.
- Nothing stops until the other computer has agreed. The session must be idle when it is asked and again just before it is
  ended. If anything fails before the other computer is asked to start it, it starts here again. If that request goes
  unanswered, the move is `unknown`: the session stays stopped here and the daemon asks the other computer again every
  minute (and when a phone checks), then finishes the move or starts it here on its answer.
- A session that arrived here and whose agent has exited since (quit, or crashed) is still this computer's, so it moves too,
  named by its conversation or the name it was hosted as, as on the Mac: nothing is stopped, the move carries the folder it
  landed in and the login that came with it by the same rules, and a move that is undone starts nothing here (Run Here does).
  Its dead pane goes once it runs on the other computer. When that folder is gone the move is refused and says so.
- A login goes along only from an account folder added with `sidead accounts`, never `~/.claude`, `$CLAUDE_CONFIG_DIR` or
  Codex's `auth.json`, and only when no other session here uses it. It waits under the state folder until the other computer
  says it stored it, and is put back otherwise.
- While the session is on the other computer its transcript here is put aside (`root/runtime/moves/away`), so it can't be
  resumed twice, and a start of it here is refused with 409 `moved`.
- Run Here, for a move left `unknown`: the other computer is asked to drop it first. If it can't be reached, or says it never
  started it, the session starts here again. If it says the session runs there, or is starting, nothing starts here and the
  move is recorded as away. That last part differs from the Mac, which starts it here anyway.
- Move all takes every hosted session that has finished its turn, one after the other, and reports each that stayed with the
  Mac's sentences ("app stayed here: …", "2 sessions stayed here. …").

Standby (the Mac's, [moving-sessions-prd.md](../moving-sessions-prd.md) 4.8), both ways, advertised as `standby`:
- Sending: with `sidead config standby COMPUTER`, a checkpoint of each hosted session goes there when it finishes a turn and on
  a pass every minute, at most once a minute per session and only when its work or its conversation changed. Nothing here is
  stopped; the capture's private ref is removed again. Where each went is kept in `standby-sent.json`, so turning Standby off
  or pointing it elsewhere, even while the daemon is stopped, deletes them on the computer that held them (retried until it
  answers). A session that ended or moved has its checkpoint deleted there.
- Keeping: a linked computer's checkpoints go under `root/runtime/moves/standby/<id>` (ids `sb-` and lowercase hex, checked
  before they name anything). Only the device that sent one may add to it, replace it or delete it; a phone may list them
  (`GET /v1/standby`) and continue one (`POST /v1/standby/{conversation}/copy`, Face ID). A checkpoint whose files don't match
  their hashes is deleted ("The checkpoint was damaged on the way."); one still arriving when the daemon stops is removed at
  the next start; one is deleted thirty days after it arrived, by this computer's clock.
- A copy lands like a move, without `.env` files, and starts as a fork (`--resume <id> --fork-session`, `codex fork`): a new
  conversation that begins with everything said so far, so the original, wherever it still runs, is not the same session.
  A computer with no login for the agent refuses the copy; the Mac starts it and lets the CLI ask.

Not built: starting a link from this side (`sidead` is linked to). Checked by `swift test --package-path Daemon`, two daemons
on one machine over real pinned TLS with the stand-in agent, and moves through a stand-in relay that checks the device's
credential; not yet against a real Mac, the deployed relay, a real Claude Code or Codex, or a phone.

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
and per-session launch scripts), and the service's env file. It does not edit `~/.bashrc`, `~/.zshrc`, or the settings
in `~/.claude` and `~/.codex`. A session moved here adds its checkout, its transcript and, when one came, its login and its
`.env` files, as [above](#moving-sessions); a linked computer's standby checkpoints are kept under the state folder. Network:
the TLS listener (default port 47800) on the addresses you chose, the relay (`push.getsidea.com` unless `--no-relay` or
`--relay URL`), `api.anthropic.com` for each account's limits, and a linked computer's own listener for a move, a
checkpoint or an unlink, or its relay's `/v1/tunnel/phone` when that listener can't be reached. `install.sh` from the site asks
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

