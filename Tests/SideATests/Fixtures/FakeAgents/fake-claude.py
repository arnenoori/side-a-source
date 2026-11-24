#!/usr/bin/env python3
"""A stand-in for Claude Code's prompt in a tmux pane, drawn as `Hosting` reads it (2.1.303).

The composer is `❯` and a no-break space between two rule lines, a dim placeholder when empty, the mode footer under it.
Enter submits (noted in __OUT__ as repr) and works for __WORK__ seconds; Enter while working queues the text, shown
under the spinner, and the turn takes it when it ends. Esc stops the turn and puts what was queued back into the
prompt, as Claude Code does. A long or multi-line paste shows as `[Pasted text #1 +N lines]`.
"""
import os
import select
import sys
import time
import tty

OUT, WORK = "__OUT__", float("__WORK__")
open(OUT + ".pid", "w").write(str(os.getpid()))
tty.setraw(0)
echoed, queued, buffer, shown, busy_until = [], [], "", None, 0.0


def note(line):
    with open(OUT, "a") as out:
        out.write(line + "\n")


def placeholder(text):
    return "[Pasted text #1 +%d lines]" % (text.count("\n") + 1) if "\n" in text or len(text) > 200 else None


def draw():
    write = lambda text: os.write(1, text.encode())
    write("\x1b[2J\x1b[H\x1b[?2004h")
    for line in echoed[-5:]:
        write("❯ " + line + "\r\n")
    if time.time() < busy_until:
        write("✻ Working… (esc to interrupt)\r\n")
        for line in queued:
            write("  ⎿ " + line.split("\n")[0] + "\r\n")
    write("─" * 40 + "\r\n")
    write("❯ " + (shown or buffer) if (shown or buffer) else "❯ \x1b[2mTry \"refactor <filepath>\"\x1b[0m")
    write("\r\n" + "─" * 40 + "\r\n  \x1b[2m⏵⏵ auto mode on (shift+tab to cycle)\x1b[0m")


def submit(text):
    global busy_until
    note(repr(text))
    echoed.append(text.split("\n")[0])
    busy_until = time.time() + WORK


draw()
data = b""
while True:
    working = time.time() < busy_until
    ready, _, _ = select.select([0], [], [], 0.2 if working else None)
    if working and time.time() >= busy_until:
        # The turn ended by itself: what waited goes as the next prompt.
        if queued:
            submit("\n".join(queued))
            queued = []
        draw()
    if not ready:
        continue
    chunk = os.read(0, 65536)
    if not chunk:
        sys.exit(1)
    data += chunk
    while data:
        if data.startswith(b"\x1b[200~"):
            end = data.find(b"\x1b[201~")
            if end < 0:
                break
            text = data[6:end].decode().replace("\r", "\n")
            buffer += text
            shown = placeholder(buffer)
            data = data[end + 6:]
        elif data[:1] == b"\r":
            data = data[1:]
            if not buffer:
                continue
            if time.time() < busy_until:
                queued.append(buffer)
            else:
                submit(buffer)
            buffer, shown = "", None
        elif data[:1] == b"\x7f":
            data = data[1:]
            buffer, shown = buffer[:-1] if not shown else "", None
        elif data[:1] == b"\x1b":
            data = data[1:]
            note("ESC")
            if time.time() < busy_until:
                busy_until = 0.0
                if queued:
                    buffer = "\n".join(queued + ([buffer] if buffer else []))
                    shown, queued = placeholder(buffer), []
        else:
            buffer += data[:1].decode(errors="replace")
            data = data[1:]
    draw()
