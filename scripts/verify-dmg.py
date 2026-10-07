#!/usr/bin/env python3
"""Mount a disk image read-only and verify the actual install payload."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
from ds_store import DSStore

root = Path(__file__).resolve().parent.parent
image = Path(sys.argv[1]).resolve()
subprocess.run(["hdiutil", "verify", str(image)], check=True, stdout=subprocess.DEVNULL)
with tempfile.TemporaryDirectory(prefix="sidea-installer-") as temporary:
    mount = Path(temporary) / "volume"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)], check=True, stdout=subprocess.DEVNULL)
    try:
        if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
            raise SystemExit("Installer Applications shortcut is missing or incorrect")
        if not (mount / ".DS_Store").is_file() or not (mount / ".background.png").is_file():
            raise SystemExit("Custom installer layout is missing")
        with DSStore.open(str(mount / ".DS_Store"), "r") as layout:
            if layout["Side A.app"]["Iloc"] != (174, 210) or layout["Applications"]["Iloc"] != (506, 210):
                raise SystemExit("Installer icon positions differ from the approved layout")
            view = layout["."]["icvp"]
            if view["iconSize"] != 112 or view["backgroundType"] != 2:
                raise SystemExit("Installer background or icon sizing is incorrect")
        subprocess.run([sys.executable, str(root / "scripts/verify-bundle.py"), str(mount / "Side A.app"), "--architectures", "arm64", "x86_64"], check=True)
        print("Verified read-only installer and Applications shortcut")
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
