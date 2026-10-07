#!/usr/bin/env python3
"""Publish only the built site to the public downloads repository, atomically."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess

repository = "arnenoori/side-a-releases"
root = Path(__file__).resolve().parent.parent
distribution = root / "site/dist"
if not (distribution / "index.html").is_file():
    raise SystemExit("Build the download page first")


def api(path, data=None, method=None):
    command = ["gh", "api", f"repos/{repository}/{path}"]
    if data is not None:
        command += ["--method", method or "POST", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


head = api("git/ref/heads/main")["object"]["sha"]
commit = api(f"git/commits/{head}")
tree = api(f"git/trees/{commit['tree']['sha']}?recursive=1")
if tree.get("truncated"):
    raise SystemExit("Cannot safely update a truncated repository tree")
old_files = {entry["path"]: entry["sha"] for entry in tree["tree"] if entry["type"] == "blob" and entry["path"].startswith("docs/")}
files = {"docs/" + path.relative_to(distribution).as_posix(): path.read_bytes() for path in distribution.rglob("*") if path.is_file() and path.name != "_headers"}
files["docs/.nojekyll"] = b""
changes = []
for path, data in files.items():
    sha = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    if old_files.get(path) == sha:
        continue
    blob = api("git/blobs", {"content": base64.b64encode(data).decode(), "encoding": "base64"})
    changes.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
for path in old_files.keys() - files.keys() - {"docs/CNAME"}:
    changes.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
if not changes:
    print("Download page is already current")
    raise SystemExit(0)
new_tree = api("git/trees", {"base_tree": commit["tree"]["sha"], "tree": changes})
new_commit = api("git/commits", {"message": "site: update the Side A download experience", "tree": new_tree["sha"], "parents": [head]})
# Reject concurrent branch movement; never overwrite an unrelated public commit.
api("git/refs/heads/main", {"sha": new_commit["sha"], "force": False}, method="PATCH")
print("Published built site:", new_commit["sha"])
