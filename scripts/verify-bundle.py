#!/usr/bin/env python3
"""Validate a packaged app against the checked-out release sources."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import subprocess


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--architectures", nargs="+", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    contents = args.app / "Contents"
    expected = plistlib.loads((root / "scripts/Info.plist").read_bytes())
    actual = plistlib.loads((contents / "Info.plist").read_bytes())
    require(actual == expected, "Packaged Info.plist differs from release metadata")
    executable = contents / "MacOS/SideA"
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    require(set(architectures) == set(args.architectures), f"Unexpected architectures: {architectures}")
    # The fixed paths AppResources reads; SwiftPM's resource bundle must not ship.
    expected_resources = {f"Resources/bridge/{path.name}": path for path in (root / "bridge").glob("*.py")}
    expected_resources["Resources/discman.json"] = root / "Sources/SideA/Resources/discman.json"
    require("Resources/bridge/sidea_bridge.py" in expected_resources, "No bridge sources found")
    for name, source in expected_resources.items():
        require((contents / name).is_file(), f"Resource missing: {name}")
        require(digest(contents / name) == digest(source), f"Resource differs: {name}")
    helper = contents / "MacOS/SideAKeepAwake"
    helper_architectures = subprocess.check_output(["lipo", "-archs", str(helper)], text=True).split()
    require(set(helper_architectures) == set(args.architectures), f"Unexpected helper architectures: {helper_architectures}")
    daemon = contents / "Library/LaunchDaemons/com.sidea.keepawake.plist"
    require(plistlib.loads(daemon.read_bytes()) == plistlib.loads((root / "scripts/com.sidea.keepawake.plist").read_bytes()),
            "Packaged keep-awake daemon differs from release metadata")
    signature = subprocess.run(["codesign", "--display", "--verbose=2", str(helper)], capture_output=True, text=True).stderr
    require("Identifier=com.sidea.keepawake" in signature, "Keep-awake helper has the wrong signing identifier")
    pool = contents / "MacOS/SideAPool"
    pool_architectures = subprocess.check_output(["lipo", "-archs", str(pool)], text=True).split()
    require(set(pool_architectures) == set(args.architectures), f"Unexpected pool helper architectures: {pool_architectures}")
    agent = contents / "Library/LaunchAgents/com.sidea.pool.plist"
    require(plistlib.loads(agent.read_bytes()) == plistlib.loads((root / "scripts/com.sidea.pool.plist").read_bytes()),
            "Packaged pool agent differs from release metadata")
    signature = subprocess.run(["codesign", "--display", "--verbose=2", str(pool)], capture_output=True, text=True).stderr
    require("Identifier=com.sidea.pool" in signature, "Pool helper has the wrong signing identifier")
    # tmux is built universal (scripts/build-tmux.sh) and goes into both single-architecture apps whole.
    tmux = contents / "Helpers/tmux"
    tmux_architectures = subprocess.check_output(["lipo", "-archs", str(tmux)], text=True).split()
    require({"arm64", "x86_64"} == set(tmux_architectures), f"Unexpected tmux architectures: {tmux_architectures}")
    tmux_version = re.search(r"^TMUX_VERSION=(\S+)$", (root / "scripts/build-tmux.sh").read_text(), re.M)[1]
    require(subprocess.check_output([str(tmux), "-V"], text=True).strip() == f"tmux {tmux_version}", "Bundled tmux does not run")
    signature = subprocess.run(["codesign", "--display", "--verbose=2", str(tmux)], capture_output=True, text=True).stderr
    require("Identifier=com.sidea.tmux" in signature, "tmux helper has the wrong signing identifier")
    allowed = {"Info.plist", "MacOS/SideA", "MacOS/SideAKeepAwake", "Library/LaunchDaemons/com.sidea.keepawake.plist",
               "MacOS/SideAPool", "Library/LaunchAgents/com.sidea.pool.plist",
               "Resources/SideA.icns", *expected_resources, "Helpers/tmux",
               "Resources/terminfo/74/tmux", "Resources/terminfo/74/tmux-256color"}
    allowed.update(f"Resources/Licenses/{name}.txt" for name in ["tmux", "libevent", "ncurses", "utf8proc", "jemalloc"])
    framework = contents / "Frameworks/Sparkle.framework"
    framework_info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    require(framework_info["CFBundleShortVersionString"] == "2.9.6", "Unexpected Sparkle version")
    for binary in ["Sparkle", "Versions/B/Autoupdate", "Versions/B/Updater.app/Contents/MacOS/Updater",
                   "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
                   "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"]:
        arches = subprocess.check_output(["lipo", "-archs", str(framework / binary)], text=True).split()
        require(set(args.architectures).issubset(arches), f"Sparkle helper missing architecture: {binary}")
    links = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    require("@rpath/Sparkle.framework/Versions/B/Sparkle" in links, "App does not link Sparkle")
    require(actual.get("SUFeedURL") == "https://getsidea.com/appcast.xml" and actual.get("SURequireSignedFeed") is True,
            "Missing signed HTTPS update feed")
    import base64
    require(len(base64.b64decode(actual.get("SUPublicEDKey", ""), validate=True)) == 32, "Invalid update signing key")
    manifest = json.loads((root / "scripts/sparkle-manifest.json").read_text())
    seen = set()
    for path in framework.rglob("*"):
        name = path.relative_to(framework).as_posix()
        if "_CodeSignature" in path.parts or (path.is_dir() and not path.is_symlink()):
            continue
        require(name in manifest, f"Unexpected Sparkle file: {name}")
        seen.add(name)
        entry = manifest[name]
        if path.is_symlink(): require(str(path.readlink()) == entry.get("symlink"), f"Changed Sparkle symlink: {name}")
        elif "sha256" in entry: require(hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], f"Changed Sparkle resource: {name}")
    require(seen == set(manifest), "Sparkle framework is incomplete")
    for path in contents.rglob("*"):
        if path.is_relative_to(framework):
            require(path.resolve().is_relative_to(framework.resolve()), "Sparkle symlink escapes the framework")
            continue
        require(not path.is_symlink(), f"Unexpected bundle symlink: {path.name}")
        if path.is_file():
            relative = path.relative_to(contents).as_posix()
            # Signing/notarization may add these Apple-managed files.
            require(relative in allowed or relative == "_CodeSignature/CodeResources"
                    or relative == "CodeResources", f"Unexpected bundle file: {relative}")
    require(digest(contents / "Resources/SideA.icns") == digest(root / "design/SideA.icns"), "Icon differs")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
    print(f"Verified Side A {actual['CFBundleShortVersionString']} ({', '.join(architectures)})")


if __name__ == "__main__":
    main()
