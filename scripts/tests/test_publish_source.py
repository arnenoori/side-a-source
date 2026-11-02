import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("scan_public_source", ROOT / "scripts/scan-public-source.py")
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)

# Assembled at run time, so this file doesn't trip the scan it tests.
PEM = "-----BEGIN " + "PRIVATE KEY-----\n" + "MC4CAQAwBQYDK2VwBCIEI" * 4 + "\n-----END " + "PRIVATE KEY-----\n"
GITHUB = "gh" + "p_" + "a1B2" * 10
TAILNET = "my-mac.tail" + "9f8e7d.ts.net"
REAL_HOME = "/Us" + "ers/somebody/project"


def clean_env(**extra):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", **extra)
    return env


class ScanTests(unittest.TestCase):
    def test_every_real_env_file_is_a_secret_file(self):
        for name in (".env", ".env.local", ".env.production", "apps/web/.env.local"):
            self.assertTrue(scanner.SECRET_FILES.search(name), name)
        self.assertFalse(scanner.SECRET_FILES.search(".env.example"))

    def tree(self, files):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        for name, text in files.items():
            path = Path(folder.name) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return folder.name

    def test_finds_each_kind_without_printing_the_value(self):
        root = self.tree({"a.txt": PEM, "b.txt": f"token = {GITHUB}\n", "c.md": f"https://{TAILNET}:47800\n", "d.swift": f'"{REAL_HOME}"\n'})
        findings = "\n".join(scanner.scan(root))
        for expected in ("a.txt:1: private key", "b.txt:1: GitHub token", "c.md:1: tailnet name", "d.swift:1: real home path"):
            self.assertIn(expected, findings)
        for value in (GITHUB, TAILNET, "somebody"):
            self.assertNotIn(value, findings)

    def test_secret_files_are_refused_by_name(self):
        root = self.tree({"relay/.dev.vars": "x", "AuthKey_ABC.p8": "x", "signing.p12": "x"})
        self.assertEqual(sorted(scanner.scan(root)), ["AuthKey_ABC.p8: secret file", "relay/.dev.vars: secret file", "signing.p12: secret file"])

    def test_fixtures_and_placeholders_pass(self):
        root = self.tree({
            "relay/.dev.vars.example": 'APNS_KEY_P8="-----BEGIN ' + 'PRIVATE KEY-----\\n...\\n-----END ' + 'PRIVATE KEY-----"\n',
            "fixture.json": '{"cwd": "/Users/you/code/app", "name": "macbook-pro.tail1234.ts.net:47800"}\n',
            "notes.md": "someone@example.com /Users/demo/api\n",
            scanner.TEST_VECTORS + "key.json": PEM,
        })
        self.assertEqual(scanner.scan(root), [])

    def test_the_publishers_own_home_always_counts(self):
        root = self.tree({"a.txt": "/Users/demo/x\n"})
        with unittest.mock.patch.object(Path, "home", return_value=Path("/Users/demo")):
            self.assertEqual(scanner.scan(root), ["a.txt:1: real home path"])

    def test_this_repository_is_clean(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = subprocess.run(["git", "archive", "HEAD"], cwd=ROOT, env=clean_env(), capture_output=True, check=True).stdout
            subprocess.run(["tar", "-x", "-C", folder], input=archive, check=True)
            self.assertEqual(scanner.scan(folder), [])
            for private in ("relay/DEPLOY.md", "docs/remote/staging-runbook.md", "docs/remote/tunnel-field-test.md", ".github/workflows/local-release.yml"):
                self.assertFalse((Path(folder) / private).exists(), private)


class PublishTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.remote = self.root / "public.git"
        self.repo = self.root / "repo"
        self.env = clean_env(SOURCE_REMOTE=str(self.remote), TMPDIR=folder.name, HOME=folder.name)
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)], check=True, env=self.env)
        self.seed = self.root / "seed"
        self.git(["clone", "-q", str(self.remote), str(self.seed)], cwd=self.root)
        (self.seed / "README").write_text("public\n")
        self.git(["add", "-A"], cwd=self.seed)
        self.git(["commit", "-qm", "first"], cwd=self.seed)
        self.git(["push", "-q", "origin", "HEAD:main"], cwd=self.seed)
        (self.repo / "scripts").mkdir(parents=True)
        self.git(["init", "-q", "-b", "main"], cwd=self.repo)
        for name in ("publish-source.sh", "scan-public-source.py"):
            shutil.copy(ROOT / "scripts" / name, self.repo / "scripts" / name)

    def git(self, arguments, cwd):
        subprocess.run(["git", *arguments], cwd=cwd, env=self.env, check=True, capture_output=True)

    def publish(self, tag, files):
        for name, text in files.items():
            (self.repo / name).write_text(text)
        self.git(["add", "-A"], cwd=self.repo)
        self.git(["commit", "-qm", tag], cwd=self.repo)
        self.git(["tag", tag], cwd=self.repo)
        return subprocess.run(["bash", "scripts/publish-source.sh", tag], cwd=self.repo, env=self.env, capture_output=True, text=True)

    def public_tags(self):
        return subprocess.run(["git", "ls-remote", "--tags", str(self.remote)], env=self.env, capture_output=True, text=True, check=True).stdout

    def test_clean_source_publishes(self):
        result = self.publish("v1.0.0", {"code.txt": "fine\n"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("v1.0.0", self.public_tags())

    def test_a_secret_stops_the_publish_and_nothing_is_pushed(self):
        result = self.publish("v1.0.1", {"leak.txt": f"{GITHUB}\n"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leak.txt:1: GitHub token", result.stderr)
        self.assertNotIn(GITHUB, result.stderr + result.stdout)
        self.assertEqual(self.public_tags(), "")


if __name__ == "__main__":
    unittest.main()
