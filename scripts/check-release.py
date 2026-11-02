#!/usr/bin/env python3
"""Reject mismatched release tags and missing public release notes."""
import plistlib
from pathlib import Path
import re
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
print(f"Validated {tag}, build {metadata['CFBundleVersion']}")
