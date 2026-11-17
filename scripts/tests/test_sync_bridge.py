import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CALLERS = ["build-app.sh", "check.sh", "local-ci.sh"]


class SyncBridgeTests(unittest.TestCase):
    def test_copies_the_bridge_in_and_drops_what_it_no_longer_has(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/sync-bridge.sh", repo / "scripts/sync-bridge.sh")
            (repo / "bridge").mkdir()
            (repo / "bridge/sidea_bridge.py").write_text("new\n")
            (repo / "bridge/notes.txt").write_text("not copied\n")
            resources = repo / "Sources/SideA/Resources"
            resources.mkdir(parents=True)
            (resources / "sidea_bridge.py").write_text("old\n")
            (resources / "gone.py").write_text("removed from bridge/\n")
            (resources / "discman.json").write_text("{}\n")
            subprocess.run(["bash", str(repo / "scripts/sync-bridge.sh")], check=True)
            self.assertEqual((resources / "sidea_bridge.py").read_text(), "new\n")
            self.assertFalse((resources / "gone.py").exists())
            self.assertTrue((resources / "discman.json").exists())
            self.assertFalse((resources / "notes.txt").exists())

    def test_the_build_and_both_checks_use_it(self):
        for name in CALLERS:
            text = (ROOT / "scripts" / name).read_text()
            self.assertIn("scripts/sync-bridge.sh", text, name)
            self.assertNotIn("rm -f Sources/SideA/Resources/*.py", text, name)


if __name__ == "__main__":
    unittest.main()
