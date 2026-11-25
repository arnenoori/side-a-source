"""The local-check proof: what check.sh records and posts, merge-pr.sh's refusal, the pre-push hook and setup-hooks.sh.

gh is a fake on PATH that logs its arguments, so nothing here reaches GitHub."""

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from test_check_env import ROOT, clean_env, stub

SCRIPTS = ("check.sh", "lint-python.sh", "lint-swift.sh", "sync-bridge.sh", "test-bridge.sh", "lint-scripts.sh", "scan-public-source.py", "setup-hooks.sh")


def git(repo, *arguments, env):
    return subprocess.run(["git", *arguments], cwd=repo, env=env, check=True, capture_output=True, text=True).stdout.strip()


class Fixture(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        base = Path(folder.name)
        self.repo, self.tools = base / "repo", base / "tools"
        self.gh_log, self.calls = base / "gh.log", base / "calls.log"
        self.tools.mkdir()
        self.gh_log.touch()
        self.calls.touch()
        (self.repo / "scripts/tests").mkdir(parents=True)
        (self.repo / "scripts/tests/test_x.py").write_text("import unittest\nclass T(unittest.TestCase):\n    def test(self): pass\n")
        (self.repo / "bridge/tests").mkdir(parents=True)
        (self.repo / "bridge/a.py").write_text("")
        (self.repo / "bridge/tests/test_a.py").write_text("import unittest\nclass T(unittest.TestCase):\n    def test(self): pass\n")
        (self.repo / "Sources/SideA/Resources").mkdir(parents=True)
        for name in SCRIPTS:
            (self.repo / "scripts" / name).write_text((ROOT / "scripts" / name).read_text())
            (self.repo / "scripts" / name).chmod(0o755)
        (self.repo / ".githooks").mkdir()
        self.env = clean_env(PATH=f"{self.tools}:{os.environ['PATH']}", SIDEA_POST_INTERVAL="1", SIDEA_POST_WAIT="2")
        self.env.pop("SIDEA_IOS_TESTS", None)
        self.env.pop("SIDEA_IOS_SIMULATOR", None)
        for arguments in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-qm", "base"]):
            git(self.repo, *arguments, env=self.env)
        for name in ("swift", "xcodegen", "xcodebuild", "swiftlint", "ruff", "shellcheck", "actionlint", "npm"):
            stub(self.tools, name, f'echo "{name} $*" >> "{self.calls}"')
        stub(self.tools, "xcrun", 'echo "{}"')
        self.gh("exit 0")

    def gh(self, body):
        stub(self.tools, "gh", f'echo "gh $*" >> "{self.gh_log}"\n{body}')

    def commit(self, path, text="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.repo, "add", "-A", env=self.env)
        git(self.repo, "commit", "-qm", f"change {path}", env=self.env)
        return git(self.repo, "rev-parse", "HEAD", env=self.env)

    def check(self, *arguments):
        return subprocess.run(["bash", "scripts/check.sh", *arguments], cwd=self.repo, env=self.env, capture_output=True, text=True, check=False)

    def posts(self):
        return [line for line in self.gh_log.read_text().splitlines() if "/statuses/" in line]

    def marker(self, sha):
        return Path(git(self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir", env=self.env)) / "sidea-local-check" / sha


class PostingTests(Fixture):
    def test_a_clean_full_pass_posts_success_naming_what_ran(self):
        sha = self.commit("docs/a.md")
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        (post,) = self.posts()
        self.assertIn(f"api repos/{{owner}}/{{repo}}/statuses/{sha} -f state=success -f context=local-check", post)
        self.assertIn("description=check.sh vs HEAD~1: public-scan", post)
        self.assertTrue(self.marker(sha).exists())

    def test_a_dirty_tree_posts_and_records_nothing(self):
        sha = self.commit("docs/a.md")
        (self.repo / "scratch.txt").write_text("uncommitted")
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertFalse(self.marker(sha).exists())
        self.assertIn("uncommitted changes", result.stderr)

    def test_a_skipped_gate_posts_nothing(self):
        sha = self.commit("Packages/P/A.swift")
        self.env["SIDEA_IOS_TESTS"] = "skip"
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("iOS tests were skipped", result.stdout)
        self.assertEqual(self.posts(), [])
        self.assertFalse(self.marker(sha).exists())
        self.assertIn("gates were skipped", result.stderr)

    def test_a_failing_gate_posts_nothing(self):
        stub(self.tools, "ruff", "exit 1")
        sha = self.commit("bridge/b.py", "")
        result = self.check("HEAD~1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.posts(), [])
        self.assertFalse(self.marker(sha).exists())

    def test_without_gh_the_pass_is_recorded_and_the_gap_is_said_plainly(self):
        (self.tools / "gh").unlink()
        self.env["PATH"] = f"{self.tools}:/usr/bin:/bin"
        sha = self.commit("docs/a.md")
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gh is not installed, so the local-check status was NOT posted", result.stderr)
        self.assertIn(f"scripts/check.sh --post {sha}", result.stderr)
        self.assertTrue(self.marker(sha).exists())

    def test_a_commit_github_does_not_have_yet_says_so_and_still_passes(self):
        self.gh("echo 'No commit found for SHA' >&2; exit 1")
        sha = self.commit("docs/a.md")
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("was NOT posted", result.stderr)
        self.assertIn("No commit found", result.stderr)
        self.assertTrue(self.marker(sha).exists())

    def test_a_missing_shellcheck_or_actionlint_fails_a_scripts_change(self):
        for tool in ("shellcheck", "actionlint"):
            with self.subTest(tool=tool):
                (self.tools / tool).unlink()
                self.env["PATH"] = f"{self.tools}:/usr/bin:/bin"
                self.commit(f"scripts/{tool}.sh", "#!/bin/sh\n")
                result = self.check("HEAD~1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"brew install {tool}", result.stderr)
                self.assertEqual(self.posts(), [])
                stub(self.tools, tool, "exit 0")


class PostAndShaTests(Fixture):
    def test_post_needs_a_recorded_pass(self):
        sha = self.commit("docs/a.md")
        result = self.check("--post", sha)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no passing run is recorded", result.stderr)
        self.assertEqual(self.posts(), [])

    def test_post_after_the_push_posts_for_the_recorded_commit(self):
        self.gh("exit 1")
        sha = self.commit("docs/a.md")
        self.check("HEAD~1")
        self.gh("exit 0")
        self.gh_log.write_text("")
        result = self.check("--post", sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"statuses/{sha} -f state=success -f context=local-check", self.posts()[0])

    def test_wait_retries_until_the_commit_is_on_github(self):
        sha = self.commit("docs/a.md")
        self.check("HEAD~1")
        self.gh_log.write_text("")
        counter = self.repo.parent / "attempts"
        self.gh(f'echo x >> "{counter}"; [[ $(wc -l < "{counter}") -ge 3 ]] || exit 1')
        result = self.check("--post", sha, "--wait")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.posts()), 3)

    def test_sha_checks_that_commit_in_a_clean_worktree_and_posts_for_it(self):
        first = self.commit("docs/a.md")
        second = self.commit("docs/b.md")
        self.assertNotEqual(first, second)
        result = self.check("--sha", first, "HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        (post,) = self.posts()
        self.assertIn(f"statuses/{first} ", post)
        self.assertTrue(self.marker(first).exists())
        self.assertFalse(self.marker(second).exists())
        self.assertEqual(git(self.repo, "worktree", "list", env=self.env).count("\n"), 0, "the temporary worktree is removed")

    def test_sha_lints_in_a_tree_outside_private(self):
        """swiftlint cannot match its baseline under /private/{var,tmp,etc}, where $TMPDIR is: the tree goes in the git dir."""
        where = self.repo.parent / "lint-dir.log"
        stub(self.tools, "swiftlint", f'pwd -P >> "{where}"')
        self.env["SIDEA_IOS_TESTS"] = "skip"
        first = self.commit(".swiftlint.yml")
        self.commit("docs/b.md")
        self.assertEqual(self.check("--sha", first, "HEAD~1").returncode, 0)
        (tree,) = where.read_text().splitlines()
        self.assertNotEqual(tree, str(self.repo), "it linted in a temporary tree, not this checkout")
        self.assertTrue(tree.startswith(str((self.repo / ".git").resolve())), f"{tree} is not inside the checkout's git dir")
        self.assertFalse(tree.startswith(str(Path(tempfile.gettempdir()).resolve()) + "/sidea-check"), tree)

    def test_sha_ignores_uncommitted_files_in_this_checkout(self):
        first = self.commit("docs/a.md")
        self.commit("docs/b.md")
        (self.repo / "scratch.txt").write_text("uncommitted")
        self.assertEqual(self.check("--sha", first, "HEAD~1").returncode, 0)
        self.assertTrue(self.marker(first).exists())


class MergePrTests(Fixture):
    def setUp(self):
        super().setUp()
        (self.repo / "scripts/merge-pr.sh").write_text((ROOT / "scripts/merge-pr.sh").read_text())
        (self.repo / "scripts/merge-pr.sh").chmod(0o755)
        self.state = self.repo.parent / "state"
        self.sha = "abc123"
        self.verdict = "pass"
        self.env.update(SIDEA_MERGE_ATTEMPTS="3", SIDEA_MERGE_INTERVAL="0")
        self.reads = self.repo.parent / "reads"

    def install(self, status="", pr="OPEN\tfalse\tabc123"):
        self.state.write_text(status)
        stub(self.repo / "scripts", "check.sh", f'echo "check $*" >> "{self.calls}"\n[[ "{self.verdict}" == pass ]] || exit 1\necho success > "{self.state}"')
        self.gh(
            f'''case "$*" in
  "pr view"*) printf '{pr}\\n' ;;
  *"/status "*) [[ -s "{self.state}" ]] && cat "{self.state}" || echo "" ;;
  "pr merge"*) echo "merge $*" >> "{self.calls}" ;;
esac'''
        )
        stub(self.tools, "git", 'if [[ "$1" == fetch ]]; then exit 0; fi\nexec /usr/bin/git "$@"')

    def lag(self, script):
        """A gh stub whose script sees `kind` (view or status) and `n`, how many times that kind was called."""
        self.reads.write_text("0")
        stub(self.repo / "scripts", "check.sh", f'echo "check $*" >> "{self.calls}"\necho success > "{self.state}"')
        self.gh(f'''kind=other
case "$*" in "pr view"*) kind=view ;; *"/status "*) kind=status ;; "pr merge"*) echo "merge $*" >> "{self.calls}"; exit 0 ;; esac
n=$(( $(cat "{self.reads}.$kind" 2>/dev/null || echo 0) + 1 )); echo $n > "{self.reads}.$kind"
{script}''')
        stub(self.tools, "git", 'if [[ "$1" == fetch ]]; then exit 0; fi\nexec /usr/bin/git "$@"')
        self.state.write_text("")

    def merge(self):
        return subprocess.run(["bash", "scripts/merge-pr.sh", "7"], cwd=self.repo, env=self.env, capture_output=True, text=True, check=False)

    def test_a_pr_with_a_passing_local_check_merges_without_rerunning(self):
        self.install(status="success")
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().strip(), "merge pr merge 7 --squash --match-head-commit abc123")

    def test_a_pr_without_the_status_is_checked_then_merged(self):
        self.install()
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["check --sha abc123", "merge pr merge 7 --squash --match-head-commit abc123"])

    def test_a_failing_check_never_merges(self):
        self.verdict = "fail"
        self.install()
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("merge", self.calls.read_text())

    def test_a_pass_that_could_not_be_posted_never_merges(self):
        self.install()
        stub(self.repo / "scripts", "check.sh", f'echo "check $*" >> "{self.calls}"')
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no local-check success", result.stderr)
        self.assertNotIn("merge", self.calls.read_text())

    def test_a_status_that_shows_up_late_is_waited_for_and_check_is_not_rerun(self):
        self.lag('''case $kind in view) printf 'OPEN\\tfalse\\tabc123\\n' ;; status) [[ $n -ge 3 ]] && echo success || echo "" ;; esac''')
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().strip(), "merge pr merge 7 --squash --match-head-commit abc123")

    def test_a_head_that_changes_while_waiting_is_refused(self):
        self.lag('''case $kind in view) [[ $n -ge 2 ]] && printf 'OPEN\\tfalse\\tdef456\\n' || printf 'OPEN\\tfalse\\tabc123\\n' ;; status) echo "" ;; esac''')
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed from abc123 to def456", result.stderr)
        self.assertEqual(self.calls.read_text(), "")

    def test_a_head_that_changes_during_the_check_is_refused(self):
        self.lag('''case $kind in view) [[ $n -ge 2 ]] && printf 'OPEN\\tfalse\\tdef456\\n' || printf 'OPEN\\tfalse\\tabc123\\n' ;; status) [[ -s "{self.state}" ]] && echo success || echo "" ;; esac'''.replace("{self.state}", str(self.state)))
        stub(self.repo / "scripts", "check.sh", f'echo "check $*" >> "{self.calls}"\necho success > "{self.state}"')
        self.env["SIDEA_MERGE_ATTEMPTS"] = "1"
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed from abc123 to def456", result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["check --sha abc123"])

    def test_drafts_and_closed_prs_are_refused(self):
        for pr in ("OPEN\ttrue\tabc123", "MERGED\tfalse\tabc123"):
            with self.subTest(pr=pr):
                self.install(status="success", pr=pr)
                self.assertNotEqual(self.merge().returncode, 0)
                self.assertEqual(self.calls.read_text(), "")


class HookTests(Fixture):
    def test_setup_hooks_sets_the_path_only_when_unset(self):
        subprocess.run(["bash", "scripts/setup-hooks.sh"], cwd=self.repo, env=self.env, check=True, capture_output=True)
        self.assertEqual(git(self.repo, "config", "core.hooksPath", env=self.env), ".githooks")
        git(self.repo, "config", "core.hooksPath", "elsewhere", env=self.env)
        subprocess.run(["bash", "scripts/setup-hooks.sh"], cwd=self.repo, env=self.env, check=True, capture_output=True)
        self.assertEqual(git(self.repo, "config", "core.hooksPath", env=self.env), "elsewhere")

    def test_check_sets_the_hook_path_in_a_fresh_clone(self):
        self.commit("docs/a.md")
        self.check("HEAD~1")
        self.assertEqual(git(self.repo, "config", "core.hooksPath", env=self.env), ".githooks")

    def test_the_hook_is_shared_by_a_worktree(self):
        subprocess.run(["bash", "scripts/setup-hooks.sh"], cwd=self.repo, env=self.env, check=True, capture_output=True)
        tree = self.repo.parent / "tree"
        git(self.repo, "worktree", "add", "-q", "--detach", str(tree), env=self.env)
        self.assertEqual(git(tree, "config", "core.hooksPath", env=self.env), ".githooks")

    def test_the_hook_checks_each_pushed_branch_commit_and_posts_after_the_push(self):
        (self.repo / ".githooks/pre-push").write_text((ROOT / ".githooks/pre-push").read_text())
        (self.repo / ".githooks/pre-push").chmod(0o755)
        stub(self.repo / "scripts", "check.sh", f'echo "check $*" >> "{self.calls}"')
        git(self.repo, "add", "-A", env=self.env)
        git(self.repo, "commit", "-qm", "hook", env=self.env)
        sha = git(self.repo, "rev-parse", "HEAD", env=self.env)
        refs = f"refs/heads/topic {sha} refs/heads/topic {'0' * 40}\n(delete) {'0' * 40} refs/heads/gone {sha}\nrefs/tags/v1 {sha} refs/tags/v1 {'0' * 40}\n"
        result = subprocess.run([".githooks/pre-push", "origin", "url"], cwd=self.repo, env=self.env, input=refs, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = [f"check --sha {sha}", f"check --post {sha} --wait"]
        for _ in range(50):
            if sorted(self.calls.read_text().splitlines()) == sorted(expected):
                break
            time.sleep(0.1)
        self.assertEqual(sorted(self.calls.read_text().splitlines()), sorted(expected))


class RoutingTests(Fixture):
    def calls_for(self, path, text="changed\n"):
        self.commit(path, text)
        result = self.check("HEAD~1")
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.calls.read_text()

    def test_ios_only_swift_runs_swiftlint(self):
        self.env["SIDEA_IOS_SIMULATOR"] = "NAMED"
        self.assertIn("swiftlint lint", self.calls_for("apps/ios/View.swift"))

    def test_package_only_swift_runs_swiftlint(self):
        self.env["SIDEA_IOS_TESTS"] = "skip"
        self.assertIn("swiftlint lint", self.calls_for("Packages/SideAProtocol/Sources/A.swift"))

    def test_python_outside_the_bridge_runs_ruff_on_scripts(self):
        self.assertIn("ruff check", self.calls_for("scripts/tool.py", ""))

    def test_shell_and_workflow_changes_run_shellcheck_and_actionlint(self):
        calls = self.calls_for("scripts/tool.sh", "#!/bin/sh\n")
        self.assertIn("shellcheck scripts/", calls)
        self.assertIn("actionlint", calls)
        self.calls.write_text("")
        self.assertIn("actionlint", self.calls_for(".github/workflows/x.yml", "name: x\n"))

    def test_a_relay_only_change_runs_the_relays_typecheck_lint_and_tests(self):
        calls = self.calls_for("relay/src/a.ts").splitlines()
        self.assertEqual([line for line in calls if line.startswith("npm")], ["npm run typecheck", "npm run lint", "npm test"])
        self.assertNotIn("swift", " ".join(calls))

    def test_a_site_only_change_runs_the_sites_ci_lint_tests_and_build(self):
        calls = self.calls_for("site/src/a.ts").splitlines()
        self.assertEqual(
            [line for line in calls if line.startswith("npm")],
            ["npm --prefix site ci", "npm --prefix site run lint", "npm --prefix site test", "npm --prefix site run build"],
        )

    def test_a_docs_only_change_runs_no_linter(self):
        self.assertEqual(self.calls_for("docs/a.md"), "")


if __name__ == "__main__":
    unittest.main()
