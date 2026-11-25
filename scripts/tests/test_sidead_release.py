#!/usr/bin/env python3
"""ship-sidead.sh without Docker or GitHub (a fake gh records what it is asked), and site/public/install.sh against
a stand-in for the system (a fake uname and getconf) and a folder served over file://."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "site/public/install.sh"
VERSION = "1.2.3"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["SHIP_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["release", "list"]:
    print(os.environ.get("FAKE_RELEASES", "[]"))
'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class ShipSideadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        self.origin, self.repo, tools = base / "origin.git", base / "repo", base / "bin"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], check=True, env=self.env)
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ship-sidead.sh", self.repo / "scripts/ship-sidead.sh")
        self.write_version(VERSION)
        (self.repo / "releases").mkdir()
        (self.repo / "releases" / f"sidead-v{VERSION}.md").write_text("Notes")
        (self.repo / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\nA change.\n")
        self.out = base / "out"
        self.out.mkdir()
        self.names = [f"side-a-daemon-{VERSION}-linux-amd64.tar.gz", f"side-a-daemon-{VERSION}-linux-arm64.tar.gz",
                      f"side-a-daemon_{VERSION}_amd64.deb", f"side-a-daemon_{VERSION}_arm64.deb"]
        for name in self.names:
            (self.out / name).write_bytes(name.encode() * 10)
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("commit", "-qm", "release")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        tools.mkdir()
        (tools / "gh").write_text(FAKE_GH)
        (tools / "gh").chmod(0o755)
        self.log = base / "gh.jsonl"
        self.env.update(PATH=f"{tools}:{os.environ['PATH']}", SHIP_LOG=str(self.log))

    def write_version(self, version):
        path = self.repo / "Daemon/Sources/SideADaemonKit/SideADaemon.swift"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'public enum SideADaemon {{\n    public static let version = "{version}"\n}}\n')

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.repo, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def ship(self, *arguments, **env):
        result = subprocess.run(["bash", "scripts/ship-sidead.sh", "--skip-build", "--skip-verify", "--out", str(self.out), *arguments],
                                cwd=self.repo, env={**self.env, **env}, capture_output=True, text=True, check=False)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_it_writes_sums_that_cover_the_four_packages_and_never_calls_github(self):
        result, calls = self.ship()
        self.assertEqual(result.returncode, 0, result.stderr)
        sums = (self.out / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(sorted(line.split("  ")[1] for line in sums), sorted(self.names))
        for line in sums:
            digest, name = line.split("  ")
            self.assertEqual(digest, sha256((self.out / name).read_bytes()))
        self.assertEqual(calls, [])

    def test_a_pre_release_version_is_refused(self):
        self.write_version("0.0.0-phase0")
        result, _ = self.ship()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MAJOR.MINOR.PATCH", result.stderr)

    def test_missing_notes_or_a_missing_package_stop_it(self):
        (self.repo / "releases" / f"sidead-v{VERSION}.md").unlink()
        result, _ = self.ship()
        self.assertIn("release notes", result.stderr)
        (self.repo / "releases" / f"sidead-v{VERSION}.md").write_text("Notes")
        (self.out / self.names[3]).unlink()
        result, _ = self.ship()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.names[3], result.stderr)

    def test_publish_makes_a_draft_uploads_then_publishes_without_taking_latest(self):
        result, calls = self.ship("--publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        verbs = [call[:2] for call in calls]
        self.assertEqual(verbs, [["release", "list"], ["release", "create"], ["release", "upload"], ["release", "edit"]])
        create, upload, edit = calls[1], calls[2], calls[3]
        self.assertEqual(create[2], f"sidead-v{VERSION}")
        self.assertIn("--draft", create)
        self.assertIn("--latest=false", create)
        self.assertIn("--latest=false", edit)
        self.assertIn("--draft=false", edit)
        self.assertNotIn("--latest", edit)
        uploaded = {Path(item).name for item in upload if item.endswith((".gz", ".deb", ".txt"))}
        self.assertEqual(uploaded, {*self.names, "SHA256SUMS.txt"})
        self.assertEqual(self.git("ls-remote", str(self.origin), f"refs/tags/sidead-v{VERSION}").split("\t")[0], self.git("rev-parse", "HEAD"))

    def test_publish_refuses_a_version_that_is_already_public(self):
        result, calls = self.ship("--publish", FAKE_RELEASES=json.dumps([{"tagName": f"sidead-v{VERSION}", "isDraft": False}]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertEqual([call[:2] for call in calls], [["release", "list"]])

    def test_publish_refuses_a_main_that_is_not_the_remotes(self):
        (self.repo / "extra").write_text("x")
        self.git("add", "-A")
        self.git("commit", "-qm", "local only")
        result, calls = self.ship("--publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("up-to-date main", result.stderr)
        self.assertEqual(calls, [])


class InstallScriptTests(unittest.TestCase):
    """The one-liner's script, where a fake `uname` and `getconf` say what system this is."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.served = self.base / "served"
        self.served.mkdir()
        self.home = self.base / "home"
        self.home.mkdir()
        self.marker = self.base / "installed.txt"

    def system(self, kernel="Linux", machine="x86_64", libc="glibc 2.39"):
        (self.bin / "uname").write_text(f'#!/bin/sh\ncase "$1" in -s) echo {kernel} ;; -m) echo {machine} ;; *) echo {kernel} ;; esac\n')
        (self.bin / "getconf").write_text(f'#!/bin/sh\n[ "$1" = GNU_LIBC_VERSION ] && echo "{libc}" || exit 1\n' if libc else "#!/bin/sh\nexit 1\n")
        for tool in ("uname", "getconf"):
            (self.bin / tool).chmod(0o755)

    def serve(self, arch="amd64", tamper=False):
        name = f"side-a-daemon-{VERSION}-linux-{arch}.tar.gz"
        script = f'#!/bin/sh\necho "installed $*" > "{self.marker}"\n'.encode()
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            info = tarfile.TarInfo(f"side-a-daemon-{VERSION}-linux-{arch}/install.sh")
            info.size, info.mode = len(script), 0o755
            archive.addfile(info, io.BytesIO(script))
        data = buffer.getvalue()
        (self.served / name).write_bytes(data)
        listed = sha256(b"something else" if tamper else data)
        (self.served / "SHA256SUMS.txt").write_text(f"{'0' * 64}  other-file\n{listed}  {name}\n")

    def install(self, *arguments, **env):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SIDEAD")}
        environment.update(PATH=f"{self.bin}:{os.environ['PATH']}", HOME=str(self.home), TMPDIR=str(self.base),
                           SIDEAD_VERSION=VERSION, SIDEAD_BASE_URL=f"file://{self.served}", **env)
        return subprocess.run(["sh", str(INSTALL), *arguments], env=environment, capture_output=True, text=True, check=False)

    def test_it_downloads_checks_and_runs_the_packages_installer_with_its_arguments(self):
        self.system()
        self.serve()
        result = self.install("--no-service")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checksum ok", result.stdout)
        self.assertEqual(self.marker.read_text().strip(), "installed --no-service")
        self.assertEqual(list(self.base.glob("sidead-install.*")), [])

    def test_an_arm_machine_gets_the_arm_package(self):
        self.system(machine="aarch64")
        self.serve(arch="arm64")
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(self.marker.exists())

    def test_a_download_that_does_not_match_its_sum_installs_nothing(self):
        self.system()
        self.serve(tamper=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("doesn't match its SHA-256", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_old_glibc_other_architectures_other_systems_and_musl_are_refused_with_a_reason(self):
        self.serve()
        cases = [
            (dict(libc="glibc 2.35"), "glibc 2.35"),
            (dict(libc="glibc 2.38"), "2.39 or newer"),
            (dict(machine="armv7l"), "armv7l isn't supported"),
            (dict(kernel="Darwin"), "On a Mac"),
            (dict(libc=None), "doesn't use glibc"),
        ]
        for settings, message in cases:
            with self.subTest(settings=settings):
                self.system(**settings)
                result = self.install()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.marker.exists())

    def test_a_newer_glibc_passes_the_check(self):
        for libc in ("glibc 2.39", "glibc 2.40", "glibc 2.100", "glibc 3.0"):
            with self.subTest(libc=libc):
                self.system(libc=libc)
                self.serve()
                self.assertEqual(self.install().returncode, 0)
                self.marker.unlink()

    def test_a_missing_listing_entry_is_refused(self):
        self.system()
        self.serve()
        (self.served / "SHA256SUMS.txt").write_text(f"{'0' * 64}  other-file\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("doesn't list", result.stderr)


if __name__ == "__main__":
    unittest.main()
