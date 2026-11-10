"""ship.sh against a fake GitHub: what it dispatches, what it skips on a rerun, and the order it publishes in."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

# Answers the gh calls ship.sh and publish-appcast.py make, from state.json, and logs each one.
FAKE_GH = r'''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
state_path = Path(os.environ["SHIP_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with Path(os.environ["SHIP_LOG"]).open("a") as log:
    log.write(json.dumps(["gh", *args]) + "\n")
def save():
    state_path.write_text(json.dumps(state))
if args[:1] == ["api"]:
    path = args[1]
    if path.endswith("/actions/runners"):
        print(1)
    elif "/releases/tags/" in path:
        if state["release"] is None:
            sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
        print(json.dumps({"draft": state["release"] == "draft", "prerelease": False}))
    elif "/contents/appcast.xml" in path:
        if state["feed_build"] is None:
            sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
        feed = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                f'<sparkle:version>{state["feed_build"]}</sparkle:version></item></channel></rss>')
        print(json.dumps({"content": base64.b64encode(feed.encode()).decode()}))
    else:
        sys.exit(f"unexpected gh api {path}")
elif args[:2] == ["workflow", "run"]:
    state["runs"].insert(0, {"id": 101, "sha": state["dispatch_sha"], "ok": True})
    save()
elif args[:2] == ["run", "list"]:
    runs = [run for run in state["runs"] if "--status" not in args or run["ok"]]
    for run in runs:
        print(run["sha"] if "--status" in args else f'{run["id"]} {run["sha"]}')
elif args[:2] == ["run", "view"]:
    print(next(run["sha"] for run in state["runs"] if str(run["id"]) == args[2]))
elif args[:2] in (["run", "watch"], ["run", "cancel"]):
    pass
else:
    sys.exit(f"unexpected gh {args}")
'''

LOGGED = '''#!/bin/sh
printf '%s\\n' "[\\"$(basename "$0")\\", \\"$*\\"]" >> "$SHIP_LOG"
'''


class ShipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@example.com")
        self.origin, self.source, self.repo, tools = base / "origin.git", base / "source.git", base / "repo", base / "bin"
        for bare in (self.origin, self.source):
            self.git("init", "-q", "--bare", "-b", "main", str(bare), cwd=base)
        self.repo.mkdir()
        shutil.copytree(ROOT / "scripts", self.repo / "scripts", ignore=shutil.ignore_patterns("tests", "__pycache__"))
        (self.repo / "scripts/publish-site.py").write_text(
            'import json, os\nopen(os.environ["SHIP_LOG"], "a").write(json.dumps(["publish-site"]) + "\\n")\n')
        metadata = plistlib.loads((self.repo / "scripts/Info.plist").read_bytes())
        self.version, self.build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
        self.tag = f"v{self.version}"
        (self.repo / "releases").mkdir()
        (self.repo / "releases" / f"{self.tag}.md").write_text("Notes")
        (self.repo / "CHANGELOG.md").write_text(f"# Changelog\n\n## {self.version} — 2026-11-09\n\nA change.\n")
        (self.repo / "site").mkdir()
        (self.repo / "site/index.html").write_text("site\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("commit", "-qm", "release")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        self.head = self.git("rev-parse", "HEAD")
        tools.mkdir()
        (tools / "gh").write_text(FAKE_GH)
        (tools / "npm").write_text(LOGGED)
        for tool in ("gh", "npm"):
            (tools / tool).chmod(0o755)
        self.log, self.state = base / "calls.jsonl", base / "state.json"
        self.env.update(PATH=f"{tools}:{os.environ['PATH']}", SHIP_LOG=str(self.log), SHIP_STATE=str(self.state),
                        SOURCE_REMOTE=str(self.source))

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def ship(self, release=None, feed_build=None, runs=(), dispatch_sha=None):
        self.state.write_text(json.dumps({"release": release, "feed_build": feed_build, "runs": list(runs),
                                          "dispatch_sha": dispatch_sha or self.head}))
        result = subprocess.run(["bash", "scripts/ship.sh"], cwd=self.repo, env=self.env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def remote_tag(self, remote):
        return self.git("ls-remote", str(remote), f"refs/tags/{self.tag}").split("\t")[0]

    def test_a_first_run_dispatches_then_tags_publishes_source_and_then_the_site(self):
        result, calls = self.ship()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["gh", "workflow", "run", "local-release.yml", "--ref", "main", "-f", f"tag={self.tag}"], calls)
        self.assertEqual(self.remote_tag(self.origin), self.head)
        self.assertTrue(self.remote_tag(self.source))
        self.assertEqual(calls[-1], ["publish-site"])

    def test_a_rerun_after_the_binary_is_public_skips_the_dispatch(self):
        published = dict(release="published", feed_build=self.build, runs=[{"id": 7, "sha": self.head, "ok": True}])
        result, calls = self.ship(**published)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("workflow", [call[1] for call in calls if call[0] == "gh"])
        self.assertEqual(self.remote_tag(self.origin), self.head)
        self.assertTrue(self.remote_tag(self.source))
        self.log.unlink()
        again, calls = self.ship(**published)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already public", again.stdout)
        self.assertEqual(calls[-1], ["publish-site"])

    def test_a_published_release_without_its_feed_stops_without_dispatching(self):
        result, calls = self.ship(release="published", feed_build=int(self.build) - 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update feed", result.stderr)
        self.assertNotIn(["gh", "workflow"], [call[:2] for call in calls])
        self.assertFalse(self.remote_tag(self.origin))

    def test_a_run_for_another_commit_is_cancelled_and_nothing_else_is_published(self):
        result, calls = self.ship(dispatch_sha="f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(["gh", "run", "cancel", "101"], calls)
        self.assertNotIn(["gh", "run", "watch"], [call[:3] for call in calls])
        self.assertFalse(self.remote_tag(self.origin))
        self.assertNotIn(["publish-site"], calls)

    def test_uncommitted_site_changes_stop_it_before_anything_runs(self):
        (self.repo / "site/index.html").write_text("edited\n")
        result, calls = self.ship()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("site/", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
