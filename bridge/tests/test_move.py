import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import move

SESSION = "a06442e2-3f6b-4a35-931a-a4599bfa8acd"
PARENT = "01a215c0-4e5f-7413-956c-ec930a79fa5a"


def git(cwd, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_AUTHOR_NAME": "you", "GIT_AUTHOR_EMAIL": "you@example.com", "GIT_COMMITTER_NAME": "you",
                "GIT_COMMITTER_EMAIL": "you@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})
    return subprocess.run(["git", *args], cwd=str(cwd), env=env, capture_output=True, text=True, check=True).stdout


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def fingerprint(top):
    """Status, index tree, and the mode and bytes of every file git does not ignore."""
    top = Path(top)
    lines = [git(top, "status", "--porcelain=v1", "-uall")]
    names = git(top, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    for name in sorted(set(filter(None, names))):
        path = top / name
        if path.is_symlink():
            lines.append(f"L {os.readlink(path)} {name}")
        elif path.is_file():
            lines.append(f"{os.access(path, os.X_OK)} {hashlib.sha256(path.read_bytes()).hexdigest()} {name}")
    return lines


class Repos(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(os.path.realpath(self.temp.name))
        self.source = self.base / "source" / "app"
        self.out = self.base / "out"
        self.source.mkdir(parents=True)
        git(self.source, "init", "-q", "-b", "main")
        for name, data in (("staged.txt", "one\n"), ("both.txt", "one\n"), ("gone-staged.txt", "x\n"), ("gone.txt", "x\n"),
                           ("run.sh", "#!/bin/sh\n"), ("old-name.txt", "a\n"), ("blob.bin", b"bin\0ary\n"),
                           (".gitignore", "*.log\nbuild/\n.env*\n"), ("pkg/deep.txt", "deep\n")):
            write(self.source / name, data)
        git(self.source, "add", "-A")
        git(self.source, "commit", "-qm", "base")

    def tearDown(self):
        self.temp.cleanup()

    def dirty(self):
        source = self.source
        write(source / "staged.txt", "two\n")
        write(source / "both.txt", "two\n")
        git(source, "add", "staged.txt", "both.txt")
        write(source / "both.txt", "three\n")
        git(source, "rm", "-q", "gone-staged.txt")
        (source / "gone.txt").unlink()
        os.chmod(source / "run.sh", 0o700)
        git(source, "mv", "old-name.txt", "new-name.txt")
        write(source / "added.txt", "new staged\n")
        git(source, "add", "added.txt")
        write(source / "sub dir/untracked file.txt", "untracked\n")
        os.symlink("staged.txt", source / "link")
        write(source / "crlf.txt", "a\r\nb\r\n")
        write(source / "ünïcode.txt", "unicode\n")
        write(source / "empty.txt", "")
        write(source / "build/out.o", "junk")
        write(source / "x.log", "log")
        write(source / ".env", "SECRET=1\n")
        write(source / "pkg/.env.local", "LOCAL=1\n")

    def clone(self):
        """A second checkout that has the base commit and nothing else, as the other computer would."""
        other = self.base / "other" / "app"
        other.parent.mkdir(parents=True)
        git(self.base, "clone", "-q", str(self.source), str(other))
        return other


class WorkspaceTests(Repos):
    def test_every_kind_of_uncommitted_change_lands_byte_for_byte_in_a_new_worktree(self):
        other = self.clone()
        self.dirty()
        index_before = (self.source / ".git/index").read_bytes()
        report = move.inspect(self.source)
        self.assertEqual(report["refusals"], [])
        self.assertEqual(report["env"], [".env", "pkg/.env.local"])
        have = move.known(other, report["candidates"])["have"]
        self.assertEqual(have, [report["base"]])

        manifest = move.capture(self.source / "pkg", "move-0001", self.out, have, env=True)
        self.assertEqual((self.source / ".git/index").read_bytes(), index_before)
        self.assertEqual(git(self.source, "stash", "list"), "")
        self.assertEqual(git(self.source, "rev-parse", "--abbrev-ref", "HEAD").strip(), "main")
        self.assertFalse(manifest["bundle"]["complete"])
        self.assertEqual(manifest["inside"], "pkg")
        self.assertIn("gone.txt", manifest["deleted"])
        json.dumps(manifest)

        landed = move.land(self.out / "workspace.bundle", manifest, "sa-app-1a2b", repo=other, extras=self.out / "extras.tar")
        tree = Path(landed["tree"])
        self.assertEqual(tree, other / ".sidea-worktrees/sa-app-1a2b")
        self.assertEqual(landed["folder"], str(tree / "pkg"))
        self.assertEqual(landed["branch"], "sidea/sa-app-1a2b")
        self.assertEqual(sorted(landed["env"]), [".env", "pkg/.env.local"])
        self.assertEqual((tree / ".env").read_text(), "SECRET=1\n")
        self.assertEqual(fingerprint(tree), fingerprint(self.source))
        self.assertFalse((tree / "build").exists())
        self.assertFalse((tree / "x.log").exists())
        # The other computer's own checkout is exactly as it was.
        self.assertEqual(git(other, "status", "--porcelain"), "")
        self.assertEqual(git(other, "rev-parse", "--abbrev-ref", "HEAD").strip(), "main")

        move.release(self.source, "move-0001")
        self.assertEqual(git(self.source, "for-each-ref", "refs/sidea"), "")

    def test_a_computer_without_the_repository_gets_a_clone_on_the_same_branch(self):
        git(self.source, "remote", "add", "origin", "https://example.com/you/app.git")
        self.dirty()
        manifest = move.capture(self.source, "move-0002", self.out)
        self.assertTrue(manifest["bundle"]["complete"])
        landing = self.base / "landing"
        landed = move.land(self.out / "workspace.bundle", manifest, "sa-app-9f9f", landing=landing)
        self.assertTrue(landed["created"])
        self.assertEqual(landed["folder"], str(landing / "app"))
        self.assertEqual(fingerprint(landed["folder"]), fingerprint(self.source))
        self.assertEqual(git(landed["folder"], "rev-parse", "--abbrev-ref", "HEAD").strip(), "main")
        self.assertEqual(git(landed["folder"], "remote", "get-url", "origin").strip(), "https://example.com/you/app.git")
        self.assertEqual(git(landed["folder"], "log", "--oneline").count("\n"), 1)

    def test_an_edit_of_the_same_size_made_right_after_a_commit_is_captured(self):
        for attempt in range(5):
            write(self.source / "staged.txt", f"n{attempt}\n")
            git(self.source, "commit", "-qam", f"commit {attempt}")
            write(self.source / "staged.txt", f"m{attempt}\n")
            manifest = move.capture(self.source, f"move-racy-{attempt}", self.out)
            self.assertEqual([entry["path"] for entry in manifest["files"]], ["staged.txt"], attempt)

    def test_a_clean_checkout_moves_and_a_second_move_gets_another_worktree(self):
        other = self.clone()
        manifest = move.capture(self.source, "move-0003", self.out)
        self.assertEqual(manifest["files"], [])
        first = move.land(self.out / "workspace.bundle", manifest, "sa-app-0001", repo=other)
        second = move.land(self.out / "workspace.bundle", manifest, "sa-app-0002", repo=other)
        self.assertNotEqual(first["tree"], second["tree"])
        self.assertEqual(move.run({"action": "land", "bundle": str(self.out / "workspace.bundle"), "manifest": manifest,
                                   "name": "sa-app-0001", "repo": str(other)})["refused"],
                         f"{other / '.sidea-worktrees/sa-app-0001'} already exists.")

    def test_states_that_cannot_be_restored_exactly_are_refused_before_anything_is_written(self):
        cases = {}
        write(self.source / ".git/MERGE_HEAD", git(self.source, "rev-parse", "HEAD"))
        cases["merge"] = move.inspect(self.source)["refusals"]
        (self.source / ".git/MERGE_HEAD").unlink()
        write(self.source / "later.txt", "x")
        git(self.source, "add", "-N", "later.txt")
        cases["intent"] = move.inspect(self.source)["refusals"]
        git(self.source, "reset", "-q")
        (self.source / "later.txt").unlink()
        git(self.source, "update-index", "--assume-unchanged", "staged.txt")
        cases["assumed"] = move.inspect(self.source)["refusals"]
        git(self.source, "update-index", "--no-assume-unchanged", "staged.txt")
        write(self.source / ".gitattributes", "*.bin filter=lfs\n")
        cases["filter"] = move.inspect(self.source)["refusals"]
        (self.source / ".gitattributes").unlink()
        nested = self.source / "vendor/lib"
        nested.mkdir(parents=True)
        git(nested, "init", "-q")
        write(nested / "f", "x")
        git(nested, "add", "-A")
        git(nested, "commit", "-qm", "inner")
        cases["nested"] = move.inspect(self.source)["refusals"]
        self.assertIn("merge", cases["merge"][0])
        self.assertIn("git add -N", cases["intent"][0])
        self.assertIn("assume-unchanged", cases["assumed"][0])
        self.assertIn("git filter", cases["filter"][0])
        self.assertIn("nested repositories", cases["nested"][0])
        self.assertEqual(move.run({"action": "capture", "folder": str(self.source), "move": "move-0004", "out": str(self.out)})["refused"],
                         cases["nested"][0])
        self.assertFalse(self.out.exists())
        self.assertEqual(git(self.source, "for-each-ref", "refs/sidea"), "")
        self.assertIn("not in a git repository", move.inspect(self.base)["refusals"][0])

    def test_a_file_a_line_ending_rule_would_rewrite_is_refused(self):
        write(self.source / ".gitattributes", "f.txt text eol=crlf\n")
        write(self.source / "f.txt", "a\n")
        git(self.source, "add", "-A")
        git(self.source, "commit", "-qm", "attributes")
        write(self.source / "f.txt", "a\nb\n")
        self.assertIn("different line endings (f.txt)", move.inspect(self.source)["refusals"][0])
        write(self.source / "f.txt", "a\r\nb\r\n")
        self.assertEqual(move.inspect(self.source)["refusals"], [])

    def test_a_damaged_or_swapped_workspace_is_refused_and_leaves_nothing_behind(self):
        other = self.clone()
        self.dirty()
        manifest = move.capture(self.source, "move-0005", self.out)
        bundle = self.out / "workspace.bundle"
        with self.assertRaises(move.Refused):
            move.land(bundle, dict(manifest, bundle=dict(manifest["bundle"], sha256="0" * 64)), "sa-app-0001", repo=other)
        wrong = json.loads(json.dumps(manifest))
        wrong["files"][0]["sha256"] = "0" * 64
        with self.assertRaises(move.Refused):
            move.land(bundle, wrong, "sa-app-0001", repo=other)
        self.assertFalse((other / ".sidea-worktrees/sa-app-0001").exists())
        self.assertEqual(git(other, "branch", "--list", "sidea/*"), "")
        self.assertEqual(git(other, "worktree", "list").count("\n"), 1)
        with self.assertRaises(move.Refused):
            move.land(bundle, manifest, "../escape", repo=other)

    def test_the_repository_to_land_beside_is_the_one_with_the_work_or_the_same_origin(self):
        other = self.clone()
        unrelated = self.base / "unrelated"
        unrelated.mkdir()
        git(unrelated, "init", "-q")
        report = move.inspect(self.source)
        root = self.base / "Side A"
        found = move.find(root, report["candidates"], folders=[str(unrelated), str(other / "pkg")])
        self.assertEqual(found, {"repo": str(other), "have": [report["base"]]})
        self.assertEqual(move.find(root, ["0" * 40], folders=[str(other)]), {"have": []})
        self.assertEqual(move.find(root, ["0" * 40], origin=str(self.source), folders=[str(other)])["repo"], str(other))
        # A clone an earlier move left under the landing folder is found with no session running in it.
        landing = self.base / "landing"
        landing.mkdir()
        (landing / "notes.txt").write_text("not a folder")
        self.assertEqual(move.find(root, report["candidates"], landing=str(landing)), {"have": []})
        subprocess.run(["git", "clone", "-q", str(self.source), str(landing / "app")], check=True)
        self.assertEqual(move.find(root, report["candidates"], landing=str(landing))["repo"], str(landing / "app"))
        self.assertEqual(move.find(root, report["candidates"], landing=str(self.base / "missing")), {"have": []})

    def test_executable_agent_configuration_that_changed_is_listed(self):
        write(self.source / ".claude/settings.json", '{"hooks": {}}')
        report = move.inspect(self.source)
        self.assertEqual(report["config"], [".claude/settings.json"])


class LandingPathTests(unittest.TestCase):
    def test_an_env_file_is_never_written_through_a_link_out_of_the_landed_tree(self):
        base = Path(tempfile.mkdtemp())
        tree, outside, extras = base / 'tree', base / 'outside', base / 'extras.tar'
        (tree / 'real').mkdir(parents=True)
        outside.mkdir()
        # What a hostile bundle could commit: a folder that is really a link to somewhere else here.
        (tree / 'proj').symlink_to(outside, target_is_directory=True)
        with tarfile.open(extras, 'w') as archive:
            for name in ('env/proj/.env', 'env/real/.env'):
                info = tarfile.TarInfo(name)
                info.size = 4
                archive.addfile(info, io.BytesIO(b'A=1\n'))
        manifest = {'env': {'sha256': move.sha256_file(extras), 'names': ['proj/.env', 'real/.env']}}
        self.assertEqual(move.land_env(tree, extras, manifest), ['real/.env'])
        self.assertFalse((outside / '.env').exists())
        self.assertEqual((tree / 'real/.env').read_bytes(), b'A=1\n')
        self.assertTrue(move.within(tree / 'real', tree) and move.within(tree, tree))
        self.assertFalse(move.within(tree / 'proj', tree) or move.within(base, tree) or move.within(str(tree) + '-other', tree))


class ConversationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(os.path.realpath(self.temp.name))
        self.here, self.there = self.base / "here", self.base / "there"
        self.out = self.base / "out"
        self.folder = "/code/my app"
        self.project = self.here / "projects" / "-code-my-app"

    def tearDown(self):
        self.temp.cleanup()

    def claude(self):
        write(self.project / f"{SESSION}.jsonl", '{"type":"user"}\n')
        write(self.project / SESSION / "subagents/agent-1.jsonl", "{}\n")
        write(self.project / SESSION / "tool-results/big.txt", "result")
        write(self.project / "memory/MEMORY.md", "- a note\n")
        write(self.project / "other-session.jsonl", "{}\n")

    def test_a_claude_conversation_is_filed_under_the_landing_folder_with_its_subagents_and_memory(self):
        self.claude()
        expected = move.export_conversation("claude", SESSION, self.out, projects=self.here / "projects", folder=self.folder)
        names = [member["name"] for member in expected["members"]]
        self.assertEqual(names, [f"transcript/{SESSION}.jsonl", f"transcript/{SESSION}/subagents/agent-1.jsonl",
                                 f"transcript/{SESSION}/tool-results/big.txt", "memory/MEMORY.md"])
        landing = "/Users/alex/code/app/.sidea-worktrees/sa-app-1a2b"
        move.import_conversation("claude", SESSION, self.out / "conversation.tar", expected, projects=self.there / "projects", folder=landing)
        home = self.there / "projects" / "-Users-alex-code-app--sidea-worktrees-sa-app-1a2b"
        self.assertEqual((home / f"{SESSION}.jsonl").read_text(), '{"type":"user"}\n')
        self.assertEqual((home / SESSION / "tool-results/big.txt").read_text(), "result")
        self.assertEqual((home / "memory/MEMORY.md").read_text(), "- a note\n")
        self.assertEqual(oct((home / f"{SESSION}.jsonl").stat().st_mode & 0o777), "0o600")
        again = move.import_conversation("claude", SESSION, self.out / "conversation.tar", expected, projects=self.there / "projects", folder=landing)
        self.assertEqual(again["created"], [])
        self.assertEqual(move.forget(again["written"] + [str(self.project / f"{SESSION}.jsonl")], [str(self.there / "projects")])["removed"], 3)
        self.assertFalse((home / f"{SESSION}.jsonl").exists())
        self.assertTrue((self.project / f"{SESSION}.jsonl").exists())
        self.assertFalse((home / "other-session.jsonl").exists())

    def test_a_transcript_already_there_is_replaced_only_by_one_that_continues_it(self):
        self.claude()
        home = self.there / "projects" / "-code-my-app"
        write(home / "memory/MEMORY.md", "- theirs\n")
        write(home / f"{SESSION}.jsonl", '{"type":"other"}\n')
        expected = move.export_conversation("claude", SESSION, self.out, projects=self.here / "projects", folder=self.folder)
        arguments = ("claude", SESSION, self.out / "conversation.tar", expected)
        with self.assertRaises(move.Refused) as refused:
            move.import_conversation(*arguments, projects=self.there / "projects", folder=self.folder)
        self.assertIn("different copy", str(refused.exception))
        self.assertFalse((home / SESSION).exists())
        write(home / f"{SESSION}.jsonl", '{"type":')
        move.import_conversation(*arguments, projects=self.there / "projects", folder=self.folder)
        self.assertEqual((home / f"{SESSION}.jsonl").read_text(), '{"type":"user"}\n')
        self.assertEqual((home / "memory/MEMORY.md").read_text(), "- theirs\n")

    def test_a_copy_names_only_the_file_that_resumes_the_original_and_touches_nothing_that_was_there(self):
        self.claude()
        expected = move.export_conversation("claude", SESSION, self.out, projects=self.here / "projects", folder=self.folder)
        projects = self.there / "projects"
        # The original, filed under another folder on this computer before the copy came: not the copy's to change.
        before = projects / "-somewhere-else" / f"{SESSION}.jsonl"
        write(before, '{"type":"user"}\n{"type":"older"}\n')
        landing = "/code/app/.sidea-worktrees/sa-app-1a2b"
        copied = move.run({"action": "import", "agent": "claude", "session": SESSION, "archive": str(self.out / "conversation.tar"),
                           "expected": expected, "projects": str(projects), "folder": landing, "copy": True})
        home = projects / "-code-app--sidea-worktrees-sa-app-1a2b"
        self.assertEqual(copied["resumable"], [str(home / f"{SESSION}.jsonl")])
        # What the fork reads besides the transcript stays: its records point at the tool results.
        self.assertEqual(move.forget(copied["resumable"], [str(projects)])["removed"], 1)
        self.assertEqual(sorted(p.name for p in projects.glob(f"*/{SESSION}.jsonl")), [f"{SESSION}.jsonl"])
        self.assertEqual(before.read_text(), '{"type":"user"}\n{"type":"older"}\n')
        self.assertEqual((home / SESSION / "tool-results/big.txt").read_text(), "result")
        # A copy never replaces a file, even one it would continue, and says so before writing anything.
        write(home / f"{SESSION}.jsonl", '{"type":')
        with self.assertRaises(move.Refused):
            move.import_conversation("claude", SESSION, self.out / "conversation.tar", expected, projects=projects, folder=landing, copy=True)
        self.assertEqual((home / f"{SESSION}.jsonl").read_text(), '{"type":')
        # A plain import says nothing of it.
        self.assertNotIn("resumable", move.import_conversation("claude", SESSION, self.out / "conversation.tar", expected, projects=projects,
                                                               folder="/code/other"))

    def test_a_codex_copy_names_the_threads_own_rollout_and_not_the_one_it_continues(self):
        store = self.here / "sessions"
        write(store / f"2026/11/24/rollout-2026-11-24T09-00-00-{PARENT}.jsonl", json.dumps({"type": "session_meta", "payload": {"id": PARENT}}) + "\n")
        write(store / f"2026/11/25/rollout-2026-11-25T18-47-34-{SESSION}.jsonl",
              json.dumps({"type": "session_meta", "payload": {"id": SESSION, "history_base": {"thread_id": PARENT}}}) + "\n")
        expected = move.export_conversation("codex", SESSION, self.out, stores=[store])
        copied = move.import_conversation("codex", SESSION, self.out / "conversation.tar", expected, store=self.there / "sessions", copy=True)
        self.assertEqual(copied["resumable"], [str(self.there / f"sessions/2026/11/25/rollout-2026-11-25T18-47-34-{SESSION}.jsonl")])
        self.assertEqual(len(copied["created"]), 2)

    def test_a_transcript_found_under_another_folder_is_still_exported(self):
        self.claude()
        expected = move.export_conversation("claude", SESSION, self.out, projects=self.here / "projects", folder="/somewhere/else")
        self.assertEqual(expected["members"][0]["name"], f"transcript/{SESSION}.jsonl")
        self.assertEqual(move.run({"action": "export", "agent": "claude", "session": "0000aaaa-0000", "out": str(self.out),
                                   "projects": str(self.here / "projects")})["refused"], "This conversation's transcript was not found.")

    def test_a_codex_thread_moves_with_the_rollout_it_continues(self):
        store = self.here / "sessions"
        write(store / f"2026/11/24/rollout-2026-11-24T09-00-00-{PARENT}.jsonl", json.dumps({"type": "session_meta", "payload": {"id": PARENT}}) + "\n")
        write(store / f"2026/11/25/rollout-2026-11-25T18-47-34-{SESSION}.jsonl",
              json.dumps({"type": "session_meta", "payload": {"id": SESSION, "history_base": {"thread_id": PARENT}}}) + "\n")
        write(store / "2026/11/25/rollout-2026-11-25T10-00-00-99999999-4e5f-7413-956c-ec930a79fa5a.jsonl", "{}\n")
        expected = move.export_conversation("codex", SESSION, self.out, stores=[store])
        self.assertEqual(sorted(member["name"] for member in expected["members"]),
                         [f"rollouts/2026/11/24/rollout-2026-11-24T09-00-00-{PARENT}.jsonl",
                          f"rollouts/2026/11/25/rollout-2026-11-25T18-47-34-{SESSION}.jsonl"])
        move.import_conversation("codex", SESSION, self.out / "conversation.tar", expected, store=self.there / "sessions")
        self.assertEqual(len(list((self.there / "sessions").glob("**/rollout-*.jsonl"))), 2)

    def archive(self, members, kind=tarfile.REGTYPE):
        path = self.base / "bad.tar"
        listed = []
        with tarfile.open(path, "w") as archive:
            for name, data in members:
                info = tarfile.TarInfo(name)
                info.size, info.type = (len(data), kind) if kind == tarfile.REGTYPE else (0, kind)
                info.linkname = "/etc/passwd"
                archive.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
                listed.append({"name": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
        return path, {"members": listed, "sha256": move.sha256_file(path)}

    def test_an_archive_that_reaches_outside_or_holds_another_conversation_writes_nothing(self):
        bad = ([(f"transcript/../../{SESSION}.jsonl", b"x")], [("/abs.jsonl", b"x")], [("elsewhere/x", b"x")],
               [("transcript/another-session.jsonl", b"x")], [(f"transcript/{SESSION}/../../x", b"x")])
        for members in bad:
            path, expected = self.archive(members)
            with self.assertRaises(move.Refused, msg=members):
                move.import_conversation("claude", SESSION, path, expected, projects=self.there / "projects", folder=self.folder)
        path, expected = self.archive([(f"transcript/{SESSION}.jsonl", b"")], kind=tarfile.SYMTYPE)
        with self.assertRaises(move.Refused):
            move.import_conversation("claude", SESSION, path, expected, projects=self.there / "projects", folder=self.folder)
        path, expected = self.archive([("rollouts/../x.jsonl", b"x")])
        with self.assertRaises(move.Refused):
            move.import_conversation("codex", SESSION, path, expected, store=self.there / "sessions")
        path, expected = self.archive([(f"transcript/{SESSION}.jsonl", b"real")])
        expected["members"].append({"name": "memory/missing.md", "sha256": "0" * 64, "size": 1})
        with self.assertRaises(move.Refused):
            move.import_conversation("claude", SESSION, path, expected, projects=self.there / "projects", folder=self.folder)
        self.assertFalse(self.there.exists())

    def test_a_parked_conversation_cannot_be_found_and_comes_back_where_it_was(self):
        self.claude()
        elsewhere = self.here / "projects" / "-another-folder" / f"{SESSION}.jsonl"
        write(elsewhere, "copy\n")
        away = self.here / "away"
        self.assertEqual(move.park("claude", SESSION, away, projects=self.here / "projects")["parked"], 3)
        self.assertEqual(list((self.here / "projects").glob(f"*/{SESSION}*")), [])
        self.assertTrue((self.project / "memory/MEMORY.md").exists())
        self.assertEqual(move.park("claude", SESSION, away, projects=self.here / "projects")["parked"], 0)
        self.assertEqual(move.unpark(SESSION, away), {"restored": 3, "kept": 0})
        self.assertEqual((self.project / SESSION / "tool-results/big.txt").read_text(), "result")
        self.assertEqual(elsewhere.read_text(), "copy\n")
        self.assertFalse((away / SESSION).exists())
        self.assertEqual(move.unpark(SESSION, away), {"restored": 0, "kept": 0})


if __name__ == "__main__":
    unittest.main()
