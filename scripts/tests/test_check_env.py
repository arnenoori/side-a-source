import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def clean_env(**extra):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", **extra)
    return env


def stub(folder, name, body):
    path = folder / name
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class CheckEnvironmentTests(unittest.TestCase):
    def probe(self, repo):
        (repo / "scripts").mkdir()
        head = (ROOT / "scripts/check.sh").read_text().split("base=")[0]
        probe = repo / "scripts/probe.sh"
        probe.write_text(head + 'echo "GIT_DIR=${GIT_DIR:-unset} INDEX=${GIT_INDEX_FILE:-unset}"\n')
        return probe

    def test_git_variables_from_a_hook_never_reach_the_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            subprocess.run(["git", "init", "-q", str(repo)], check=True, env=clean_env())
            probe = self.probe(repo)
            env = clean_env(GIT_DIR=str(repo / ".git"), GIT_INDEX_FILE=str(repo / ".git/index"))
            result = subprocess.run(["bash", str(probe)], env=env, capture_output=True, text=True, check=True)
            self.assertIn("GIT_DIR=unset INDEX=unset", result.stdout)

    def test_refuses_to_continue_when_they_could_not_be_cleared(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            subprocess.run(["git", "init", "-q", str(repo)], check=True, env=clean_env())
            probe = self.probe(repo)
            tools = repo / "tools"
            tools.mkdir()
            stub(tools, "git", "exit 0")
            env = clean_env(GIT_DIR=str(repo / ".git"), PATH=f"{tools}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(probe)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GIT_DIR is still set", result.stderr)
            self.assertNotIn("INDEX=", result.stdout)


class CheckRoutingTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Path(folder.name) / "repo"
        self.tools = Path(folder.name) / "tools"
        self.log = Path(folder.name) / "log"
        self.tools.mkdir()
        self.log.touch()
        (self.repo / "scripts").mkdir(parents=True)
        for script in ("check.sh", "scan-public-source.py"):
            (self.repo / "scripts" / script).write_text((ROOT / "scripts" / script).read_text())
        (self.repo / "bridge/tests").mkdir(parents=True)
        (self.repo / "bridge/a.py").write_text("")
        (self.repo / "bridge/tests/test_a.py").write_text("import unittest\nclass T(unittest.TestCase):\n    def test(self): pass\n")
        (self.repo / "Sources/SideA/Resources").mkdir(parents=True)
        (self.repo / "apps/ios").mkdir(parents=True)
        (self.repo / "Packages/P").mkdir(parents=True)
        self.env = clean_env(PATH=f"{self.tools}:{os.environ['PATH']}")
        self.env.pop("SIDEA_IOS_SIMULATOR", None)
        self.env.pop("SIDEA_IOS_TESTS", None)
        for arguments in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-qm", "base"]):
            subprocess.run(["git", *arguments], cwd=self.repo, env=self.env, check=True)
        for name in ("swift", "xcodegen", "xcodebuild"):
            stub(self.tools, name, f'echo "{name} $*" >> "{self.log}"')

    def simulators(self, devices):
        listing = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": devices}})
        stub(self.tools, "xcrun", f"cat <<'EOF'\n{listing}\nEOF")

    def change(self, path, text="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        for arguments in (["add", "-A"], ["commit", "-qm", "change"]):
            subprocess.run(["git", *arguments], cwd=self.repo, env=self.env, check=True)
        return subprocess.run(["bash", "scripts/check.sh", "HEAD~1"], cwd=self.repo, env=self.env, capture_output=True, text=True)

    def test_apps_run_the_ios_tests_on_a_simulator(self):
        self.simulators([{"name": "iPhone 17", "udid": "OFF", "state": "Shutdown"}, {"name": "iPhone 16", "udid": "UP", "state": "Booted"}])
        result = self.change("apps/ios/View.swift")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text()
        self.assertIn("xcodebuild test -project SideARemote.xcodeproj -scheme SideARemote -destination id=UP", log)
        self.assertNotIn("swift test", log)

    def test_no_simulator_fails_clearly(self):
        self.simulators([{"name": "iPad Pro", "udid": "PAD", "state": "Shutdown"}])
        result = self.change("apps/ios/View.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no iPhone simulator", result.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_broken_simctl_fails_clearly(self):
        stub(self.tools, "xcrun", "echo 'CoreSimulatorService connection became invalid' >&2; exit 1")
        result = self.change("apps/ios/View.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no iPhone simulator", result.stderr)

    def test_a_named_simulator_is_used_as_is(self):
        self.env["SIDEA_IOS_SIMULATOR"] = "NAMED"
        result = self.change("apps/ios/View.swift")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-destination id=NAMED", self.log.read_text())

    def test_packages_run_their_own_tests_the_macs_and_the_ios_tests(self):
        self.simulators([{"name": "iPhone 16", "udid": "UP", "state": "Booted"}])
        result = self.change("Packages/P/A.swift")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text().splitlines()
        self.assertEqual(log[:2], ["swift test", "swift test --package-path Packages/SideAProtocol"])
        self.assertIn("-destination id=UP", log[-1])

    def test_packages_without_a_simulator_fail_unless_told_to_skip_out_loud(self):
        self.simulators([])
        result = self.change("Packages/P/A.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SIDEA_IOS_TESTS=skip", result.stderr)
        self.env["SIDEA_IOS_TESTS"] = "skip"
        result = self.change("Packages/P/B.swift")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIPPED the iOS tests", result.stderr)
        self.assertIn("iOS tests were skipped", result.stdout)

    def test_the_skip_never_covers_an_apps_change(self):
        self.simulators([])
        self.env["SIDEA_IOS_TESTS"] = "skip"
        result = self.change("apps/ios/View.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no iPhone simulator", result.stderr)

    def test_any_change_runs_the_public_source_scan(self):
        self.assertEqual(self.change("docs/clean.md").returncode, 0)
        leak = "Reach it at my-mac.tail" + "9f8e7d.ts.net\n"  # assembled so this file passes the scan
        result = self.change("docs/notes.md", leak)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/notes.md:1: tailnet name", result.stdout + result.stderr)

    def test_the_hook_no_longer_skips_main(self):
        hook = (ROOT / ".githooks/pre-push").read_text()
        self.assertIn("scripts/check.sh", hook)
        self.assertNotIn("symbolic-ref", hook)


if __name__ == "__main__":
    unittest.main()
