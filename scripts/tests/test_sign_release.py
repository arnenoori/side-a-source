import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Every tool that touches a keychain or Apple is a stub: this test never reaches the real ones.
SECURITY = """#!/bin/bash
if [[ "$1" == find-identity ]]; then echo "1) ABC \\"$SIGNING_IDENTITY\\""; fi
if [[ "$1" == list-keychains && "$*" != *" -s "* ]]; then echo '    "/fixture/login.keychain-db"'; fi
exit 0
"""
# Reports which keys are on disk, and which secrets the environment still shows, while this step runs.
STEP = """#!/bin/bash
{
  echo "step $(basename "$0")"
  for key in "$(dirname "$SIGNING_KEYCHAIN")"/*; do [[ -f "$key" ]] && echo "disk $(basename "$key")"; done
  env | grep -qE '^(SIGNING_CERTIFICATE_BASE64|SIGNING_CERTIFICATE_PASSWORD|NOTARY_PRIVATE_KEY|SPARKLE_PRIVATE_KEY)=' && echo "leaked env"
  echo "folder $(dirname "$SIGNING_KEYCHAIN")"
} >> "$REPORT"
exit ${STEP_EXIT:-0}
"""


class SignReleaseTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.tools = self.root / "tools"
        self.report = self.root / "report"
        (self.root / "repo/scripts").mkdir(parents=True)
        self.tools.mkdir()
        shutil.copy(ROOT / "scripts/sign-release.sh", self.root / "repo/scripts/sign-release.sh")
        self.script(self.tools / "security", SECURITY)
        self.script(self.tools / "swift", "#!/bin/bash\nexit 0\n")
        self.script(self.root / "repo/scripts/notarize-app.sh", STEP)
        self.script(self.root / "repo/scripts/build-appcast.sh", STEP)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(
            PATH=f"{self.tools}:{os.environ['PATH']}", REPORT=str(self.report), RUNNER_TEMP=str(self.root),
            SIGNING_IDENTITY="Developer ID Application: Test", SIGNING_CERTIFICATE_BASE64="dGVzdA==", SIGNING_CERTIFICATE_PASSWORD="fixture",
            NOTARY_PRIVATE_KEY="fixture-notary", SPARKLE_PRIVATE_KEY="fixture-sparkle",
        )

    def script(self, path, body):
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def run_it(self):
        return subprocess.run(["bash", "scripts/sign-release.sh"], cwd=self.root / "repo", env=self.env, capture_output=True, text=True)

    def steps(self):
        steps = {}
        current = None
        for line in self.report.read_text().splitlines():
            kind, _, value = line.partition(" ")
            if kind == "step":
                current = steps.setdefault(value, [])
            elif kind != "folder":
                current.append(line)
        return steps

    def test_each_key_is_on_disk_only_for_its_step(self):
        result = self.run_it()
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = self.steps()
        self.assertEqual(steps["notarize-app.sh"], ["disk AuthKey.p8"])
        self.assertEqual(steps["build-appcast.sh"], ["disk sparkle.key"])

    def test_everything_goes_when_it_ends(self):
        self.assertEqual(self.run_it().returncode, 0)
        self.assertEqual(list(self.root.glob("sidea-signing.*")), [])

    def test_a_failed_step_still_removes_the_keys(self):
        self.env["STEP_EXIT"] = "3"
        self.assertEqual(self.run_it().returncode, 3)
        self.assertEqual(list(self.root.glob("sidea-signing.*")), [])

    def test_the_keys_reach_their_files_intact(self):
        self.script(self.root / "repo/scripts/notarize-app.sh", "#!/bin/bash\ncat \"$NOTARY_KEY_PATH\" > \"$REPORT.notary\"\n")
        self.script(self.root / "repo/scripts/build-appcast.sh", "#!/bin/bash\ncat \"$SPARKLE_PRIVATE_KEY_FILE\" > \"$REPORT.sparkle\"\n")
        self.assertEqual(self.run_it().returncode, 0)
        self.assertEqual(Path(f"{self.report}.notary").read_text(), "fixture-notary")
        self.assertEqual(Path(f"{self.report}.sparkle").read_text(), "fixture-sparkle")


class WorkflowTests(unittest.TestCase):
    def test_every_job_with_secrets_names_the_release_environment(self):
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            text = workflow.read_text()
            for job in text.split("\n  ")[1:]:
                if "secrets." in job and job.split(":")[0].strip() and "runs-on" in job:
                    self.assertIn("environment: release", job, workflow.name)

    def test_the_old_hosted_release_is_gone(self):
        self.assertFalse((ROOT / ".github/workflows/release.yml").exists())


if __name__ == "__main__":
    unittest.main()
