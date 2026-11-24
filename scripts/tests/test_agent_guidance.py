"""AGENTS.md is guidance agents trust, so it must not name a path, script or folder that is gone.

Every backtick span and Markdown link in every AGENTS.md is checked: a path written from the repository root (or from the
file's own folder) has to exist. CLAUDE.md stays the one-line import so there is a single source.
"""
import glob
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Made by a build or an install, so absent from a fresh checkout.
GENERATED = {"dist", ".build", "node_modules", "build", "DerivedData"}
TOKEN = re.compile(r"[A-Za-z0-9_.@+*/<>-]+")
BARE = (".sh", ".py")
ROOT_LIMIT = 150


def tracked_top_level():
    listing = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=False).stdout.split()
    names = {line.split("/")[0] for line in listing}
    return names or set(os.listdir(ROOT))


def guidance_files():
    found = subprocess.run(["git", "-C", str(ROOT), "ls-files", "AGENTS.md", "*/AGENTS.md"], capture_output=True, text=True, check=False).stdout.split()
    return [ROOT / name for name in found] or [path for path in ROOT.rglob("AGENTS.md") if "node_modules" not in path.parts]


def generated(token):
    """A path a build makes: git ignores it, or it is a generated Xcode project."""
    path = token.lstrip("./")
    # A folder pattern such as `generated/` only matches a path that ends in a slash when the folder doesn't exist yet.
    ignored = any(subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", candidate], check=False).returncode == 0 for candidate in (path, path + "/"))
    return ignored or path.endswith(".xcodeproj")


def references(text):
    """The tokens in code spans and link targets that read as paths or script names."""
    spans = re.findall(r"`([^`\n]+)`", text) + re.findall(r"\]\(([^)\s#]+)", text)
    for span in spans:
        for word in span.split():
            token = word.strip(",.;:()\"'")
            if TOKEN.fullmatch(token) and not token.startswith(("-", "http")):
                yield token


class AgentGuidanceTests(unittest.TestCase):
    def test_claude_md_only_imports_agents_md(self):
        self.assertEqual((ROOT / "CLAUDE.md").read_text().strip(), "@AGENTS.md")

    def test_the_root_file_stays_short(self):
        lines = len((ROOT / "AGENTS.md").read_text().splitlines())
        self.assertLessEqual(lines, ROOT_LIMIT, "AGENTS.md is loaded into every agent's context: move area rules to that area's AGENTS.md")

    def test_every_path_and_script_it_names_exists(self):
        top = tracked_top_level()
        missing = []
        for guide in guidance_files():
            for token in references(guide.read_text()):
                if token.startswith("<") or "<" in token:
                    continue
                parts = token.lstrip("./").split("/")
                if "/" in token:
                    if parts[0] not in top or parts[0] in GENERATED:
                        continue
                    candidates = [ROOT / token.lstrip("./"), guide.parent / token]
                elif token.endswith(BARE):
                    candidates = [ROOT / token, guide.parent / token, ROOT / "scripts" / token]
                else:
                    continue
                if not any(glob.glob(str(candidate)) for candidate in candidates) and not generated(token):
                    missing.append(f"{guide.relative_to(ROOT)}: {token}")
        self.assertEqual(missing, [], "AGENTS.md names files that do not exist; fix the guidance or restore the file")


if __name__ == "__main__":
    unittest.main()
