"""A step every gate needs lives in one script, and the gates call it instead of repeating it."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATES = [ROOT / "scripts/check.sh", ROOT / "scripts/local-ci.sh", ROOT / ".github/workflows/ci.yml"]


class SharedStepTests(unittest.TestCase):
    def test_the_bridge_tests_and_their_python_3_9_rerun_are_one_script(self):
        for gate in GATES:
            text = gate.read_text()
            self.assertIn("scripts/test-bridge.sh", text, gate.name)
            self.assertNotIn("unittest discover -s bridge/tests", text, gate.name)
        self.assertIn("/usr/bin/python3", (ROOT / "scripts/test-bridge.sh").read_text())

    def test_the_script_and_workflow_lint_is_one_script_for_both_local_gates(self):
        for name in ("check.sh", "local-ci.sh"):
            text = (ROOT / "scripts" / name).read_text()
            self.assertIn("scripts/lint-scripts.sh", text, name)
            self.assertNotIn("shellcheck scripts/", text, name)
        self.assertIn(".githooks/*", (ROOT / "scripts/lint-scripts.sh").read_text())


if __name__ == "__main__":
    unittest.main()
