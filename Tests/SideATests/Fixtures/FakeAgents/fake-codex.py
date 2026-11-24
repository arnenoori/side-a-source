#!/usr/bin/env python3
"""A stand-in for Codex's prompt in a tmux pane, drawn as `Hosting` reads it: `› ` for the composer and for echoed
prompts, an escape sequence between the glyph and a dim placeholder when empty.

Enter submits (noted in __OUT__ as repr) and works for __WORK__ seconds; while working, Enter steers (noted STEER) and
Tab queues, shown under the spinner and sent when the turn ends. Esc stops the turn and puts what was queued back into
the prompt. A long or multi-line paste shows as `[Pasted text #1 +N lines]`.
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
        write("› " + line + "\r\n\r\n")
    if time.time() < busy_until:
        write("• Working (esc to interrupt)\r\n")
        for line in queued:
            write("  ↳ " + line.split("\n")[0] + "\r\n")
    write("\r\n")
    write("› " + (shown or buffer) if (shown or buffer) else "›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m")
    write("\r\n\r\n  \x1b[2m⏎ send   ⇥ queue   ? for shortcuts\x1b[0m")


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
            buffer += data[6:end].decode().replace("\r", "\n")
            shown = placeholder(buffer)
            data = data[end + 6:]
        elif data[:1] in (b"\r", b"\t"):
            key, data = data[:1], data[1:]
            if not buffer:
                continue
            if time.time() >= busy_until:
                submit(buffer)
            elif key == b"\t":
                queued.append(buffer)
            else:
                note("STEER " + repr(buffer))
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
