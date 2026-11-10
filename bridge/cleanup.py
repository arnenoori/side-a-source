"""Disk and worktree cleanup for Side A.

Old transcripts are moved, never deleted, into `<root>/archive/` under their path relative to
the home folder, so restoring is moving them back. Pinned and running sessions stay put.
Worktrees are removed only through `git worktree remove` without --force, so git itself
refuses one with changes or untracked files. Side A also refuses one a process is working in,
one whose commit no branch, tag or remote has, and one holding ignored files such as .env that
a build can't bring back.
"""
from __future__ import annotations
import os
from pathlib import Path
import shutil
import subprocess
import time

DAYS = 90
MAX_REPOS = 50
MAX_CWDS = 400
GIT_TIMEOUT = 10
STALE_AFTER = 7 * 86400
# Ignored folders a build or install brings back; anything else ignored (.env, local data) blocks removal.
REGENERABLE = {"node_modules", ".build", "build", "dist", ".venv", "__pycache__", ".next", "target", "DerivedData",
               ".cache", ".DS_Store"}


def stores(root=None):
    """Where transcripts live: Claude's projects, and every Codex sessions folder the session index reads."""
    import sessions
    return (("claude", Path.home() / ".claude" / "projects"),) + tuple(("codex", folder) for folder in sessions.codex_session_folders(root))


def archive_dir(root):
    return Path(root) / "archive"


# Codex profiles' shared history lives in Side A's own folder, which need not be under the home folder.
OWN = ".side-a-root"


def archived_path(root, item):
    try:
        relative = item.relative_to(Path.home())
    except ValueError:
        relative = Path(OWN) / item.relative_to(root)
    return archive_dir(root) / relative


def original_path(root, item):
    relative = item.relative_to(archive_dir(root))
    return Path(root).joinpath(*relative.parts[1:]) if relative.parts[0] == OWN else Path.home() / relative


def size_of(path):
    if path.is_file():
        return path.stat().st_size
    total = 0
    for item in path.rglob("*") if path.is_dir() else []:
        try:
            total += item.stat().st_size if item.is_file() else 0
        except OSError:
            continue
    return total


def running_ids():
    """Session ids of Claude Code processes still alive, from its registry."""
    import sessions
    return {data["sessionId"] for data, _ in sessions.running_claude() if isinstance(data.get("sessionId"), str)}


def transcripts(root=None):
    """Each conversation as (agent, transcript, companion folder or None, session id)."""
    for agent, folder in stores(root):
        if not folder.is_dir():
            continue
        if agent == "claude":
            for path in folder.glob("*/*.jsonl"):
                companion = path.with_suffix("")
                yield agent, path, companion if companion.is_dir() else None, path.stem
        else:
            for path in folder.glob("**/rollout-*.jsonl"):
                yield agent, path, None, path.stem


def kept(session_id, skip):
    # A Codex file is named rollout-<time>-<id>, so its id is the end of the name.
    return session_id in skip or any(session_id.endswith("-" + item) for item in skip)


def old_conversations(root, days=DAYS, keep=()):
    cutoff = time.time() - float(days) * 86400
    skip = set(keep) | running_ids()
    for agent, path, companion, session_id in transcripts(root):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if mtime >= cutoff or kept(session_id, skip):
            continue
        yield agent, path, companion, size_of(path) + (size_of(companion) if companion else 0)


def project_paths(root):
    """Claude's project folder name to the cwd its sessions ran in, from the sessions index."""
    import sessions
    try:
        db = sessions.connect(root)
        rows = db.execute("SELECT path, cwd FROM sessions WHERE agent='claude' AND cwd IS NOT NULL").fetchall()
        db.close()
    except Exception:
        return {}
    return {Path(path).parent.name: cwd for path, cwd in rows if path}


def disk(root, days=DAYS, keep=()):
    names = project_paths(root)
    projects = []
    totals = {"claude": 0, "codex": 0}
    for agent, folder in stores(root):
        if not folder.is_dir():
            continue
        if agent == "codex":
            totals[agent] += size_of(folder)
            continue
        for project in folder.iterdir():
            if not project.is_dir():
                continue
            bytes_ = size_of(project)
            totals[agent] += bytes_
            projects.append({"folder": project.name, "path": names.get(project.name), "bytes": bytes_,
                             "conversations": sum(1 for _ in project.glob("*.jsonl"))})
    projects.sort(key=lambda item: -item["bytes"])
    old = list(old_conversations(root, days, keep))
    archived = [p for p in archive_dir(root).rglob("*.jsonl") if "subagents" not in p.parts] if archive_dir(root).is_dir() else []
    conversations = sum(item["conversations"] for item in projects) + sum(1 for agent, *_ in transcripts(root) if agent == "codex")
    return {"total": sum(totals.values()), "claude": totals["claude"], "codex": totals["codex"], "projects": projects[:30],
            "conversations": conversations,
            "old": {"days": days, "count": len(old), "bytes": sum(item[3] for item in old)},
            "archived": {"count": len(archived), "bytes": size_of(archive_dir(root))}}


def reindex(root, paths):
    """Points the sessions index at moved files: missing ones drop out, returned ones are read again."""
    import sessions
    for _ in range(10):
        result = sessions.index(root, 20, [str(p) for p in paths])
        if result.get("remaining", 0) >= 0:
            return True
        time.sleep(1)  # the background indexer holds the lock for a few seconds
    return False


def jsonl_in(path):
    return [path] if path.is_file() else list(path.rglob("*.jsonl"))


def archive(root, days=DAYS, keep=()):
    """Moves each old transcript, then its companion folder; only what actually moved is counted.
    A destination that already exists is left alone, and the index is updated even when a move fails."""
    moved, freed, gone, errors = [], 0, [], []

    def move(item):
        destination = archived_path(root, item)
        if destination.exists():
            return None
        files, bytes_ = jsonl_in(item), size_of(item)
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(item), str(destination))
        except OSError as error:
            errors.append(f"{item.name}: {error.strerror or error}")
            return None
        gone.extend(files)
        return bytes_

    reindexed = True
    try:
        for agent, path, companion, _ in list(old_conversations(root, days, keep)):
            bytes_ = move(path)
            if bytes_ is None:
                continue
            if companion:
                bytes_ += move(companion) or 0
            moved.append({"agent": agent, "path": str(path), "bytes": bytes_})
            freed += bytes_
    finally:
        if gone:
            reindexed = reindex(root, gone)
    return {"moved": moved, "bytes": freed, "reindexed": reindexed, "errors": errors}


def restore(root):
    source = archive_dir(root)
    restored, skipped, back = [], [], []
    if not source.is_dir():
        return {"restored": [], "skipped": [], "reindexed": True}
    # Transcripts and their companion folders move back as the units archive() moved.
    units = []
    for agent, folder in stores(root):
        base = archived_path(root, folder)
        if not base.is_dir():
            continue
        if agent == "claude":
            units += list(base.glob("*/*.jsonl")) + [p for p in base.glob("*/*") if p.is_dir()]
        else:
            units += list(base.glob("**/rollout-*.jsonl"))
    for item in units:
        destination = original_path(root, item)
        if destination.exists():
            skipped.append(str(destination))
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(item), str(destination))
        back += jsonl_in(destination)
        if destination.suffix == ".jsonl":
            restored.append(str(destination))
    for folder in sorted((p for p in source.rglob("*") if p.is_dir()), key=lambda p: -len(p.parts)):
        try:
            folder.rmdir()
        except OSError:
            pass
    return {"restored": restored, "skipped": skipped, "reindexed": reindex(root, back) if back else True}


def git(*args, cwd=None):
    """Runs git read-only by default: no optional locks, so listing never blocks a running session's git."""
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"}
    try:
        done = subprocess.run(["git", *(["-C", str(cwd)] if cwd else []), *args], capture_output=True, text=True,
                              timeout=GIT_TIMEOUT, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, "", str(error)
    return done.returncode, done.stdout.strip(), done.stderr.strip()


def session_cwds(root):
    import sessions
    try:
        db = sessions.connect(root)
        rows = db.execute("SELECT cwd FROM sessions WHERE cwd IS NOT NULL GROUP BY cwd ORDER BY max(last_ts) DESC LIMIT ?",
                          (MAX_CWDS,)).fetchall()
        db.close()
    except Exception:
        return []
    return [row[0] for row in rows]


def repos(cwds):
    """Each repository's main worktree once, however many of its folders and worktrees sessions ran in."""
    found, seen = [], set()
    for cwd in cwds:
        if len(found) >= MAX_REPOS:
            break
        if not os.path.isdir(cwd) or any(cwd == s or cwd.startswith(s + "/") for s in seen):
            continue
        code, common, _ = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
        if code != 0 or not common:
            continue
        code, top, _ = git("rev-parse", "--show-toplevel", cwd=cwd)
        if code == 0:
            seen.add(top)
        if common in seen:
            continue
        seen.add(common)
        main = str(Path(common).parent) if Path(common).name == ".git" else common
        found.append(main)
    return found


def parse_worktrees(text):
    entries, entry = [], {}
    for line in text.splitlines() + [""]:
        if not line:
            if entry:
                entries.append(entry)
            entry = {}
            continue
        key, _, value = line.partition(" ")
        entry[key] = value or True
    return entries


def default_branch(repo):
    code, ref, _ = git("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", cwd=repo)
    if code == 0 and ref:
        return ref
    for name in ("main", "master"):
        if git("rev-parse", "--verify", "--quiet", f"refs/heads/{name}", cwd=repo)[0] == 0:
            return name
    return None


def cwds_in_use():
    """Real paths of every process's working folder, from one lsof call plus Claude Code's registry;
    None when lsof fails, so callers refuse rather than guess."""
    try:
        done = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fpn"], capture_output=True, text=True, timeout=GIT_TIMEOUT,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not done.stdout:
        return None
    found, pid = set(), None
    for line in done.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:]) if line[1:].isdigit() else None
        elif line.startswith("n") and pid not in (None, os.getpid()):
            found.add(os.path.realpath(line[1:]))
    import sessions
    for data, _ in sessions.running_claude():
        if isinstance(data.get("cwd"), str):
            found.add(os.path.realpath(data["cwd"]))
    return found


def in_use(path, cwds):
    if cwds is None:
        return None
    path = os.path.realpath(path)
    return any(cwd == path or cwd.startswith(path + "/") for cwd in cwds)


def reachable(path):
    """Whether HEAD is on a branch, tag or remote ref; a detached commit nothing points at goes with the worktree."""
    code, refs, _ = git("for-each-ref", "--count=1", "--contains", "HEAD", "--format=%(refname)",
                        "refs/heads", "refs/tags", "refs/remotes", cwd=path)
    return bool(refs) if code == 0 else None


def ignored(path):
    """Ignored files `git worktree remove` would delete, as (kept, regenerable folder names); None when git fails."""
    code, listing, _ = git("ls-files", "-oi", "--exclude-standard", "--directory", cwd=path)
    if code != 0:
        return None
    entries = [line for line in listing.splitlines() if line]
    # git also lists a folder whose only contents are ignored folders.
    entries = [e for e in entries if not (e.endswith("/") and any(o != e and o.startswith(e) for o in entries))]
    kept, regenerable = [], []
    for entry in entries:
        name = next((part for part in entry.rstrip("/").split("/") if part in REGENERABLE), None)
        if not name:
            kept.append(entry.rstrip("/"))
        elif name not in regenerable:
            regenerable.append(name)
    return kept, regenerable


def refusal(path, cwds):
    """Why Side A won't remove this worktree although git would, or None."""
    busy = in_use(path, cwds)
    if busy is None:
        return "Could not check whether a session is working here."
    if busy:
        return "A session is working here."
    on_ref = reachable(path)
    if on_ref is None:
        return "Could not check whether its commit is on a branch."
    if not on_ref:
        return "Its commit is on no branch or tag, so removing it would lose that work."
    found = ignored(path)
    if found is None:
        return "Could not list its ignored files."
    if found[0]:
        names = ", ".join(found[0][:3]) + (f" and {len(found[0]) - 3} more" if len(found[0]) > 3 else "")
        return f"Has ignored files git would delete: {names}."
    return None


def touched(path):
    """When the worktree was last used: a checkout, a staged change or the folder itself changing."""
    code, gitdir, _ = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=path)
    stamps = []
    for candidate in [Path(path)] + ([Path(gitdir) / name for name in ("index", "HEAD", "logs/HEAD")] if code == 0 else []):
        try:
            stamps.append(candidate.stat().st_mtime)
        except OSError:
            continue
    return max(stamps, default=None)


def own_commits(repo, branch, head):
    """Commits on the branch since it was created, from its reflog; None without one."""
    if not branch or not head:
        return None
    code, log, _ = git("reflog", "show", "--format=%H", f"refs/heads/{branch}", cwd=repo)
    if code != 0 or not log:
        return None
    code, count, _ = git("rev-list", "--count", f"{log.splitlines()[-1]}..{head}", cwd=repo)
    return int(count) if code == 0 and count.isdigit() else None


def worktree_info(repo, entry, base, now, cwds=None):
    path = entry["worktree"]
    branch = entry.get("branch")
    info = {"repo": repo, "path": path, "branch": branch.removeprefix("refs/heads/") if isinstance(branch, str) else None,
            "head": entry.get("HEAD"), "locked": "locked" in entry, "missing": not os.path.isdir(path),
            "dirty": None, "merged": None, "age": None, "base": base, "inUse": None, "refused": None, "regenerable": []}
    if info["missing"]:
        return info
    code, stamp, _ = git("log", "-1", "--format=%ct", cwd=path)
    stamps = [t for t in (int(stamp) if code == 0 and stamp.isdigit() else None, touched(path)) if t is not None]
    if stamps:
        info["age"] = now - max(stamps)
    code, status, _ = git("status", "--porcelain", cwd=path)
    info["dirty"] = bool(status) if code == 0 else None
    if base and info["head"]:
        code, _, _ = git("merge-base", "--is-ancestor", info["head"], base, cwd=repo)
        # A worktree just made from the base is "in" it too, so that alone isn't merged.
        if code in (0, 1):
            fresh = (own_commits(repo, info["branch"], info["head"]) or 0) < 1
            info["merged"] = code == 0 and (not fresh or (info["age"] or 0) >= STALE_AFTER)
    info["inUse"] = in_use(path, cwds)
    info["refused"] = refusal(path, cwds)
    found = ignored(path)
    info["regenerable"] = found[1] if found else []
    return info


def worktrees(root):
    now = time.time()
    found = []
    busy = cwds_in_use()
    for repo in repos(session_cwds(root)):
        code, listing, _ = git("worktree", "list", "--porcelain", cwd=repo)
        if code != 0:
            continue
        entries = [e for e in parse_worktrees(listing) if "worktree" in e and "bare" not in e]
        if len(entries) < 2:
            continue
        base = default_branch(repo)
        found += [worktree_info(repo, entry, base, now, busy) for entry in entries[1:]]
    return {"worktrees": found}


def remove_worktree(path):
    """Removes one linked worktree that has no changes. Never forces, never the main worktree, and checks
    again what the listing showed, since a session may have started in it since."""
    path = str(Path(path).expanduser())
    if not os.path.isdir(path):
        return {"removed": False, "error": "That folder no longer exists."}
    code, common, error = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=path)
    if code != 0:
        return {"removed": False, "error": error or "Not a git worktree."}
    code, own, _ = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=path)
    if own == common:
        return {"removed": False, "error": "That is the repository's main worktree."}
    code, status, error = git("status", "--porcelain", cwd=path)
    if code != 0 or status:
        return {"removed": False, "error": error or "The worktree has changes or untracked files."}
    reason = refusal(path, cwds_in_use())
    if reason:
        return {"removed": False, "error": reason}
    main = str(Path(common).parent) if Path(common).name == ".git" else common
    code, _, error = git("worktree", "remove", path, cwd=main)
    return {"removed": code == 0, "error": None if code == 0 else error}
