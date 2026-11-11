# Hosted sessions

How Side A runs Claude Code and Codex inside its own tmux server, so the same session can be
watched and typed into from a Mac terminal tab and from Side A Remote on the phone. This expands
"Hosted sessions (tmux)" and Decisions 3 to 5 in [remote.md](../remote.md). It is a spec: nothing
here is built yet. Measured facts are marked with the experiment they come from (see
[Experiments](#experiments)).

```
             Side A.app                                   tmux -L sidea  (runtime/tmux.conf)
 ┌──────────────────────────────┐                  ┌──────────────────────────────────────┐
 │ HostedSessions               │── tmux commands ▶│ session sa-sidea-3f2a                 │
 │  start / attach / keys       │                  │  pane: zsh -lic 'source launch.zsh'   │
 │  wait-for sidea-changed  ◀───│── hooks ─────────│    └─ claude --resume …               │
 │ TerminalViewer (per phone)   │                  │  @sidea_agent  @sidea_cwd  …          │
 │  forkpty → tmux attach -f    │── tmux client ──▶│                                       │
 │  ignore-size                 │                  │  clients: Warp tab (tmux attach)      │
 └──────────────────────────────┘                  │           phone viewer (ignore-size)  │
                                                   └──────────────────────────────────────┘
```

The Mac terminal tab is an ordinary tmux client running `sidea attach`. The phone's terminal view
is another tmux client, one per viewer, in a PTY the app owns. Replies, keys and interrupts from
the phone's chat view don't need a client at all: they go in with `paste-buffer` and `send-keys`.

## The tmux server

### Binary

tmux client and server must be the same version, so everything (the app, `sidea attach`, the
wrappers, the phone viewers) runs one binary. Side A writes its path to `runtime/tmux-path` at
launch: the bundled build at `Contents/Helpers/tmux` if we ship one (see open questions), else
the first of `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/opt/local/bin/tmux` that reports
3.4 or later (`tmux -V`). Without one, hosting is off and Side A falls back to today's
unhosted launches, with a Setup row that says why.

### Socket and start

`tmux -L sidea` (socket `/private/tmp/tmux-<uid>/sidea`), config `-f runtime/tmux.conf`. The
user's own tmux and its config are never touched.

The server keeps the environment of the process that starts it (experiment 13), and the global
environment ends up in every pane. A server started from a Warp tab would carry
`WARP_FOCUS_URL`, `TERM_PROGRAM`, `SIDE_A_PIN` and whatever that tab exported. So the server is
only ever started with `start-server` under a fixed environment, by whoever needs it first (the
app, `sidea attach`, a wrapper):

```sh
env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" SHELL=/bin/zsh \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG="${LANG:-en_US.UTF-8}" TMPDIR="$TMPDIR" \
  ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} \
  "$tmux" -L sidea -f "$conf" start-server
```

Panes get the rest (PATH, the account selector, tool versions) from their own login shell.
Concurrent starts are safe; tmux locks the socket. The server must start inside the user's GUI
session, which all three starters are, so the Keychain and the clipboard work in panes. Starting
it from an SSH login would break Claude Code's Keychain reads.

macOS may clean the socket file out of `/private/tmp` on a long-lived server. When the socket is
gone but the pid in `runtime/tmux.pid` is still a tmux, the app sends it `SIGUSR1`, which makes
tmux recreate the socket.

### Config file

`runtime/tmux.conf`, rewritten at every app launch. If the server is already running, the app then
runs `source-file` on it. Every line in the file is safe to run twice.

```tmux
# Written by Side A at launch; edits are overwritten. Your own ~/.tmux.conf is not read.
set -s  escape-time 0
set -s  exit-empty off              # start-server with no sessions stays up
set -s  extended-keys on            # Shift+Enter and friends reach Claude Code
set -s  extended-keys-format csi-u
set -s  focus-events on
set -s  set-clipboard on
set -s  default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB:extkeys:sync:title:clipboard:ccolour:cstyle"
set -as terminal-features ",xterm-ghostty:RGB:extkeys:sync:title:clipboard"
set -s  copy-command "pbcopy"

set -g  default-shell /bin/zsh
set -g  update-environment ""       # attaching from a tab never copies its variables in
set -g  history-limit 50000
set -g  status off
set -g  prefix None                 # Ctrl+B belongs to Claude Code (background a task)
set -g  prefix2 None
set -g  mouse on                    # wheel scrolls tmux history (see Warp and scrollback)
set -g  destroy-unattached off
set -g  remain-on-exit on           # a finished pane stays until Side A has read it
set -g  remain-on-exit-format "Session ended (#{?pane_dead_status,status #{pane_dead_status},signal #{pane_dead_signal}})."
set -g  set-titles on               # Claude's tab title reaches the outer terminal
set -g  set-titles-string "#{pane_title}"
set -g  allow-passthrough off
set -g  allow-rename off
set -gw window-size latest          # Mac clients drive the size; see Resize
set -gw aggressive-resize off

# Hooks wake the app; indexes are fixed so re-sourcing replaces instead of appending.
set-hook -g pane-died[50]        "wait-for -S sidea-changed"
set-hook -g session-closed[50]   "wait-for -S sidea-changed"
set-hook -g client-attached[50]  "wait-for -S sidea-changed"
set-hook -g client-detached[50]  "wait-for -S sidea-changed"
set-hook -g client-active[50]    "wait-for -S sidea-changed"
set-hook -g client-resized[50]   "wait-for -S sidea-changed"
```

The app keeps one `tmux -L sidea wait-for sidea-changed` process blocked at a time. When it
returns, the app reads `list-sessions` and `list-clients` again and starts another one. A signal
sent while nobody waits is remembered, so a change between two waits isn't lost
(experiment 9). A 5-second poll backs it up.

### Names

`sa-<project>-<4hex>`. `<project>` is the base name of the main repository (`git rev-parse
--git-common-dir`, then its parent), or of the folder when it's not in a repository. It is
lowercased, runs of anything outside `[a-z0-9]` become `-`, it's cut to 24 characters, and `-`
is trimmed from both ends. `<4hex>` comes from `/dev/urandom`. If `has-session -t =NAME` finds the
name already taken, a new `<4hex>` is drawn. tmux matches bare names by prefix, so every
command targets a session as `-t =NAME` and a pane as `-t =NAME:` (experiment 15).

### Metadata

tmux is the source of truth, held in session user options. They can be read in
`list-sessions` and `list-panes` formats (experiment 2):

| Option | Value |
| --- | --- |
| `@sidea_v` | `1`, the metadata version |
| `@sidea_agent` | `claude` or `codex` |
| `@sidea_cwd` | folder the agent was started in (the worktree when there is one) |
| `@sidea_repo` | main worktree of the repository, or empty |
| `@sidea_worktree` | worktree path Side A created for this session, or empty |
| `@sidea_branch` | `sidea/<name>` when Side A created the worktree |
| `@sidea_origin` | `mac`, `phone`, `terminal` (a wrapper) or `continue` (Continue on phone) |
| `@sidea_session` | the agent's session id: known up front for resume, filled in once matched for new ones |
| `@sidea_account` | the `sidea use` pin name the session was started on, or empty (follows Side A) |
| `@sidea_created` | Unix time |

Per-session files live in `runtime/hosted/<name>/` (0700): `launch.zsh`, `prompt.txt` (deleted by
the launch), and `last.txt` (the last screen once the session has ended).

### Adoption after an app restart

At launch, after writing the config:

1. `list-sessions -F '#{session_name}\t#{@sidea_v}\t#{@sidea_agent}\t#{@sidea_cwd}\t#{@sidea_worktree}\t#{@sidea_session}\t#{@sidea_origin}\t#{session_created}'`.
   Every session with `@sidea_v` becomes a `HostedSession`. Sessions without it (someone ran
   `tmux -L sidea new` by hand) are listed in Sessions as plain terminals but never typed into.
2. `source-file runtime/tmux.conf`, which also re-installs the hooks.
3. Dead panes found now are handled as if the hook had just fired (below).
4. `runtime/hosted/<name>/` folders with no session are deleted after 7 days.

If the socket is gone, the server died. Then no session is left (tmux took its panes and agents
with it). Each `runtime/hosted/<name>/` that still records a session id becomes a "Resume" row
in Sessions.

### When a session ends

`remain-on-exit on` keeps the pane, with its exit status and last screen, until the app has read
them (experiment 10). On `pane-died` (or at adoption):

1. `capture-pane -p -J -t =NAME: -S -200` goes to `runtime/hosted/<name>/last.txt`.
2. `#{pane_dead_status}` and `#{pane_dead_signal}` are recorded, and the phone gets
   `hosted.remove` with them.
3. `kill-session -t =NAME`. An attached Mac tab's client exits, and the tab is back at its own
   shell prompt, just as when Claude exits in a plain tab.
4. Worktree cleanup (below).

Nothing is kept for later: one dead session costs nothing, but a stuck "Session ended" tab would
confuse people. A server with no sessions left stays up (`exit-empty off`). The app runs
`kill-server` only when Remote is off and no session has existed for an hour.

## Launch

### One launcher for everyone

The app, the phone (through the app), `sidea attach` and the wrappers all go through one script
that the app rewrites at each launch: `runtime/sidea-tmux` (0700). That way naming, environment
and quoting live in one place.

```zsh
#!/bin/zsh -f
# Written by Side A at launch; edits are overwritten.
emulate -L zsh; setopt no_unset pipe_fail extended_glob
root=${0:A:h:h}                                   # …/Application Support/SideA
tmux=$(<$root/runtime/tmux-path) || exit 69
conf=$root/runtime/tmux.conf
T=($tmux -L sidea -f $conf)

ensure_server() {
  $T list-sessions >/dev/null 2>&1 && return
  env -i HOME=$HOME USER=$USER LOGNAME=$LOGNAME SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=${LANG:-en_US.UTF-8} TMPDIR=${TMPDIR:-/tmp} ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK=$SSH_AUTH_SOCK} \
    $tmux -L sidea -f $conf start-server
}

project_of() {   # base name of the main repository, or of the folder
  local common p
  common=$(git -C $1 rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && p=${${common%/.git}:t} || p=${1:t}
  p=${${(L)p}//[^a-z0-9]##/-}; p=${p[1,24]}; p=${${p#-}%-}
  print -r -- ${p:-session}
}

new_name() {
  local base=sa-$(project_of $1) name
  repeat 20; do
    name=$base-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
    $T has-session -t "=$name" 2>/dev/null || { print -r -- $name; return; }
  done
  return 75
}

# host <claude|codex> [--detach] [--cwd DIR] [--pin NAME] [--origin X] [--session ID] [--prompt-file F] -- ARGS…
host() {
  local agent=$1; shift
  local detach=0 cwd=$PWD pin= origin=terminal session= promptfile=
  while (( $# )); do
    case $1 in
      (--detach) detach=1;; (--cwd) cwd=$2; shift;; (--pin) pin=$2; shift;;
      (--origin) origin=$2; shift;; (--session) session=$2; shift;; (--prompt-file) promptfile=$2; shift;;
      (--) shift; break;; (*) break;;
    esac; shift
  done
  ensure_server || return 69
  local name=$(new_name $cwd) || return 75
  local dir=$root/runtime/hosted/$name; mkdir -p -m 700 $dir
  [[ -n $promptfile ]] && mv -f -- $promptfile $dir/prompt.txt
  {
    print -r -- "cd -- ${(q)cwd} || exit 66"
    print -r -- '(( $+functions[_side_a_select] )) && _side_a_select'
    if [[ -f $dir/prompt.txt ]]; then
      print -r -- "_side_a_prompt=\$(<${(q)dir}/prompt.txt); rm -f -- ${(q)dir}/prompt.txt"
      print -r -- "$agent ${(j: :)${(q)@}} \"\$_side_a_prompt\""
    else
      print -r -- "$agent ${(j: :)${(q)@}}"
    fi
  } > $dir/launch.zsh
  # The pane's argv carries only fixed words: tmux splits its own argv on a trailing ';'
  # even after -- (experiment 6), so user arguments travel in launch.zsh.
  $T new-session -d -s $name -c $cwd -x 120 -y 40 \
       -e SIDE_A_HOSTED=$name ${pin:+-e} ${pin:+SIDE_A_PIN=$pin} \
       -- /bin/zsh -lic 'source "$1"' zsh $dir/launch.zsh || return 70
  $T set -t "=$name" @sidea_v 1 \; set -t "=$name" @sidea_agent $agent \; set -t "=$name" @sidea_cwd $cwd \
     \; set -t "=$name" @sidea_origin $origin \; set -t "=$name" @sidea_session "$session" \
     \; set -t "=$name" @sidea_account "$pin" \; set -t "=$name" @sidea_created $EPOCHSECONDS
  print -r -- $name
  (( detach )) || exec $T attach-session -t "=$name"
}

attach() {
  ensure_server
  if [[ -n ${1:-} ]]; then exec $T attach-session -t "=$1"; fi
  local -a here=(${(f)"$($T list-sessions -F '#{session_name} #{@sidea_cwd}' 2>/dev/null | awk -v d="$PWD" '$2==d {print $1}')"})
  if (( $#here == 1 )); then exec $T attach-session -t "=$here[1]"; fi
  $T list-sessions -F '#{session_name}  #{@sidea_agent}  #{@sidea_cwd}' 2>/dev/null || print "No hosted sessions."
  (( $#here > 1 )) && print "Several sessions run here; name one: sidea attach <name>"
}

zmodload -F zsh/datetime p:EPOCHSECONDS
cmd=${1:-}; shift 2>/dev/null
case $cmd in
  (host) host "$@";; (attach) attach "$@";;
  (ls) $T list-sessions -F '#{session_name}  #{@sidea_agent}  #{@sidea_cwd}' 2>/dev/null;;
  (*) print -u2 "usage: sidea-tmux host|attach|ls"; exit 64;;
esac
```

Notes on the launch:

- The pane runs `zsh -lic 'source launch.zsh'`. That shell is interactive and a login shell, so
  `.zprofile` and `.zshrc` run, Side A's line included. The line ends by calling
  `_side_a_select`, which exports `CLAUDE_SECURESTORAGE_CONFIG_DIR` (or `SIDE_A_PIN`'s slot) for
  the `-c` command (experiment 12). The launch file calls it once more to be safe. This is the
  same rule a new tab follows, so Autopilot's choice and trades apply unchanged. When the
  `.zshrc` line is off, the session uses the Mac's own login, as an unhosted `claude` would.
- The agent runs without `exec`, so a `claude` alias (`alias claude=~/.claude/local/claude`) still
  resolves. The pane is then `zsh → claude`. When the agent exits, `zsh -c` exits with the
  agent's status and the pane dies.
- This differs from remote.md's "start `zsh -l`, then type the command": nothing is typed, so
  there's no race with prompt plugins, and arguments arrive exact.
- `-x 120 -y 40` is the size until a client attaches.
- An interactive `.zshrc` can stop and ask something (oh-my-zsh's update prompt). The pane
  then waits like a tab would; the phone sees it in the terminal view.

### Commands per agent

`$agent ARGS` in the launch file:

| | Claude Code | Codex |
| --- | --- | --- |
| New | `claude [--model M] [PROMPT]` | `codex [-m M] [-i IMG,…] [PROMPT]` |
| Resume | `claude --resume ID [PROMPT]` | `codex resume ID [PROMPT]` |
| Fork | `claude --resume ID --fork-session [PROMPT]` | `codex fork ID` if the installed Codex lists it in `codex --help`, else not offered |
| Account | `--pin <name>` → `SIDE_A_PIN` in the session env | `codex_bridge.invocation(root, account)`, unchanged (below) |
| Effort | `--effort` / `/effort` after start | `-c model_reasoning_effort=…` |

**Codex accounts reuse the existing launch rule.** Hosted starts, resumes, forks and Continue on
phone for Codex never build their own `CODEX_HOME`. The app asks the bridge for
`codex_bridge.invocation(root, account)` (`bridge/codex_bridge.py:131-138`, after `owned()` and
`prepare_profile()`), which returns the argv prefix and environment Side A already uses: for the
Mac's own Codex login, plain `codex` with `CODEX_HOME=~/.codex`; for any other account, its
profile folder itself as `CODEX_HOME` (not a `codex-home` subfolder) plus
`-c cli_auth_credentials_store="file"`, `-c forced_login_method="chatgpt"`,
`-c model_provider="openai"` and `-c sqlite_home=<root>/codex-conversations`, so every account
shares the one conversation index and rollout folder. `host` receives the argv prefix in front of
the agent arguments (written into `launch.zsh` like any argument) and the environment as
`new-session -e` pairs. With no account picked, the session follows the Mac's Codex login as an
unhosted `codex` would.

The app reads `@sidea_session` for resumed sessions right away. For new ones it fills it in once
the session shows up in the live list (see [Matching](#matching-panes-to-live-sessions)).

Before a resume or fork, the app makes sure the session id isn't already live, **idle sessions
included**. If it's live and hosted, the app attaches to it. If it's live and unhosted, the app
refuses ("It's still running in Warp") and offers Show. Two processes on one transcript corrupt
it, and Codeman found the same with `codex resume`. The check can't use `SessionStore.liveByID`,
which deliberately leaves out idle sessions (`SessionStore.swift:24-28`), and an idle session is
exactly the common one being resumed. See the guard under
[Everything Side A opens is hosted](#everything-side-a-opens-is-hosted).

### Environment in the pane

| Variable | From |
| --- | --- |
| `SIDE_A_HOSTED=<name>` | `new-session -e`; the wrappers, `live` and the island hook read it |
| `SIDE_A_PIN` | `new-session -e`, only when an account was picked or the wrapper's tab had `sidea use` |
| `CODEX_HOME` | `new-session -e`, from `codex_bridge.invocation` for a picked Codex account |
| `TMUX`, `TMUX_PANE`, `TERM=tmux-256color`, `TERM_PROGRAM=tmux` | tmux |
| everything else | the login shell |

### Worktrees

When New session asks for a worktree:

```sh
repo=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir); repo=${repo%/.git}
git -C "$repo" worktree add -b "sidea/$name" "$repo/.sidea-worktrees/$name" "${base:-HEAD}"
grep -qxF '/.sidea-worktrees/' "$repo/.git/info/exclude" || echo '/.sidea-worktrees/' >> "$repo/.git/info/exclude"
```

The app creates the worktree before `host`, and passes it as `--cwd`. `@sidea_repo`,
`@sidea_worktree` and `@sidea_branch` record it. The exclude line keeps the folder out of the main
worktree's `git status`. It's local and never committed. Living inside the repository also
means Claude Code's folder trust, which is checked up the parent folders, covers it (to verify;
see open questions). Ignored files such as `.env` aren't copied.

When the session ends, the worktree goes only if it's clean. The check is
`cleanup.remove_worktree(path)`: no changes, no untracked files, no process working in it, its
commit on a ref, no ignored files a build can't bring back. After that, `git branch -d
sidea/<name>`, which itself refuses a branch with unmerged commits. Anything refused stays, and
Settings > Sessions > Cleanup lists it like any other worktree, tagged "Side A". Nothing is ever
forced.

### First prompt

**New sessions, resumes and forks take the prompt as an argument.** It travels as `prompt.txt`
and becomes the last argument (`"$_side_a_prompt"`). The CLI submits it once its composer is up,
so no Enter is sent. Checked on Claude Code 2.1.302 and Codex 0.156.1: the prompt auto-submits for
`claude --resume ID "p"`, `claude --resume ID --fork-session "p"`, `codex resume ID "p"` and
`codex fork ID "p"`. `codex fork` exists in 0.156.1; older Codex versions are still checked with
`codex --help` and Fork isn't offered without it. If the folder isn't trusted yet, the trust
dialog comes first and the prompt waits behind it. Up to 100 KB goes this way (macOS `ARG_MAX` is
1 MiB, environment included); anything longer is pasted.

**Images in the first prompt.** Codex takes them as `-i path,…`. Claude Code has no flag, so their
paths go at the end of the prompt text, single-quoted, and Claude reads them.

**Dialogs before the composer.** While a new session has no composer, the app looks at the screen
every second for up to two minutes (`capture-pane -p -e -J -t =NAME:`). When it finds a trust
dialog it raises `hosted.attention {name, kind: "trust", text}` (protocol, `HostedAttention`). The
phone shows a card with **Trust and start** and **Open terminal**. What Trust sends depends on the
CLI:

- **Claude Code 2.1.302** asks "Do you trust the files in this folder?" with unnumbered options
  and **"No, exit" highlighted by default**. Trust sends `Down`, re-captures until the highlighted
  row is `❯ Yes, I trust this folder` (at most three `Down`s, one capture after each), and only
  then sends `Enter`. If that row never becomes highlighted, nothing is pressed and the card
  falls back to Open terminal.
- **Codex 0.156.1** highlights `› 1. Trust and continue` by default. Trust sends `Enter` only after
  a fresh capture still shows that row highlighted.

The phone's Trust and start is `POST /v1/hosted/{name}/trust` (capability `hosted.trust`), signed
with the confirm key after Face ID over the session's name and folder (protocol, Signed confirms);
the unlock key is refused and the Lock Screen never offers it. Side A presses only while the trust
dialog is still on screen; otherwise the answer is 409 `cannot_deliver` and nothing is pressed.

Any other screen that isn't a composer for 20 seconds raises `kind: "screen"` with the last lines,
and the only action is Open terminal.

**Composer ready.** Measured on the versions above (captures with `-e`, so attributes are kept):

- **Claude:** the composer is the line starting `❯` + U+00A0 (no-break space) at column 0. Echoed
  prompts higher up use `❯` + an ordinary space; dialog rows are indented (`  ❯ 1. …`). The `>`
  glyph of older versions is no longer accepted. Ready mark: the footer contains `shift+tab`.
- **Codex:** the composer is the last `› ` row at column 0. Ready mark: the footer reads
  `<model> · <cwd>`.
- **Empty composer:** both CLIs draw a dim (SGR 2) placeholder in an empty composer, so a run of
  dim text after the glyph counts as empty, not as text.

Pastes into a new session wait for composer and ready mark together, with a 60-second timeout.
`~/.claude/sessions/<pid>.json` now also carries `"tmux": "<session>:@win.%pane"`; it doesn't name
the socket, so it is used only to cross-check the pane match, never instead of it.

### The Enter re-press (SubmitVerifier)

This is a port of Codeman's `session-submit-verifier.ts`, made stricter. Its job is a missed
Enter (Codeman saw recent Claude Code ignore Enter for 30 to 50 seconds after its composer first
paints; one sample on 2.1.302 didn't show it, so the verifier stays but presses less). It's armed
after every paste plus Enter that Side A sends (replies and pasted first prompts), one verifier
per session. A newer send cancels the older one.

- **Schedule:** checks at 2, 5, 10, 20, 30 and 60 s after the send.
- **Cancel on any other input.** The verifier stops for good the moment anything else could have
  touched the composer: a Mac client's activity on the session (`client-active` hook,
  `client_activity` newer than the send), input from a phone terminal viewer, or another Side A
  send. It never decides whose text a composer holds after someone else could have typed.
- **Check:** `capture-pane -p -e -J -t =NAME:` (the visible screen with attributes); the composer
  line by the rules above.
  - No composer line at all: stop. Never press Enter blind, because it could confirm a dialog.
  - Composer empty (nothing, or only the dim placeholder): taken, stop.
  - **Exact match only.** Right after its own paste and before its Enter, Side A captured the
    composer and recorded exactly what it showed: the pasted text itself (short single-line
    sends) or the placeholder the paste produced (Claude `[Pasted text #N +K lines]`, Codex
    `[Pasted Content N chars]`, with that N). A re-press happens only when the composer now shows
    that same recorded content, character for character, and nothing else. A prefix match or "some
    placeholder" isn't enough: a different `#N` is someone else's paste.
  - Anything else, or a capture that can't be read cleanly: stop, and raise
    `hosted.attention {kind: "unsent", text}` so the phone can show "It may not have been sent ·
    Open terminal". The user decides; Side A doesn't press Enter on ambiguity.
- **Early stop:** Claude's registry entry for the session turning `busy` after the send, or a new
  Codex `task_started` in the rollout, means the prompt was taken.
- **Logging:** each re-press goes to the Remote log with its delay.

## On the Mac

### Everything Side A opens is hosted

`SessionStore.resume(_:fork:in:)` (today: a login shell typing `claude --resume …` into a new
tab) becomes "host, then attach":

```swift
func resume(_ session: SessionInfo, fork: Bool, in app: TerminalApp) {
    if let cwd = session.cwd, !FileManager.default.fileExists(atPath: cwd) { error = …; return }
    Sounds.play(.spinUp)
    Task {
        do {
            let name = try await store.hosted.start(.init(
                agent: session.isCodex ? .codex : .claude,
                cwd: session.cwd ?? NSHomeDirectory(),
                mode: fork ? .fork(session.id) : .resume(session.id),
                origin: .mac))
            attach(name, in: app)
        } catch HostedError.alreadyLive(let live) {                // never two processes on one transcript
            if let name = live.hosted { attach(name, in: app) } else { error = "It's still running in \(hostName(live) ?? "a terminal")." }
        } catch HostedError.unavailable {
            legacyResume(session, fork: fork, in: app)              // today's code, unchanged
        } catch { self.error = error.localizedDescription }
    }
}
```

The guard lives in `HostedSessions`, an actor, so it is serialized with the launch itself:

1. `HostedSessions.start` takes a per-conversation lock (`resume` and `fork` of the same id, and
   Continue on phone, queue behind each other).
2. Inside the lock it runs a fresh `sessions.py live` (not the cached list) and builds a complete
   index of every live process by conversation id, **all statuses including idle**, plus every
   hosted pane's `@sidea_session`. A hit throws `alreadyLive(live)`.
3. Still inside the lock it runs `host`, and releases the lock only once the pane exists and its
   `@sidea_session` is set, so a second start can't slip between the check and the launch.

A Claude fork (`--resume ID --fork-session`) only reads the parent and writes a new transcript, so
it is allowed while the parent is live. A Codex `fork` of a live thread is refused until it is
verified that `codex fork` never writes to the parent rollout.

`HostedSessions.start` runs `runtime/sidea-tmux host <agent> --detach --origin mac
[--session ID] -- <args>` and returns the name it prints. `attach(name, in:)` opens a tab running
`'<root>/runtime/sidea-tmux' attach <name>`. It uses the script's full path, so it works without
the `.zshrc` line:

| Terminal | How the tab is opened |
| --- | --- |
| Ghostty | as today: `new surface configuration`, `initial working directory` = the session's folder, `initial input` = the attach command + linefeed |
| iTerm | as today: `create window with default profile`, `write text` the attach command |
| Warp | as today, one reused tab config `~/.warp/tab_configs/side_a_resume.toml` whose `commands` holds the attach command, then `warp://tab_config/side_a_resume` |
| Terminal | `runtime/attach-<name>.command`: `#!/bin/zsh` + `'<root>/runtime/sidea-tmux' attach <name>; exec zsh -l` |

The tab's own shell is left behind the attach. Detaching or the session ending puts the user at a
prompt, as today. Closing the tab only detaches: the session keeps running, Sessions shows it
with a terminal badge and "No terminal open", and the phone can still attach.

New session from the Mac (and the phone) uses the same `start` with `.new(prompt:, model:,
worktree:, account:)`, and Fork is `.fork(id)`. `quit(_:)` on a hosted session still sends SIGTERM
to the agent's pid. The pane then dies and the session is cleaned up as above.

### Show on Mac for hosted sessions

`TerminalFocus.host(of:)` walks parents from the agent's pid. For a hosted session that walk ends
at launchd, because the tmux server is daemonized (experiment 3). Hosted sessions use their
clients instead:

1. `list-clients -t =NAME -F '#{client_pid}\t#{client_tty}\t#{client_activity}\t#{client_flags}'`,
   dropping `ignore-size` clients (phones), newest activity first.
2. `TerminalFocus.host(of: client_pid)` finds the terminal app. The client's tty is the tab's tty,
   so Terminal and iTerm match by tty as today.
3. Warp: `WarpFocus.focusURL(client_pid)` reads `WARP_FOCUS_URL` from the `tmux attach` process.
   It inherited the tab's environment, so the link lands on the exact tab. The agent's own
   environment no longer carries that link.
4. Ghostty: tmux forwards Claude's title to the outer terminal (`set-titles`, experiment 14), so
   matching by title keeps working. The folder match uses the client's cwd.
5. No client: open a new tab with `attach(name, in: usualTerminal)`.

`hostName(_:)` reports the client's app the same way.

### `sidea attach`

The `sidea` function in the `.zshrc` line (`shell_snippet` in `bridge/sidea_bridge.py`; it's still
emitted on one line) gains the hosted subcommands. Shown expanded, with the new lines in the
middle:

```zsh
sidea() {
  local p="${${${2:-}:l}// /-}"
  if [ "${1:-}" = use ] && [ -f $PINS/"$p" ]; then export SIDE_A_PIN="$p"; echo "This terminal now uses $p."
  elif [ "${1:-}" = auto ]; then unset SIDE_A_PIN; echo "This terminal follows Side A again."
  elif [ "${1:-}" = attach ] || [ "${1:-}" = ls ]; then $ROOT/runtime/sidea-tmux "$@"
  else echo "sidea use <account> keeps this terminal on one account; sidea auto follows Side A; sidea attach [name] opens a hosted session; sidea ls lists them. Accounts: $(ls $PINS 2>/dev/null | tr '\n' ' ')"; fi
}
```

`$PINS` and `$ROOT` are the quoted paths `shell_snippet` already substitutes. With no name,
`attach` joins the only session in the current folder, or lists all of them.

### Host terminal sessions (opt-in wrappers)

Settings > Remote > **Host terminal sessions** adds a second marked line to `~/.zshrc`, after the
first one, and creates the flag file `runtime/host-terminal`. `set_shell` handles it like the
existing line: marker, one line, removed together. Turning the setting off deletes the flag
first, and shells that are already open stop hosting at their next command, without a restart.

Expanded form; it's written joined with `; ` on one line:

```zsh
# side-a host terminal sessions
typeset -gA _side_a_real
_side_a_hostbin=$ROOT/runtime/sidea-tmux
_side_a_hostflag=$ROOT/runtime/host-terminal

# Whether `agent args…` opens the interactive TUI (only those are hosted).
_side_a_tui() {
  local agent=$1 a; shift
  for a in "$@"; do
    case $a in (-p|--print|-v|--version|-V|-h|--help|--output-format|--output-format=*|--input-format|--input-format=*) return 1;; esac
  done
  case $agent:${1:-} in
    (claude:(mcp|config|doctor|update|upgrade|install|migrate-installer|setup-token|plugin|plugins|auth|agents)) return 1;;
    (codex:(exec|e|login|logout|mcp|mcp-server|app-server|completion|sandbox|debug|apply|a|cloud|features|help)) return 1;;
  esac
  return 0
}

_side_a_host() {
  local agent=$1; shift
  if [[ -o interactive && -t 0 && -t 1 && -z ${TMUX:-} && -z ${SIDE_A_HOSTED:-} && -z ${SIDE_A_NO_HOST:-} \
        && -f $_side_a_hostflag && -x $_side_a_hostbin ]] && _side_a_tui $agent "$@"; then
    "$_side_a_hostbin" host $agent --cwd "$PWD" --origin terminal ${SIDE_A_PIN:+--pin} ${SIDE_A_PIN:+"$SIDE_A_PIN"} -- "$@"
  else
    eval "${_side_a_real[$agent]:-command $agent} \"\$@\""
  fi
}

# An alias would win over a function, so take it over: remember what it ran, then remove it.
for _side_a_a in claude codex; do
  if (( $+aliases[$_side_a_a] )); then _side_a_real[$_side_a_a]=${aliases[$_side_a_a]}; unalias $_side_a_a; fi
  eval "function $_side_a_a { _side_a_host $_side_a_a \"\$@\"; }"
done
unset _side_a_a
```

Guards, in order:

| Guard | Why |
| --- | --- |
| `-o interactive`, `-t 0`, `-t 1` | scripts, pipes (`echo x \| claude`) and redirections run the CLI as is |
| `-z $TMUX` | inside the user's own tmux (or ours) it runs as is; no tmux in tmux |
| `-z $SIDE_A_HOSTED` | the pane's own shell loads this line too; there it must run the real CLI |
| `-z $SIDE_A_NO_HOST` | escape hatch for one command: `SIDE_A_NO_HOST=1 claude` |
| `runtime/host-terminal` exists | the setting is on, checked live |
| `sidea-tmux` executable | Side A still installed |
| `_side_a_tui` | `-p`, `--version`, `mcp`, `codex exec` and other non-TUI uses run as is |

Other escape hatches: `command claude` skips functions, as zsh always does. Arguments pass
untouched, because `host` writes them into the launch file with `${(q)@}`. The tab's `sidea use`
pin carries over as `--pin`. Variables exported only in that tab don't carry over (the pane
has its login shell's environment). A one-off `FOO=1 claude` is the case most likely to
surprise; the Settings text says so. In the pane, `claude` resolves through the alias or PATH
again (the wrapper sees `SIDE_A_HOSTED` and runs `_side_a_real`), so an alias-only install works.
The line has to come after any `alias claude=…` in `.zshrc`. Side A appends its lines at the end,
and Setup warns if an alias is defined later in the file.

What the user sees: typing `claude` in Warp looks the same. Quitting Claude ends the session and
the tab returns to its prompt. Closing the tab leaves it running for the phone. `sidea attach`
brings it back.

### Warp, scrollback and other terminal caveats

- **Scrollback.** tmux draws on the outer terminal's alternate screen, so the terminal's own
  scrollback no longer holds the conversation. In Warp this is the biggest change: Warp scrolls
  Claude's output natively today. `mouse on` makes the wheel scroll tmux's history, and
  dragging selects and copies to the macOS clipboard through `pbcopy`. Native selection needs
  Option-drag (Terminal, iTerm, Ghostty) or Shift-drag. Claude's own Ctrl+O transcript view
  still works. How mouse and scrollback feel inside tmux in Warp is still open (open question 4);
  it has to be tried by hand before Host terminal sessions is offered (remote.md open question 1).
- **Copy mode is per pane, so every client sees it.** If someone on the Mac scrolls into history,
  the phone's terminal view shows copy mode too, and typing on either side goes to copy mode
  until it's left. The phone therefore never sends wheel events (its history is the native
  transcript), and the terminal view shows a "Mac is scrolling, Exit" pill when `#{pane_in_mode}`
  is 1. Exit sends `send-keys -t =NAME: -X cancel`.
- **Warp.** Inside tmux, Warp's blocks, input editor and per-command features don't apply. That
  was already mostly true while Claude's TUI ran, but scrollback and selection change as above.
  `WARP_FOCUS_URL` keeps working through the client pid. The Warp tab title follows Claude's
  title through `set-titles`.
- **Escape lag.** tmux holds a lone Esc for up to 500 ms until the outer terminal has answered its
  startup queries (experiment 11). Measured: the hold is per client and stops about 5 s after
  attach, and it happens only with terminals that don't answer XTVERSION. Terminal 488 doesn't, so
  Esc can feel late there for the first seconds of an attach; Warp 2026.09.16 showed none; Ghostty
  and iTerm answer everything. The phone's own PTY client answers XTVERSION (Terminal streaming).
- **Keys.** The prefix is off, so tmux takes no keys. Ctrl+B, Ctrl+O, Shift+Tab and Esc all reach
  the agent. Shift+Enter needs `extended-keys` (set) and a terminal that sends CSI u or
  modifyOtherKeys.
- **Notifications.** Claude's terminal bell reaches the outer terminal. OSC 9 and OSC 777
  notifications don't (`allow-passthrough off`). Side A's island covers this.

## Input

All input goes through `HostedSessions`, which runs the tmux binary with an argument array (no
shell). Text never goes on the command line: tmux's argv parsing drops a trailing `;`
(experiments 4 and 5). It's fed on stdin to `load-buffer`, which keeps every byte.

### Reply text

`POST /v1/sessions/{id}/reply {text, mode}` for a hosted session. Which mode types and which
queues, notes or refuses is protocol's [delivery table](protocol.md#delivery-table); this is how
`.typed` is done.

1. **Guard.** Refuse with 409 `session_waiting` when the session's registry status is `waiting`
   or a capture shows a dialog (an indented `  ❯ 1.` row or a `› 1.` row near the bottom, or
   Claude's unnumbered trust options). Enter would confirm the highlighted option. The phone
   answers through the request card instead. Status `unknown` is 409 `cannot_deliver`.
2. **Clean the text.** Normalize CRLF and CR to LF. Remove every C0 control except LF and TAB, plus
   DEL. ESC matters most: text holding `ESC [201~` would close the bracketed paste and the
   rest would be typed as keys. Cap at 1 MiB.
3. **Single character:** `send-keys -t =NAME: -l <c>`. Selection dialogs ignore a pasted `3`, and a
   typed one picks option 3 (Codeman's `submitsAsKeys`). A lone `;` is sent as `\;`.
4. **Longer text:**

   ```
   tmux -L sidea load-buffer -b sidea-in-<pid>-<n> -   ;   paste-buffer -p -d -b sidea-in-<pid>-<n> -t =NAME:
   ```

   That's one tmux invocation with the text on stdin (the `;` is its own argv element). `-p`
   wraps the text in `ESC[200~ … ESC[201~` only when the pane asked for bracketed paste. `-d`
   deletes the buffer, and a failed paste deletes it with `delete-buffer`. tmux turns LF into
   CR inside the paste by default, as a real terminal paste does (experiment 4). Each send gets
   its own buffer name, so two concurrent sends can't paste each other's text.
5. **Enter**, 60 ms later in a separate invocation: `send-keys -t =NAME: Enter`. Ink treats an
   Enter that arrives with the text as a newline, and Codex folds it into a paste burst.
6. **Arm the SubmitVerifier.**

`mode: note` for a hosted Claude session that's working uses the existing mail hook (it arrives
as `additionalContext` at the next tool call) rather than typing. For `auto` on a busy hosted
session the table says `.typed` for both: Claude queues a message submitted mid-turn, and Codex
steers on Enter. `followUp` or `submit: queue` to Codex is typed and submitted with Tab, which
queues it for the next turn.

### Single keys

`POST /v1/sessions/{id}/reply {mode: "keys", keys: [...]}` (protocol's `Key` values, mapped
here), allowlisted, one `send-keys` per key:

| Key | tmux | Use |
| --- | --- | --- |
| `1`–`9`, `y`, `n`, space | `send-keys -l <c>` | pick an option |
| `Enter`, `Escape`, `Tab`, `BTab`, `Up`, `Down`, `Left`, `Right` | `send-keys <Key>` | navigate dialogs, Shift+Tab mode cycling |
| `C-c`, `C-o`, `C-t`, `C-r`, `C-b` | `send-keys C-x` | cancel, transcript, todos, history search, background |

Every byte was checked on a test pane: `-l 3` gives `3`, `Escape` gives `ESC`, `C-c` gives `0x03`
(experiment 5).

### Interrupt

`POST /v1/sessions/{id}/interrupt` (`when: now`) sends `send-keys -t =NAME: Escape`. It goes in server-side, so
there's no client and no 500 ms Esc hold. It's sent only while the session is working
(Claude's registry says `busy`, or Codex's rollout shows a turn started and not completed).
Otherwise (idle, or status `unknown`) it returns 409 `cannot_deliver`, because a second Esc on an
idle Claude opens the rewind menu. At most one per 1.5 s. `when: nextStep` leaves stop mail
instead, hosted or not. Unhosted sessions keep the mail stop.

### Images

1. `POST /v1/uploads` with the photo. The app decodes it with ImageIO, scales it to at most
   2048 px on the long side, writes JPEG (PNG for screenshots with alpha), drops EXIF and GPS, and
   stores it at `runtime/uploads/<yyyymmdd>/<sha1 12>.jpg` (0600). It returns protocol's `Upload`
   (`id`, `path`, `mime`, `bytes`); replies and `StartHosted` name attachments by `Upload.id`,
   and the Mac maps ids back to paths. Uploads older than 7 days are deleted.
2. Reply with attachments, hosted: each path goes in as its own bracketed paste, **always
   single-quoted** (`'/Users/…/Application Support/SideA/runtime/uploads/…/3f2a….jpg'`), followed
   by a typed space, then the text paste, then Enter. Checked on the versions above: Claude makes
   an attachment (`[Image #1]`) from any form of the path; Codex makes an image chip only from a
   quoted or escaped path, and upload paths contain a space ("Application Support"). Before the
   Enter, the app captures the composer. If no chip appeared, the path stays as plain text and the
   agent can Read it. A Read outside the project asks permission, which the phone can answer.
3. Unhosted sessions (Stop-hook reply, note): the paths go into the text.

## Continue on phone

Moves an unhosted session into tmux. It's always the user's explicit choice, never automatic.

**Offered when** all of these hold:

- the session is in Claude Code's registry (or is a live Codex process with a rollout), has a
  session id and a transcript, and isn't hosted;
- it isn't headless (`claude -p`, SDK `kind`) and isn't Side A's own window priming;
- its status is `idle`, or `waiting` (never `unknown`). For `waiting` the sheet says the open request will be
  cancelled and won't come back by itself. It's never offered while `busy`, or while it runs a
  background shell (`shell`): ending it would kill that job;
- for Codex: the last rollout turn is positively complete (`task_complete` or `turn_aborted` for
  the last `turn_id`); a tail with no turn evidence is `unknown` and doesn't qualify.

The sheet always says: "Ends it in <terminal> and continues it here. The Mac tab goes back to its
prompt; `sidea attach <name>` there joins again. The next reply starts without the prompt cache."

**Steps:**

1. Check again with a fresh `live` (same pid, same start time, same session id, still eligible),
   as `quit` does.
2. Record the session's pin: `SIDE_A_PIN` from its environment (`KERN_PROCARGS2`), if any. The new
   session uses that pin, or follows Side A when there isn't one.
3. `kill(pid, SIGTERM)`. Claude Code saves on SIGTERM.
4. Wait up to 5 s for the pid to exit (`kill(pid, 0)`, then its registry file gone), then until the
   transcript's size stops changing for 300 ms.
5. `host <agent> --detach --origin continue --session ID -- --resume ID` (Codex: `resume ID`,
   behind the account's `codex_bridge.invocation` prefix and environment), in the same folder.
   This goes through `HostedSessions.start`, so the same per-conversation lock and live check
   apply.
6. Success means the pane is alive and the registry shows that session id under the pane within
   20 s. The phone then opens the session, now hosted. A reply typed on the phone in the meantime
   is held and sent once the composer is up, with the verifier armed (this is the 30 to 50 s case).

**Failure handling:**

| Failure | Result |
| --- | --- |
| Not eligible on re-check | nothing is sent; "It started working again, so it was left running." |
| Still running after 5 s | no SIGKILL; "It didn't quit, so it's still running on the Mac." |
| Pane dies or no registry entry within 20 s | the pane is kept, not cleaned up, so the phone shows the screen; the card offers **Try again** and the Mac command `claude --resume ID` to copy |
| The folder is gone | refused before anything is ended |

Only one Continue runs per session id at a time.

## Terminal streaming

### A tmux client per viewer

Each open terminal view on a phone gets its own tmux client, in a PTY the app owns:

- **Spawn.** A small C target (`CSideAPTY`) does `forkpty()` and only `execve` in the child. Swift
  must not run between fork and exec in a multithreaded process. The child runs
  `tmux -u -L sidea -f runtime/tmux.conf attach-session -f ignore-size -t =NAME` with
  `TERM=xterm-256color` and `LANG` set, and the PTY sized to the phone's grid.
- **`ignore-size`** keeps phone clients from ever changing the window size by themselves
  (experiment 8). Size is decided by the app (Resize below).
- **Startup queries.** tmux asks every new client for DA1 (`CSI c`), DA2 (`CSI > c`), XTVERSION
  (`CSI > q`), the colour scheme (`CSI ? 996 n`) and the colours (OSC 10 and OSC 11). Until all are
  answered it holds a lone Esc for 500 ms (experiment 11). The viewer answers them itself, from
  the Mac, during the first 6 s after attach (tmux stops waiting after about 5 s): `CSI ? 62 ; 22 c`, `CSI > 0 ; 10 ; 1 c`, `DCS > | SideA-Remote
  1.0 ST`, `CSI ? 997 ; 1|2 n` (the phone's appearance), and `OSC 10/11 ; rgb:… ST` with the
  phone's theme colours. XTVERSION matters most: the hold is per client, stops about 5 s after
  attach, and was seen only with terminals that don't answer XTVERSION (Terminal.app). It also
  removes those queries from what goes to the phone, so SwiftTerm doesn't answer twice.
- **Input** from the WebSocket is written to the PTY master in one `write` per frame. A key
  sequence never gets split, and tmux parses it as one key (experiment 11: even ESC and `[A` 4 ms
  apart still parse as Up).
- **Lifetime.** The PTY and client die with the socket: SIGHUP to the child, then SIGKILL after
  1 s. A reconnect spawns a fresh client, and tmux redraws the whole screen on attach, so no
  output needs replaying. At most 4 viewers per session; the oldest is closed for a fifth.

### WebSocket `/v1/ws/term/{name}`

The frames, control messages, limits and close codes are protocol's
[terminal section](protocol.md#websocket-v1wstermname), the only definition; this file
implements it. In short: binary output frames start `0x01`, binary input frames start `0x02` with
a big-endian u32 `seq`, input frames are at most 16 KiB, control is `{"type", "data"}` JSON
(`hello`, `resize`, `ready`, `ack`, `size`, `mode`, `exit`), and the session ending is `exit` then
close 4410. Mac-side details:

**Coalescing.** A `DispatchSource` reads the PTY master. The first byte after a quiet period
starts a 4 ms timer. The buffer goes out when the timer fires, or at once at 32 KiB (protocol's
output frame limit). Nothing is wrapped around chunks: inserting `CSI ? 2026 h/l` at arbitrary
byte boundaries could land inside an escape sequence. If SwiftTerm supports synchronized output,
the `sync` feature in `terminal-features` makes tmux bracket its own frames instead.

**Backpressure.** When more than 1 MiB is waiting to be sent on the socket, the viewer stops
reading the PTY. tmux notices the slow client, drops what it can no longer send and redraws
when it catches up. So a phone on a bad link sees the current screen, not a replay.

**Copy mode.** When `#{pane_in_mode}` changes, the server sends `mode{copy}` (see the caveats).

### Resize: the Mac wins while it's typing

Decision 5 in tmux terms. This was measured (experiments 7 and 8): `client_activity` changes on
attach and on keys, not on output, in whole seconds. `window-size latest` follows the latest
active client. `manual` ignores clients until `resize-window`. Unsetting the window option falls
back to the global `latest`.

```
evaluate(session):                           # on any hook wake, a phone resize or input, and every 5 s
  phones = this session's viewers            # ignore-size clients
  macs   = list-clients without ignore-size
  if phones is empty:            set -w -u -t =NAME window-size        # plain tmux behaviour
  elif macs nonempty and now - max(mac.client_activity) < 60:
                                 set -w -u -t =NAME window-size        # Mac owns: latest = Mac
                                 owner = mac
  else:
    p = the phone with the most recent input or resize
                                 set -w -t =NAME window-size manual
                                 resize-window -t =NAME -x p.cols -y p.rows
                                 owner = phone
  every viewer's PTY := the window's size; send size{window size, owner}
```

- While the Mac owns the window, the phone gets the Mac's grid. SwiftTerm renders it scaled to fit
  the width down to 7 pt, then pans sideways.
- When the Mac types again, `client-active` wakes the app at once. The window option is unset and
  tmux applies the Mac's size. That first keystroke lands in the phone-sized window, which is
  harmless.
- A Mac tab opening counts as typing, since attach sets activity.
- Replies sent with `send-keys` don't touch any client and don't change ownership.

### Numbered, acked input

A port of Codeman's reliable input delivery, with protocol's rules (Input, numbered and acked):

- **Phone.** A stable `viewer` id per (device, terminal view) and a `seq` that only grows within
  an epoch. Unacked frames are persisted in the App Group store before each send, so they survive
  the app being suspended. Frames go out in order, and a frame is dropped only when an `ack`
  covers it. If the oldest unacked frame is 3 s old, the socket is presumed half-open: close,
  reconnect, and resend only if the reconnect's `ready` proves the same epoch and a known
  `applied`.
- **Mac.** `applied[viewer]`, in memory, kept 120 s after the socket closes. A frame is written
  only when `seq > applied`, and then `applied = seq`. A duplicate is still acked. `ready.applied`
  tells a reconnecting phone what landed; it drops those frames and resends the rest at once.
- **Uncertain delivery.** If Side A restarted (`ready.epoch` changed) or the record expired
  (`ready.applied` is nil), keystrokes including an Enter may have reached tmux with their ack
  lost. The phone **discards** every unacked frame and shows "Side A restarted. Some keys may not
  have reached the session." in the terminal view; it never replays them, and age is never used to
  guess. Chat replies go through REST with persisted idempotency and aren't affected.

### Predictive echo in SwiftTerm

This is a port of Codeman's `PredictiveEchoAddon` (mosh-style write-through), for both agents.
Codeman's other mode, buffer-until-Enter, is left out: it starves the live slash and `@` pickers.
Every keystroke goes to the wire unchanged. The predictor only paints, so it can't corrupt
input. Its whole job is to make the composer feel local on a slow link.

**Where it hooks in.** In `TerminalViewDelegate.send(source:data:)`, before the frame is queued,
each send is classified (pure function):

| Data | Class | Predictor |
| --- | --- | --- |
| one scalar ≥ 0x20, not 0x7F | `char` | `predict(ch)` |
| `0x7F` | `backspace` | `predictBackspace()` |
| several printable scalars (IME commit, plain paste, ZWJ emoji) | `text` | anchor hold |
| anything starting with ESC (arrows, bracketed paste, mouse), CR, TAB, other controls | `clear` | `clear()` + anchor hold |

After every `terminalView.feed(byteArray:)` from the socket (SwiftTerm parses synchronously, so
the buffer is current when it returns), the predictor runs `reconcile()` and releases the anchor
hold. Resize, font change, leaving the view and `yDisp != yBase` (scrolled up) all clear.

**State.** `outstanding: [Record]`. Each record holds `seq`, `char`, `width` (1 or 2 cells),
`offset` (cells from the anchor before this char), `snapshot` (the cell's content when
predicted, empty as space), `sentAt` and `mismatches`. `anchor (row, col)` is taken when
outstanding goes from 0 to 1; `row` counts from `yBase`. Positions are fixed when predicted;
confirming removes glyphs and never re-lays-out, so partial confirmation doesn't jitter.

**Gate (`predictWhen`).** The cursor row as text (`buffer.lines[yBase + y]`, translated, trailing
blanks trimmed):

- Codex: `^› ` and not `^› \d+\. ` (the trust dialog and question options use `› 1.`). Cursor
  column ≥ 2.
- Claude: `^❯\u00A0` at column 0 (the composer, per First prompt; echoes use `❯` + space and
  dialog rows are indented, so neither passes). Cursor column ≥ 2. The session must not be
  `waiting`.
- Wrapped continuation rows (two-space indent, no glyph) fail the gate on purpose. Echo there
  comes from the Mac, at RTT.

**`predict(ch)`** runs `reconcile()` first, then stops (returning false, though the key still
goes out) if any of these hold: anchor hold; no cell metrics; scrolled up; the gate is false;
not exactly one scalar; width not 1 or 2; 32 outstanding; the glyph would land within 4 cells of
the right edge. If outstanding is empty, it re-anchors at the cursor. Otherwise
`col = anchor.col + last.offset + last.width`. It snapshots the cell, appends the record and
paints the glyph at `(anchor.row, col)`.

**`reconcile()`:**

1. Nothing outstanding: return (costs one check while output streams).
2. Scrolled up: clear.
3. Cursor off the anchor row: tolerate for 150 ms (a repaint parks the cursor elsewhere mid-frame),
   then clear.
4. **Confirm, prefix only.** While the first record's cell now holds its char *and* the cursor is
   on the anchor row at or past `anchor.col + offset + width`: remove it and count a
   confirmation. Matching the cell alone isn't enough: Codex's placeholder text can hold the
   same letter, and an identical repaint by tmux must not confirm anything.
5. **Mismatch, two passes.** For each record, a cell that is neither the snapshot, nor the
   predicted char, nor blank counts as foreign. Foreign on two passes in a row drops that record
   and everything after it. Blank is neutral: Codex clears its placeholder on the first echo,
   and blanks under later predictions just mean "not echoed yet". A half-parsed row on one pass
   is redrawn a few milliseconds later.
6. **TTL.** The first record older than 1 s drops itself and everything after it.
7. Empty: reset anchor and timers. Otherwise re-arm the TTL timer for the oldest record.

A change of `yBase` (the history grows while Codex keeps its composer pinned at the bottom)
doesn't clear: the anchor counts from `yBase` and stays valid.

**`predictBackspace()`** removes the newest record if there is one. If there isn't, the
backspace will delete text that's already echoed, which the predictor can't see, so it sets the
anchor hold. **Anchor hold:** after an input whose effect on the cursor hasn't been displayed
(backspace into echoed text, any `clear` or `text` input), no new prediction is made until the
next feed. Anchoring on the stale cursor paints ghosts one cell off. The worst case is one key
without prediction.

**Painting.** An overlay view above `TerminalView`. Each prediction is a layer at
`(col × cellWidth, (row − (yDisp − yBase)) × cellHeight)`. It uses the terminal's font,
foreground and background colours, so it covers a placeholder glyph beneath and the swap is
invisible when the real echo lands. Cell metrics come from the same font measurement SwiftTerm
uses. Wide glyphs take two cells, and they're predicted only when per-cell access is available.

**Constants:** TTL 1000 ms, off-row grace 150 ms, max 32 outstanding, edge margin 4 cells. Later:
predict only once the measured RTT (input frame to ack) is over 30 ms, so a LAN connection never
paints.

## Matching panes to live sessions

Hosted sessions show up in the same Running list as all the others. The list gets a terminal
badge, and `LiveSession` gains `hosted: String?`. `sessions.py live` does the matching, since it
already takes one `ps` snapshot (`process_tree`):

1. `tmux -L sidea list-panes -a -F '#{session_name}\t#{pane_pid}\t#{pane_dead}\t#{@sidea_agent}'`,
   using the binary in `runtime/tmux-path`. If there's no server, nothing is hosted.
2. For each live session (Claude's registry, and Codex processes from `live_codex`), walk
   `ppid` from its pid until the pid is a `pane_pid` (hosted in that pane) or reaches 1 (not
   hosted), at most 32 steps. A pane's `pane_pid` is its `zsh`, with the agent beneath it; tmux
   itself is a daemon whose parent is launchd (experiment 3).
3. If several live sessions reach the same pane, the one with the fewest steps belongs to it. A
   `claude -p` the session started belongs to the session, and is headless anyway.
4. Cross-check: the session's environment (`KERN_PROCARGS2`, already read for the account) should
   have `SIDE_A_HOSTED=<that name>`. If they disagree, ancestry wins and the disagreement goes to
   the diagnostic log.
5. The first match fills `@sidea_session` if it's empty (`set -t =NAME @sidea_session ID`), so
   the session can be resumed after a tmux crash.

The island hook can pass `SIDE_A_HOSTED` along with each request, so a request is known to come
from a hosted session before `live` refreshes. That's what allows the longer hold for hosted
Codex requests, since nobody is at that terminal.

## Experiments

Run on 2026-10-17 with tmux 3.7c (Homebrew) on macOS 27.0.1, on a private server (`tmux -L
sidea-spec`), with a test program in place of an agent. Claude and Codex were not started. The
server was killed afterwards. A later round of live checks with the real CLIs (Claude Code
2.1.302, Codex 0.156.1, Warp 2026.09.16, Terminal 488) settled the composer, trust dialog, prompt
argument, image path and Esc questions; its results are folded into the sections above and the
open questions.

| # | Question | Result |
| --- | --- | --- |
| 1 | Config basics | `escape-time 0`, `remain-on-exit on`, `window-size latest`, `default-terminal tmux-256color` read back as set; `-e SIDE_A_HOSTED=…` shows in `show-environment -t` |
| 2 | User options | `set-option -t S @sidea_agent claude` etc.; values with spaces and empty values round-trip in `list-sessions -F`, and session options also resolve in `list-panes -a -F` |
| 3 | `pane_pid` | is the pane's first process (`zsh`); the server's parent is pid 1, so walking parents from an agent never reaches the terminal app |
| 4 | Bracketed paste | `paste-buffer -p` adds `ESC[200~`/`ESC[201~` only when the pane enabled mode 2004; LF becomes CR unless `-r`; `set-buffer -- 'x tab;'` stored `x tab` (trailing `;` lost); `load-buffer -` from stdin kept a trailing `;`, UTF-8 and emoji, and pasted 200,000 bytes as one bracketed paste |
| 5 | Keys | `send-keys -l 3` → `3`; `Escape` → `ESC`; `C-c` → `0x03`; `-l 'semi;'` → `semi` (lost); `-l 'a\;'` → `a;` |
| 6 | Arguments through `new-session` | an argv element ending in `;` ends the tmux command even after `--` (`unknown command: x;`); `\;` gives a literal `;`. User arguments therefore go through the launch file |
| 7 | Two clients, sizes | `latest`: a client attaching takes the size (attach counts as activity); pane output doesn't change `client_activity`; a keypress does; resizing the latest client resizes the window; `client_activity` is whole seconds. `manual`: the window ignores keys and client resizes until `resize-window`. `set -w -u window-size` returns to the global `latest`, sized to the latest active client |
| 8 | `attach -f ignore-size` | that client never changed the window (attach, keys, resize); `client_flags` shows `ignore-size` |
| 9 | Hooks and `wait-for` | `pane-died` fires with `#{session_name}` and `#{pane_dead_status}` (`#{hook_session_name}` is empty there); `session-closed`, `client-attached`, `client-resized` and `client-active` (on a key from either client) fire; `wait-for -S` wakes a blocked `wait-for` in under 0.5 s, and a signal with no waiter makes the next `wait-for` return at once |
| 10 | `remain-on-exit` | the dead pane keeps status and screen (`Pane is dead (status 3, …)`), `pane_dead_status`=3; `kill-session` then fires `session-closed`; `respawn-pane` revives a dead pane in place |
| 11 | `escape-time` and Esc | with `escape-time 0`, a lone Esc written to a client's PTY was held 500 ms whenever the client hadn't answered tmux's queries (`CSI ?996n`, `CSI c`, `CSI >c`, `CSI >q`, OSC 10/11), whatever `escape-time` and `extended-keys` were; with all answered it arrived in 1 ms; DA alone, or OSC alone, wasn't enough. ESC and `[A` sent 4 ms apart parsed as Up at 0, 10 and 50. `send-keys Escape` skips client parsing |
| 12 | Login shell and accounts | `new-session … 'zsh -l'` → interactive and login, `.zshrc` ran (with a test `ZDOTDIR`), and a typed command saw the selector file's current value through the `preexec` hook; `zsh -lic '…'` ran `.zshrc` and the `-c` command saw the selector exported by the snippet's final `_side_a_select` |
| 13 | Clean start | `env -i … tmux start-server` with `exit-empty off` keeps a server with no sessions; the global environment holds only what was passed |
| 14 | Titles | with `set-titles on` and `set-titles-string '#{pane_title}'`, a pane's OSC 2 reached the client as OSC 0; before the pane sets one, the title is the host name |
| 15 | Targets | bare names are matched loosely, so a near-miss name can resolve or fail quietly; `-t '=NAME:'` matches exactly and is used everywhere |

### Measured while building (L4, branch `remote/l4-hosting`)

These override anything above that says otherwise.

- **Targets:** `set-option -t =NAME` fails ("no such session") because `set` takes a pane target.
  Use `-t =NAME:` for `set`, `send-keys`, `capture-pane` and `paste-buffer`; `=NAME` only for
  `has-session`, `kill-session`, `attach-session` and `list-clients`. The window-size lines in
  Terminal streaming need `=NAME:` too.
- **`-u` on every call:** the app runs from launchd with no `LANG`, and without a UTF-8 locale tmux
  prints tabs and non-ASCII in `-F` output as `_`. Every tmux invocation passes `-u`.
- **Lock file:** `zsystem flock` needs the file to exist (`: >> file` first).
- **`TMUX_TMPDIR`:** the launcher unsets it and the app strips it, or a shell that exported it
  would talk to a different socket.
- **Config:** `set -su terminal-features` before the `-as` appends, so a re-source doesn't pile up;
  a `session-created[50]` hook.
- **Launcher:** takes `--key K` (persisted in `runtime/hosted/<name>/key` under the lock, so a
  retried start after an app restart returns the same session) and `--env NAME=VALUE`; values
  ending in `;` are escaped to `\;`; the `@sidea_*` options are set in the same invocation as
  `new-session`. It refuses a second live pane with the same `@sidea_session` and returns the
  existing one.
- **Reply guard:** a reply needs an empty composer (the dim placeholder counts as empty) and no
  open dialog, otherwise 409 `composer_busy` ("Something is already typed in this session").
  After pasting, Side A records exactly what the composer shows; re-presses fire only while it
  still shows that, and stop at the first Mac client activity.
- **Fork while live:** a fork writes a new transcript, so it's allowed while the source session is
  live (only resume is refused). For Codex this still rests on `codex fork` not writing to the
  parent rollout.
- **Codex accounts:** started through `codex_bridge.invocation()` (args plus `CODEX_HOME`).
- **Codex fork doesn't touch the parent:** with the parent live in another pane, the parent
  rollout's size, mtime and SHA-1 were unchanged after a forked turn (0.156.1). Codex forks of a
  live thread are allowed, like Claude's.
- **Codex mid-turn (0.163.0):** Enter steers the running turn (one task_started/complete pair,
  both messages answered); Tab queues it as the next turn ("Queued follow-up inputs"). Claude
  queues on Enter. `RemoteReply.submit` is `steer` (default) or `queue`; the difference applies only
  to Codex, and the Mac advertises it with the `reply.steer` capability.
- **Trust carries over to worktrees** in both CLIs (a linked worktree maps to its main
  repository's trust). New-session worktrees copy gitignored `.env*` files, and the UI says so.
- **Codex update prompt:** a resumed Codex can draw "Update available … › 1. Update now (runs
  `brew upgrade --cask codex`)" under the composer with option 1 selected, so a stray Enter
  upgrades Codex. Hosted Codex starts pass `-c check_for_update_on_startup=false`, and a numbered
  `› N.` block under the composer counts as a dialog (replies stop, unsent).

## Open questions

Questions 1 to 3, and the Esc half of 4, were settled by live checks on Claude Code 2.1.302,
Codex 0.156.1, tmux 3.7c, Warp 2026.09.16 and Terminal 488 (folded into First prompt, the
SubmitVerifier, Images and the caveats above):

1. ~~Claude's composer glyph.~~ `❯` + U+00A0 at column 0 is the composer; `❯` + space is an echo;
   dialog rows are indented. `>` is dropped. Both CLIs dim an empty composer's placeholder.
2. ~~Prompt as an argument on resume.~~ Auto-submits for Claude resume and fork-session and for
   `codex resume` and `codex fork`; `codex fork` exists in 0.156.1 (older versions still checked).
3. ~~Pasted image paths.~~ Paste them single-quoted; Codex needs quoting, Claude takes any form.
4. **Mouse and scrollback inside tmux in Warp.** Esc lag is settled (Terminal.app only, first
   ~5 s). Whether `mouse on` and tmux scrollback feel acceptable in Warp is still open; the user
   will try it hands-on before Host terminal sessions is offered.
5. ~~**Bundle tmux or rely on Homebrew?**~~ Bundled (`remote/l4c-deps`): a universal tmux 3.7c at
   `Contents/Helpers/tmux` (`com.sidea.tmux`, hardened runtime), built by `scripts/build-tmux.sh`
   from SHA-256-pinned sources with libevent, ncurses, utf8proc and jemalloc static (3.7c needs
   jemalloc on macOS, linked with `-force_load`), plus a bundled `tmux-256color` terminfo used
   through `TERMINFO_DIRS`. Homebrew tmux 3.4+ is the fallback for dev builds only.
6. **Worktree trust and setup.** Does Claude's folder trust cover `<repo>/.sidea-worktrees/<name>`
   through its parent, and does Codex map a worktree to its repository's trust? Should New session
   offer to copy `.env` files into the worktree?
7. **Codex while busy.** Answered (0.163.0, under Experiments): Enter steers the turn and Tab queues
   the message for the next. Protocol's delivery table types `auto` with Enter and `followUp` or
   `submit: queue` with Tab.
8. **SwiftTerm details.** Synchronized output (mode 2026) support, how SwiftTerm measures cells,
   and per-cell access for the confirm step.
9. **Continue on phone while `waiting`.** Offer it, with the warning, or only when idle?
10. **Codex and SIGTERM.** Confirm Codex flushes its rollout on SIGTERM, so `codex resume` picks up
    the last turn.
11. **Remove Side A** should list running hosted sessions and offer to end them. Today it would
    leave a tmux server behind.
12. **Codex fork of a live thread.** Verify `codex fork` never writes to the parent rollout, so it
    can be allowed while the parent runs, as Claude's `--fork-session` is.
