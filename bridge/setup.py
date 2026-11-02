"""Read-only overview of the Claude Code and Codex setup: CLIs, MCP servers, hooks, skills and agents.

Nothing here writes to any file. MCP env values and headers can hold secrets, so only their key
names leave this module; URLs leave as scheme://host[:port] and commands as the program's name.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import urllib.parse

MARKS = {"side-a-island": "Dynamic Island", "side-a-limit": "Limit switch", "side-a-live": "Live limits"}
COMMAND_LIMIT = 120
PROJECT_LIMIT = 50


def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def find_binary(name):
    home = Path.home()
    for path in [home / ".local/bin" / name, home / ".npm-global/bin" / name, Path("/opt/homebrew/bin") / name, Path("/usr/local/bin") / name]:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def tool(name):
    path = find_binary(name)
    if not path:
        return {"name": name, "path": None, "version": None}
    try:
        result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL)
        match = re.search(r"\b\d+\.\d+(?:\.\d+)?\b", result.stdout + result.stderr) if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        match = None
    return {"name": name, "path": path, "version": match.group(0) if match else None}


def server(name, scope, value, project=None):
    value = value if isinstance(value, dict) else {}
    kind = value.get("type") or ("http" if value.get("url") and not value.get("command") else "stdio")
    remote = kind in ("http", "sse") or not value.get("command")
    args = value.get("args") if isinstance(value.get("args"), list) else []
    target = address(value.get("url")) if remote else program(value.get("command"), [str(a) for a in args])
    entry = {"name": str(name), "scope": scope, "type": str(kind), "target": truncate(target or ""),
             "env": key_names(value.get("env")), "headers": key_names(value.get("headers"))}
    if project:
        entry["project"] = project
    if value.get("enabled") is False:
        entry["disabled"] = True
    return entry


INTERPRETERS = {"python", "python3", "node", "bash", "sh", "zsh", "npx", "uvx", "bunx", "deno", "ruby"}
QUIET_FLAGS = {"-y", "--yes", "-q", "--quiet"}


def address(url):
    """Only scheme://host[:port]: userinfo, paths, queries and fragments can all hold tokens."""
    try:
        parts = urllib.parse.urlsplit(str(url or ""))
        host, port = parts.hostname, parts.port
    except ValueError:
        return ""
    if not parts.scheme or not host:
        return ""
    host = f"[{host}]" if ":" in host else host
    return f"{parts.scheme}://{host}" + (f":{port}" if port else "")


def program(command, args=()):
    """The executable's name, plus the script an interpreter runs; never arguments, which can hold keys."""
    try:
        words = shlex.split(str(command or ""))
    except ValueError:
        words = str(command or "").split()
    words += list(args)
    while words and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]) or os.path.basename(words[0]) == "env"):
        words.pop(0)
    if not words:
        return ""
    name = os.path.basename(words[0])
    if name in INTERPRETERS or re.fullmatch(r"python3(\.\d+)?", name):
        rest = [w for w in words[1:] if w not in QUIET_FLAGS]
        if rest and re.fullmatch(r"[\w@.+/~${}-]+", rest[0]) and not rest[0].startswith("-"):
            script = os.path.basename(rest[0].rstrip("/"))
            if script:
                return f"{name} {script}"
    return name


def key_names(value):
    return sorted(str(key) for key in value) if isinstance(value, dict) else []


def truncate(text):
    text = str(text)
    return text if len(text) <= COMMAND_LIMIT else text[:COMMAND_LIMIT - 1] + "…"


def session_projects(root):
    if not root:
        return []
    path = Path(root) / "runtime" / "sessions.db"
    if not path.exists():
        return []
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
        try:
            return [row[0] for row in db.execute("SELECT cwd FROM sessions WHERE cwd IS NOT NULL GROUP BY cwd "
                                                  "ORDER BY max(last_ts) DESC LIMIT ?", (PROJECT_LIMIT,))]
        finally:
            db.close()
    except sqlite3.Error:
        return []


def toml_tables(text, prefix):
    """The [prefix.name] tables of a TOML file, for Pythons without tomllib. Strings, numbers,
    booleans and flat arrays only; subtables such as [prefix.name.env] give their key names."""
    tables, current, sub = {}, None, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        header = re.fullmatch(r"\[([^\[\]]+)\]", line)
        if header:
            parts = [p.strip().strip('"') for p in re.findall(r'"[^"]*"|[^.]+', header.group(1))]
            current = sub = None
            if len(parts) >= 2 and parts[0] == prefix:
                current = tables.setdefault(parts[1], {})
                if len(parts) > 2:
                    sub = current.setdefault(parts[2], {})
            continue
        if current is None or "=" not in line:
            continue
        key, value = (s.strip() for s in line.split("=", 1))
        key = key.strip('"')
        if sub is not None:
            sub[key] = None
            continue
        current[key] = toml_value(value)
    return tables


def toml_value(value):
    if value.startswith('"'):
        match = re.match(r'"((?:[^"\\]|\\.)*)"', value)
        return match.group(1) if match else value
    if value.startswith("'"):
        return value[1:].split("'", 1)[0]
    if value.startswith("["):
        return [toml_value(item.strip()) for item in re.findall(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[^,\[\]\s][^,\[\]]*', value)]
    if value.startswith("{"):
        return {k.strip().strip('"'): None for k in re.findall(r'([\w"-]+)\s*=', value)}
    if value in ("true", "false"):
        return value == "true"
    return value.split("#", 1)[0].strip()


def codex_servers():
    path = codex_home() / "config.toml"
    try:
        text = path.read_text()
    except OSError:
        return {}
    try:
        import tomllib
        return (tomllib.loads(text).get("mcp_servers") or {})
    except ImportError:
        return toml_tables(text, "mcp_servers")
    except ValueError:
        return {}


def mcp_servers(root=None):
    home = Path.home()
    servers = []
    config = read_json(home / ".claude.json") or {}
    for name, value in (config.get("mcpServers") or {}).items():
        servers.append(server(name, "user", value))
    projects = config.get("projects") if isinstance(config.get("projects"), dict) else {}
    for project, data in projects.items():
        for name, value in ((data or {}).get("mcpServers") or {}).items() if isinstance(data, dict) else ():
            servers.append(server(name, "project", value, project))
    for project in session_projects(root):
        for name, value in ((read_json(Path(project) / ".mcp.json") or {}).get("mcpServers") or {}).items():
            servers.append(server(name, "project", value, project))
    for name, value in codex_servers().items():
        servers.append(server(name, "codex", value))
    return servers


def hooks():
    home = Path.home()
    found = []
    sources = [("claude", home / ".claude/settings.json"), ("claude", home / ".claude/settings.local.json"), ("codex", codex_home() / "hooks.json")]
    for agent, path in sources:
        settings = read_json(path) or {}
        events = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
        for event, groups in events.items():
            for group in groups if isinstance(groups, list) else ():
                if not isinstance(group, dict):
                    continue
                for handler in group.get("hooks") or ():
                    if isinstance(handler, dict):
                        found.append(hook(agent, path, event, group.get("matcher"), handler.get("command"), handler.get("url")))
        line = settings.get("statusLine")
        if isinstance(line, dict) and line.get("command"):
            found.append(hook(agent, path, "statusLine", None, line["command"]))
    return found


def hook(agent, path, event, matcher, command, url=None):
    command = str(command or "")
    mark = next((label for marker, label in MARKS.items() if marker in command), None)
    shown = program(command) if command else address(url)
    return {"agent": agent, "file": str(path).replace(str(Path.home()), "~", 1), "event": str(event),
            "matcher": str(matcher) if matcher else None, "command": truncate(shown), "sideA": mark}


def frontmatter_name(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            if stream.readline().strip() != "---":
                return None
            for _, line in zip(range(40), stream):
                if line.strip() == "---":
                    break
                if line.startswith("name:"):
                    return line[5:].strip().strip("\"'") or None
    except OSError:
        return None
    return None


def skills_in(folder, source):
    found = []
    try:
        entries = sorted(Path(folder).iterdir())
    except OSError:
        return found
    for entry in entries:
        if entry.name.startswith("."):
            continue
        skill = entry.resolve() / "SKILL.md"
        if skill.is_file():
            found.append({"name": frontmatter_name(skill) or entry.name, "source": source})
    return found


def plugin_skills():
    home = Path.home()
    enabled = (read_json(home / ".claude/settings.json") or {}).get("enabledPlugins") or {}
    installed = (read_json(home / ".claude/plugins/installed_plugins.json") or {}).get("plugins") or {}
    found = []
    for plugin, installs in installed.items():
        if not enabled.get(plugin) or not isinstance(installs, list):
            continue
        for install in installs[:1]:
            path = install.get("installPath") if isinstance(install, dict) else None
            if path:
                found += skills_in(Path(path) / "skills", plugin.split("@")[0])
    return found


def skills():
    home = Path.home()
    found, seen = [], set()
    for skill in skills_in(home / ".claude/skills", "claude") + skills_in(home / ".agents/skills", "agents") + plugin_skills():
        key = (skill["name"], skill["source"] if skill["source"] not in ("claude", "agents") else "")
        if key not in seen:
            seen.add(key)
            found.append(skill)
    return found


def agents():
    try:
        files = sorted((Path.home() / ".claude/agents").glob("*.md"))
    except OSError:
        return []
    return [{"name": frontmatter_name(path.resolve()) or path.stem} for path in files]


def overview(root=None):
    return {"tools": [tool("claude"), tool("codex")], "mcpServers": mcp_servers(root), "hooks": hooks(),
            "skills": skills(), "agents": agents()}


STATUS = (("✓", "connected"), ("connected", "connected"), ("✗", "failed"), ("failed", "failed"),
          ("needs auth", "needs-auth"), ("pending", "pending"))


def parse_mcp_list(text):
    servers = {}
    for line in text.splitlines():
        head, separator, status = line.strip().rpartition(" - ")
        name = head.rpartition(": ")[0]
        if not separator or not name:
            continue
        status = status.casefold()
        servers[name] = next((value for needle, value in STATUS if needle in status), "unknown")
    return servers


def mcp_health():
    binary = find_binary("claude")
    if not binary:
        raise ValueError("Install Claude Code first: https://code.claude.com/docs/en/setup")
    try:
        result = subprocess.run([binary, "mcp", "list"], capture_output=True, text=True, timeout=30,
                                stdin=subprocess.DEVNULL, cwd=Path.home())
    except subprocess.TimeoutExpired:
        raise ValueError("Checking MCP servers took longer than 30 seconds.") from None
    return {"servers": parse_mcp_list(result.stdout)}
