#!/usr/bin/env python3
"""The slowest bridge calls and remote routes, and every main-thread stall, from Side A's own log (category perf).

    scripts/perf-summary.py                 the last day
    scripts/perf-summary.py --hours 3       a shorter window
    scripts/perf-summary.py --input FILE    a saved `log show --style ndjson --signpost` export, e.g. from another Mac

Signpost intervals give every call's time while the unified log still holds them; the "slow:" lines (a second or
more) are kept longer, so a quiet day still shows what stood out. Nothing here reads arguments or bodies: the app
logs names only.
"""
import argparse
from collections import defaultdict
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

SUBSYSTEM = "com.arnenoori.sidea"
# Routes that wait on purpose: a pairing attempt held open for the person at the Mac.
WAITS = ("v1/pair/{attempt}/wait",)
SLOW = re.compile(r"^slow: (bridge|route) (.+) (\d+) ms$")
STALL = re.compile(r"^stall: main thread blocked (\d+) ms, during (.*)$")


def read(hours, source):
    if source:
        lines = Path(source).read_text().splitlines()
    else:
        command = ["/usr/bin/log", "show", "--last", f"{hours}h", "--signpost", "--style", "ndjson",
                   "--predicate", f'subsystem == "{SUBSYSTEM}" AND category == "perf"']
        try:
            lines = subprocess.run(command, capture_output=True, text=True, check=True).stdout.splitlines()
        except (OSError, subprocess.CalledProcessError) as error:
            sys.exit(f"perf-summary: couldn't read the log: {error}")
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue  # log show's trailing summary line
        if isinstance(entry, dict):
            yield entry


def when(stamp):
    """log show's "2026-11-23 10:00:00.123456-0800"."""
    try:
        return datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z")
    except ValueError:
        return None


def gather(entries):
    """Durations in ms by (kind, name), from signposts and slow lines, and the stalls as (time, ms, during)."""
    times, stalls, begun, slow_lines = defaultdict(list), [], {}, defaultdict(list)
    for entry in entries:
        message = entry.get("eventMessage") or ""
        stamp = entry.get("timestamp") or ""
        kind = entry.get("signpostName")
        if entry.get("signpostType") == "begin" and kind in ("bridge", "route"):
            begun[(kind, entry.get("signpostID"))] = (message, when(stamp))
        elif entry.get("signpostType") == "end" and kind in ("bridge", "route"):
            start = begun.pop((kind, entry.get("signpostID")), None)
            end = when(stamp)
            if start and start[1] and end:
                times[(kind, start[0])].append((end - start[1]).total_seconds() * 1000)
        elif match := SLOW.match(message):
            slow_lines[(match.group(1), match.group(2))].append(float(match.group(3)))
        elif match := STALL.match(message):
            stalls.append((stamp[:19], int(match.group(1)), match.group(2)))
    # Signposts the log already dropped leave only the slow lines; where both exist the signposts are the whole set.
    for key, values in slow_lines.items():
        if not times.get(key) or max(times[key]) < min(values):
            times[key] = values
    return times, stalls


def table(times, kind, limit):
    rows = []
    for (each, name), values in times.items():
        if each != kind or name in WAITS or name.endswith(WAITS):
            continue
        ordered = sorted(values)
        rows.append((ordered[-1], ordered[len(ordered) // 2], len(ordered), name))
    rows.sort(reverse=True)
    if not rows:
        return f"No {kind} calls in the log.\n"
    out = f"{'slowest':>9} {'median':>8} {'calls':>6}  {kind}\n"
    for slowest, median, count, name in rows[:limit]:
        out += f"{slowest:>7.0f}ms {median:>6.0f}ms {count:>6}  {name}\n"
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hours", type=int, default=24)
    parser.add_argument("--input", help="an ndjson export of `log show --signpost`")
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args()
    times, stalls = gather(read(args.hours, args.input))
    print(f"Side A performance, last {args.hours} h\n")
    print(table(times, "bridge", args.top))
    print(table(times, "route", args.top))
    if stalls:
        print(f"{len(stalls)} main-thread stall(s) of 2 s or more:")
        for stamp, ms, during in sorted(stalls, key=lambda stall: -stall[1])[:args.top]:
            print(f"  {stamp}  {ms / 1000:.1f} s  during {during}")
    else:
        print("No main-thread stalls of 2 s or more.")


if __name__ == "__main__":
    main()
