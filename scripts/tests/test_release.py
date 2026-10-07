"""Exercise release safety boundaries without credentials or network access."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        (self.root / "releases").mkdir()
        self.version = plistlib.loads((self.root / "scripts/Info.plist").read_bytes())["CFBundleShortVersionString"]
        self.tag = f"v{self.version}"
        (self.root / "releases" / f"{self.tag}.md").write_text("Fixture release notes")

    def check(self, tag):
        return subprocess.run(["python3", "scripts/check-release.py", tag], cwd=self.root, capture_output=True, text=True)

    def test_matching_release_passes(self):
        self.assertEqual(self.check(self.tag).returncode, 0)

    def test_wrong_version_is_rejected(self):
        self.assertNotEqual(self.check("v99.0.0").returncode, 0)

    def test_branch_or_malformed_tag_is_rejected(self):
        for tag in ("main", "v1.2", "../../secret", self.tag + ";exit 0"):
            with self.subTest(tag=tag):
                self.assertNotEqual(self.check(tag).returncode, 0)

    def test_missing_notes_are_rejected(self):
        (self.root / "releases" / f"{self.tag}.md").unlink()
        self.assertNotEqual(self.check(self.tag).returncode, 0)

    def publish(self, state, corrupt=False):
        dist = self.root / "dist"
        dist.mkdir()
        archive = dist / f"SideA-{self.version}-macOS-universal.zip"
        archive.write_bytes(b"fixture archive")
        installer = dist / f"SideA-{self.version}-macOS-universal.dmg"
        installer.write_bytes(b"fixture installer")
        import hashlib
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        installer_checksum = hashlib.sha256(installer.read_bytes()).hexdigest()
        (dist / "SHA256SUMS.txt").write_text(f"{checksum}  {archive.name}\n{installer_checksum}  {installer.name}\n")
        if corrupt:
            archive.write_bytes(b"changed after validation")
        binaries = self.root / "bin"
        binaries.mkdir()
        gh = binaries / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ["CALL_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["release", "list"]:
    state = os.environ["RELEASE_STATE"]
    print(json.dumps([] if state == "missing" else [{"tagName": os.environ["RELEASE_TAG"], "isDraft": state == "draft"}]))
''')
        gh.chmod(0o700)
        log = self.root / "calls.jsonl"
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", CALL_LOG=str(log), RELEASE_STATE=state, RELEASE_TAG=self.tag)
        result = subprocess.run(["bash", "scripts/publish-release.sh", self.tag], cwd=self.root, env=env, capture_output=True, text=True)
        import json
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_published_version_cannot_be_replaced(self):
        result, calls = self.publish("published")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["release", "list"])

    def test_corrupt_archive_never_reaches_github(self):
        result, calls = self.publish("missing", corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_new_release_publishes_only_after_draft_and_upload(self):
        result, calls = self.publish("missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in calls], ["list", "create", "upload", "edit"])
        self.assertIn("--draft", calls[1])
        self.assertIn("--draft=false", calls[-1])

    def test_failed_draft_can_be_retried(self):
        result, calls = self.publish("draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in calls], ["list", "upload", "edit"])


if __name__ == "__main__":
    unittest.main()
