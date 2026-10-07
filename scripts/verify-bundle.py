#!/usr/bin/env python3
"""Validate a packaged app against the checked-out release sources."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
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
    resources = contents / "Resources/SideA_SideA.bundle"
    expected_resources = {path.name: path for path in (root / "bridge").glob("*.py")}
    expected_resources["discman.json"] = root / "Sources/SideA/Resources/discman.json"
    for name, source in expected_resources.items():
        require(digest(resources / name) == digest(source), f"Resource differs: {name}")
    allowed = {"Info.plist", "MacOS/SideA", "Resources/SideA.icns", "Resources/SideA_SideA.bundle/Info.plist"}
    allowed.update(f"Resources/SideA_SideA.bundle/{name}" for name in expected_resources)
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
