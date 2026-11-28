"""Moving a session between computers: the files side (docs/moving-sessions-prd.md, sections 4.3 to 4.5).

A move carries two things as files. The workspace travels as git objects: HEAD, the index and the
working tree (untracked files included) are captured as two commits under a private ref without
touching the branch, the index or the stash, and sent as a bundle that leaves out what the other
computer already has. The conversation travels as the agent's own transcript files, unchanged.

Nothing here talks to the network or starts an agent. The app sends what `capture` and
`export_conversation` write, and calls `land` and `import_conversation` on the other side. A
repository state that cannot be restored byte for byte is refused by `inspect` before anything is
stopped, and `land` checks every byte it wrote against the manifest and removes its work when one
differs.
"""
from __future__ import annotations
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time

GIT_TIMEOUT = 120
REF = "refs/sidea/moves/{}/work"
WORKTREES = ".sidea-worktrees"
MAX_CHANGED = 5000
MAX_LOOSE_BYTES = 512 * 1024 * 1024
MAX_BUNDLE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENV_BYTES = 1024 * 1024
MAX_MEMBERS = 20000
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_SLUG = 200
CANDIDATES = 64
MOVE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{5,63}$")
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
SESSION = re.compile(r"^[0-9a-fA-F][0-9a-fA-F-]{7,63}$")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
IN_PROGRESS = (("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"),
               ("BISECT_LOG", "a bisect"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"))
EXECUTABLE_CONFIG = (".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".codex/hooks.json", ".codex/config.toml")


class Refused(ValueError):
    """A state Side A will not move, with the sentence the sheet shows."""


def git(*args, cwd, index=None, data=None, check=True, text=True):
    """Runs git with nothing inherited that could redirect it, no hooks, and no background work."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C",
                "GIT_AUTHOR_NAME": "Side A", "GIT_AUTHOR_EMAIL": "move@side-a.invalid",
                "GIT_COMMITTER_NAME": "Side A", "GIT_COMMITTER_EMAIL": "move@side-a.invalid"})
    if index:
        env["GIT_INDEX_FILE"] = str(index)
    run = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0",
                          "-c", "commit.gpgsign=false", "-c", "advice.addEmbeddedRepo=false", *args],
                         cwd=str(cwd), env=env, input=data, capture_output=True, timeout=GIT_TIMEOUT, text=text, check=False)
    if check and run.returncode:
        error = run.stderr if text else run.stderr.decode("utf-8", "replace")
        raise Refused(error.strip().splitlines()[-1] if error.strip() else f"git {args[0]} failed.")
    return run.stdout if check else (run.returncode, run.stdout)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def checked(pattern, value, what):
    if not isinstance(value, str) or not pattern.match(value):
        raise Refused(f"Not a valid {what}.")
    return value


# --- The workspace ---------------------------------------------------------------------------

def layout(folder):
    """Where the checkout `folder` is in lives: its top, its own git directory and the shared one."""
    folder = Path(folder)
    if not folder.is_dir():
        raise Refused(f"No such folder: {folder}")
    code, out = git("rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", cwd=folder, check=False)
    if code:
        raise Refused("This folder is not in a git repository. Side A moves sessions that work in one.")
    top, own, common = out.strip().split("\n")
    return {"top": Path(top), "git": Path(own), "common": Path(common)}


def with_index(place):
    """A copy of the index, so reading it as a tree never rewrites the real one (a plain write-tree
    updates the index's cache tree)."""
    handle, name = tempfile.mkstemp(prefix="sidea-move-index-")
    os.close(handle)
    source = place["git"] / "index"
    if source.exists():
        # With its time: git re-reads a file changed in the same second as the index was written, and tells
        # by the index's own timestamp. A copy stamped now would hide a same-size edit made just after a commit.
        shutil.copy2(source, name)
    else:
        os.unlink(name)
    return name


def trees(place):
    """HEAD, the index as a tree, and the working tree as a tree with untracked files in it."""
    top = place["top"]
    base = git("rev-parse", "--verify", "HEAD^{commit}", cwd=top).strip()
    index = with_index(place)
    try:
        staged = git("write-tree", cwd=top, index=index).strip()
        git("add", "-A", ".", cwd=top, index=index)
        work = git("write-tree", cwd=top, index=index).strip()
    finally:
        with contextlib.suppress(OSError):
            os.unlink(index)
    return base, staged, work


def filtered_paths(top):
    """Paths whose content a clean or smudge filter rewrites (Git LFS, git-crypt): their bytes on disk are
    not what git stores, and the other computer may not have the filter."""
    listing = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", cwd=top)
    if not listing:
        return []
    out = git("check-attr", "-z", "--stdin", "filter", cwd=top, data=listing)
    fields = out.split("\0")
    return [fields[i] for i in range(0, len(fields) - 2, 3) if fields[i + 2] not in ("unspecified", "unset")]


def problems(place):
    """Why this checkout cannot be captured exactly, as sentences. Empty when it can."""
    top, own = place["top"], place["git"]
    found = []
    if git("rev-parse", "--is-bare-repository", cwd=top).strip() == "true":
        return ["This is a bare repository."]
    if git("rev-parse", "--verify", "-q", "HEAD^{commit}", cwd=top, check=False)[0]:
        return ["This repository has no commits yet. Commit once, then move."]
    for name, what in IN_PROGRESS:
        if (own / name).exists():
            found.append(f"{what.capitalize()} is in progress here. Finish or abort it, then move.")
            break
    status = git("status", "--porcelain=v2", "-z", "--untracked-files=no", cwd=top).split("\0")
    if any(line.startswith("u ") for line in status):
        found.append("Some files have merge conflicts. Resolve them, then move.")
    if any(line.startswith("1 .A ") for line in status):
        found.append("A file was added with git add -N. Stage or remove it, then move.")
    staged = git("ls-files", "-s", "-z", cwd=top)
    if (top / ".gitmodules").exists() or any(entry.startswith("160000 ") for entry in staged.split("\0")):
        found.append("This repository has submodules, which Side A does not move yet.")
    flags = {line[:1] for line in git("ls-files", "-v", "-z", cwd=top).split("\0") if line}
    if flags & {"S", "s"} or git("config", "--get", "core.sparseCheckout", cwd=top, check=False)[1].strip() == "true":
        found.append("This checkout is sparse. Side A moves full checkouts only.")
    elif any(flag.islower() for flag in flags):
        found.append("Some files are marked assume-unchanged, so their changes would be lost.")
    filtered = filtered_paths(top)
    if filtered:
        found.append(f"{len(filtered)} files go through a git filter (such as Git LFS), which Side A does not move yet.")
    return found


def tree_entries(top, tree):
    """path -> (mode, type, object) for every entry of a tree."""
    entries = {}
    for line in git("ls-tree", "-r", "-z", tree, cwd=top).split("\0"):
        if line:
            meta, path = line.split("\t", 1)
            mode, kind, name = meta.split(" ")
            entries[path] = (mode, kind, name)
    return entries


def disk_entry(top, path):
    """What is on disk at `path`, as the manifest records it: a symlink's target or a file's raw bytes."""
    full = Path(top) / path
    if full.is_symlink():
        target = os.readlink(full)
        return {"path": path, "mode": "120000", "sha256": hashlib.sha256(os.fsencode(target)).hexdigest(), "size": len(os.fsencode(target))}
    if not full.is_file():
        return {"path": path, "missing": True}
    return {"path": path, "mode": "100755" if os.access(full, os.X_OK) else "100644", "sha256": sha256_file(full), "size": full.stat().st_size}


def changed_files(top, base, work):
    """Every path that differs between HEAD and the working tree, with what is on disk there now."""
    before, after = tree_entries(top, base), tree_entries(top, work)
    if any(kind == "commit" for _, kind, _ in after.values()):
        raise Refused("A folder inside this checkout is its own git repository. Side A does not move nested repositories.")
    paths = sorted(path for path in after if before.get(path) != after[path])
    deleted = sorted(path for path in before if path not in after)
    if len(paths) + len(deleted) > MAX_CHANGED:
        raise Refused(f"{len(paths) + len(deleted)} files differ from the last commit. Commit some of the work, then move.")
    if any("\n" in path for path in paths + deleted):
        raise Refused("A changed file has a line break in its name.")
    files = [disk_entry(top, path) for path in paths]
    if sum(entry.get("size", 0) for entry in files) > MAX_LOOSE_BYTES:
        raise Refused("The uncommitted files are larger than 512 MB. Commit or remove the large ones, then move.")
    return files, deleted, after


def converted(top, paths):
    """The paths git may rewrite on checkout: ones with a line-ending, encoding or ident attribute, or all
    of them when this repository converts line endings by configuration."""
    if git("config", "--get", "core.autocrlf", cwd=top, check=False)[1].strip() in ("true", "input"):
        return set(paths)
    if not paths:
        return set()
    out = git("check-attr", "-z", "--stdin", "text", "eol", "ident", "working-tree-encoding", cwd=top, data="\0".join(paths) + "\0")
    fields = out.split("\0")
    return {fields[i] for i in range(0, len(fields) - 2, 3) if fields[i + 2] not in ("unspecified", "unset")}


def lossy(top, files, after):
    """Changed files whose bytes on disk are not what a checkout of the captured tree writes (a line-ending
    rule that rewrites them, most often)."""
    regular = [entry for entry in files if not entry.get("missing") and entry["mode"] != "120000"]
    at_risk = converted(top, [entry["path"] for entry in regular])
    wrong = []
    for entry in regular:
        if entry["path"] in at_risk:
            body = git("cat-file", "--filters", f"--path={entry['path']}", after[entry["path"]][2], cwd=top, text=False)
            if hashlib.sha256(body).hexdigest() != entry["sha256"]:
                wrong.append(entry["path"])
    return wrong


def env_files(top):
    """Ignored .env files, the same ones a Side A worktree copies on one computer."""
    listing = git("ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", cwd=top)
    found = []
    for path in listing.split("\0"):
        full = Path(top) / path
        if path and not path.endswith("/") and Path(path).name.startswith(".env") and full.is_file() and not full.is_symlink() \
                and full.stat().st_size <= MAX_ENV_BYTES:
            found.append(path)
    return sorted(found)


def executable_config(top, base, work):
    """Agent configuration that runs commands and differs from the last commit: shown in the sheet."""
    before, after = tree_entries(top, base), tree_entries(top, work)
    return [path for path in EXECUTABLE_CONFIG if before.get(path) != after.get(path)]


def inspect(folder):
    """What a move of this folder would carry, and why it cannot when it cannot. Changes nothing."""
    try:
        place = layout(folder)
    except Refused as error:
        return {"refusals": [str(error)]}
    top = place["top"]
    refusals = problems(place)
    if refusals:
        return {"top": str(top), "refusals": refusals}
    try:
        base, staged, work = trees(place)
        files, deleted, after = changed_files(top, base, work)
        wrong = lossy(top, files, after)
    except Refused as error:
        return {"top": str(top), "refusals": [str(error)]}
    if wrong:
        refusals.append(f"{len(wrong)} changed files would arrive with different line endings ({wrong[0]}). Commit them, then move.")
    branch = git("symbolic-ref", "-q", "--short", "HEAD", cwd=top, check=False)[1].strip()
    return {"top": str(top), "refusals": refusals, "base": base, "index": staged, "work": work, "branch": branch or None,
            "changed": len(files), "deleted": len(deleted), "bytes": sum(entry.get("size", 0) for entry in files),
            "env": env_files(top), "config": executable_config(top, base, work), "candidates": candidates(top, base)}


def candidates(top, base):
    """Commits the other computer may already have, nearest first: what the bundle can leave out."""
    seen = git("rev-list", "--first-parent", f"--max-count={CANDIDATES}", base, cwd=top).split()
    for ref in ("@{upstream}", "refs/remotes/origin/HEAD"):
        code, out = git("rev-parse", "--verify", "-q", f"{ref}^{{commit}}", cwd=top, check=False)
        if not code and out.strip() not in seen:
            seen.append(out.strip())
    return seen


def known(folder, commits):
    """Which of `commits` this repository has."""
    top = layout(folder)["top"]
    have = []
    for commit in commits[:CANDIDATES * 2]:
        if re.fullmatch(r"[0-9a-f]{40,64}", commit or "") and not git("cat-file", "-e", f"{commit}^{{commit}}", cwd=top, check=False)[0]:
            have.append(commit)
    return {"have": have}


def find(root, commits, origin=None, folders=(), landing=None):
    """The repository on this computer a move should land beside: one that already has the work's newest
    commits, else one with the same origin. Looks at `folders`, at every folder a session here ran in, and
    at what earlier moves cloned under `landing`, so a session that comes a second time gets a worktree of
    the clone it left and not another clone."""
    import cleanup
    best = None
    landed = sorted(str(child) for child in Path(landing).iterdir() if child.is_dir()) if landing and Path(landing).is_dir() else []
    for repo in cleanup.repos(list(folders) + cleanup.session_cwds(root) + landed):
        try:
            place = layout(repo)
        except Refused:
            continue
        if place["common"].name != ".git":
            continue
        have = known(repo, list(commits))["have"]
        same = bool(origin) and git("config", "--get", "remote.origin.url", cwd=repo, check=False)[1].strip() == origin
        rank = (len(have), same)
        if (have or same) and (best is None or rank > best[0]):
            best = (rank, repo, have)
    return {"repo": best[1], "have": best[2]} if best else {"have": []}


def capture(folder, move, out, have=(), env=False):
    """Captures the checkout under a private ref and writes `workspace.bundle` (and `extras.tar` for
    ignored .env files when asked) into `out`. Returns the manifest the other computer verifies."""
    checked(MOVE_ID, move, "move id")
    place = layout(folder)
    top = place["top"]
    refusals = problems(place)
    if refusals:
        raise Refused(refusals[0])
    base, staged, work = trees(place)
    files, deleted, after = changed_files(top, base, work)
    wrong = lossy(top, files, after)
    if wrong:
        raise Refused(f"{len(wrong)} changed files would arrive with different line endings ({wrong[0]}). Commit them, then move.")
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    on_index = git("commit-tree", staged, "-p", base, "-m", f"Side A move {move}: index", cwd=top).strip()
    on_work = git("commit-tree", work, "-p", on_index, "-m", f"Side A move {move}: working tree", cwd=top).strip()
    ref = REF.format(move)
    git("update-ref", ref, on_work, cwd=top)
    present = known(top, list(have))["have"]
    bundle = out / "workspace.bundle"
    git("bundle", "create", "-q", str(bundle), ref, *[f"^{commit}" for commit in present], cwd=top)
    if bundle.stat().st_size > MAX_BUNDLE_BYTES:
        bundle.unlink()
        raise Refused("This repository's history is larger than 2 GB. Clone it on the other computer first, then move.")
    branch = git("symbolic-ref", "-q", "--short", "HEAD", cwd=top, check=False)[1].strip()
    origin = git("config", "--get", "remote.origin.url", cwd=top, check=False)[1].strip()
    inside = os.path.relpath(os.path.realpath(folder), os.path.realpath(top))
    manifest = {"move": move, "project": project_name(place), "base": base, "index": staged, "work": work, "commit": on_work,
                "branch": branch or None, "origin": origin or None, "inside": "" if inside == "." else inside,
                "files": files, "deleted": deleted, "config": executable_config(top, base, work),
                "bundle": {"sha256": sha256_file(bundle), "size": bundle.stat().st_size, "complete": not present}}
    if env:
        names = env_files(top)
        if names:
            extras = out / "extras.tar"
            with tarfile.open(extras, "w") as archive:
                for name in names:
                    archive.add(str(top / name), arcname=f"env/{name}", recursive=False)
            manifest["env"] = {"names": names, "sha256": sha256_file(extras), "size": extras.stat().st_size}
    return manifest


def project_name(place):
    name = place["common"].parent.name if place["common"].name == ".git" else place["top"].name
    return (re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "session")[:24].strip("-") or "session"


def release(folder, move):
    """Drops the private ref a capture made; its objects go with git's next cleanup."""
    checked(MOVE_ID, move, "move id")
    git("update-ref", "-d", REF.format(move), cwd=layout(folder)["top"], check=False)
    return {"released": True}


def verify_landing(tree, manifest):
    """Raises unless the checkout at `tree` is byte for byte what the manifest describes."""
    place = layout(tree)
    base, staged, work = trees(place)
    if (base, staged, work) != (manifest["base"], manifest["index"], manifest["work"]):
        raise Refused("The files that arrived are not the files that were sent.")
    for entry in manifest["files"]:
        if disk_entry(tree, entry["path"]) != entry:
            raise Refused(f"{entry['path']} arrived changed. This computer's git settings rewrite it.")
    for path in manifest["deleted"]:
        if os.path.lexists(os.path.join(tree, path)):
            raise Refused(f"{path} should have been deleted and was not.")


def land(bundle, manifest, name, repo=None, landing=None, extras=None):
    """Puts a captured workspace into a new checkout: a worktree of `repo` when this computer has the
    repository, a new clone under `landing` when it does not. Never touches an existing checkout's files."""
    checked(NAME, name, "session name")
    move = checked(MOVE_ID, manifest.get("move"), "move id")
    if sha256_file(bundle) != manifest["bundle"]["sha256"]:
        raise Refused("The workspace was damaged on the way.")
    ref, branch = REF.format(move), f"sidea/{name}"
    created = repo is None
    if created:
        if not manifest["bundle"].get("complete"):
            raise Refused("This computer no longer has the repository this move was prepared for.")
        home = Path(landing) / checked(NAME, manifest.get("project") or "session", "project name")
        if home.exists():
            home = Path(landing) / f"{manifest['project']}-{name}"[:63]
        if home.exists():
            raise Refused(f"{home} already exists.")
        home.mkdir(parents=True)
        tree, branch = home, manifest.get("branch") or "main"
        git("init", "-q", cwd=home)
        git("symbolic-ref", "HEAD", f"refs/heads/{branch}", cwd=home)
        if manifest.get("origin"):
            git("remote", "add", "origin", manifest["origin"], cwd=home)
    else:
        place = layout(repo)
        if place["common"].name != ".git":
            raise Refused("Side A makes worktrees only for repositories with a .git folder.")
        home = place["common"].parent
        tree = home / WORKTREES / name
        if tree.exists():
            raise Refused(f"{tree} already exists.")
    try:
        git("fetch", "-q", "--no-tags", str(bundle), f"+{ref}:{ref}", cwd=home)
        if git("rev-parse", ref, cwd=home).strip() != manifest["commit"]:
            raise Refused("The workspace that arrived is not the one that was sent.")
        if created:
            git("update-ref", f"refs/heads/{branch}", manifest["base"], cwd=home)
        else:
            git("worktree", "add", "--quiet", "--no-track", "-b", branch, str(tree), manifest["base"], cwd=home)
            exclude = place["common"] / "info" / "exclude"
            line = f"/{WORKTREES}/"
            if not exclude.exists() or line not in exclude.read_text(errors="replace").splitlines():
                exclude.parent.mkdir(exist_ok=True)
                with open(exclude, "a") as handle:
                    handle.write(line + "\n")
        git("read-tree", "-u", "--reset", manifest["commit"], cwd=tree)
        git("read-tree", f"{manifest['commit']}^", cwd=tree)
        verify_landing(tree, manifest)
        copied = land_env(tree, extras, manifest) if extras else []
    except BaseException:
        discard(home, name, move, created)
        raise
    inside = tree / str(manifest.get("inside") or "")
    return {"folder": str(inside if inside.is_dir() and within(inside, tree) else tree), "tree": str(tree), "repo": str(home), "branch": branch,
            "created": created, "env": copied}


def within(path, tree):
    """Whether `path`, links followed, is `tree` or inside it."""
    real, top = os.path.realpath(path), os.path.realpath(tree)
    return real == top or real.startswith(top + os.sep)


def land_env(tree, extras, manifest):
    """Writes the .env files that came along, never over one that is already there."""
    wanted = manifest.get("env") or {}
    if sha256_file(extras) != wanted.get("sha256"):
        raise Refused("The .env files were damaged on the way.")
    written = []
    with tarfile.open(extras, "r:") as archive:
        for member in safe_members(archive, ("env/",)):
            name = member.name[len("env/"):]
            target = Path(tree) / name
            if name not in wanted.get("names", []) or not Path(name).name.startswith(".env") or os.path.lexists(target):
                continue
            # The tree came from the other computer and may hold a symlink where a folder is expected:
            # the file is written only if its folder really is inside the tree.
            if not within(target.parent, tree):
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            write_private(target, archive.extractfile(member).read())
            written.append(name)
    return written


def discard(home, name, move, created=False):
    """Removes what `land` made, and only that: its worktree, its branch and its ref."""
    checked(NAME, name, "session name")
    home = Path(home)
    if created:
        if (home / ".git").is_dir():
            shutil.rmtree(home, ignore_errors=True)
        return {"discarded": True}
    tree = home / WORKTREES / name
    if tree.exists():
        git("worktree", "remove", "--force", str(tree), cwd=home, check=False)
    git("worktree", "prune", cwd=home, check=False)
    git("branch", "-D", f"sidea/{name}", cwd=home, check=False)
    git("update-ref", "-d", REF.format(move), cwd=home, check=False)
    return {"discarded": True}


# --- The conversation ------------------------------------------------------------------------

def write_private(path, data):
    temporary = f"{path}.sidea-{os.getpid()}"
    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as handle:
        handle.write(data)
    os.replace(temporary, path)


def claude_slug(folder):
    """The folder name Claude Code files a project's transcripts under."""
    slug = re.sub(r"[^a-zA-Z0-9]", "-", str(folder))
    if len(slug) > MAX_SLUG:
        raise Refused("This folder's path is too long for Side A to file its conversation.")
    return slug


def claude_files(projects, session, folder=None):
    """A Claude conversation's files as (member name, path): the transcript, the folder beside it that
    holds subagents and large tool results, and the project's memory."""
    projects = Path(projects)
    here = projects / claude_slug(folder) / f"{session}.jsonl" if folder else None
    if not here or not here.is_file():
        found = sorted(projects.glob(f"*/{session}.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not found:
            raise Refused("This conversation's transcript was not found.")
        here = found[0]
    members = [(f"transcript/{session}.jsonl", here)]
    for root, prefix in ((here.parent / session, f"transcript/{session}/"), (here.parent / "memory", "memory/")):
        for item in sorted(root.rglob("*")) if root.is_dir() else []:
            if item.is_file() and not item.is_symlink():
                members.append((prefix + item.relative_to(root).as_posix(), item))
    return members


def codex_rollouts(stores, session):
    return sorted(path for store in stores for path in Path(store).glob(f"**/rollout-*-{session}.jsonl") if path.is_file())


def codex_files(stores, session, depth=8):
    """A Codex thread's rollout files, with the rollouts it was forked or continued from: resume reads those too."""
    wanted, seen, members = [session], set(), []
    while wanted and len(seen) <= depth:
        current = wanted.pop(0)
        if current in seen:
            continue
        seen.add(current)
        for path in codex_rollouts(stores, current):
            store = next(Path(s) for s in stores if Path(s) in path.parents)
            members.append((f"rollouts/{path.relative_to(store).as_posix()}", path))
            with open(path, errors="replace") as handle:
                first = handle.readline()
            with contextlib.suppress(ValueError):
                payload = json.loads(first).get("payload") or {}
                for key, value in payload.items():
                    if key not in ("id", "session_id") and any(word in key for word in ("base", "fork", "parent")):
                        wanted += [other for other in UUID.findall(json.dumps(value)) if other not in seen]
    if not members:
        raise Refused("This conversation's rollout was not found.")
    return members


def export_conversation(agent, session, out, projects=None, stores=(), folder=None):
    """Writes `conversation.tar` into `out` and returns what is in it, with a hash for each file."""
    checked(SESSION, session, "session id")
    members = claude_files(projects, session, folder) if agent == "claude" else codex_files(list(stores), session)
    if len(members) > MAX_MEMBERS:
        raise Refused("This conversation has too many files to move.")
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    archive_path, listed = out / "conversation.tar", []
    with tarfile.open(archive_path, "w") as archive:
        for name, path in members:
            data = path.read_bytes()
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), 0o600, int(path.stat().st_mtime)
            archive.addfile(info, io.BytesIO(data))
            listed.append({"name": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
        archive_path.unlink()
        raise Refused("This conversation is larger than 2 GB.")
    return {"agent": agent, "session": session, "members": listed, "sha256": sha256_file(archive_path), "size": archive_path.stat().st_size}


def safe_members(archive, prefixes):
    """Regular files under the allowed prefixes, with no way out of the folder they are written into."""
    total = 0
    for count, member in enumerate(archive):
        parts = member.name.split("/")
        if count >= MAX_MEMBERS or not member.isfile() or member.name.startswith("/") or "\\" in member.name \
                or any(part in ("", ".", "..") for part in parts) or not member.name.startswith(prefixes):
            raise Refused("The archive that arrived holds something Side A does not accept.")
        total += member.size
        if total > MAX_ARCHIVE_BYTES:
            raise Refused("The archive that arrived is too large.")
        yield member


def continues(old, new):
    """Whether `new` is `old` with more appended: the one case where a transcript already here is replaced."""
    return len(new) >= len(old) and new[:len(old)] == old


def resumes(agent, session, member):
    """Whether an archive member is the file the CLI resumes `session` by: Claude's transcript, or the thread's own
    Codex rollout. Subagent transcripts, tool results, memory and the rollouts a thread continues are not."""
    if agent == "claude":
        return member == f"transcript/{session}.jsonl"
    return member.startswith("rollouts/") and member.endswith(f"-{session}.jsonl")


def import_conversation(agent, session, archive_path, expected, projects=None, store=None, folder=None, copy=False):
    """Files an exported conversation where this computer's CLI will find it for `folder`. A transcript
    that is already here is replaced only by one that continues it.

    A `copy` is filed only to be forked: nothing already here is replaced, and `resumable` lists the files it
    created that would let the CLI resume the original by its id, for the caller to remove once the fork has
    read them."""
    checked(SESSION, session, "session id")
    if sha256_file(archive_path) != expected.get("sha256"):
        raise Refused("The conversation was damaged on the way.")
    hashes = {entry["name"]: entry["sha256"] for entry in expected.get("members", [])}
    if agent == "claude":
        home = Path(projects) / claude_slug(folder)
        prefixes, targets = ("transcript/", "memory/"), {"transcript/": home, "memory/": home / "memory"}
        memory_free = not (home / "memory").is_dir() or not any((home / "memory").iterdir())
    else:
        prefixes, targets, memory_free = ("rollouts/",), {"rollouts/": Path(store)}, False
    planned, seen = [], set()
    with tarfile.open(archive_path, "r:") as archive:
        for member in safe_members(archive, prefixes):
            data = archive.extractfile(member).read()
            seen.add(member.name)
            if hashes.get(member.name) != hashlib.sha256(data).hexdigest():
                raise Refused("The conversation that arrived is not the one that was sent.")
            prefix = next(p for p in prefixes if member.name.startswith(p))
            rest = member.name[len(prefix):]
            if agent == "claude" and prefix == "transcript/" and rest.split("/")[0] not in (f"{session}.jsonl", session):
                raise Refused("The archive that arrived holds another conversation.")
            if agent == "codex" and not re.fullmatch(r"(\d{4}/\d{2}/\d{2}/)?rollout-[A-Za-z0-9T:.-]+\.jsonl", rest):
                raise Refused("The archive that arrived holds something Side A does not accept.")
            if prefix == "memory/" and not memory_free:
                continue
            target = targets[prefix] / rest
            if target.is_symlink() or (target.exists() and prefix != "memory/" and (copy or not continues(target.read_bytes(), data))):
                raise Refused("A different copy of this conversation is already on this computer.")
            planned.append((target, data, resumes(agent, session, member.name)))
    if seen != set(hashes):
        raise Refused("The conversation that arrived is not the one that was sent.")
    created = [str(target) for target, _, _ in planned if not target.exists()]
    for target, data, _ in planned:
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_private(target, data)
    answer = {"written": [str(target) for target, _, _ in planned], "created": created}
    if copy:
        answer["resumable"] = [str(target) for target, _, resumable in planned if resumable and str(target) in created]
    return answer


def forget(paths, roots):
    """Removes conversation files an import created, when the move that brought them was dropped. Only files
    under the CLI's own stores, so a wrong list cannot reach anything else."""
    removed = 0
    for path in paths:
        real = os.path.realpath(path)
        if any(real.startswith(os.path.realpath(root) + os.sep) for root in roots) and os.path.isfile(real):
            os.unlink(real)
            removed += 1
    return {"removed": removed}


def park(agent, session, away, projects=None, stores=()):
    """Moves a conversation's files out of the CLI's reach while the session is on another computer:
    `claude --resume` finds a transcript from any folder, so one left in place could be run twice."""
    checked(SESSION, session, "session id")
    away = Path(away) / session
    if agent == "claude":
        found = [(path, Path(projects)) for path in Path(projects).glob(f"*/{session}.jsonl")]
        found += [(path.parent / session, Path(projects)) for path, _ in list(found) if (path.parent / session).is_dir()]
    else:
        found = [(path, next(Path(s) for s in stores if Path(s) in path.parents)) for path in codex_rollouts(stores, session)]
    record = away / "parked.json"
    moved = json.loads(record.read_text()) if record.exists() else []
    away.mkdir(parents=True, exist_ok=True, mode=0o700)
    for path, store in found:
        slot = away / str(len(moved))
        shutil.move(str(path), str(slot))
        moved.append({"from": str(path), "slot": slot.name, "store": str(store), "at": int(time.time())})
        write_private(record, json.dumps(moved).encode())
    return {"parked": len(found)}


def unpark(session, away):
    """Puts a parked conversation back where it was. A file that has appeared there since is left alone."""
    checked(SESSION, session, "session id")
    away = Path(away) / session
    record = away / "parked.json"
    if not record.exists():
        return {"restored": 0, "kept": 0}
    restored = kept = 0
    for entry in json.loads(record.read_text()):
        slot, target = away / entry["slot"], Path(entry["from"])
        if not os.path.lexists(slot):
            continue
        if os.path.lexists(target):
            kept += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(slot), str(target))
        restored += 1
    if not kept:
        shutil.rmtree(away, ignore_errors=True)
    return {"restored": restored, "kept": kept}


def run(request):
    """One action from the app, as a dictionary in and a dictionary out. A refusal is an answer, not an error."""
    action = request.get("action")
    try:
        if action == "inspect":
            return inspect(request["folder"])
        if action == "known":
            return known(request["folder"], request.get("commits", []))
        if action == "find":
            return find(request["root"], request.get("commits", []), request.get("origin"), request.get("folders", ()),
                        request.get("landing"))
        if action == "forget":
            return forget(request.get("paths", []), request.get("roots", []))
        if action == "capture":
            return capture(request["folder"], request["move"], request["out"], request.get("have", ()), bool(request.get("env")))
        if action == "release":
            return release(request["folder"], request["move"])
        if action == "land":
            return land(request["bundle"], request["manifest"], request["name"], request.get("repo"), request.get("landing"), request.get("extras"))
        if action == "discard":
            return discard(request["repo"], request["name"], request["move"], bool(request.get("created")))
        if action == "export":
            return export_conversation(request["agent"], request["session"], request["out"], request.get("projects"),
                                       request.get("stores", ()), request.get("folder"))
        if action == "import":
            return import_conversation(request["agent"], request["session"], request["archive"], request["expected"],
                                       request.get("projects"), request.get("store"), request.get("folder"), bool(request.get("copy")))
        if action == "park":
            return park(request["agent"], request["session"], request["away"], request.get("projects"), request.get("stores", ()))
        if action == "unpark":
            return unpark(request["session"], request["away"])
    except Refused as error:
        return {"refused": str(error)}
    except (subprocess.TimeoutExpired, OSError, tarfile.TarError, KeyError) as error:
        return {"refused": f"The move could not be prepared: {error}"}
    raise ValueError(f"Unknown move action: {action}")
