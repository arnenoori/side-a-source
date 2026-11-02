"""Hosted sessions: Side A's own tmux server (`tmux -L sidea`), its config and the launcher every
start and attach goes through. See docs/remote/hosting.md."""
import os
from pathlib import Path
import re
import subprocess

SOCKET = "sidea"
MINIMUM = (3, 4)
CANDIDATES = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
SYSTEM_TERMINFO = ["/usr/share/terminfo"]

CONFIG = """\
# Written by Side A at launch; edits are overwritten. Your own ~/.tmux.conf is not read.
set -s  escape-time 0
set -s  exit-empty off
set -s  extended-keys on
set -s  extended-keys-format csi-u
set -s  focus-events on
set -s  set-clipboard on
set -s  default-terminal "tmux-256color"
set -su terminal-features
set -as terminal-features ",xterm-256color:RGB:extkeys:sync:title:clipboard:ccolour:cstyle"
set -as terminal-features ",xterm-ghostty:RGB:extkeys:sync:title:clipboard"
set -s  copy-command "pbcopy"

set -g  default-shell /bin/zsh
set -g  update-environment ""
set -g  history-limit 50000
set -g  status off
set -g  prefix None
set -g  prefix2 None
set -g  mouse on
# Mouse on for scrolling and selection, but no right-click menus: their items (kill, swap, respawn) act on a pane
# with one click, and a phone viewer's taps arrive as clicks.
unbind -q -n MouseDown3Pane
unbind -q -n M-MouseDown3Pane
unbind -q -n MouseDown3Status
unbind -q -n M-MouseDown3Status
unbind -q -n MouseDown3StatusLeft
unbind -q -n M-MouseDown3StatusLeft
unbind -q -n MouseDown3Empty
unbind -q -n M-MouseDown3Empty
set -g  destroy-unattached off
set -g  remain-on-exit on
set -g  remain-on-exit-format "Session ended (#{?pane_dead_status,status #{pane_dead_status},signal #{pane_dead_signal}})."
set -g  set-titles on
set -g  set-titles-string "#{pane_title}"
set -g  allow-passthrough off
set -g  allow-rename off
set -gw window-size latest
set -gw aggressive-resize off

# Hooks wake the app; indexes are fixed so re-sourcing replaces instead of appending.
set-hook -g pane-died[50]        "wait-for -S sidea-changed"
set-hook -g session-closed[50]   "wait-for -S sidea-changed"
set-hook -g session-created[50]  "wait-for -S sidea-changed"
set-hook -g client-attached[50]  "wait-for -S sidea-changed"
set-hook -g client-detached[50]  "wait-for -S sidea-changed"
set-hook -g client-active[50]    "wait-for -S sidea-changed"
set-hook -g client-resized[50]   "wait-for -S sidea-changed"
"""

# zsh, not sh: ${(q)@} quotes arguments exactly and zsystem flock serializes starts.
LAUNCHER = r"""#!/bin/zsh -f
# Written by Side A at launch; edits are overwritten.
emulate -L zsh; setopt no_unset pipe_fail extended_glob
zmodload -F zsh/datetime p:EPOCHSECONDS; zmodload zsh/system
root=${0:A:h:h}
tmux=$(<$root/runtime/tmux-path) 2>/dev/null
[[ -n $tmux && -x $tmux ]] || { print -u2 "Side A found no tmux 3.4 or later."; exit 69; }
conf=$root/runtime/tmux.conf
# Always the default socket folder, as the app uses: a TMUX_TMPDIR exported in one shell would
# otherwise put that shell on another server. SIDE_A_TMUX_SOCKET (a path) is for tests. -u: without
# a UTF-8 locale tmux prints tabs and non-ASCII in formats as '_'.
if [[ -n ${SIDE_A_TMUX_SOCKET:-} ]]; then T=($tmux -u -S $SIDE_A_TMUX_SOCKET -f $conf); else T=($tmux -u -L sidea -f $conf); fi
unset TMUX TMUX_PANE TMUX_TMPDIR

# tmux ends a command at any argument ending in ';', even after --; '\;' is a literal ';'.
arg() { [[ ${1-} == *\; ]] && print -r -- "${1%;}\\;" || print -r -- "${1-}"; }

ensure_server() {
  $T show -s exit-empty >/dev/null 2>&1 && return
  env -i HOME=$HOME USER=${USER:-} LOGNAME=${LOGNAME:-} SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=${LANG:-en_US.UTF-8} TMPDIR=${TMPDIR:-/tmp} ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK=$SSH_AUTH_SOCK} \
    $T start-server
}

project_of() {
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

# A worktree for this session at <repo>/.sidea-worktrees/<name> on sidea/<name>, from BASE in the
# checkout cwd is in, keeping cwd's place inside it. Folder trust carries over from the repository
# (Claude Code 2.1.302, Codex 0.163). Gitignored .env files are copied and listed in copied.txt,
# so the app can say so and remove unchanged copies when the session ends.
make_worktree() {
  local common top f
  common=$(git -C $cwd rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { print -u2 "Not in a git repository: $cwd"; return 1; }
  top=$(git -C $cwd rev-parse --show-toplevel) || return 1
  [[ ${common:t} == .git ]] || { print -u2 "Side A makes worktrees only for repositories with a .git folder."; return 1; }
  repo=${common:h} branch=sidea/$name tree=${common:h}/.sidea-worktrees/$name
  git -C $cwd worktree add --quiet --no-track -b $branch $tree $worktree >&2 || return 1
  grep -qxF '/.sidea-worktrees/' $common/info/exclude 2>/dev/null || print -r -- '/.sidea-worktrees/' >> $common/info/exclude
  git -C $top ls-files --others --ignored --exclude-standard --directory -z 2>/dev/null | while IFS= read -r -d '' f; do
    [[ ${f:t} == .env* && $f != */ && -f $top/$f ]] || continue
    mkdir -p -- ${tree}/${f:h} && cp -p -- $top/$f $tree/$f && print -r -- $f >> $dir/copied.txt
  done
  [[ -s $dir/copied.txt ]] && print -r -- $top > $dir/copied-from
  # git reports resolved paths (/private/tmp, not /tmp).
  local here=${cwd:A}
  [[ $here == $top(|/*) ]] && cwd=$tree${here#$top} || cwd=$tree
}

finish() {
  print -r -- $1
  (( detach )) || exec $T attach-session -t "=$1"
}

# host <claude|codex> [--detach] [--cwd DIR] [--pin NAME] [--origin X] [--session ID] [--key K]
#      [--env NAME=VALUE]... [--worktree BASE] [--prompt-file F] -- ARGS...
host() {
  local agent=${1:-}; shift
  local detach=0 cwd=$PWD pin= origin=terminal session= promptfile= key= name= existing= lock worktree= repo= tree= branch=
  local -a envs
  while (( $# )); do
    case $1 in
      (--detach) detach=1;; (--cwd) cwd=$2; shift;; (--pin) pin=$2; shift;;
      (--origin) origin=$2; shift;; (--session) session=$2; shift;; (--prompt-file) promptfile=$2; shift;;
      (--key) key=$2; shift;; (--env) envs+=(-e "$(arg "$2")"); shift;; (--worktree) worktree=$2; shift;;
      (--) shift; break;; (*) break;;
    esac; shift
  done
  [[ $agent == (claude|codex) ]] || { print -u2 "usage: sidea-tmux host claude|codex [options] -- ARGS"; return 64; }
  [[ -d $cwd ]] || { print -u2 "No such folder: $cwd"; return 66; }
  ensure_server || return 69
  mkdir -p -m 700 $root/runtime/hosted && : >> $root/runtime/hosted/.lock
  # One start at a time, so a retried start or a second resume finds the first instead of racing it.
  zsystem flock -t 30 -f lock $root/runtime/hosted/.lock || return 75
  if [[ -n $key ]]; then
    for existing in $root/runtime/hosted/*/key(N); do
      [[ $(<$existing) == $key ]] && { zsystem flock -u $lock; [[ -n $promptfile ]] && rm -f -- $promptfile; finish ${existing:h:t}; return; }
    done
  fi
  if [[ -n $session ]]; then
    existing=$($T list-panes -a -F "#{pane_dead}	#{@sidea_session}	#{session_name}" 2>/dev/null | awk -F '\t' -v s="$session" '$1 == 0 && $2 == s { print $3; exit }')
    [[ -n $existing ]] && { zsystem flock -u $lock; [[ -n $promptfile ]] && rm -f -- $promptfile; finish $existing; return; }
  fi
  name=$(new_name $cwd) || { zsystem flock -u $lock; return 75; }
  local dir=$root/runtime/hosted/$name; mkdir -p -m 700 $dir
  if [[ -n $worktree ]]; then
    make_worktree || { zsystem flock -u $lock; rm -rf -- $dir; return 65; }
  fi
  [[ -n $key ]] && print -r -- $key > $dir/key
  [[ -n $promptfile ]] && mv -f -- $promptfile $dir/prompt.txt
  {
    print -r -- "cd -- ${(q)cwd} || exit 66"
    print -r -- '(( $+functions[_side_a_select] )) && _side_a_select'
    if [[ -f $dir/prompt.txt ]]; then
      print -r -- "_side_a_prompt=\$(<${(q)dir}/prompt.txt); rm -f -- ${(q)dir}/prompt.txt"
      # Both CLIs end their options at --, so the prompt is never read as a flag.
      print -r -- "$agent ${(j: :)${(q)@}} -- \"\$_side_a_prompt\""
    else
      print -r -- "$agent ${(j: :)${(q)@}}"
    fi
  } > $dir/launch.zsh
  # User arguments travel in launch.zsh; the pane's argv holds only fixed words. The options are
  # set in the same invocation, so nothing can see the session without them.
  $T new-session -d -s $name -c "$(arg "$cwd")" -x 120 -y 40 -e SIDE_A_HOSTED=$name \
       ${pin:+-e} ${pin:+"$(arg "SIDE_A_PIN=$pin")"} $envs \
       -- /bin/zsh -lic 'source "$1"' zsh $dir/launch.zsh \; \
     set -t "=$name:" @sidea_v 1 \; set -t "=$name:" @sidea_agent $agent \; set -t "=$name:" @sidea_cwd "$(arg "$cwd")" \
     \; set -t "=$name:" @sidea_origin "$(arg "$origin")" \; set -t "=$name:" @sidea_session "$(arg "$session")" \
     \; set -t "=$name:" @sidea_account "$(arg "$pin")" \; set -t "=$name:" @sidea_key "$(arg "$key")" \
     \; set -t "=$name:" @sidea_repo "$(arg "$repo")" \; set -t "=$name:" @sidea_worktree "$(arg "$tree")" \
     \; set -t "=$name:" @sidea_branch "$(arg "$branch")" \
     \; set -t "=$name:" @sidea_created $EPOCHSECONDS \; set -F -t "=$name:" @sidea_pane '#{pane_id}' \
     || { zsystem flock -u $lock; rm -rf -- $dir; return 70; }
  zsystem flock -u $lock
  finish $name
}

attach() {
  ensure_server || return 69
  if [[ -n ${1:-} ]]; then exec $T attach-session -t "=$1"; fi
  local -a here=(${(f)"$($T list-sessions -F '#{@sidea_cwd}	#{session_name}' 2>/dev/null | awk -F '\t' -v d="$PWD" '$1 == d { print $2 }')"})
  if (( $#here == 1 )); then exec $T attach-session -t "=$here[1]"; fi
  list
  (( $#here > 1 )) && print "Several sessions run here; name one: sidea attach <name>"
  return 0
}

list() {
  local out=$($T list-sessions -F '#{session_name}  #{@sidea_agent}  #{@sidea_cwd}' 2>/dev/null)
  print -r -- ${out:-No hosted sessions.}
}

cmd=${1:-}; shift 2>/dev/null
case $cmd in
  (host) host "$@";; (attach) attach "$@";; (ls) list;;
  (*) print -u2 "usage: sidea-tmux host|attach|ls"; exit 64;;
esac
"""


def runtime(root):
    return Path(root) / "runtime"


def version(binary):
    """(major, minor) from `tmux -V` ("tmux 3.7c", "tmux next-3.8"), or None."""
    try:
        output = subprocess.run([binary, "-V"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    found = re.search(r"(\d+)\.(\d+)", output)
    return (int(found[1]), int(found[2])) if found else None


def find_tmux(bundled=None):
    """The one tmux every client runs: the app's own build (Contents/Helpers/tmux, see
    scripts/build-tmux.sh) if it ships one, else Homebrew's or MacPorts' in development builds."""
    for path in ([bundled] if bundled else []) + CANDIDATES:
        if path and os.access(path, os.X_OK) and (version(path) or (0, 0)) >= MINIMUM:
            return path
    return None


def tmux_path(root):
    try:
        path = (runtime(root) / "tmux-path").read_text().strip()
    except OSError:
        return None
    return path if path and os.access(path, os.X_OK) else None


def write_private(path, text, mode=0o600):
    temp = path.with_name("." + path.name + ".side-a")
    temp.write_text(text)
    os.chmod(temp, mode)
    os.replace(temp, path)


def config(terminfo=None):
    """CONFIG for this Mac. Panes are tmux-256color, described by the app's own terminfo when it
    ships one (Contents/Resources/terminfo) or by the system's; with neither, screen-256color,
    which every macOS has."""
    entry = "74/tmux-256color"
    if terminfo and "'" not in str(terminfo) and (Path(terminfo) / entry).is_file():
        # The trailing colon keeps the system's own entries for every other terminal.
        return CONFIG + f"set-environment -g TERMINFO_DIRS '{terminfo}:'\n"
    if any((Path(folder) / entry).is_file() for folder in SYSTEM_TERMINFO):
        return CONFIG
    return CONFIG.replace('default-terminal "tmux-256color"', 'default-terminal "screen-256color"')


def install(root, bundled=None):
    """Writes the config and launcher, records which tmux to use, and reloads a running server.
    Without a usable tmux, tmux-path is removed and hosting stays off."""
    folder = runtime(root)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    (folder / "hosted").mkdir(exist_ok=True, mode=0o700)
    binary = find_tmux(bundled)
    # Contents/Helpers/tmux -> Contents/Resources/terminfo
    terminfo = Path(binary).parent.parent / "Resources/terminfo" if binary and binary == bundled else None
    write_private(folder / "tmux.conf", config(terminfo))
    write_private(folder / "sidea-tmux", LAUNCHER, 0o700)
    if not binary:
        (folder / "tmux-path").unlink(missing_ok=True)
        return {"tmux": None, "running": False}
    write_private(folder / "tmux-path", binary + "\n")
    command, env = server(binary)
    try:
        running = subprocess.run(command + ["source-file", str(folder / "tmux.conf")],
                                 capture_output=True, timeout=5, env=env).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        running = False
    return {"tmux": binary, "version": ".".join(map(str, version(binary) or ())), "running": running}


def server(binary):
    socket = os.environ.get("SIDE_A_TMUX_SOCKET")
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_TMPDIR")}
    # -u: without a UTF-8 locale tmux prints tabs and non-ASCII in formats as '_'.
    return [binary, "-u"] + (["-S", socket] if socket else ["-L", SOCKET]), env


def panes(root):
    """pane_pid -> tmux session name for every live pane on Side A's server; empty without one."""
    binary = tmux_path(root)
    if not binary:
        return {}
    command, env = server(binary)
    try:
        output = subprocess.run(command + ["list-panes", "-a", "-F", "#{pane_pid}\t#{pane_dead}\t#{session_name}"],
                                capture_output=True, text=True, timeout=1, env=env).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found = {}
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].isdigit() and parts[1] == "0":
            found[int(parts[0])] = parts[2]
    return found


def hosted_by(pid, parents, panes, steps=32):
    """(session name, steps) when a pane's process is pid or one of its ancestors, else None."""
    for step in range(steps):
        if pid in panes:
            return panes[pid], step
        pid = parents.get(pid, 1)
        if pid <= 1:
            return None
    return None


def match(sessions, parents, panes):
    """Sets `hosted` on each session row; when several reach one pane, the closest one keeps it."""
    best = {}
    for row in sessions:
        found = hosted_by(row["pid"], parents, panes)
        row["hosted"] = None
        if found and (found[0] not in best or found[1] < best[found[0]][1]):
            best[found[0]] = (row, found[1])
    for name, (row, _) in best.items():
        row["hosted"] = name
    return sessions
