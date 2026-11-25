"""The places the bridge's behaviour depends on the operating system, in one module so the rest stays the same on every
host (docs/ports/windows-linux-prd.md). It is not called `platform.py`: a module of that name next to the scripts would
shadow the standard library's `platform` for every import that follows.

Only what hosting needs so far is here. The Keychain, `~/.zshrc` and process-table calls are still in their own files and
move in here as the Linux daemon needs them."""
import os
import shutil
import sys

DARWIN = sys.platform == "darwin"
LINUX = sys.platform.startswith("linux")


def login_shell():
    """The shell a hosted pane starts: zsh on a Mac, the user's own on Linux, never one that isn't installed."""
    if DARWIN:
        return "/bin/zsh"
    for candidate in (os.environ.get("SHELL"), "/bin/bash", "/bin/sh"):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return "/bin/sh"


def tmux_candidates():
    """Where a tmux is looked for besides the app's own build."""
    if DARWIN:
        return ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
    return [path for path in (os.environ.get("SIDEAD_TMUX"), shutil.which("tmux"), "/usr/bin/tmux", "/usr/local/bin/tmux") if path]


def copy_command():
    """What tmux pipes a selection to; a Linux host has no one clipboard command, so none is set."""
    return "pbcopy" if DARWIN else None


def has_launcher():
    """Whether `runtime/sidea-tmux`, the zsh launcher shell lines attach through, is written. The daemon starts hosted
    sessions itself, so a Linux host has no use for it."""
    return DARWIN


def system_terminfo():
    return ["/usr/share/terminfo"] if DARWIN else ["/usr/share/terminfo", "/lib/terminfo", "/etc/terminfo"]


def claude_dirs():
    """Every folder a Claude Code process may keep its sessions and transcripts in. A Mac has one, `~/.claude` (its other
    accounts move only the login). The Linux daemon runs each account with its own `CLAUDE_CONFIG_DIR`, so it lists those in
    the JSON file `SIDEAD_CLAUDE_DIRS_FILE` names, and they are read as well."""
    import json
    from pathlib import Path
    folders = [Path.home() / ".claude"]
    path = os.environ.get("SIDEAD_CLAUDE_DIRS_FILE")
    if path:
        try:
            for entry in json.loads(Path(path).read_text()):
                if not isinstance(entry, str):
                    continue
                folder = Path(entry)
                if folder.is_absolute() and folder not in folders:
                    folders.append(folder)
        except (OSError, ValueError):
            pass
    return folders
