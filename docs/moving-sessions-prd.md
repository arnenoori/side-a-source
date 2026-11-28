# Moving sessions between computers (PRD)

Status: phase 1 is partly built on the `moving-sessions` branch ([what is built](#what-is-built-2026-11-25)). What is settled and what the owner still has to decide is in
[section 12](#12-decisions). Facts about the tree were taken at **09f5766** (`main`,
2026-11-25) with Claude Code 2.1.332 and Codex 0.169.1. Anything marked **(verify)** has not been checked against a
running system and is listed in [phase 0](#phase-0-what-to-measure-first). The draft was reviewed by Codex against
the code and against Codex's own source; what that changed is in [section 11](#11-cross-check-with-codex).

## Recommendation

Build **Move**: a session running on one computer is stopped at a turn boundary, its conversation and its working
folder are sent to another of the user's computers, and the same conversation resumes there under Side A's tmux,
with the phone following it. Then build **Standby** on top of it: one always-on computer keeps a recent copy of
every hosted session, so a laptop can hand its working sessions over before it sleeps, and a laptop that dies can be
continued from the phone.

The positions this document takes, in order of weight:

1. **Checkpoint and resume, never process migration.** Both CLIs already resume a conversation by id from files on
   disk (`claude --resume ID`, `codex resume ID`), and Side A already does this on one machine (Continue on phone,
   `HostedSessions.continueHere`). Freezing and restoring a live Node or Rust process across machines and operating
   systems is not possible Mac to Linux and not worth it Mac to Mac. A move is Continue on phone with a network in
   the middle, and with the rollback and ownership rules that the network makes necessary.
2. **A session is four things, and three of them move.** The conversation (transcript files), the workspace (git
   state plus uncommitted work) and the account the session runs on move. The runtime (background shells, dev
   servers, MCP server processes, a pending permission prompt) cannot move and is ended, with the user told what
   ends before anything is stopped. The agent's login is handed over, not duplicated: Side A's rule that a login
   lives in exactly one place stands, and the place changes. MCP sign-ins, SSH keys and `gh` credentials stay
   where they are.
3. **Git is the workspace transport.** This repository has 32 MB of tracked files and a 23 MB pack beside 69 GB of
   ignored build output and worktrees. Uncommitted work is captured as git objects under a private ref without
   touching the user's branch, index or stash, and sent as an incremental `git bundle`. Build output is never sent;
   the agent rebuilds. Repository states that cannot be captured exactly are refused before anything is stopped.
4. **Computers talk to each other directly.** Bytes go computer to computer over the tailnet, the LAN or the relay
   tunnel, inside pinned TLS. The phone starts, authorizes and watches a move and never carries it. Linking two
   computers is, plainly, giving each shell access to the other, and the product says so.
5. **One owner per conversation when the computers can talk; an honest copy when they cannot.** A coordinated move
   is a two-phase hand-over with a journal on both sides, so exactly one side runs the conversation and an unknown
   outcome is shown as unknown, never guessed. A computer that is cut off cannot be told it lost ownership, so
   picking a session up from a vanished laptop is offered as what it is: a copy from the last synced turn, which may
   run beside the original until the laptop is back.
6. **Standby is the product; Move is the mechanism.** A manual "Move to Mac mini" is useful. Sessions that keep
   working on a machine that never sleeps is the reason to build it. Phase 1 ships a narrow Move, but its bundle,
   journal and peer link are designed for Standby from the start.
7. **The better answer for work that has not started is to start it there.** Moving exists for the session that is
   already here with dirty files. For everything else, the always-on computer should be where the session starts
   and any of the user's computers should be able to attach to it. That is cheaper to build than Standby, removes
   most reasons to move, and is spiked in phase 0 and shipped in phase 2, ahead of Standby.
8. **Nobody signs in twice.** A moved session needs a login where it lands, and making the user sign in on the
   other computer first is the setup step this feature exists to remove. The login travels with the session over
   the link. The always-on computer then becomes the home of every account through pool mode (phase 5), which the
   owner has approved.

What this is not: a cloud. Side A does not run anyone's code on machines it operates. The destination is always a
computer the user owns or rents, running Side A or `sidead`.

## 1. Goal, users and non-goals

### Goal

Someone with more than one computer can send a working agent from the one in front of them to another one and back,
without losing the conversation, the uncommitted work or the phone's view of it, and can arrange for that to happen
when the first computer is about to stop being useful (lid closed, battery low, shutting down).

### Who it is for

| User | Computers | What they need first |
| --- | --- | --- |
| A laptop developer with an always-on machine at home or work | MacBook plus Mac mini, or MacBook plus a Linux box running `sidead` | Hand agents over, close the lid and leave; answer them from the phone; pick the work back up on the laptop later |
| A developer with a rented server | MacBook plus a cloud VM running `sidead` | Start locally where the tools and the screen are, then send long runs to the server |
| A developer with two desks | Two Macs | Carry a session from one to the other in the state it is in, uncommitted edits included |
| Anyone whose laptop died mid-task | Any pair with Standby on | Continue from the last synced turn on the other computer, from the phone |

### Minimum lovable version (phase 1)

Two Macs on the same tailnet or network, each paired with the same iPhone:

- link them once: Settings > Computers on one shows a code, and the other enters it and confirms six digits;
- on the Mac, in Sessions, or on the phone: **Move to *Mac mini***; a sheet lists what will not come along, and
  nothing is stopped until the destination has said it can take the session;
- the session ends on the source and appears on the destination under tmux with the same conversation and the same
  uncommitted edits in a new worktree, with model, effort and name kept and the permission mode kept as far as the
  destination allows; the phone's open conversation switches to the destination;
- if the move fails before the hand-over, the session is running on the source again; if the outcome cannot be
  known, both computers and the phone say so and nothing is started twice;
- **Bring Back** does the same in the other direction, into a new worktree, and sends only what changed.

Hosted Claude Code sessions that are idle, in git repositories in a supported state (section 4.4), with the account
handed over when the destination does not already have it.

### Non-goals

- Migrating a live process, an in-flight tool call, or a running background shell or dev server.
- Copying an MCP sign-in, an SSH key, a `gh` login or an API key between computers, or keeping a Claude or Codex
  login usable on two computers at once. A login moves with its session and lives on one computer at a time (4.9).
- Syncing a working folder continuously in both directions. One side runs the session at a time.
- Sending build output, dependency folders or anything else git ignores, apart from ignored `.env*` files, and
  those only when the user allows it for that link.
- Keeping secrets that are in the repository or the conversation from travelling. A move sends the repository's
  history and one transcript; whatever is in them goes too, and the sheet says so.
- Moving a session to a computer that belongs to someone else. Links are between one person's computers.
- Hosting. Side A never runs a session on infrastructure it operates.
- Windows as a destination before a native Windows daemon exists (WSL 2 running `sidead` is a Linux destination).

## 2. What exists today

### In Side A

| Piece | State | Where |
| --- | --- | --- |
| Hosted sessions in Side A's tmux server, metadata in `@sidea_*` session options | Built, Mac and Linux | `bridge/hosting.py`, `Sources/SideA/HostedSessions.swift`, `Daemon/Sources/SideADaemonKit/HostedTmux.swift` |
| Resume and fork by conversation id, with a per-conversation lock and a fresh process list so one transcript never has two writers | Built on the Mac. The daemon only checks its own hosted panes, with gaps between check and launch | `HostedSessions.start` (`alreadyLive`); `HostedTmux.start` |
| Continue on phone: end an idle unhosted session and resume it under tmux | Built, Mac. A failed resume is reported (`notResumed`); nothing restarts the original | `HostedSessions.continueHere` |
| Restart fresh and Claude to Codex handoff with a written summary | Built, Mac, same folder only | `SessionCommands+Actions.swift`, `SessionCommands+Handoff.swift` |
| "Please continue" for sessions a limit stopped | Built | `Sources/SideACore/StoppedSessions.swift` |
| Worktrees for hosted sessions, ignored `.env*` copies, cleanup that never forces | Built, Mac only (`sidead` refuses worktrees). Folder trust carries from a repository to its worktrees in both CLIs | `hosting.py` `make_worktree`, `bridge/cleanup.py`, `docs/remote/hosting.md` |
| One phone paired with several computers, with separate Secure Enclave keys per computer | Built | `apps/ios/Linked/PairedMac.swift`, `DeviceKeys.swift`, `MultiMacTests` |
| Host identity: stable id, name, OS, self-signed P-256 TLS key the phone pins | Built, Mac and Linux | `MacInfo`, `RemoteKeychain.swift`, `Daemon/.../Identity.swift` |
| A command-line client that pairs with software keys | Built, for tests | `Daemon/Probe` on `SideARemoteKit` (Network.framework, Mac only) |
| Relay tunnel: opaque byte streams inside pinned TLS; the "phone" side is authenticated by a registered device id and secret hash, nothing iPhone-specific | Built | `relay/src/tunnel.ts`; ceilings of 8 MiB/s per phone socket and 64 GiB per install per day |
| HTTP server: `GET`, `POST` and `DELETE` only, `Content-Length` required, 1 MiB bodies (20 MiB for photo uploads, 64 KiB unauthenticated) | Built | `Sources/SideACore/Remote/HTTP.swift`, `RemoteServer.swift` |
| Pool mode shared with the user's other Macs over Tailscale, peers checked with `tailscale whois` | Built, Mac only | `PoolGate`, `PoolPeers` |
| A link between two computers that carries sessions | **Does not exist** | `sidead` is not referenced anywhere in `Sources/SideA` or `Sources/SideACore` |
| Bringing sessions back after a reboot or a dead tmux server | **Does not exist** (hosting.md describes "Resume" rows; no code) | |
| A route that takes anything inbound but re-encoded photos | **Does not exist** | `POST /v1/uploads` |

So the parts of a move that happen on one machine exist, on the Mac. What is missing is the peer link, the bundle,
the hand-over journal, the receiving side, and on Linux the launch lock, worktrees and trust handling.

### In the CLIs

| | Claude Code 2.1.332 | Codex 0.169.1 |
| --- | --- | --- |
| Conversation on disk | `~/.claude/projects/<folder>/<id>.jsonl` plus `<id>/subagents/` and `<id>/tool-results/`. `<folder>` is derived from the working folder (non-alphanumerics become `-`; long names are shortened with a hash), so it is found by session id, not built by rule | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, with a SQLite thread index. A thread can depend on ancestor rollouts (`history_base`), and a revert can select another rollout under the same id |
| Resume | `--resume <id>`, `--fork-session`, `--session-id <uuid>` | `codex resume [-C <dir>] <id>`, `codex fork <id>`, `codex queue --thread` |
| How resume finds it | Looks in the project folder for the current working folder **(verify across folders and machines)** | Prefers the path stored in the index, then searches rollout file names and rebuilds missing metadata (read from 0.169.1 source; a stale stored path does not always fall back) |
| Ties to a place | Every record carries `cwd` and `gitBranch` | `session_meta` carries the folder; without `-C` Codex may pick the recorded folder or ask |
| Ties to an account | Records carry `accountUuid` and `organizationUuid`, and there are `session-owner` records **(verify what they gate)** | `account_scoped` filters history listings by creator user and account. A separate check on explicit resume refuses a different creator when the `cli_resume_account_check` feature is on; it is off by default in 0.169.1 |
| The vendor's own "elsewhere" | `--cloud` and `--environment` (a session on Anthropic's or a self-hosted cloud environment), `--teleport` (pull a cloud session into a terminal), `--remote-control` (drive a local session from another device), `--bg` | `codex cloud`, `resume --remote ws://…` (the terminal UI on one machine, the app server on another), `remote-control` (manages that app server), `exec-server` |

A transcript measured here: 9.6 MB of JSONL and 17 MB with its subagent and tool-result folders. All of
`~/.claude/projects` on this Mac is 19 GB, so a move sends one conversation, never the folder.

### Why not use what the vendors ship

- **Remote Control (both CLIs) and Side A Remote** move the *controls*. The agent stays where it started, so that
  computer has to stay awake and online. That is the problem Move solves, not a substitute for it.
- **`claude --cloud` / `--teleport` and Codex cloud** move work between the user's machine and the vendor's cloud,
  through a hosted git remote **(verify the exact requirements)**. They do not move a session between two machines
  the user owns, do not carry uncommitted or unpushed work as it is, are separate per vendor, and know nothing of
  Side A's accounts and limits.
- **`codex resume --remote`** is the reverse arrangement: the agent runs on the server and the terminal attaches
  from elsewhere. None of these moves a session, but this one is the right model for work that starts on the
  always-on machine, and position 7 above adopts it for both agents through Side A's own terminal stream.

Move is the one case none of them covers: the session is here, with dirty files, and has to be there.

## 3. What a session is

| Layer | Contents | In a move |
| --- | --- | --- |
| **Conversation** | Main transcript, subagent transcripts, tool-result files, images inside the transcript; for Codex, every rollout the thread depends on and any image files it references; Side A's name for the session; model, effort, fast mode | Sent, byte for byte. Never rewritten. A Codex thread whose dependencies cannot all be found is refused |
| **Workspace** | The repository: commits, the branch, the index, modified and untracked files | Sent as git objects, when the repository is in a supported state |
| **Local extras** | Ignored `.env*` files; Claude Code's per-project memory folder; file-history snapshots used by rewind | `.env*`: only when allowed for the link. Memory: sent, written only into an empty destination folder (decision 8). File history: not sent; rewind past the move is unavailable, and the sheet says so |
| **Inputs in flight** | Follow-ups queued on the host, replies in the phone's outbox, an open permission request, an armed "Please continue" | Never moved. They must be empty or are returned to their sender before the hand-over (section 4.6) |
| **Runtime** | The agent process, background shells, dev servers and their ports, MCP server processes, a running subagent | Ended on the source. Listed in the sheet first |
| **Setup** | CLI version, user-level settings, hooks, skills, plugins, MCP servers, tools on `PATH` | Not sent. Compared, and the differences shown before the move |
| **Identity** | Claude and Codex logins, MCP OAuth tokens, SSH keys, `gh` login, API keys in the environment | The session's own Claude or Codex login is handed over when the destination lacks it (4.9). Nothing else is sent; the destination must have what it needs |

## 4. Design

### 4.1 Peers: linking two computers

A **peer** is another computer running Side A or `sidead` that this one may send sessions to and accept them from.
For each peer a computer stores: the peer's host id, name, OS and addresses; the SHA-256 of the peer's TLS key (the
pin for outbound connections); an **outbound** token it presents to that peer; and the hash of the **inbound** token
that peer presents here, with the scope it was granted (send sessions, keep a standby). These are new records. They
are not `RemoteDevice` rows: a phone's row holds only a token hash and has no outbound secret or pin.

**Linking with a code (phase 1).** Settings > Computers > Link a Computer on one side (or `sidea link`) shows a link
and a QR code in the pairing format: addresses, the key hash, the host id and an eight-character single-use code
valid five minutes. The other side opens the link or types `sidea link <link>`, dials the first computer under that
pin, and both show six comparison digits derived as in phone pairing, over both hosts' keys. The user confirms on
each computer. Each then issues the other a token. This is the phone pairing protocol run in both directions with a
computer as the client; `Daemon/Probe` already does the client half with software keys.

**Linking from the phone (phase 2, then the default).** The phone is paired with each computer and holds a separate
confirm key for each, so it cannot make one signature both accept. It makes two. After one Face ID prompt per
computer it sends each an introduction signed with *that computer's* confirm key, containing: a shared transaction
nonce, both host ids, both key hashes, both address lists, the direction and scope being granted, an expiry of two
minutes, and a fresh shared secret. Each computer verifies its own envelope, records the nonce so it cannot be
replayed, dials the other under the pin it was given, and proves possession of the shared secret before tokens are
exchanged. Each shows a notification naming the other computer and the phone that linked them.

Rules:

- **A link is shell access between two of one person's computers.** A peer can deliver a repository and have an
  agent run in it, and a received repository can carry agent configuration that runs without a prompt (section 7).
  The link sheet and Settings say this in one sentence. There is no "share with a colleague".
- On a tailnet, a peer connection is also checked the way pool sharing is (`tailscale whois` names the same
  Tailscale login, tagged devices refused), as a second gate, not the only one.
- Each side has its own switch for **accepting** sessions and its own landing folder (`sidead --project`; a setting
  on the Mac, default `~/Side A Sessions`). A computer can send without accepting.
- Unlinking revokes at once on the side that did it, and on the other side as soon as they can talk.
- Peer secrets are stored where device tokens are: the Keychain on the Mac, 0600 files in the state folder on
  Linux. They are never synced to iCloud.

### 4.2 Transport between peers

Phase 1 uses direct paths only: the tailnet address, then LAN addresses when Wi-Fi listening is on. All carry
TLS 1.3 pinned to the peer's key.

- **Client.** `SideARemoteKit` needs Network.framework and is left out of Linux builds, and `sidead` must be able to
  send as well as receive. The peer client is a new small target, `SideAPeerKit`, in `Packages/SideAProtocol`,
  written against a transport protocol. Phase 1 has one implementation (Network.framework). Phase 2 adds NIOSSL in
  `Daemon`, which already links SwiftNIO. It speaks only the peer routes, not the phone's sync engine.
- **Requests the existing parser can serve.** Peer routes use `POST` with a fixed `Content-Length` and a raw binary
  body. The server chooses its body limit after authentication today; a valid peer token is added to that choice so
  peer requests get 1 MiB and are not treated as unauthenticated.
- **Through the relay (phase 2).** Reading `relay/src/tunnel.ts`, a host can dial another host's install in the
  existing phone role, since that role is a device id and a secret hash. No relay change is needed for the wire,
  but hosts must then include their peers in the device list they register with the relay (registration replaces
  the whole list) and remove them on unlink, and both platforms need the client side of the tunnel framing. Live
  interoperability is unverified **(verify)**. The tunnel's rates are ceilings shared with the phone's traffic, not
  promises: at the 8 MiB/s ceiling a 40 MB bundle would take five seconds at best. Standby's background sync is
  rate-limited and prefers direct paths.

### 4.3 The bundle

One move sends one bundle: a manifest and parts.

```
manifest.json            version, move id, authorization id, conversation id, agent, source host, created;
                         session settings (model, effort, mode, fast, name, origin, account identity);
                         workspace description (base commit, tree ids, lists below); every part with its
                         SHA-256, size and chunk hashes; what was left out and why
conversation/            <id>.jsonl, <id>/subagents/*, <id>/tool-results/*          (Claude)
                         every rollout the thread depends on, referenced image files  (Codex)
workspace/pack.bundle    git bundle: the checkpoint objects and every object the destination lacks
workspace/extras.tar     allowed ignored .env* files, only when the link allows it
state/memory.tar         Claude Code's per-project memory folder
```

- **Chunks.** `POST /v1/peer/moves/{id}/parts/{n}/chunks/{k}` with a body of at most 1 MiB. The manifest lists every
  chunk's hash, so the receiver verifies each on arrival, answers with a receipt it has stored durably, treats a
  repeated chunk as already received, and verifies the whole part's hash when the last chunk lands. A broken
  transfer resumes from the receiver's list of receipts.
- **Limits, checked in the preflight and enforced by the receiver:** conversation 2 GiB; pack 4 GiB; extras 20 MiB;
  expanded size of the checkout 8 GiB and 500,000 files; one move in flight per peer; staging per peer 10 GiB, with
  the space reserved before the source stops anything; staged data from a move that did not complete is deleted
  after 24 hours. The sheet shows the size and an estimate.
- **What the destination already has.** Before building the pack, the source asks the destination which commits it
  has for that repository (matched by root commit ids, then remote URL), so a repository both computers have cloned
  sends only what is new: usually kilobytes.
- **Writing safely.** Parts land in a private staging folder (0700) under names the receiver chooses. Every path
  taken from a manifest or an archive is validated: relative, no `..`, no absolute paths, no symlink or hard-link
  members, no device or FIFO entries, no duplicate members, no names that collide on a case-insensitive volume.
  Files are created without following links and the result is moved into place only when complete.

### 4.4 The workspace

**Supported states (phase 1).** A git repository with a `HEAD` commit, a fully merged index, no merge, rebase,
cherry-pick or bisect in progress, no intent-to-add entries, no sparse checkout, no submodules, no Git LFS, and no
clean or smudge filter other than git's built-in end-of-line conversion. Anything else is refused in the preflight,
by name ("This repository uses Git LFS, which can't move yet"), before the session is touched. A repository whose
root is the home folder, or inside `~/Library`, `~/.ssh`, `~/.claude`, `~/.codex`, `~/.config` or another protected
folder of the existing file route, is refused outright.

**Capture, without touching the user's tree.** Using plumbing and a temporary index (so no hook, alias or stash
setting takes part), the source records:

- `B`, the `HEAD` commit, and the branch name;
- `I`, a tree written from the real index (`git write-tree`): what is staged;
- `W`, a tree written from a temporary index holding every tracked file as it is on disk plus every untracked file
  that is not ignored, with file modes and symlinks as git stores them;
- in the manifest: the paths that are untracked, the paths deleted in the working tree, and a SHA-256 of the raw
  bytes of every file that differs from `B`.

`I` and `W` are wrapped in commits with parent `B` and stored under `refs/sidea/moves/<move id>`, so they are not
garbage collected and never show in `git branch`, `git stash list` or `git status`. The user's branch, index, stash
and files are not modified. The capture is taken twice, a moment apart; if the two differ, something else is still
writing and the move stops before the hand-over.

**Deliver.** Git commands on the destination run with a fixed configuration: hooks path empty, `fsmonitor` off, no
filter or credential helper from any config, `transfer.fsckObjects` on.

1. Find the repository: a clone under the landing folder or among known projects whose root commits match.
2. If there is one, fetch the bundle into it. If not, clone from the bundle into `<landing>/<project>/` and set
   `origin` to the source's remote URL with any embedded credential removed.
3. Always make a **new worktree**, `<repo>/.sidea-worktrees/<name>`, at `B`, on the session's branch name when that
   name is free in this clone and on `sidea/<name>` otherwise. The destination's own checkout is never changed.
4. Restore: write `W`'s files into the worktree, removing the paths recorded as deleted; then set the index to `I`.
   Files in `W` and not in `I` are then present and untracked, as they were.
5. Check: the staged blobs equal `I`, and the raw bytes of every changed file match the manifest's hashes. A
   mismatch (an end-of-line or mode difference between the two systems) fails the move before the hand-over.
6. Unpack allowed extras into the worktree.

**What is not there.** `node_modules`, `.build`, virtual environments, caches, databases, and any ignored file
outside the allow-list. The move note (section 4.6) tells the agent, and the sheet tells the user. A project that
cannot be built on the destination (a Mac-only build moved to Linux) still moves; the preflight warns when the two
computers differ in OS or CPU.

**Bring back** is a move in the other direction and, in phases 1 to 3, lands the same way: in a new worktree on
the source, beside the folder the session left, which is untouched. The sheet says where the work is. Returning the
work into the original folder in place is deferred (phase 4): it needs the original branch, `HEAD`, index and files
all proven unchanged, a compare-and-swap on the branch ref, an answer for a session that rebased while away, and a
way to undo, and an editor open on that folder can race every one of those checks.

**Later.** Submodules, LFS (the destination downloads objects with its own credentials), unmerged or mid-rebase
states, custom filters, and folders that are not repositories (an archive with the limits above).

### 4.5 The conversation

**Claude Code.** The destination writes the transcript and its folders into the project folder Claude Code uses
for the destination worktree, under the config directory of the account that will run it (`~/.claude` on a Mac;
that account's `CLAUDE_CONFIG_DIR` on Linux), then starts `claude --resume <id>` in that worktree. The project
folder's name is not computed by Side A's own rule: long paths are shortened with a hash, so a small adapter, tested
per CLI version, finds or creates the right folder (for example by starting the CLI once in the worktree and reading
its registry entry) **(verify the cheapest reliable way)**. The transcript is not edited: its records keep the
source's `cwd`, branch and paths, which are history. Whether Claude Code resumes a transcript whose records name
another folder, home directory and OS is the first phase 0 experiment **(verify)**.

**Codex.** The destination writes every rollout the thread depends on into the receiving account's sessions folder
under their original file names, and starts `codex resume -C <worktree> <id>`. No row is written into Codex's
SQLite index: read from 0.169.1's source, resume searches rollout file names when the index has no entry and
rebuilds the metadata. Side A does not own that database and shares one across profiles (`sqlite_home` in
`codex_bridge.py`). If the destination's index already has a thread with that id (the session was there before),
the stored path is authoritative, so the import adapter replaces the files that path names instead of adding new
ones. The adapter is versioned per Codex release, and a thread using a history mode it does not know (compressed
rollouts, an unresolved `history_base`) is refused. An actual cross-machine Codex resume has not been run
**(verify)**.

**Accounts and the conversation.** A session resumes on the account it was running on, which section 4.9 brings
to the destination. Side A does not strip creator metadata from a transcript or turn Codex's resume account check
off.

**Versions.** The adapter lists the oldest CLI version it accepts on arrival, and the preflight refuses below it.
In phase 0 an older CLI resumed a newer transcript for both agents, so an exact match is not required; Codex's
history format is changing, so its floor is reviewed with each Codex release.

**Ownership on one computer.** Each computer keeps a record per conversation it has ever held:
`{conversation, state, peer, move id, at}` with state `here`, `leaving`, `arriving`, `away`, `unknown` or `copy`.
Everything that can make a conversation run consults it, not only launch: `HostedSessions.start` and the daemon's
equivalent, typed replies, queued follow-ups, notes, the `Stop`-hook reply, and automatic "Please continue". For a
conversation that is `away` they refuse with "It's on Mac mini now." A resume typed by hand in a terminal is outside
Side A's control; the Sessions row says where the conversation is, and a `SessionStart` hook that warns is phase 2.

### 4.6 The move, step by step

A move is a two-phase hand-over. Each side writes every transition to a journal before acting on it, and reconciles
the journal at launch, so a crash or a lost reply leaves a known state.

```
source                                          destination
──────                                          ───────────
1 Preflight ───── offer (settings, sizes, ────▶ accepting? room (reserved)? CLI version? same
                    repository state)            account signed in? landing folder? tmux?
                ◀── answer: ok, or refusals      effective permission mode it will allow
2 Authorize (person; see 4.7)
3 Hold: journal `leaving`; stop accepting replies,
  queue delivery, auto-continue and cleanup for
  this session; wait for idle or interrupt;
  SIGTERM; wait for pid and registry file
4 Snapshot: transcript final, capture twice,
  build parts, final manifest
5 Ship ──────────── chunks, receipts ─────────▶ 6 Prepare: verify, fetch, worktree, restore,
                                                   check, transcript in place; journal `arriving`
                ◀── prepared (manifest hash)       (nothing is started)
7 Commit: journal `away`, then ── commit ─────▶ 8 Start: journal `here`; host … --resume ID
                ◀── live (registry shows the conversation under the new pane)
9 Release: tell phones; cleanup allowed again
```

- **Nothing is stopped before step 2 completes**, so a destination that is asleep, full, signed out or too old
  costs the user nothing.
- **The hold (step 3) is more than stopping the agent.** Today a dead pane triggers worktree cleanup at once
  (`HostedSessions` `finish`), which could remove a clean source worktree mid-move; the hold suspends it. The source
  also refuses a move when another live session, hosted or not, has the same folder as its working folder, and
  quiesces Codex's app-server daemon for that thread where Codex runs hooks there. A quiet transcript is necessary
  and not sufficient, which is why the capture is taken twice.
- **Inputs in flight.** A session with an open permission request is not movable: answer it first. Follow-ups
  queued on the host are returned to the phone that sent them as unsent drafts ("Not sent: the session moved"),
  because a queued follow-up carries that phone's authority on the source and cannot be replayed elsewhere. After
  step 7 the source answers any reply for the conversation with a `moved` refusal naming the destination, and the
  phone's outbox, whose entries are bound to one host and its idempotency keys, re-addresses nothing by itself: it
  shows the entry as not sent and lets the user send it to the destination, signed for that host.
- **When it may start.** Phase 1: idle or finished sessions only. Phase 2 adds **After This Turn** (the move waits
  for the turn to end, within the authorization's expiry) and **Now** (interrupt as the phone's Stop does, then
  move), and sessions with background shells behind an explicit confirmation that they will be stopped.
- **The move note.** A resumed CLI submits a positional prompt at once, for both agents, so a note passed that way
  would start a turn nobody asked for. An idle session is therefore resumed **with no prompt**, and Side A puts the
  note in front of the next message the user sends (the phone and the Mac show that it will). A session moved with
  **Now**, or one a limit had stopped, was authorized to continue, and gets the note with "Continue where you left
  off." as its first prompt. The note:

  > This session moved from MacBook (macOS, `/Users/you/Coding/app`) to Mac mini (macOS,
  > `/Users/you/Side A Sessions/app/.sidea-worktrees/sa-app-3f2a`). Paths in the conversation above that start with
  > the old folder are now under the new one. Uncommitted changes came with it. Dependencies and build output did
  > not; reinstall or rebuild before running anything. These were running and were stopped: `npm run dev`
  > (port 3000).

- **Failure and uncertainty.**

  | Happens | Result |
  | --- | --- |
  | Preflight refuses | Nothing was touched. The sheet names the reason and the fix |
  | The session did not stop in 5 s, or the capture changed between the two takes | No SIGKILL. The hold is lifted; "It didn't stop, so it's still running here." |
  | Ship or prepare fails, or the destination answers `abort` | The destination deletes what it staged and confirms. The source lifts the hold and resumes the conversation itself with `--resume`. If that resume fails, the pane is kept and the row offers Try Again, as Continue on phone does |
  | The source cannot reach the destination before step 7 | Same as above after the destination's prepared state expires (10 minutes, by its own clock); a destination that never receives `commit` deletes its staging and never starts |
  | `commit` was sent and no answer came | The source's state is `unknown`. It does **not** resume. It keeps asking the destination; the row and the phone say "It may be running on Mac mini." The user can wait, or choose **Continue Here as a Copy**, which starts a fork with a new id |
  | The destination started but the pane died or never registered | The destination reports `failed` and keeps the pane for reading. Only on that report does the source resume |
  | Either side crashed mid-move | At launch it reads its journal and asks the peer; `leaving` with no `commit` sent rolls back, anything after `commit` follows the two rows above |

  The rule in one line: the source runs the conversation again only when the destination has said it is not, or
  provably never could.
- **What stays on the source.** The transcript, the checkpoint ref and the working folder as they were, for 30 days
  or until the work is brought back; a Side A worktree is removed only by the existing clean-only rule.
- **Targets.** Both Macs having the repository, on a LAN or tailnet: under 20 seconds from approval to a live
  session at the median, most of it the CLI starting. With a first full clone of a repository this size: under 40
  seconds. These are to be measured in phase 0, not promised.

### 4.7 Who may start a move, and how it is approved

The final bytes do not exist when the user says yes, and with After This Turn they may not exist for an hour. So
the approval is an **authorization**, and the manifest is bound to it afterwards.

An authorization names: the conversation, the source and destination host ids, the options (include `.env*`,
interrupt or wait, stop background tasks), the size limits accepted, the landing folder, and an expiry (ten minutes,
or two hours for After This Turn). The final manifest carries the authorization's id and must stay inside its terms;
the source refuses to ship one that does not, and the destination refuses one whose authorization it was not shown
in the preflight.

| Started from | Authorization |
| --- | --- |
| The source Mac (Sessions row, menu bar, `sidea move <session> <computer>`) | The click or command at the Mac |
| The phone | A signed confirm to the **source**, made with the Face ID key the phone holds for that computer, over the authorization's fields; the unlock key is refused and the Lock Screen never offers it. The source verifies it. The destination does not see a phone signature it could check (the phone's keys are per computer); it trusts its linked peer, which is what the link means |
| `sidead move …` in a login shell | The command |
| Standby, by itself (section 4.8) | A standing authorization, given at the source when Standby was turned on for that one peer; each automatic move is logged and pushed to the phone |

**Permission mode on arrival.** The destination has its own setting for what an arriving session may run with,
default **Ask first**: Claude `default`, `plan` and `acceptEdits` arrive as they were, and every mode Side A treats
as raising (`auto`, `dontAsk`, `bypassPermissions`, Codex `never` and `dangerFullAccess`, and any mode it does not
know) arrives as `default`. For Codex the destination passes the sandbox, approval policy and writable roots
explicitly, because a Codex session started with no flags inherits the destination's own configuration, which may
be looser or tighter than the source's. The preflight answer carries the mode the session will actually get, and
the sheet shows it when it differs.

### 4.8 Standby

One linked computer can be chosen as this computer's **standby**.

**Checkpoint generations.** After a turn finishes (the `Stop` hook reports no background tasks) and at most once a
minute, the source makes a generation: the transcript up to an exact byte offset and its hash, a workspace capture
taken after that offset was fixed and verified unchanged by a second read of the offset, and the settings. It is
sent as an incremental bundle, and the standby keeps the previous complete generation until the new one is verified.
A generation is one consistent point; transcript bytes are never streamed on their own, and a Codex thread whose
selected rollout changed (a revert) starts a new full generation. Nothing runs on the standby. The phone and the
Mac show each session's generation age ("Synced 40 s ago").

**Leave.** Handing working sessions to the standby before this computer stops:

| Trigger | Behaviour |
| --- | --- |
| **Move Everything to Mac mini** (menu bar, phone, `sidea leave`) | Runs each move to completion and says when it is safe to close the lid |
| **Move and Sleep** (menu bar, a keyboard shortcut) | The same, then sleeps the Mac |
| Lid closed with "Also with the lid closed" on | The root helper is already holding sleep off. Side A interrupts working sessions at the next step, moves them, and releases the helper when the last hand-over is acknowledged, so the Mac then sleeps. The helper's own safety rules (battery floor, 30-second handover) still apply |
| Lid closed without the helper, low battery, sleep or shutdown requested | **Best effort.** The idle-sleep assertion Side A holds does not stop lid-close, menu or low-battery sleep, and macOS gives no dependable interval. Side A tries the tail sync; what does not finish is covered by pick-up below, from the last generation |

Standby does not make the lid-closed helper unnecessary. With both on, the helper's job shrinks from "stay awake
all night" to "stay awake for the seconds a hand-over takes", which is the combination to recommend.

**Pick up.** If the source disappears (crash, dead battery, network gone), the standby does nothing by itself. The
phone shows the sessions that were working there, with the generation's age, and **Continue on Mac mini as a Copy**
behind Face ID. It is a copy because the source cannot be told: if it is merely offline and its agent is still
running, both will work, and anything they do outside the repository (a deploy, a push, a message) happens twice.
The sheet says so. The copy is a fork with a new conversation id, started from the generation. When the source is
reachable again, the phone shows both, and the user ends one. Side A never merges transcripts and never claims to
have fenced a computer it cannot reach.

A coordinated move, by contrast, keeps the conversation id, because both sides took part in the hand-over.

**Return.** When the source is back, awake and on power, the phone and the Mac offer **Bring Back**. Never
automatic.

Standby is opt-in per pair, set at the source, and the standby's own accept switch still applies. A generation is
source code and conversation at rest on a second machine; the setting says so, and turning Standby off deletes them.

### 4.9 Accounts

The account travels with the session. The user never signs in on the destination to make a move work.

- **Already there.** The source sends the account's identity (provider and the ids the CLI records). If the
  destination holds a working login for that account, nothing else is sent and the session starts on it.
- **Handed over.** Otherwise the source sends the stored login itself, inside the pinned link, as part of the
  commit step, and the destination stores it the way Side A stores any account. The source then marks the account
  **On *Mac mini*** and stops using it: both CLIs rotate their refresh tokens, so one login used from two
  computers signs one of them out **(verify: phase 0, with a throwaway account)**. Other sessions on the source
  that were using the account are traded to another account by Autopilot, and the sheet says how many before
  anything is stopped. With no other account to trade to, the sheet says those sessions will be signed out and
  offers to move them too.
- **Bring Back** returns the login with the session when no other session on the destination uses it.
- **A failed or unknown hand-over never leaves two live copies.** The login is sent only after the destination has
  verified the checkpoint, and the source deletes its copy only on the destination's word that it is stored. In
  the `unknown` state the source keeps the login unused until the two computers agree.
- **A different account on arrival** already works for Codex (phase 0). For Claude it is still to run; it matters
  only when the user asks to land a session on another account.
- **The sheet names it**: "Signs *Mac mini* in to *Work*". A login goes only to a linked computer, and linking is
  already shell access (section 7).
- **The prompt cache does not survive a move** in practice: the system prompt names the folder and the machine. The
  sheet says what Continue on phone says today.
- **Pool mode.** A pooled session has no login of its own and reaches its accounts through the proxy on the Mac
  that started it. Moved elsewhere it would need that Mac awake, which defeats the purpose. In phases 1 to 4 a
  pooled session arrives as an ordinary session on one account, handed over as above; the sheet says so. Phase 5 changes this by letting the always-on computer host the pool.

### 4.10 Setup and trust on the destination

The preflight compares, by name only, what the session has used against what the destination has. It is a list in
the sheet, not a gate, except where marked.

| Compared | If different |
| --- | --- |
| CLI version | **Gate** when the destination is older or not listed as compatible |
| OS and CPU | "Mac mini runs Linux; anything that needs macOS won't work there." |
| MCP servers this conversation called | "Not set up on Mac mini: linear, posthog." |
| Skills, plugins and subagents this conversation used | Listed |
| Side A's island hooks on the destination | **Gate** on Linux until `sidead hooks on` has been run there, since otherwise requests never reach the phone; the sheet gives the command |
| Tools the transcript ran repeatedly (`npm`, `swift`, `docker`, `gh`) and are not on the destination's `PATH` | Listed |
| Agent configuration in the checkpoint that executes: `.claude/settings*.json` hooks, `.mcp.json`, `.codex/` hooks, where it differs from the destination clone's own `HEAD` | Listed by file, with **Review** showing the difference |

That last row exists because folder trust is not a boundary here. Both CLIs extend a repository's trust to its
worktrees, so a session arriving into a clone the destination already trusts runs the hooks in its checkpoint with
no trust dialog. Side A lists them and does not block them: a linked computer already has shell access, so refusing a hook would
protect nothing (decision 9). A first
clone into the landing folder does get the CLI's trust dialog, which on a Mac the phone's Trust card already
handles; `sidead` has no trust handling today and gains it in phase 2.

Nothing is installed or configured on the destination by a move.

## 5. What the user sees

Apple-native, and text only where it is actionable.

**Mac.** A session row's menu gains **Move to ▸** with each linked computer (greyed with its reason when it cannot
take the session: Asleep, Not Signed In, Update Claude Code). Choosing one opens a sheet: the destination, where it
will land, the size and an estimate, the list of what ends, what is missing and what configuration will run, and
**Move** (default button, Return). Progress replaces the row's status ("Moving to Mac mini…") with a cancel that
works until the hand-over. Afterwards the row stays, dimmed, as "On Mac mini" with **Bring Back** and **Show**; an
unknown outcome reads "May be running on Mac mini" with **Check Again** and **Continue Here as a Copy**. Settings
gains a Computers section: linked computers, Accept Sessions, the landing folder, the mode arriving sessions may
use, Include Ignored `.env` Files, and later Standby. Every action has a keyboard path and a VoiceOver label, the
status change is announced, and Reduce Motion removes the row's travel animation.

**Phone.** The session's menu gains **Move to…**; the sheet has the same content and is confirmed with Face ID.
While a move runs, the open conversation shows one line of status. After the hand-over it reopens as the
destination's session: the transcript is re-read from the destination with a fresh cursor (cursors belong to a host
and a generation), the scroll position is re-anchored to the same message, and the composer's draft is kept as a
draft for the new host. A push arrives for an automatic leave ("3 sessions moved to Mac mini") and for a source that
vanished with work in progress ("MacBook went offline with 2 sessions working"). A Live Activity for a working
session ends on the source and starts for the destination.

**Terminal.** `sidea move [session] <computer>`, `sidea bring [session]`, `sidea link`, `sidea computers`, and later
the same under `sidead`. A Mac terminal tab attached to a session that moves away returns to its prompt with one
line: `Moved to Mac mini. sidea bring sa-app-3f2a brings it back.`

## 6. Wire and code changes

All additive and optional, gated by capabilities, with new fixtures appended to `Fixtures/v1` and its manifest.

- **Capabilities:** `peer` (this host can link), `move` (can send), `move.accept` (will receive now),
  `move.standby`. A phone offers Move for a session only when its host has `move` and a linked host has
  `move.accept`, and the server enforces the same.
- **`RemoteSession`** gains optional `moved: {to | from: host id, at, move id, state}`; `SessionAbility` gains
  `move` and `bringBack`; `SessionStatus` gains `moving`. `SessionStatus` is an open enum, so an older phone keeps
  the string and draws its fallback; what keeps it from acting on a moving session is that the abilities are absent
  and the server refuses, not the decoding.
- **Errors:** a `moved` refusal carrying the destination's host id, for replies and other actions on a conversation
  that is `away`.
- **Host routes for the phone:** `GET /v1/peers`, `POST /v1/peers/introductions` (signed), `DELETE /v1/peers/{id}`,
  `POST /v1/sessions/{id}/move` (preflight when `dryRun`, signed otherwise), `GET /v1/moves/{id}`,
  `DELETE /v1/moves/{id}` (cancel before hand-over), `POST /v1/standby/{id}/copy` (signed), `move.update` events.
- **Peer routes, host to host**, under `/v1/peer/`, accepted only with a peer token: `hello`, `offers` (preflight),
  `moves/{id}/have`, `moves/{id}/parts/{n}/chunks/{k}`, `moves/{id}/prepare`, `moves/{id}/commit`,
  `moves/{id}/abort`, `moves/{id}` (state, for reconciliation).
- **Code.** New `Sources/SideACore/Move/` (pure and Linux-safe: manifest, journal, ownership records, the state
  machine, preflight comparison, move note), tested without a network. New `SideAPeerKit` client. Git and transcript
  work in the bridge (`bridge/move.py`: capture, bundle, deliver, restore, place transcript; per-CLI import
  adapters), so the Mac and `sidead` share it. `HostedSessions` gains the transfer hold and the ownership check.
- **`sidead`, before it can take part (phase 2):** a per-conversation launch lock and detection of sessions it did
  not host (today it checks only its own panes, with suspension points between check and launch), worktrees, folder
  trust handling, the NIOSSL peer client, and the same ownership checks on replies.
- **Lint baseline.** New code goes in new files; `HostedSessions.swift` and other baselined files get extension
  files, not edits that change their length.

## 7. Security and privacy

What changes in `SECURITY.md`, which needs a new "Moving sessions" section and edits to the lines quoted here.

| Statement today | After |
| --- | --- |
| "Side A never copies a login." | Becomes "a login lives on one computer at a time". A move hands the login to the destination over the pinned link and removes it from the source; `SECURITY.md` changes with it |
| "sign-ins, shell history and Side A's own keys stay on the Mac" (file route) | Unchanged for the file route. A bundle is built from one repository and one conversation, never from `~/Library`, `~/.config` or the CLIs' credential files, and a repository rooted in a protected folder is refused |
| "`sidead` … never edits `~/.claude` or `~/.codex` by itself" | Revised: with accepting on, it writes moved transcripts into the receiving account's `projects` or `sessions` folder, and nothing else there |
| "Hosted sessions start only in folders your recent sessions used." | Revised: or in a worktree a move created |
| "the relay sees neither tokens nor content" | Unchanged: peer traffic is pinned TLS end to end. The relay sees that two installs exchanged a number of bytes |

New statements:

- **What leaves the computer in a move.** The commits of one repository that the other computer lacks, which means
  its history, including any secret ever committed; the uncommitted changes and untracked files git does not
  ignore, including an untracked key or `.npmrc` nobody ignored; one conversation's transcript files, which hold
  whatever the agent read or printed; the project's Claude memory folder; and ignored `.env*` files only when the
  link allows them. It goes only to a computer the user linked, and to no service. The switch is called "Include
  Ignored `.env` Files" because that is all it controls.
- **A link is shell access**, in both directions when both accept. Said in the link sheet, in Settings and here.
- **Trust dialogs are not the boundary.** Received agent configuration can run without a prompt (section 4.10); the
  boundary is the link.
- **Authorization is always a person**, at the source or by Face ID, except Standby's automatic leave, which a
  person turned on at the source for one named computer. The phone never authorizes a link or a move for a computer
  with a key that belongs to another.
- **Arriving sessions never gain permissions** beyond the destination's own setting (section 4.7).
- **Git configuration and hooks do not travel.** `.git/config`, `.git/hooks` and credential helpers stay; only
  objects and the remote URL, stripped of any embedded credential, are sent, and the destination runs git for
  import with hooks, filters, `fsmonitor` and credential helpers off.
- **Limits and staging** as in section 4.3, so a peer cannot fill a disk or leave data behind.
- **At rest.** Staged bundles and Standby generations live in the state folder (0700/0600) and are deleted when a
  move completes or fails, or Standby is turned off; checkpoint refs are deleted after 30 days.
- **Remove Side A** on either computer unlinks its peers and deletes generations, staged bundles, journals and
  checkpoint refs. Repositories that arrived under the landing folder are the user's work and are left, and the
  removal sheet names the folder.
- **Logs** record move ids, sizes, durations and failure reasons; never paths inside the repository, file names or
  content.

## 8. Phases

| Phase | Ships | Size | Main risks |
| --- | --- | --- | --- |
| 0. Measure | Answers to the verify items below; a throwaway script that moves one Claude session between two Macs by hand; a spike of attaching a Mac terminal tab to a session hosted on another computer | S | A CLI refusing a transcript from another path, which changes section 4.5 |
| 1. Move, narrow | Link with a code; manual Move and Bring Back for idle hosted Claude sessions, Mac to Mac, direct paths, the account handed over, supported repository states, always a new worktree; the journal, hold, ownership checks and unknown-outcome state; the Mac sheet; the phone sheet and host switch | L | Exact restore of uncommitted state; the hand-over journal; the phone switching hosts |
| 2. Start there, and more that moves | **Start on *Mac mini*** from the Mac and `sidea attach` across a link (the terminal stream, which `sidead` gains); `sidead` as source and destination (launch lock, worktrees, trust, NIOSSL client); link from the phone; relay path; After This Turn and Now; `sidea move` | L | Two network stacks; Linux parity; relay registration of peers |
| 3. Codex | The Codex import adapter, dependency inventory, `-C`, explicit sandbox on arrival | M | Codex's history format is moving; hooks in its daemon |
| 4. Standby | Checkpoint generations, Move Everything and Move and Sleep, the lid-closed hand-over with the helper, best-effort leave, pick up as a copy; in-place Bring Back; submodules, LFS and plain folders | L | Consistent generations; honest copy semantics; disk use on the standby |
| 5. One home | Pool mode on the always-on computer (including `sidead`), so moved sessions keep their accounts and limits; a different account on arrival if phase 0 allows | L | Pool on Linux; Anthropic's stance on proxied subscriptions (`SECURITY.md`) |

Phase 1 needs a Side A Remote release for the sheet and the host switch; older phones do not show Move (capability
absent) and are refused by the server if they act on a moved conversation.

### Phase 0: what to measure first

Manual experiments on the owner's machines with throwaway sessions, under the guard rails in `AGENTS.md`:

1. Claude Code resumes a transcript placed in another folder's project entry, on another Mac, with another home
   path, and macOS to Linux. Do subagent and tool-result folders have to be present? How is the project folder name
   for a long path best obtained?
2. The same under a different account's config directory: what do `accountUuid` and `session-owner` records gate?
3. Codex: `resume -C` of a rollout copied from another machine, with and without an existing index entry for that
   id, with a `history_base` ancestor, and with `cli_resume_account_check` on and off.
4. A newer transcript under an older CLI, for both agents.
5. Capture and restore: staged, unstaged and untracked changes, deletions, mode changes, symlinks, a CRLF file
   under `core.autocrlf` and under a `.gitattributes` rule, a case-only rename, Mac to Mac and Mac to Linux. Staged
   blobs and raw bytes must match.
6. Whether received `.claude/settings.json` hooks run without a prompt in a worktree of a trusted clone (hosting.md
   says trust carries; confirm for hooks specifically).
7. A host dialling another host's install through the relay in the phone role, against a local relay.
8. On a MacBook: with the lid-closed helper holding sleep off, how long an interrupt, tail sync and hand-over take;
   without it, what if anything runs after the lid closes.
9. What `claude --teleport` and Codex cloud require and carry, to keep section 2 honest.
10. Attaching a Mac terminal tab to a hosted session on another computer over the terminal WebSocket: latency and
    key handling, as the basis for Start There.
11. Time and size for a move of this repository, cold and warm.

### Phase 0: results so far (2026-11-25)

Run on the owner's laptop (Claude Code 2.1.332, Codex 0.169.1) and always-on Mac (Claude Code 2.1.150, Codex
0.156.1) over the tailnet, with throwaway sessions in a scratch repository. The two Macs are signed in to different
accounts for both agents.

| Item | Result | What it changes |
| --- | --- | --- |
| 3. Codex across computers | **Works.** A rollout copied into the other Mac's `sessions/` folder resumed by id with its full history: a different account, an older CLI reading a newer rollout, no index entry, and a recorded folder that does not exist there | Codex can move in phase 1 beside Claude, and a different account on arrival is not a blocker for Codex. The move must pass the model: the destination resumed with its own default and warned |
| 1. Claude on the same Mac | **Works.** A transcript copied into another folder's project entry resumes there with no rewriting; records keep their old folder and new ones carry the new folder | Section 4.5's plan to copy the file unchanged holds |
| 1. Claude finds a session from any folder | `claude --resume <id>` run in a different folder found the transcript under the first folder's entry and appended to it. With a copy under each, the current folder's copy wins and the two diverge under one id | A transcript left behind after a move is still resumable by hand from anywhere. The source must move it out of `projects/` while the session is away, not rely on where it sits |
| 1 and 4. Claude across computers | **Works.** After the other Mac was signed in again, the transcript copied from the laptop resumed there with its full history, with an older CLI (2.1.150) reading the newer transcript, on the same account. The older CLI added a "Continue from where you left off" turn before the prompt. Its first attempt had failed only because that Mac's login had expired | Section 4.5 holds across computers. An expired login on the destination is the failure this feature must remove (4.9). The added turn is a reason for a minimum CLI version on arrival |
| A login is only reachable from the desktop session | Over SSH that Mac's keychain is locked and `claude` reports signed out; the same command in the desktop session reports signed in | A Mac destination must launch agents from the app's session, as hosting already does. Never over SSH |
| 5. Capture and restore, Mac to Mac | **Exact.** Staged, unstaged and both; staged and unstaged deletions; a rename; a mode change; a symlink; untracked files in a folder with spaces and with non-ASCII names; an empty file; a binary; CRLF content. Status, index tree, modes and bytes matched on the other Mac; ignored files did not travel. The source's branch, stash and index were untouched | Section 4.4 holds. The index tree must be written from a copy of the index: a plain `git write-tree` rewrites the real index's cache tree |
| 5. The lossy case | A file with LF on disk under `eol=crlf` landed with CRLF | Confirms the raw-hash check and the refusal in 4.4 |
| 11. This repository | Warm (destination has `origin/main`): 0.2 s to capture, a 26 KB bundle. Cold: 0.4 s to capture, a 21 MB bundle, 1.3 s to send, 0.8 s to land in a new worktree | The 20 s target in section 10 is loose; the agent's own start will dominate |

Not run yet: Claude with a different account (item 2), whether a login used on two computers signs one out, hooks in a received worktree (6), the relay with
a host as client (7), lid-close timing (8), the attach spike (10), anything Mac to Linux, and Codex with
`cli_resume_account_check` on.

### What is built (2026-11-26)

On the `moving-sessions` branch, for hosted Claude and Codex sessions that are idle:

| Piece | Where | Proven by |
| --- | --- | --- |
| Capture, refusals, bundle, landing in a new worktree or a new clone, conversation export and import, parking the copy left behind | `bridge/move.py` | `bridge/tests/test_move.py`, and a real move between the owner's two Macs |
| A login held out of use, sent, stored and released (4.9); the computer's own login never leaves | `bridge/move_login.py`, `Sources/SideA/Moves+Logins.swift` | `bridge/tests/test_move_login.py` with a fake Keychain; app tests with fake accounts for sent, already there, must stay, unknown outcome and never started. **Not run with real logins** |
| The two-phase hand-over and its `unknown` state | `Sources/SideACore/Move/MoveJournal.swift` | A simulation that drops each message in turn: never running on both, never lost |
| Sending, rolling back, settling after a lost answer and at launch, receiving, starting once, coming back | `Sources/SideA/Moves*.swift` | Two hosts in one test with fake agents, and one run over pinned TLS through the real server and routes |
| A link that goes both ways, with signing keys for each side; unlinking on either ends both; move and standby routes refuse a phone's token | `Moves+App.swift`, `Remote/RemoteRoutes+Computers.swift` | Route tests. **Not yet linked by hand between two Macs** |
| The move sheet with a preview from both computers, sessions that are away with Bring Back and Check Again, Move to > All Idle Sessions, Accept Sessions, Include Ignored .env Files | `Remote/ComputersSettings.swift`, `Moves+Phone.swift` | Preview and list tests; the views build and lint, and have not been driven by hand |
| The phone's routes: computers, preview, a move signed with Face ID, the list of moves, check again | `Remote/RemoteRoutes+Moves.swift`, `docs/remote/protocol.md` | Route tests for what is missing; the signed path through `Moves.start` |
| Standby: a checkpoint per hosted session when its turn ends, the newest kept, continued as a copy (a fork) | `Moves+Standby.swift` | Two hosts in one test: unchanged sessions are not resent, the copy starts with the newer work, the original keeps running |
| Wire types, fixtures, capabilities `moves`, `computer`, `standby` | `Packages/SideAProtocol` | Fixtures and round trips |
| A working session moves After This Turn (remembered across a restart, cancellable, two hours at most) or Now (the turn interrupted, then moved once idle, or left alone after 30 s); Move and Sleep, which then sleeps the Mac with `pmset sleepnow` after letting go of Keep Awake; capability `moves.when` | `Moves+When.swift`, `Remote/MoveWhenViews.swift`, `KeepAwakeController.swift` | Two hosts in one test with fake agents, one of them stopped by a real Esc in its pane; the sleep is a test hook. **The views have not been driven by hand** |

Differences from this document, to close or to accept:

- **Accounts (4.9).** The login travels, but the Mac's own login never does: a session on it runs on an account
  the destination already has, and is refused only when the destination has none. Other sessions using the
  account are not traded away by Autopilot first; the login then stays and the session runs on the
  destination's own account. Whether a login used on two computers signs one out is still unmeasured, which is
  why the sender never keeps a usable copy.
- **Authorization (4.7).** A move from the phone is one Face ID signature over the session, the destination and
  `when`, not a separate authorization object with terms; After This Turn lapses after two hours, and the bytes it
  ships are not bound to the signature. A session moved Now is resumed with no prompt, not with the move note and
  "Continue where you left off.", and background shells are not checked for first.
- **Standby (4.8).** A generation is taken only when the session is idle, which makes it one consistent point
  without byte offsets. Leaving is Move to > All Idle Sessions, or All Sessions and Sleep, which moves working
  sessions After This Turn or Now and sleeps once each has gone or failed; the lid-closed hand-over with the helper
  is not built. Pick-up from the phone needs the phone's side.
- **Transport (4.2, 4.3).** The peer client is `SideARemoteKit`'s, so a Mac reaches a linked computer over the
  tailnet, the LAN or the relay tunnel as a phone does, and each side registers the other as a relay device. The
  relay path between two computers has not been run live. Parts are 512 KiB pieces checked as whole files, not
  hashed chunk by chunk with receipts, and a broken transfer starts again.
- **Ownership (4.5).** A session that is away is not running here, so there is nothing to reply to; its transcript
  is parked out of the CLI's reach. A `SessionStart` hook that warns on a hand-typed resume is not built.
- **Pool (4.9, phase 5).** A pooled session has no account of its own and arrives unpinned, so on a computer
  whose own pool is on it keeps using a pool. Making the always-on computer the pool every other one joins is
  the existing Share Pool setting plus `sidea pool join`; it needs Side A and the sign-ins on that computer.
- **Built on other branches and merged here as they land:** the phone's sheet and host switch, `sidead` as
  sender and receiver, starting a session on a linked computer and attaching to it from this Mac.

### Before work starts

The positions phase 1 is built on are settled in [section 12](#12-decisions). Two things must be true before
phase 1 is announced: a Side A Remote release carries the phone side (the "moved" state, the host switch and the
sheet, behind a capability), and `SECURITY.md` describes the link between computers.

## 9. Testing

- **Pure logic** (`Sources/SideACore/Move`): the state machine with a failure, a crash and a lost reply injected at
  every step, asserting the invariant that the conversation is never started on both sides; journal reconciliation
  from every state; manifest and wire fixtures.
- **Bridge** (`bridge/tests`): capture, deliver and restore against temporary repositories covering phase 0 item 5
  and every refused state, on the oldest and newest supported Python; archive members that must be rejected.
- **Two hosts in one test**: two `HostedSessions` on port 0 with separate state folders and temporary tmux sockets,
  moving a fake agent (`Tests/SideATests/Fixtures/FakeAgents`) and checking the destination's fake received
  `--resume <id>`, that an idle move submitted no prompt, and that a reply to the source afterwards is refused as
  `moved`. Waits use `eventually`.
- **Interrupted transfers**: drop the connection at each chunk and at each protocol step. The outcome is one of:
  rolled back and live on the source, live on the destination, or `unknown` with nothing started twice.
- **`scripts/linux-e2e.sh`** gains Mac-to-container and container-to-container moves in phase 2.
- **By hand, on real machines**: real Claude Code and Codex on two Macs and a Linux box; a lid close with and
  without the helper; a network cut mid-move; a pick-up as a copy followed by the source coming back.

## 10. How we will know it works

| Measure | Target |
| --- | --- |
| A conversation running on both computers after a coordinated move | Never. A release blocker |
| A conversation lost on both computers | Never. A release blocker |
| Moves that end `unknown` | Tracked; each one resolves by itself once the computers can talk |
| Uncommitted state identical after a move (staged blobs and raw bytes) | 100 % in tests |
| Time from approval to live, both Macs having the repository, direct path | Under 20 s at the median |
| Hand-over time on a lid close with the helper on | Measured in phase 0, then given a target |
| People with two linked computers who use Start There, Move, and Standby | Tracked through opt-in analytics (counts only), to learn which of the three is the feature |

## 11. Cross-check with Codex

The first draft was given to Codex (0.169.1, read-only) to check against this repository and against Codex's own
source. It returned 25 findings; its citations into this repository were spot-checked and hold. What changed:

| Codex found | Change made |
| --- | --- |
| Rolling back when the destination's reply is lost could leave both sides running; the draft's ownership order contradicted itself | Section 4.6 is now a two-phase hand-over with a journal and an `unknown` state; the source resumes only on the destination's word |
| An epoch cannot fence a computer that is cut off | The epoch is gone. Coordinated moves keep the id; picking up from a vanished computer is an explicit copy (4.8). Ownership is checked on replies, queues and auto-continue, not only launch (4.5) |
| The user would sign a manifest that does not exist yet | Authorization and manifest are separate and bound (4.7) |
| Two commits cannot hold every index and working-tree state; filters and line endings can change bytes | Supported states are defined and the rest refused; the manifest lists untracked and deleted paths and raw hashes; restore is specified and verified by bytes (4.4) |
| "`.env` only when allowed" hid that history and tracked files carry secrets | Stated in non-goals and section 7; the switch renamed; protected roots refused |
| Folder trust carries to worktrees, so received hooks run with no dialog | Section 4.10's last row and "trust dialogs are not the boundary" |
| Stopping the agent does not make a stable snapshot, and dead-pane cleanup could remove the source worktree | The transfer hold, the double capture, and the same-folder refusal (4.6) |
| The idle-sleep assertion does not stop lid-close sleep | Lid-close hand-over needs the helper; without it, best effort plus pick-up (4.8). The claim that Standby replaces the helper is withdrawn |
| In-place Bring Back is unsafe on a matching tree alone | Always a new worktree until phase 4 (4.4) |
| The phone's keys are per computer, and `RemoteDevice` is not a peer record | Two signed envelopes; separate inbound and outbound peer secrets; the destination trusts the peer, not a phone signature (4.1, 4.7) |
| Codex resume searches file names and needs no index row; `migrate-rollouts` is unrelated; `-C` is required; account checks are two separate mechanisms; a thread can span rollouts | Section 2's table and the Codex paragraphs of 4.5 rewritten from those findings; same-account moves as policy |
| Only `bypassPermissions` was restricted on arrival | Every raising mode, and explicit Codex sandbox settings (4.7) |
| The phone's outbox and queued follow-ups are bound to a host | Inputs in flight are returned, not migrated (3, 4.6) |
| The daemon lacks the Mac's launch guard, worktrees and trust handling | Listed as phase 2 work (6, 8) |
| `PUT` and chunk identity do not fit the parser | `POST`, fixed length, indexed chunks with receipts (4.3) |
| Limits and extraction rules were incomplete | Aggregate limits, reservation, and the write rules (4.3) |
| A resumed CLI auto-submits a positional prompt | Idle sessions resume with no prompt (4.6) |
| "Last synced turn" was not one consistent point | Checkpoint generations (4.8) |
| Phase 1 was several projects, and remote-first attach was too late | Phase 1 is Mac to Mac, idle Claude, direct paths; Start There is phase 2 and spiked in phase 0 |

What Codex **verified from source**: how `codex resume` locates a rollout, the `-C` override, the two account
mechanisms and the default of the resume check, rollout lineage, and that the relay's phone role is not tied to an
iPhone. What it **inferred**: that a complete copied rollout resumes without rewriting its recorded folder. What
**nobody had run** at review time: any cross-machine resume, the relay with a host as client, and sleep timing. Phase 0 has
since confirmed the Codex inference ([results](#phase-0-results-so-far-2026-11-25)).

Where this document did not follow the review: Codex suggested expiring execution authority (a lease) as one way to
make takeover exclusive. That would stop an agent on a laptop that is merely offline, on a train or a plane, which
is worse than the problem it solves. The copy is the honest alternative and is what section 4.8 specifies.

## 12. Decisions

### Settled

These follow from the design or from a rule Side A already has. Each is the plan unless the owner overrules it.

| # | Decision | Why it is not a real choice |
| --- | --- | --- |
| 1 | Standby is the goal. Move ships first, Start There second, Standby third | Start There reuses the terminal stream and has none of Standby's hard cases; Standby then only has to serve the session that began on the laptop |
| 2 | Phase 1 is Mac to Mac. `sidead` follows in phase 2 | One network stack, the same paths and tools on both ends, no Linux parity work, so the first release tests the hand-over itself |
| 3 | Picking up from a computer that cannot be reached is a copy, and the product says both may run | The only way to make it exclusive is a lease that stops agents on a laptop that is merely offline |
| 4 | The account travels with the session: used in place when the destination has it, handed over when it does not | Asking the user to sign in on the other computer first is the setup this feature removes (owner, 2026-11-25) |
| 5 | A session always lands in a new worktree, Bring Back included, until phase 4 | An arriving session must never change a folder someone may have open |
| 6 | Ignored `.env*` files are off by default, one switch per link, listed by name in every sheet | Side A already copies them into worktrees on one machine; across machines the default has to be the safe one |
| 7 | Ask First on arrival. The receiving computer has the setting, and only its owner can loosen it there | A sender must not be able to choose how freely an agent runs on another computer |
| 8 | Claude's project memory folder is sent and written only when the destination has none | Merging two memory folders is not Side A's job, and overwriting one loses data |
| 9 | Hooks and MCP configuration in a checkpoint are listed with **Review**, never blocked | A linked computer already has shell access, so a refusal protects nothing. The list is there so the user sees what will run |
| 10 | Linking from the phone is the default from phase 2; the code stays | The phone is already paired with both computers; the code covers a user without the phone at hand |
| 11 | Linking two computers is shell access between them, and the sheet and `SECURITY.md` say so | It is a property of resuming an agent on another machine, not a choice. The choice is the wording |
| 12 | A login lives on one computer at a time | Refresh tokens rotate, so two live copies sign one out. Hand-over keeps Side A's existing rule and changes the place |
| 13 | `sidead` writes into the receiving account's conversation folder (phase 2) | A session cannot resume otherwise. `docs/ports/linux.md` and `SECURITY.md` change with it |
| 14 | No lease or expiring right to run | See decision 3 |
| 15 | In the product the actions are "Move to *computer*", "Start on *computer*" and "Bring Back", with no feature name | Side A's UI names actions, not features |

### Waiting on a measurement, not on the owner

| Question | Settled by |
| --- | --- |
| Can a session arrive under a different account before phase 5? | Phase 0 items 2 and 3 |
| Does Codex resume a copied rollout without rewriting its recorded folder? | Phase 0 item 3 |
| What target does the lid-close hand-over get, and is it offered without the helper? | Phase 0 item 8 |
| Is attaching from another computer good enough to make Start There the headline? | Phase 0 item 10 |

### Decided by the owner (2026-11-25)

1. **Phase 0 runs on the owner's computers**: the laptop and the always-on Mac first, Linux after, with real
   `claude` and `codex`, throwaway sessions in a scratch repository and a few small paid turns.
2. **Pool mode on the always-on computer is in the plan**, not a later maybe. On an always-on Mac it is Side A's
   existing pool mode; on `sidead` it is phase 5's work. The caution stands and is repeated wherever the feature is
   described: Anthropic does not support routing a subscription through a proxy (`SECURITY.md`).
3. **The feature has no name of its own.** It is part of Side A, in the product, on the site and in release notes.
   It is described by its actions (decision 15).
