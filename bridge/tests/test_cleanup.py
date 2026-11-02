import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import cleanup  # noqa: E402
import sessions  # noqa: E402

OLD = time.time() - 200 * 86400


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main",
                    "-C", str(cwd), *args], check=True, capture_output=True)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name).resolve()
        self.home, self.root = base / "home", base / "SideA"
        self.project = self.home / ".claude/projects/-code-app"
        self.project.mkdir(parents=True)
        home = patch.object(Path, "home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        self.addCleanup(self.temp.cleanup)

    def transcript(self, sid, age=OLD, companion=False):
        path = self.project / f"{sid}.jsonl"
        path.write_text(json.dumps({"type": "user", "uuid": sid, "timestamp": "2026-01-01T10:00:00Z", "cwd": "/code/app",
                                    "message": {"content": f"Prompt for {sid}"}}) + "\n")
        if companion:
            sub = self.project / sid / "subagents"
            sub.mkdir(parents=True)
            (sub / "agent-1.jsonl").write_text("{}\n")
            os.utime(sub / "agent-1.jsonl", (age, age))
        os.utime(path, (age, age))
        return path

    def test_archive_moves_old_skips_pinned_and_running_then_restores(self):
        old = self.transcript("old", companion=True)
        self.transcript("pinned")
        self.transcript("running")
        self.transcript("fresh", age=time.time())
        registry = self.home / ".claude/sessions"
        registry.mkdir(parents=True)
        (registry / "1.json").write_text(json.dumps({"pid": os.getpid(), "sessionId": "running"}))
        sessions.index(self.root)
        self.assertEqual(len(sessions.recent(self.root)["sessions"]), 4)

        report = cleanup.disk(self.root, keep=["pinned"])
        self.assertEqual(report["old"]["count"], 1)
        self.assertEqual(report["projects"][0]["path"], "/code/app")

        result = cleanup.archive(self.root, 90, keep=["pinned"])
        self.assertEqual([Path(m["path"]).name for m in result["moved"]], ["old.jsonl"])
        self.assertGreater(result["bytes"], 0)
        self.assertFalse(old.exists())
        archived = self.root / "archive/.claude/projects/-code-app"
        self.assertTrue((archived / "old.jsonl").exists())
        self.assertTrue((archived / "old/subagents/agent-1.jsonl").exists())
        self.assertEqual({p.stem for p in self.project.glob("*.jsonl")}, {"pinned", "running", "fresh"})
        self.assertNotIn("old", {s["id"] for s in sessions.recent(self.root)["sessions"]})

        back = cleanup.restore(self.root)
        self.assertEqual([Path(p).name for p in back["restored"]], ["old.jsonl"])
        self.assertTrue(old.exists() and (self.project / "old/subagents/agent-1.jsonl").exists())
        self.assertLess(old.stat().st_mtime, time.time() - 100 * 86400)
        self.assertFalse(any((self.root / "archive").rglob("*.jsonl")))
        self.assertIn("old", {s["id"] for s in sessions.recent(self.root)["sessions"]})

    def test_restore_never_overwrites(self):
        self.transcript("old")
        cleanup.archive(self.root, 90)
        self.transcript("old", age=time.time())
        result = cleanup.restore(self.root)
        self.assertEqual(result["restored"], [])
        self.assertEqual(len(result["skipped"]), 1)
        self.assertTrue((self.root / "archive/.claude/projects/-code-app/old.jsonl").exists())

    def test_archive_counts_only_what_moved_and_reports_failures(self):
        self.transcript("taken", companion=True)
        self.transcript("broken")
        self.transcript("fine")
        archived = self.root / "archive/.claude/projects/-code-app"
        archived.mkdir(parents=True)
        (archived / "taken.jsonl").write_text("already here\n")
        real = cleanup.shutil.move

        def move(source, destination):
            if source.endswith("broken.jsonl"):
                raise PermissionError(13, "Permission denied")
            return real(source, destination)

        sessions.index(self.root)
        with patch.object(cleanup.shutil, "move", side_effect=move):
            result = cleanup.archive(self.root, 90)
        self.assertEqual([Path(m["path"]).name for m in result["moved"]], ["fine.jsonl"])
        self.assertEqual(result["errors"], ["broken.jsonl: Permission denied"])
        self.assertTrue((self.project / "taken.jsonl").exists() and (self.project / "taken/subagents/agent-1.jsonl").exists())
        self.assertFalse((archived / "taken").exists())
        self.assertEqual({s["id"] for s in sessions.recent(self.root)["sessions"]}, {"taken", "broken"})


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        home = patch.object(Path, "home", return_value=self.base / "home")
        home.start()
        self.addCleanup(home.stop)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        git(self.repo, "init")
        (self.repo / "a.txt").write_text("a")
        (self.repo / ".gitignore").write_text(".env\nnode_modules/\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "first")
        self.merged, self.ahead, self.dirty, self.fresh = (self.base / name for name in ("merged", "ahead", "dirty", "fresh"))
        git(self.repo, "worktree", "add", "-b", "done", str(self.merged))
        (self.merged / "c.txt").write_text("c")
        git(self.merged, "add", ".")
        git(self.merged, "commit", "-m", "landed")
        git(self.repo, "merge", "--ff-only", "done")
        git(self.repo, "worktree", "add", "-b", "wip", str(self.ahead))
        (self.ahead / "b.txt").write_text("b")
        git(self.ahead, "add", ".")
        git(self.ahead, "commit", "-m", "more")
        git(self.repo, "worktree", "add", "-b", "messy", str(self.dirty))
        (self.dirty / "scratch.txt").write_text("untracked")
        git(self.repo, "worktree", "add", "-b", "new", str(self.fresh))
        # Repositories are found through the folders indexed sessions ran in.
        self.root = self.base / "SideA"
        project = self.base / "home/.claude/projects/-repo"
        project.mkdir(parents=True)
        for sid, cwd in (("in-ahead", self.ahead), ("in-repo", self.repo)):
            (project / f"{sid}.jsonl").write_text(json.dumps({"type": "user", "uuid": sid, "timestamp": "2026-10-01T10:00:00Z", "cwd": str(cwd),
                                                              "message": {"content": f"Work in {cwd.name}"}}) + "\n")
        sessions.index(self.root)

    def listing(self):
        return {Path(w["path"]).name: w for w in cleanup.worktrees(self.root)["worktrees"]}

    def test_lists_each_worktrees_state_and_what_counts_as_in_use(self):
        found = self.listing()
        self.assertEqual(set(found), {"merged", "ahead", "dirty", "fresh"})
        self.assertEqual((found["merged"]["branch"], found["merged"]["merged"], found["merged"]["dirty"]), ("done", True, False))
        self.assertEqual((found["ahead"]["merged"], found["ahead"]["dirty"]), (False, False))
        self.assertTrue(found["dirty"]["dirty"])
        self.assertLess(found["merged"]["age"], 600)
        self.assertEqual((found["merged"]["inUse"], found["merged"]["refused"]), (False, None))
        # A brand new worktree isn't merged until it has sat untouched for a week.
        self.assertFalse(found["fresh"]["merged"])
        with patch.object(cleanup.time, "time", return_value=time.time() + 8 * 86400):
            self.assertTrue(self.listing()["fresh"]["merged"])
        # Claude Code's registry counts as in use beside lsof; a failed check refuses.
        registry = Path.home() / ".claude/sessions"
        registry.mkdir(parents=True)
        (registry / "a.json").write_text(json.dumps({"pid": os.getpid(), "cwd": str(self.ahead / "sub")}))
        (registry / "b.json").write_text(json.dumps({"pid": 1, "cwd": str(self.merged)}))
        with patch.object(cleanup.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "p1\nfcwd\nn/\n", "")):
            cwds = cleanup.cwds_in_use()
        self.assertTrue(cleanup.in_use(str(self.ahead), cwds))
        self.assertFalse(cleanup.in_use(str(self.merged), cwds))
        with patch.object(cleanup.subprocess, "run", side_effect=OSError):
            self.assertIsNone(cleanup.cwds_in_use())
        self.assertIn("Could not check", cleanup.refusal(str(self.merged), None))

    def test_removal_refuses_whatever_would_lose_work_and_removes_a_clean_merged_worktree(self):
        # Uncommitted files and the main checkout stay.
        self.assertFalse(cleanup.remove_worktree(str(self.dirty))["removed"])
        self.assertTrue((self.dirty / "scratch.txt").exists())
        self.assertFalse(cleanup.remove_worktree(str(self.repo))["removed"])
        # A commit on no branch exists only there.
        lone = self.base / "lone"
        git(self.repo, "worktree", "add", "--detach", str(lone))
        (lone / "d.txt").write_text("d")
        git(lone, "add", ".")
        git(lone, "commit", "-m", "only here")
        # Ignored files a build brings back don't block; a secret does.
        (self.merged / "node_modules/pkg").mkdir(parents=True)
        (self.merged / "node_modules/pkg/index.js").write_text("x")
        found = self.listing()
        self.assertIsNone(found["lone"]["branch"])
        self.assertIn("no branch", found["lone"]["refused"])
        self.assertEqual((found["merged"]["refused"], found["merged"]["regenerable"]), (None, ["node_modules"]))
        result = cleanup.remove_worktree(str(lone))
        self.assertFalse(result["removed"])
        self.assertIn("no branch", result["error"])
        self.assertTrue((lone / "d.txt").exists())
        (self.merged / ".env").write_text("SECRET=1")
        self.assertIn(".env", self.listing()["merged"]["refused"])
        result = cleanup.remove_worktree(str(self.merged))
        self.assertFalse(result["removed"])
        self.assertIn(".env", result["error"])
        self.assertTrue((self.merged / ".env").exists())
        (self.merged / ".env").unlink()
        # A process working there blocks it until it's gone.
        process = subprocess.Popen(["sleep", "30"], cwd=self.merged)
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        found = self.listing()["merged"]
        self.assertTrue(found["inUse"])
        self.assertEqual(found["refused"], "A session is working here.")
        self.assertEqual(cleanup.remove_worktree(str(self.merged))["error"], "A session is working here.")
        self.assertTrue(self.merged.exists())
        process.kill()
        process.wait()
        self.assertTrue(cleanup.remove_worktree(str(self.merged))["removed"])
        self.assertFalse(self.merged.exists())
        self.assertTrue(self.repo.exists())

if __name__ == "__main__":
    unittest.main()
