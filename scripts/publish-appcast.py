#!/usr/bin/env python3
"""Publish a signed update feed only after its immutable installer is public."""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from urllib.request import urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "arnenoori/side-a-releases"


def api(path, data=None):
    command = ["gh", "api", f"repos/{REPOSITORY}/{path}"]
    if data is not None:
        command += ["--method", "PUT", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def require_newer_feed(previous, current):
    namespace = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    def build(data):
        return max(int(item.findtext("s:version", namespaces=namespace))
                   for item in ET.fromstring(data).findall("./channel/item"))
    if build(current) <= build(previous) and previous != current:
        raise ValueError("Cannot replace or downgrade a published update")


def main():
    metadata = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
    version = metadata["CFBundleShortVersionString"]
    installer = ROOT / f"dist/SideA-{version}-macOS-universal.dmg"
    feed_path = ROOT / "dist/appcast.xml"
    subprocess.run(["python3", "scripts/verify-downloads.py"], cwd=ROOT, check=True)
    subprocess.run(["python3", "scripts/verify-appcast.py", str(feed_path), str(installer)], cwd=ROOT, check=True)
    release = api(f"releases/tags/v{version}")
    if release["draft"] or release["prerelease"]:
        raise ValueError("Publish the stable release before its feed")
    asset = next(asset for asset in release["assets"] if asset["name"] == installer.name)
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/v{version}/{installer.name}"
    if asset["browser_download_url"] != expected_url:
        raise ValueError("Unexpected public installer URL")
    digest = hashlib.sha256()
    with urlopen(expected_url, timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    if digest.digest() != hashlib.sha256(installer.read_bytes()).digest():
        raise ValueError("Public installer differs from signed local installer")
    # Listing the root distinguishes a first feed from an API/authentication error.
    entries = api("contents/?ref=main")
    previous = next((entry for entry in entries if entry["name"] == "appcast.xml"), None)
    feed = feed_path.read_bytes()
    data = {"message": f"release: signed update feed for {version}", "branch": "main",
            "content": base64.b64encode(feed).decode()}
    if previous:
        old = api("contents/appcast.xml?ref=main")
        old_feed = base64.b64decode(old["content"])
        require_newer_feed(old_feed, feed)
        if old_feed == feed:
            print("Published feed is already current")
            return
        data["sha"] = old["sha"]
    result = api("contents/appcast.xml", data)
    print("Published verified update feed:", result["commit"]["sha"])


if __name__ == "__main__":
    main()
