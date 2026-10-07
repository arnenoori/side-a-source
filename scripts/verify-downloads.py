#!/usr/bin/env python3
"""Require the checksum manifest to cover exactly the two public downloads."""
import hashlib
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parent.parent
version = plistlib.loads((root / "scripts/Info.plist").read_bytes())["CFBundleShortVersionString"]
expected = {f"SideA-{version}-macOS-universal.{extension}" for extension in ("zip", "dmg")}
entries = {}
for line in (root / "dist/SHA256SUMS.txt").read_text().splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
    if not match or match[2] not in expected or match[2] in entries:
        raise SystemExit("Invalid or unexpected checksum entry")
    entries[match[2]] = match[1]
if set(entries) != expected:
    raise SystemExit("Checksums must cover both the ZIP and DMG")
for name, checksum in entries.items():
    if hashlib.sha256((root / "dist" / name).read_bytes()).hexdigest() != checksum:
        raise SystemExit(f"Download checksum mismatch: {name}")
print("Verified both public download checksums")
