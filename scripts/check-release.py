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
print(f"Validated {tag}, build {metadata['CFBundleVersion']}")
