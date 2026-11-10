#!/usr/bin/env python3
"""Reject mismatched release tags, missing public release notes and a build that isn't newer."""
import plistlib
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
tag = sys.argv[1]
metadata = plistlib.loads((root / "scripts/Info.plist").read_bytes())
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
    raise SystemExit("Use a vMAJOR.MINOR.PATCH release tag")
if tag != "v" + metadata["CFBundleShortVersionString"]:
    raise SystemExit("Release tag does not match the app version")
notes = root / "releases" / f"{tag}.md"
if not notes.is_file() or not notes.read_text().strip():
    raise SystemExit("Public release notes are missing")
# The changelog names the version in its own section, with what changed in it; "## Unreleased" is renamed at release.
changelog = (root / "CHANGELOG.md").read_text() if (root / "CHANGELOG.md").is_file() else ""
version = re.escape(tag[1:])
section = re.search(rf"^## {version}(?: |$)[^\n]*\n(.*?)(?=^## |\Z)", changelog, re.MULTILINE | re.DOTALL)
if not section or not section.group(1).strip():
    raise SystemExit(f"CHANGELOG.md has no section for {tag[1:]} saying what changed")
if re.search(r"^## Unreleased[ \t]*\n\s*(?!## )\S", changelog, re.MULTILINE):
    raise SystemExit("CHANGELOG.md still has Unreleased entries; move them into the release's section")
# Sparkle and publish-appcast.py refuse a build that isn't newer, but only after the binary is public.
build = str(metadata.get("CFBundleVersion", ""))
if not re.fullmatch(r"[0-9]+", build):
    raise SystemExit(f"CFBundleVersion must be a whole number, not {build!r}")


def git(*arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)


def release(name):
    return tuple(int(part) for part in name[1:].split(".")) if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", name) else None


# Only this checkout's own tags: a copy of scripts/ outside any repository has none.
top = git("rev-parse", "--show-toplevel")
tags = git("tag", "--list", "v*").stdout.split() if top.returncode == 0 and Path(top.stdout.strip()).resolve() == root else []
earlier = [name for name in tags if release(name) and release(name) < release(tag)]
if not earlier:
    print(f"Note: no release tag below {tag} here, so build {build} isn't compared with one")
else:
    previous = max(earlier, key=release)
    shown = git("show", f"{previous}:scripts/Info.plist")
    if shown.returncode != 0:
        raise SystemExit(f"Can't read scripts/Info.plist at {previous}: {shown.stderr.strip()}")
    previous_build = str(plistlib.loads(shown.stdout.encode()).get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+", previous_build) or int(build) <= int(previous_build):
        raise SystemExit(f"CFBundleVersion {build} must be greater than {previous}'s {previous_build}")
print(f"Validated {tag}, build {build}")
