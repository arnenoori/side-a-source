#!/usr/bin/env python3
"""A stand-in for Claude Code that a headless host can run under tmux: it draws the prompt the way `Hosting` reads it,
registers itself in ~/.claude/sessions/<pid>.json and writes its conversation to ~/.claude/projects/<slug>/<id>.jsonl (appending to
the one that is there when it resumes, or copying it under a new id with --fork-session), so
`sidead` sees a live session, a transcript that grows and a status that goes busy and idle. It never talks to a model: a
turn takes FAKE_CLAUDE_WORK seconds (default 1) and answers `Echo: <what was typed>`.

    fake-claude-live.py [--resume ID [--fork-session]] [other flags] [-- PROMPT]
"""
import json
import os
import re
import select
import sys
import time
import tty
import uuid
from pathlib import Path

WORK = float(os.environ.get("FAKE_CLAUDE_WORK", "1"))
args = sys.argv[1:]
first = args[args.index("--") + 1] if "--" in args and args.index("--") + 1 < len(args) else None
resumed = args[args.index("--resume") + 1] if "--resume" in args and args.index("--resume") + 1 < len(args) else None
forked = resumed is not None and "--fork-session" in args
session = resumed if resumed and not forked else str(uuid.uuid4())
cwd = os.getcwd()
home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
registry = home / "sessions" / f"{os.getpid()}.json"
# Claude Code names a project folder for its path with every character that is not a letter or digit made "-".
transcript = home / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", cwd) / f"{session}.jsonl"
registry.parent.mkdir(parents=True, exist_ok=True)
transcript.parent.mkdir(parents=True, exist_ok=True)
original = transcript.parent / f"{resumed}.jsonl"
if forked and original.exists():
    # A fork starts with the conversation so far, as its own.
    with open(original) as source, open(transcript, "w") as copy:
        for line in source:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            copy.write(json.dumps({**entry, "sessionId": session}) + "\n")
if os.environ.get("FAKE_CLAUDE_STARTS"):
    # One line per start, so a test can tell what it was started with and how many times.
    with open(os.environ["FAKE_CLAUDE_STARTS"], "a") as starts:
        starts.write(json.dumps({"args": args, "cwd": cwd, "home": str(home)}) + "\n")

echoed, buffer, busy_until, pending = [], "", 0.0, None


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".%03dZ" % (time.time() * 1000 % 1000)


def register(status):
    registry.write_text(json.dumps({"pid": os.getpid(), "sessionId": session, "cwd": cwd, "status": status, "kind": "interactive",
                                    "startedAt": int(START * 1000), "statusUpdatedAt": int(time.time() * 1000), "version": "2.1.303"}))


def write(entry):
    with open(transcript, "a") as out:
        out.write(json.dumps({"sessionId": session, "cwd": cwd, "timestamp": now(), **entry}) + "\n")


def draw():
    put = lambda text: os.write(1, text.encode())
    put("\x1b[2J\x1b[H\x1b[?2004h")
    for line in echoed[-5:]:
        put("❯ " + line + "\r\n")
    if time.time() < busy_until:
        put("✻ Working… (esc to interrupt)\r\n")
    put("─" * 40 + "\r\n")
    put("❯ " + buffer if buffer else "❯ \x1b[2mTry \"refactor <filepath>\"\x1b[0m")
    put("\r\n" + "─" * 40 + "\r\n  \x1b[2m⏵⏵ auto mode on (shift+tab to cycle)\x1b[0m")


def submit(text):
    global busy_until, pending
    echoed.append(text.split("\n")[0])
    write({"type": "user", "uuid": str(uuid.uuid4()), "message": {"role": "user", "content": text}})
    busy_until = time.time() + WORK
    pending = text
    register("busy")


def finish():
    global pending
    write({"type": "assistant", "uuid": str(uuid.uuid4()),
           "message": {"id": "m-" + str(uuid.uuid4()), "model": "claude-opus-5-5", "content": [{"type": "text", "text": "Echo: " + pending}]}})
    pending = None
    register("idle")


START = time.time()
register("idle")
tty.setraw(0)
draw()
if first:
    submit(first)
    draw()
data = b""
try:
    while True:
        working = time.time() < busy_until
        ready, _, _ = select.select([0], [], [], 0.2 if working else 1.0)
        if pending is not None and time.time() >= busy_until:
            finish()
            draw()
        if not ready:
            continue
        chunk = os.read(0, 65536)
        if not chunk:
            break
        data += chunk
        while data:
            if data.startswith(b"\x1b[200~"):
                end = data.find(b"\x1b[201~")
                if end < 0:
                    break
                buffer += data[6:end].decode().replace("\r", "\n")
                data = data[end + 6:]
            elif data[:1] == b"\r":
                data = data[1:]
                if buffer and pending is None:
                    submit(buffer)
                    buffer = ""
            elif data[:1] == b"\x1b":
                data = data[1:]
                if pending is not None:
                    busy_until = 0.0
            else:
                buffer += data[:1].decode(errors="replace")
                data = data[1:]
        draw()
finally:
    registry.unlink(missing_ok=True)
