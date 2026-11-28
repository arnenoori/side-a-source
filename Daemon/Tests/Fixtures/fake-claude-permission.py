#!/usr/bin/env python3
"""A stand-in for Claude Code at the moment it wants a tool's permission: it never talks to a model, and it is not the real CLI.
It reads the PermissionRequest hooks from settings.json (in CLAUDE_CONFIG_DIR, else ~/.claude) and runs each hook command the
way Claude Code does: through `sh -c`, with the request as JSON on standard input, shaped as Claude Code shapes it. A hook's
decision wins (a deny over an allow); with none, the real CLI would ask in its own terminal, and this says so.

    fake-claude-permission.py --command "npm test" [--tool Bash] [--cwd DIR] [--session ID] [--timeout SECONDS]

Prints one line, `RESULT {"outcome": "allow" | "deny" | "ask", "message": ..., "hooks": N, "seconds": S}`.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--tool", default="Bash")
parser.add_argument("--command", required=True)
parser.add_argument("--cwd", default=os.getcwd())
parser.add_argument("--session", default=str(uuid.uuid4()))
parser.add_argument("--timeout", type=float, default=60)
args = parser.parse_args()

home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
try:
    settings = json.loads((home / "settings.json").read_text())
except (OSError, ValueError):
    settings = {}

request = {
    "session_id": args.session,
    "transcript_path": str(home / "projects" / args.cwd.replace("/", "-") / f"{args.session}.jsonl"),
    "cwd": args.cwd,
    "permission_mode": "default",
    "hook_event_name": "PermissionRequest",
    "tool_name": args.tool,
    "tool_input": {"command": args.command, "description": "Asked for by the stand-in"},
    "permission_suggestions": [{"type": "addRules", "behavior": "allow", "destination": "localSettings",
                                "rules": [{"toolName": args.tool, "ruleContent": args.command}]}],
}

started = time.time()
hooks = []
for group in settings.get("hooks", {}).get("PermissionRequest", []):
    matcher = group.get("matcher") or "*"
    if matcher != "*" and not re.fullmatch(matcher, args.tool):
        continue
    hooks += [hook for hook in group.get("hooks", []) if hook.get("type") == "command"]

decisions = []
for hook in hooks:
    try:
        run = subprocess.run(["sh", "-c", hook["command"]], input=json.dumps(request), capture_output=True, text=True,
                             timeout=min(args.timeout, hook.get("timeout", args.timeout)), check=False)
    except subprocess.TimeoutExpired:
        continue
    try:
        decision = json.loads(run.stdout)["hookSpecificOutput"]["decision"]
    except (ValueError, KeyError, TypeError):
        continue
    decisions.append(decision)

verdict = next((d for d in decisions if d.get("behavior") == "deny"), None) or next((d for d in decisions if d.get("behavior") == "allow"), None)
result = {"outcome": verdict["behavior"] if verdict else "ask", "message": (verdict or {}).get("message"), "hooks": len(hooks),
          "seconds": round(time.time() - started, 2)}
print("RESULT " + json.dumps(result), flush=True)
sys.exit(0)
