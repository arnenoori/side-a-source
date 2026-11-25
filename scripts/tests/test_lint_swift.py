"""lint-swift.sh and the temporary tree check.sh --sha lints in.

SwiftLint cannot match its baseline from a checkout under /private/{var,tmp,etc} ($TMPDIR is /private/var), so a
tree made there reported ~445 untouched violations and failed every Swift PR in merge-pr.sh's fallback."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_check_env import ROOT, clean_env, stub

LINT = ROOT / "scripts/lint-swift.sh"


def private_folder():
    """A folder whose real path is under /private/var or /private/tmp, or None where this OS has no such place."""
    for base in (tempfile.gettempdir(), "/private/tmp", "/tmp"):
        if Path(base).resolve().as_posix().startswith(("/private/var/", "/private/tmp/")):
            return tempfile.TemporaryDirectory(dir=base)
    return None


class LintSwiftPathTests(unittest.TestCase):
    def test_refuses_a_baselined_lint_under_private(self):
        folder = private_folder()
        if folder is None:
            self.skipTest("no /private/var or /private/tmp on this OS")
        with folder:
            root = Path(folder.name).resolve()
            (root / ".swiftlint-baseline.json").write_text("[]")
            # The script cd's to its own repo root, so run a copy that lives in the throwaway tree.
            (root / "scripts").mkdir()
            script = root / "scripts/lint-swift.sh"
            shutil.copy(LINT, script)
            tools = root / "tools"
            tools.mkdir()
            calls = root / "calls.log"
            calls.touch()
            stub(tools, "swiftlint", f'echo "swiftlint $*" >> "{calls}"')
            env = clean_env(PATH=f"{tools}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(script)], cwd=root, env=env, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("cannot match", result.stderr)
            self.assertEqual(calls.read_text(), "", "swiftlint must not run and report bogus violations")
            unbaselined = subprocess.run(["bash", str(script), "--no-baseline"], cwd=root, env=env, capture_output=True, text=True, check=False)
            self.assertEqual(unbaselined.returncode, 0, unbaselined.stderr)
            self.assertIn("swiftlint lint", calls.read_text())

    @unittest.skipUnless(shutil.which("swiftlint"), "swiftlint is not installed")
    def test_this_checkout_lints_clean_where_it_lives(self):
        """The real baseline against the real tree, from the real path and from a symlink to it."""
        if str(ROOT.resolve()).startswith(("/private/var/", "/private/tmp/", "/private/etc/")):
            self.skipTest("this checkout is itself under /private")
        with tempfile.TemporaryDirectory() as folder:
            link = Path(folder) / "link"
            link.symlink_to(ROOT)
            for place in (ROOT, link):
                with self.subTest(place=str(place)):
                    result = subprocess.run(["bash", "scripts/lint-swift.sh"], cwd=place, env=clean_env(), capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr)
