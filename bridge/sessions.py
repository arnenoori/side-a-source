"""Session search for Side A: an incremental SQLite FTS5 index over Claude Code and Codex
transcripts, the live session registry, and one session's messages for the viewer.

Transcripts are append-only, so each file is read from where the last run stopped. A fork
copies its parent's history with `forkedFrom` on every copied entry; those copies are not
indexed again, and the last one is where the fork branched off. Nothing is written outside
Side A's own folder; Codex's state database is opened read-only.
"""
from __future__ import annotations
import base64
import binascii
import bisect
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, session TEXT, offset INTEGER, size INTEGER, mtime REAL, state TEXT);
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, agent TEXT, path TEXT, cwd TEXT, branch TEXT, title TEXT,
    title_source TEXT, first_prompt TEXT, model TEXT, first_ts REAL, last_ts REAL, cost REAL, tokens INTEGER,
    prompts INTEGER, messages INTEGER, forked_from TEXT, fork_point TEXT, pr_url TEXT, automated INTEGER DEFAULT 0);
CREATE VIRTUAL TABLE IF NOT EXISTS msgs USING fts5(text, session UNINDEXED, uuid UNINDEXED, role UNINDEXED,
    ts UNINDEXED, tokenize='trigram');
CREATE TABLE IF NOT EXISTS rows(id INTEGER PRIMARY KEY, session TEXT, role TEXT);
CREATE INDEX IF NOT EXISTS rows_session ON rows(session);
CREATE TABLE IF NOT EXISTS views(session TEXT, seq INTEGER, uuids TEXT, data TEXT, rev INTEGER,
    PRIMARY KEY(session, seq)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS views_rev ON views(session, rev);
CREATE TABLE IF NOT EXISTS view_state(session TEXT PRIMARY KEY, path TEXT, offset INTEGER, head TEXT,
    count INTEGER, used REAL, generation TEXT, rev INTEGER, calls TEXT, agent_id TEXT);
CREATE TABLE IF NOT EXISTS images(id TEXT NOT NULL, session TEXT NOT NULL, agent_id TEXT, path TEXT NOT NULL,
    line_offset INTEGER NOT NULL, line_length INTEGER NOT NULL, block INTEGER NOT NULL, data_offset INTEGER,
    data_length INTEGER, file TEXT, uuid TEXT, call_id TEXT, tool TEXT, source TEXT, mime TEXT, bytes INTEGER,
    width INTEGER, height INTEGER, ts REAL, inherited INTEGER DEFAULT 0,
    PRIMARY KEY(path, line_offset, block)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS images_id ON images(id);
CREATE INDEX IF NOT EXISTS images_session ON images(session, ts);
"""
# Reading an unindexed FTS column reads the whole row, message text included, so `rows` maps each
# message to its session; matching and deleting never touch the text. A version 3 index gets it at the
# start of the next index pass; until then search reads the session from the FTS row.
VERSION = 6
TITLE_RANK = {"custom": 0, "codex": 1, "ai": 2, "agent": 3, "summary": 4, "prompt": 5}
TEXT_LIMIT = 8000
SKIP = (b'"toolUseResult"', b'"type":"attachment"', b'"type":"queue-operation"', b'"type":"file-history-',
        b'"type":"atis-latch"', b'"type":"permission-mode"', b'"type":"mode"', b'"type":"last-prompt"',
        b'"type":"api-request-blob"')
# The viewer reads tool results and queued prompts, so it skips less than the search index.
VIEW_SKIP = SKIP[2:]


def connect(root):
    path = Path(root) / "runtime" / "sessions.db"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(path, timeout=30)
    os.chmod(path, 0o600)
    db.execute("PRAGMA journal_mode=WAL")
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version not in (3, 4, 5, VERSION):
        db.executescript("DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS sessions; DROP TABLE IF EXISTS msgs; DROP TABLE IF EXISTS rows; "
                         "DROP TABLE IF EXISTS views; DROP TABLE IF EXISTS view_state; DROP TABLE IF EXISTS images;")
        db.execute(f"PRAGMA user_version={VERSION}")
    elif version < VERSION and "rev" not in {row[1] for row in db.execute("PRAGMA table_info(views)")}:
        # 4 to 5: the viewer's cache gains revisions. It's only a cache, so it starts over; the index stays.
        db.executescript("DROP TABLE IF EXISTS views; DROP TABLE IF EXISTS view_state;")
    db.executescript(SCHEMA)
    if version in (4, 5):
        # 6 shows follow-ups that reached a busy session: the search index stays, conversations are read again.
        db.executescript(f"DELETE FROM views; DELETE FROM view_state; PRAGMA user_version={VERSION};")
    return db


def upgrade(db):
    if db.execute("PRAGMA user_version").fetchone()[0] == 3:
        db.execute("DELETE FROM rows")
        db.execute("INSERT INTO rows(id, session, role) SELECT rowid, session, role FROM msgs")
        db.execute("DELETE FROM views")
        db.execute("DELETE FROM view_state")
        db.execute(f"PRAGMA user_version={VERSION}")
        db.commit()


def sources(db):
    """The FROM clause and session column for matching, with or without the row map."""
    if db.execute("PRAGMA user_version").fetchone()[0] >= 4:
        return "msgs m CROSS JOIN rows r ON r.id = m.rowid", "r.session"
    return "msgs m", "m.session"


def add_rows(db, rows):
    for row in rows:
        rowid = db.execute("INSERT INTO rows(session, role) VALUES(?,?)", (row[1], row[3])).lastrowid
        db.execute("INSERT INTO msgs(rowid, text, session, uuid, role, ts) VALUES(?,?,?,?,?,?)", (rowid, *row))


def delete_rows(db, session, role=None):
    where, args = ("session=? AND role=?", (session, role)) if role else ("session=?", (session,))
    db.execute(f"DELETE FROM msgs WHERE rowid IN (SELECT id FROM rows WHERE {where})", args)
    db.execute(f"DELETE FROM rows WHERE {where}", args)
    if not role:
        db.execute("DELETE FROM views WHERE session=?", (session,))
        db.execute("DELETE FROM view_state WHERE session=?", (session,))


def epoch(value):
    if isinstance(value, (int, float)):
        return float(value) / (1000 if value > 1e11 else 1)
    try:
        from datetime import datetime
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text", "") for part in content or [] if isinstance(part, dict) and part.get("type") in ("text", "input_text", "output_text"))


COMMAND = re.compile(r"<command-name>(.*?)</command-name>.*?(?:<command-args>(.*?)</command-args>)?", re.S)


# A reply from Side A reaches Claude Code as hook feedback (a Stop follow-up, or the inbox): the user's words follow
# island_hook's preamble inside the task notification.
SIDE_A_FEEDBACK = re.compile(r"(?:The user sent you their next request from Side A's island|The user sent you this from Side A):\n\n(.*?)\s*(?:</system-reminder>|\Z)", re.S)


def prompt_text(text):
    """What the user typed: slash commands as `/name args`; Claude Code's own injected notes are dropped."""
    text = text.strip()
    match = COMMAND.search(text)
    if match:
        return f"{match.group(1)} {match.group(2) or ''}".strip()
    if text.startswith("<task-notification>"):
        match = SIDE_A_FEEDBACK.search(text)
        return match.group(1).strip() if match else ""
    if text.startswith(("<local-command", "<system-reminder>", "Caveat:", "<bash-", "<task-notification>", "[Request interrupted")):
        return ""
    return text


def tool_summary(name, value):
    value = value if isinstance(value, dict) else {}
    for key in ("command", "file_path", "path", "pattern", "url", "query", "description", "prompt"):
        if isinstance(value.get(key), str) and value[key].strip():
            return f"{name}: {value[key].strip()[:400]}"
    return name


def claude_files():
    folders = [Path.home() / ".claude" / "projects"]
    for folder in folders:
        if folder.is_dir():
            yield from folder.glob("*/*.jsonl")
            yield from folder.glob("*/*/subagents/*.jsonl")


def codex_homes(root=None):
    """~/.codex and the folder every Side A Codex profile shares (its `sessions` is a link to it), each once."""
    homes, seen = [Path.home() / ".codex"] + ([Path(root) / "codex-conversations"] if root else []), set()
    for home in homes:
        real = os.path.realpath(home)
        if real not in seen:
            seen.add(real)
            yield home


def codex_files(root=None):
    for home in codex_homes(root):
        if (home / "sessions").is_dir():
            yield from (home / "sessions").glob("**/rollout-*.jsonl")


def is_codex_path(path):
    return Path(path).name.startswith("rollout-") and ("/.codex/sessions/" in str(path) or "/codex-conversations/sessions/" in str(path))


def codex_threads(root=None):
    threads = {}
    for home in codex_homes(root):
        path = home / "state_5.sqlite"
        if not path.exists():
            continue
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
            columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
            name = "name" if "name" in columns else "NULL"
            rows = db.execute(f"SELECT id, {name}, title, tokens_used, git_branch FROM threads").fetchall()
            db.close()
        except sqlite3.Error:
            continue
        threads.update({row[0]: {"title": (row[1] or row[2] or "").strip(), "tokens": row[3] or 0, "branch": row[4]} for row in rows})
    return threads


class Session:
    def __init__(self, row):
        self.row = dict(row)

    def title(self, text, source):
        text = " ".join((text or "").split())[:200]
        if not text:
            return
        current = self.row.get("title_source")
        if current is None or TITLE_RANK[source] <= TITLE_RANK.get(current, 9):
            self.row["title"], self.row["title_source"] = text, source

    def seen(self, ts):
        if ts:
            self.row["first_ts"] = min(self.row.get("first_ts") or ts, ts)
            self.row["last_ts"] = max(self.row.get("last_ts") or ts, ts)


def save(db, session):
    row = session.row
    columns = ["id", "agent", "path", "cwd", "branch", "title", "title_source", "first_prompt", "model", "first_ts", "last_ts",
               "cost", "tokens", "prompts", "messages", "forked_from", "fork_point", "pr_url", "automated"]
    db.execute(f"INSERT OR REPLACE INTO sessions({','.join(columns)}) VALUES({','.join('?' * len(columns))})",
               [row.get(c) if c != "automated" else int(row.get(c) or 0) for c in columns])
    delete_rows(db, row["id"], "title")
    if row.get("title"):
        add_rows(db, [(row["title"], row["id"], "", "title", row.get("last_ts"))])


def load(db, session_id, agent, path):
    found = db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
    names = [d[0] for d in db.execute("SELECT * FROM sessions LIMIT 0").description]
    row = dict(zip(names, found)) if found else {"id": session_id, "agent": agent, "path": str(path), "prompts": 0, "messages": 0, "tokens": 0}
    return Session(row)


# Image bytes stay in the transcripts. The index records where each one starts, so the app can seek
# and read it; nothing here ever writes base64 anywhere else.
# Only the short header is matched by pattern; the base64 after it runs to the next quote, found with
# bytes.find, which is several times faster than a regex over megabytes.
SPAN = re.compile(rb'"type":"base64","(?:media_type":"([a-z0-9/+.-]+)","data":"|data":")')
MEDIA_AFTER = re.compile(rb'","media_type":"([a-z0-9/+.-]+)"')
DATA_URL = re.compile(rb'"(?:image_url|result)":"(?:data:(image/[a-z0-9+.-]+);base64,)?([A-Za-z0-9+/=]{256,})"')
BLANK_KEYS = (b'"data":"', b'"base64":"', b'"image_url":"', b'"result":"')  # Claude's two, then Codex's
BIG_LINE = 65536
BASE64 = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
TOOL_USE = re.compile(rb'"type":"tool_use","id":"([^"]+)","name":"([^"]+)"')
IMAGE_MARKERS = (b'"type":"base64"', b'data:image/', b'"image_gen.generation"')
FILE_MARKERS = (b'"ImageView"', b'"local_image"', b'"savedPath":"')
SIGNATURES = ((b'\x89PNG\r\n\x1a\n', "image/png"), (b'\xff\xd8\xff', "image/jpeg"), (b'GIF87a', "image/gif"),
              (b'GIF89a', "image/gif"), (b'RIFF', "image/webp"))
FILE_LIMIT = 50 << 20


def blank(line):
    """The line with every base64 image span emptied, so a 3 MB screenshot line parses like a short one."""
    if not any(marker in line for marker in IMAGE_MARKERS):
        return line
    cuts = []
    for key in BLANK_KEYS[:2] if b'"type":"base64"' in line else BLANK_KEYS[2:]:
        at = line.find(key)
        while at >= 0:
            start = at + len(key)
            end = line.find(b'"', start)
            if end < 0:
                break
            if end - start >= 256:
                body = start
                if line.startswith(b"data:image/", start):
                    body = line.find(b",", start, start + 64) + 1 or start
                # Its ends are enough to tell base64 from a long string of text.
                if not (line[body:body + 512] + line[end - 64:end]).translate(None, BASE64):
                    cuts.append((start, end))
            at = line.find(key, end)
    if not cuts:
        return line
    pieces, last = [], 0
    for start, end in sorted(cuts):
        pieces.append(line[last:start])
        last = end
    return b"".join(pieces) + line[last:]


def parse(line):
    try:
        entry = json.loads(blank(line))
    except ValueError:
        return None
    return entry if isinstance(entry, dict) else None


def sniff(data):
    for signature, mime in SIGNATURES:
        if data.startswith(signature) and (mime != "image/webp" or data[8:12] == b"WEBP"):
            return mime
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"heis", b"hevc"):
        return "image/heic"
    return None


def image_size(data):
    """Width and height from the header of a PNG, JPEG, GIF or WebP; (None, None) for anything else."""
    import struct
    try:
        if data.startswith(b'\x89PNG') and data[12:16] == b"IHDR":
            return struct.unpack(">II", data[16:24])
        if data.startswith(b"GIF8"):
            return struct.unpack("<HH", data[6:10])
        if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
            kind = data[12:16]
            if kind == b"VP8 ":
                width, height = struct.unpack("<HH", data[26:30])
                return width & 0x3FFF, height & 0x3FFF
            if kind == b"VP8L":
                bits = int.from_bytes(data[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            if kind == b"VP8X":
                return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
        if data.startswith(b"\xff\xd8"):
            at = 2
            while at + 9 < len(data):
                if data[at] != 0xFF:
                    at += 1
                    continue
                marker = data[at + 1]
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7 or marker == 0xFF:
                    at += 1 if marker == 0xFF else 2
                    continue
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    height, width = struct.unpack(">HH", data[at + 5:at + 9])
                    return width, height
                at += 2 + struct.unpack(">H", data[at + 2:at + 4])[0]
    except struct.error:
        pass
    return None, None


def describe(data, mime=None):
    """id, mime, bytes, width, height of decoded image bytes."""
    width, height = image_size(data)
    return {"id": hashlib.sha1(data).hexdigest(), "mime": sniff(data) or mime or "application/octet-stream",
            "bytes": len(data), "width": width, "height": height}


def decode(text):
    try:
        return base64.b64decode(text)
    except (binascii.Error, ValueError):
        return None


def file_image(path):
    """A Codex image that lives in its own file: hashed when it's still there and is an image."""
    try:
        target = Path(path)
        if target.stat().st_size <= FILE_LIMIT:
            with open(target, "rb") as stream:
                data = stream.read(FILE_LIMIT + 1)
            if sniff(data):
                return describe(data)
    except OSError:
        pass
    mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}
    return {"id": hashlib.sha1(f"missing:{path}".encode()).hexdigest(), "mime": mime.get(Path(path).suffix.lower(), "image/png"),
            "bytes": None, "width": None, "height": None}


def image_source(name, result=None):
    if name == "Read" or (isinstance(result, dict) and isinstance(result.get("file"), dict)):
        return "read"
    if (name or "").startswith("mcp__") or isinstance(result, list):
        return "mcp"
    return "other"


def claude_blocks(entry, name_of):
    """Each image block of a Claude line in file order: (source, call id, tool name, block)."""
    blocks = []
    if entry.get("type") == "attachment":
        prompt = (entry.get("attachment") or {}).get("prompt")
        return [("pasted", None, None, part) for part in prompt if isinstance(part, dict) and part.get("type") == "image"] if isinstance(prompt, list) else []
    content = (entry.get("message") or {}).get("content") if entry.get("type") == "user" else None
    for part in content if isinstance(content, list) else []:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "image":
            blocks.append(("pasted", None, None, part))
        elif part.get("type") == "tool_result" and isinstance(part.get("content"), list):
            call = part.get("tool_use_id")
            name = name_of(call)
            source = image_source(name, entry.get("toolUseResult"))
            blocks += [(source, call, name, inner) for inner in part["content"] if isinstance(inner, dict) and inner.get("type") == "image"]
    return blocks


def claude_images(line, at, entry, name_of):
    """The images of one Claude transcript line. The base64 is verbatim in the line, so each block's
    span is found by a byte scan that stops at toolUseResult, which repeats them; when the scan and the
    parsed blocks disagree, the rows say to parse the line instead ("parse mode")."""
    if entry is None or b'"type":"base64"' not in line or b'"type":"api-request-blob"' in line:
        return []
    blocks = claude_blocks(entry, name_of)
    if not blocks:
        return []
    cut = line.find(b'"toolUseResult"')
    spans = []
    for match in SPAN.finditer(line, 0, len(line) if cut < 0 else cut):
        start = match.end()
        end = line.find(b'"', start)
        after = MEDIA_AFTER.match(line, end) if end >= 0 else None
        spans.append((start, end, (match.group(1) or (after.group(1) if after else b"")).decode()))
    whole = None
    if len(spans) != len(blocks):
        try:
            whole = claude_blocks(json.loads(line), name_of)
        except ValueError:
            return []
    found = []
    for block, (source, call, name, part) in enumerate(blocks):
        if whole is None:
            start, end, mime = spans[block]
            data, offset, length = decode(line[start:end]), at + start, end - start
        else:
            raw = (whole[block][3].get("source") or {}) if block < len(whole) else {}
            data, mime, offset, length = decode(raw.get("data") or ""), raw.get("media_type"), None, None
        if not data:
            continue
        found.append({**describe(data, mime), "block": block, "data_offset": offset, "data_length": length, "file": None,
                      "uuid": entry.get("uuid"), "call_id": call, "tool": name, "source": source,
                      "ts": epoch(entry.get("timestamp")), "inherited": int(bool(entry.get("forkedFrom")))})
    return found


def codex_images(line, at, entry, name_of, state=None):
    """The images of one Codex rollout line: data URLs in messages and tool outputs, image generation's
    inline result, and files (ImageView, pasted local_image copies, saved generations)."""
    if entry is None:
        return []
    payload = entry.get("payload") or {}
    kind = payload.get("type")
    item = (payload.get("item") or {}) if kind == "item_completed" else {}
    found = []
    base = {"file": None, "data_offset": None, "data_length": None, "uuid": payload.get("id") or item.get("id"),
            "ts": epoch(entry.get("timestamp")), "inherited": 0}
    if kind == "message":
        meta = {"call_id": None, "tool": None, "source": "pasted"}
    elif kind in ("function_call_output", "custom_tool_call_output"):
        meta = {"call_id": payload.get("call_id"), "tool": name_of(payload.get("call_id")), "source": "screenshot"}
    else:
        meta = {"call_id": item.get("id"), "tool": item.get("kind") or item.get("type"), "source": "other"}
    if b'data:image/' in line or b'"image_gen.generation"' in line:
        for span in DATA_URL.finditer(line):
            data = decode(span.group(2))
            if data and sniff(data):
                found.append({**base, **meta, **describe(data, (span.group(1) or b"").decode() or None), "block": len(found),
                              "data_offset": at + span.start(2), "data_length": span.end(2) - span.start(2)})
    if item.get("type") == "ImageView" and item.get("path"):
        files = [(item["path"], "view")]
    elif item.get("type") == "UserMessage":
        files = [(part.get("path"), "view") for part in item.get("content") or [] if isinstance(part, dict) and part.get("type") == "local_image" and part.get("path")]
        if state is not None:
            # A pasted image is also in the turn's message; that copy outlives the temporary file.
            embedded = state.get("pasted", 0) - state.get("local", 0)
            state["local"] = state.get("local", 0) + len(files)
            files = files[max(embedded, 0):]
    elif item.get("type") == "Extension" and item.get("savedPath") and not found:
        files = [(item["savedPath"], "other")]
    else:
        files = []
    for path, source in files:
        found.append({**base, **meta, **file_image(path), "source": source, "file": path, "block": len(found)})
    return found


def ref(image, name=None):
    """An image as a transcript row names it: no location, no bytes."""
    return {"id": image["id"], "mime": image["mime"], "bytes": image["bytes"], "width": image["width"], "height": image["height"],
            "source": image["source"], "name": name or (os.path.basename(image["file"]) if image.get("file") else None)}


IMAGE_COLUMNS = ("id", "session", "agent_id", "path", "line_offset", "line_length", "block", "data_offset", "data_length", "file",
                 "uuid", "call_id", "tool", "source", "mime", "bytes", "width", "height", "ts", "inherited")


def add_images(db, rows):
    db.executemany(f"INSERT OR REPLACE INTO images({','.join(IMAGE_COLUMNS)}) VALUES({','.join('?' * len(IMAGE_COLUMNS))})",
                   [[row.get(column) for column in IMAGE_COLUMNS] for row in rows])


class Images:
    """Collects the image rows of one transcript as its lines go by, for the indexer and its backfill."""

    def __init__(self, path, agent, session, agent_id, state):
        self.path, self.agent, self.session, self.agent_id, self.state = str(path), agent, session, agent_id, state
        self.rows = []
        self.names = state.setdefault("tools", {})

    def name_of(self, call):
        return self.names.get(call) if call else None

    def remember(self, call, name):
        if call and name:
            self.names[call] = name
            while len(self.names) > 64:
                self.names.pop(next(iter(self.names)))

    def feed(self, line, at, entry=None):
        """Records the line's images; returns the line parsed when it had to be parsed for that."""
        if self.agent == "claude":
            # A tool call long enough to skip here (a big Write) is named from its result's shape instead.
            for match in TOOL_USE.finditer(line) if len(line) <= BIG_LINE and b'"type":"tool_use"' in line else ():
                self.remember(match.group(1).decode(), match.group(2).decode())
            if b'"type":"base64"' in line and b'"type":"api-request-blob"' not in line[:4096]:
                entry = entry if entry is not None else parse(line)
                self.keep(claude_images(line, at, entry, self.name_of), line, at)
            return entry
        if b'"task_started"' in line:
            self.state["pasted"] = self.state["local"] = 0
        if b'"function_call"' in line or b'"custom_tool_call"' in line or b'"role":"user"' in line:
            entry = entry if entry is not None else parse(line)
            payload = (entry or {}).get("payload") or {}
            self.remember(payload.get("call_id"), payload.get("name"))
            if payload.get("type") == "message" and payload.get("role") == "user":
                self.state["pasted"] = self.state.get("pasted", 0) + sum(
                    1 for part in payload.get("content") or [] if isinstance(part, dict) and part.get("type") == "input_image")
        if any(marker in line for marker in IMAGE_MARKERS + FILE_MARKERS):
            entry = entry if entry is not None else parse(line)
            self.keep(codex_images(line, at, entry, self.name_of, self.state), line, at)
        return entry

    def keep(self, found, line, at):
        for image in found:
            self.rows.append({**image, "session": self.session, "agent_id": self.agent_id, "path": self.path,
                              "line_offset": at, "line_length": len(line)})


def image_owner(path, agent, session, state):
    """The session and subagent an image is filed under: subagents' images belong to their parent."""
    path = Path(path)
    if agent == "claude" and path.parent.name == "subagents":
        return path.parent.parent.name, path.stem.removeprefix("agent-")
    if agent == "codex" and state.get("parent"):
        return state["parent"], session
    return session, None


def queued_prompt(entry):
    """What the user typed while Claude worked (an `attachment` line), or None for anything else queued. A follow-up
    from Side A to a busy session is queued as a task notification, which prompt_text reads; it drops the rest."""
    attachment = entry.get("attachment") if entry.get("type") == "attachment" else None
    if not isinstance(attachment, dict) or attachment.get("type") != "queued_command" \
            or attachment.get("commandMode") not in (None, "prompt", "task-notification"):
        return None
    return attachment.get("prompt")


def index_claude(db, path, offset, state):
    """Reads one Claude transcript from `offset`. Subagent files are searchable under their parent.
    Images are indexed in the same pass unless an older index is still being backfilled for this file."""
    sub = path.parent.name == "subagents"
    session_id = path.parent.parent.name if sub else path.stem
    session = load(db, session_id, "claude", path)
    if not sub:
        session.row["path"] = str(path)
    rows = []
    images = Images(path, "claude", *image_owner(path, "claude", session_id, state), state) if state.get("img", 0) == offset else None
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            at = offset
            offset += len(line)
            entry = images.feed(line, at) if images else None
            big = len(line) > BIG_LINE
            # Scanning a screenshot line for every marker costs more than the parse feed already did.
            if (entry is not None and entry.get("type") == "attachment") or (not big and b'"queued_command"' in line):
                entry = entry if entry is not None else parse(line)
                prompt = queued_prompt(entry or {})
                text = prompt_text(text_of(prompt)) if prompt is not None and not entry.get("isSidechain") else ""
                if text and (sub or not entry.get("forkedFrom")):
                    rows.append((text[:TEXT_LIMIT], session_id, entry.get("uuid") or "", "subagent" if sub else "user", epoch(entry.get("timestamp"))))
                continue
            if (b'"toolUseResult"' in line or b'"type":"api-request-blob"' in line[:4096]) if big else any(marker in line for marker in SKIP):
                continue
            entry = entry if entry is not None else parse(line)
            if entry is None:
                continue
            kind = entry.get("type")
            if kind == "ai-title":
                session.title(entry.get("aiTitle"), "ai")
            elif kind == "custom-title":
                session.title(entry.get("customTitle"), "custom")
            elif kind == "agent-name":
                session.title(entry.get("agentName"), "agent")
            elif kind == "summary":
                session.title(entry.get("summary"), "summary")
            elif kind == "pr-link":
                session.row["pr_url"] = entry.get("prUrl") or session.row.get("pr_url")
            elif kind == "cost-state" and not sub:
                session.row["cost"] = entry.get("totalCostUSD")
                usage = entry.get("modelUsage") or {}
                session.row["tokens"] = sum(int(v.get(k) or 0) for v in usage.values() if isinstance(v, dict)
                                            for k in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
            if kind not in ("user", "assistant"):
                continue
            fork = entry.get("forkedFrom")
            if fork and not sub:
                # A copy of the parent's history: indexed under the parent already.
                session.row["forked_from"], session.row["fork_point"] = fork.get("sessionId"), fork.get("messageUuid")
                continue
            if entry.get("isSidechain") and not sub:
                continue
            ts = epoch(entry.get("timestamp"))
            if not sub:
                session.seen(ts)
                session.row["cwd"] = session.row.get("cwd") or entry.get("cwd")
                # `claude -p` and SDK runs (sdk-cli, sdk-ts…) are jobs, not conversations someone had.
                if entry.get("entrypoint"):
                    session.row["automated"] = int(entry["entrypoint"].startswith("sdk"))
                session.row["branch"] = entry.get("gitBranch") or session.row.get("branch")
            message = entry.get("message") or {}
            uuid = entry.get("uuid") or ""
            if kind == "user":
                if entry.get("isMeta") or entry.get("isCompactSummary"):
                    continue
                text = prompt_text(text_of(message.get("content")))
                if not text:
                    continue
                if not sub:
                    session.row["prompts"] = (session.row.get("prompts") or 0) + 1
                    if not session.row.get("first_prompt"):
                        session.row["first_prompt"] = " ".join(text.split())[:300]
                        session.title(text, "prompt")
                rows.append((text[:TEXT_LIMIT], session_id, uuid, "subagent" if sub else "user", ts))
            else:
                model = message.get("model")
                if model and not model.startswith("<") and not sub:
                    session.row["model"] = model
                    # Streaming repeats one response per content block; count it once. cost-state,
                    # written when a session ends, replaces this sum.
                    usage = message.get("usage") or {}
                    if message.get("id") != state.get("last") and session.row.get("cost") is None:
                        state["last"] = message.get("id")
                        session.row["tokens"] = (session.row.get("tokens") or 0) + sum(int(usage.get(k) or 0) for k in (
                            "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                for part in message.get("content") or []:
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "text" and part.get("text", "").strip():
                        rows.append((part["text"][:TEXT_LIMIT], session_id, uuid, "subagent" if sub else "assistant", ts))
                    elif part.get("type") == "tool_use" and not sub:
                        rows.append((tool_summary(part.get("name", "tool"), part.get("input")), session_id, uuid, "tool", ts))
            if not sub:
                session.row["messages"] = (session.row.get("messages") or 0) + 1
    add_rows(db, rows)
    if images:
        add_images(db, images.rows)
        state["img"] = offset
    save(db, session)
    return session_id, offset, state


CODEX_NOISE = ("# AGENTS.md", "<environment_context>", "<user_instructions>", "<permissions", "<turn_aborted>", "## Memory")


def index_codex(db, path, offset, state, threads):
    session_id = state.get("id")
    session = load(db, session_id, "codex", path) if session_id else None
    rows = []
    images = Images(path, "codex", *image_owner(path, "codex", session_id, state), state) if state.get("img", 0) == offset else None
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            at = offset
            offset += len(line)
            entry = None
            if b'"session_meta"' in line:
                entry = parse(line)
                payload = (entry or {}).get("payload") or {}
                if entry and entry.get("type") == "session_meta":
                    state["id"], state["parent"] = payload.get("id") or path.stem, payload.get("parent_thread_id")
                    if images:
                        images.session, images.agent_id = image_owner(path, "codex", state["id"], state)
            if images:
                entry = images.feed(line, at, entry)
            if not (b'"session_meta"' in line or b'"response_item"' in line or b'"turn_context"' in line):
                continue
            entry = entry if entry is not None else parse(line)
            if entry is None:
                continue
            payload = entry.get("payload") or {}
            ts = epoch(entry.get("timestamp"))
            if entry.get("type") == "session_meta":
                session_id = state["id"] = payload.get("id") or path.stem
                session = load(db, session_id, "codex", path)
                session.row["cwd"] = payload.get("cwd")
                session.row["branch"] = (payload.get("git") or {}).get("branch")
                # Threads Claude Code's Codex plugin or `codex exec` started are jobs, not conversations.
                session.row["automated"] = int(payload.get("source") not in ("cli", "vscode")
                                               or payload.get("originator") in ("Claude Code", "codex_exec"))
                continue
            if session is None:
                continue
            if entry.get("type") == "turn_context":
                session.row["model"] = payload.get("model") or session.row.get("model")
                continue
            session.seen(ts)
            kind = payload.get("type")
            if kind == "message" and payload.get("role") in ("user", "assistant"):
                text = text_of(payload.get("content")).strip()
                if not text or text.startswith(CODEX_NOISE):
                    continue
                role = payload["role"]
                if role == "user":
                    session.row["prompts"] = (session.row.get("prompts") or 0) + 1
                    if not session.row.get("first_prompt"):
                        session.row["first_prompt"] = " ".join(text.split())[:300]
                        session.title(text, "prompt")
                session.row["messages"] = (session.row.get("messages") or 0) + 1
                rows.append((text[:TEXT_LIMIT], session_id, payload.get("id") or "", role, ts))
            elif kind in ("function_call", "custom_tool_call"):
                raw = payload.get("arguments") or payload.get("input") or ""
                try:
                    value = json.loads(raw) if isinstance(raw, str) and raw.startswith("{") else {"command": str(raw)}
                except ValueError:
                    value = {"command": str(raw)}
                rows.append((tool_summary(payload.get("name", "tool"), value), session_id, payload.get("call_id") or "", "tool", ts))
    if session is not None:
        thread = threads.get(session_id) or {}
        session.title(thread.get("title"), "codex")
        session.row["tokens"] = thread.get("tokens") or session.row.get("tokens")
        session.row["branch"] = session.row.get("branch") or thread.get("branch")
        add_rows(db, rows)
        save(db, session)
    if images:
        add_images(db, [row for row in images.rows if row["session"]])
        state["img"] = offset
    return session_id, offset, state


def index(root, seconds=20.0, paths=None):
    """Indexes what changed, newest files first, for up to `seconds`. Returns how many files remain.
    One indexer at a time: two would both append the same new lines."""
    lock = open(Path(root) / "runtime" / "sessions.lock", "a") if (Path(root) / "runtime").is_dir() else None
    if lock is None:
        connect(root).close()
        lock = open(Path(root) / "runtime" / "sessions.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return {"remaining": -1, "indexed": 0, "sessions": 0}
    with lock:
        return _index(root, seconds, paths)


def _index(root, seconds, paths=None):
    db = connect(root)
    upgrade(db)
    deadline = time.time() + seconds
    found = []
    if paths is not None:
        # The app watches the transcript folders and names what changed, so nothing else is listed or statted.
        # A profile's `sessions` is a link to the shared folder; file its rollouts under the one real path.
        paths = [Path(os.path.realpath(p)) if "/profiles/" in p else Path(p) for p in paths if p.endswith(".jsonl")]
        sources = (("claude", [p for p in paths if "/.claude/projects/" in str(p)]),
                   ("codex", [p for p in paths if is_codex_path(p)]))
        # Only the named files' rows: the table has one per transcript ever read, each with its parser's state.
        named = [str(p) for p in paths]
        known = {row[0]: row for start in range(0, len(named), 500) for row in db.execute(
            f"SELECT path, session, offset, size, mtime, state FROM files WHERE path IN ({','.join('?' * len(named[start:start + 500]))})",
            named[start:start + 500])}
    else:
        sources = (("claude", claude_files()), ("codex", codex_files(root)))
        known = {row[0]: row for row in db.execute("SELECT path, session, offset, size, mtime, state FROM files")}
    for agent, files in sources:
        for path in files:
            try:
                stat = path.stat()
            except OSError:
                continue
            row = known.get(str(path))
            if row is None or row[3] != stat.st_size or row[4] != stat.st_mtime:
                found.append((stat.st_mtime, agent, path, stat))
    present = {str(item[2]) for item in found} | {p for p in known if Path(p).exists()}
    for gone in set(known) - present:
        session = known[gone][1]
        db.execute("DELETE FROM files WHERE path=?", (gone,))
        db.execute("DELETE FROM images WHERE path=?", (gone,))
        if session and not db.execute("SELECT 1 FROM files WHERE session=?", (session,)).fetchone():
            delete_rows(db, session)
            db.execute("DELETE FROM images WHERE session=?", (session,))
            db.execute("DELETE FROM sessions WHERE id=?", (session,))
    db.commit()
    found.sort(key=lambda item: item[0], reverse=True)
    threads = codex_threads(root) if any(item[1] == "codex" for item in found) else {}
    done = 0
    for _, agent, path, stat in found:
        if time.time() > deadline:
            break
        row = known.get(str(path))
        offset, state = (row[2], json.loads(row[5] or "{}")) if row and row[3] <= stat.st_size else (0, {})
        if row and offset == 0:
            db.execute("DELETE FROM images WHERE path=?", (str(path),))
        if row and offset == 0 and row[1]:
            delete_rows(db, row[1])
            db.execute("DELETE FROM sessions WHERE id=?", (row[1],))
        try:
            if agent == "claude":
                session, offset, state = index_claude(db, path, offset, state)
            else:
                session, offset, state = index_codex(db, path, offset, state, threads)
        except OSError:
            continue
        db.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)",
                   (str(path), session, offset, stat.st_size, stat.st_mtime, json.dumps(state)))
        db.commit()
        done += 1
    # Spare time keeps the newest conversations ready to open; one already current costs a stat.
    for session_id, path, agent in db.execute("SELECT id, path, agent FROM sessions WHERE prompts > 0 ORDER BY last_ts DESC LIMIT 20").fetchall():
        if time.time() > deadline:
            break
        try:
            update_view(db, session_id, Path(path), agent)
        except OSError:
            continue
    result = {"remaining": len(found) - done, "indexed": done}
    # The upkeep reads whole tables, so it runs on the passes over everything, not after each file that changed.
    if paths is None:
        result["images_remaining"] = backfill(db, deadline)
        tidy(root, db)
    result["sessions"] = db.execute("SELECT count(*) FROM sessions").fetchone()[0]
    db.close()
    return result


VIEWS_KEPT = 300


def tidy(root, db):
    """Keeps the viewer's cache to the conversations opened most recently, and the file to what it holds."""
    # By session, which is the cache's key: a NOT IN over the kept ones reads every cached row to delete none.
    for (session,) in db.execute("SELECT session FROM view_state ORDER BY used DESC LIMIT -1 OFFSET ?", (VIEWS_KEPT,)).fetchall():
        db.execute("DELETE FROM views WHERE session=?", (session,))
        db.execute("DELETE FROM view_state WHERE session=?", (session,))
    db.commit()
    sweep_thumbnails(root, db)
    free, pages = db.execute("PRAGMA freelist_count").fetchone()[0], db.execute("PRAGMA page_count").fetchone()[0]
    # Deleted conversations leave free pages SQLite reuses but never returns; compact once they're a quarter of the file.
    if pages and free * 4 > pages and free * db.execute("PRAGMA page_size").fetchone()[0] > 32 << 20:
        db.execute("VACUUM")


def backfill(db, deadline):
    """Indexes the images of files read before the image index existed, newest first, in what's left of
    this pass. Returns how many files still have lines to scan."""
    pending = []
    for path, session, offset, state in db.execute("SELECT path, session, offset, state FROM files ORDER BY mtime DESC").fetchall():
        state = json.loads(state or "{}")
        if state.get("img", 0) < offset or "img" not in state:
            pending.append((path, session, offset, state))
    left = len(pending)
    for path, session, offset, state in pending:
        if time.time() > deadline:
            break
        agent = "codex" if is_codex_path(path) else "claude"
        start = state.get("img", 0)
        images = Images(path, agent, *image_owner(path, agent, session, state), state)
        try:
            with open(path, "rb") as stream:
                stream.seek(start)
                while start < offset and time.time() <= deadline:
                    line = stream.readline()
                    if not line.endswith(b"\n"):
                        break
                    images.feed(line, start)
                    start += len(line)
        except OSError:
            continue
        add_images(db, [row for row in images.rows if row["session"]])
        state["img"] = start
        db.execute("UPDATE files SET state=? WHERE path=?", (json.dumps(state), path))
        db.commit()
        left -= start >= offset
    return left


def sweep_thumbnails(root, db, cap=200 << 20):
    """At most once an hour: drops thumbnails of images no transcript holds any more, then the least
    recently served ones until the folder is under `cap`. The app touches a thumbnail when it serves it."""
    folder = Path(root) / "runtime" / "thumbs"
    stamp = folder / ".swept"
    try:
        if not folder.is_dir() or time.time() - stamp.stat().st_mtime < 3600:
            return
    except FileNotFoundError:
        pass
    kept = []
    for thumb in folder.glob("*.jpg"):
        try:
            stat = thumb.stat()
            if not db.execute("SELECT 1 FROM images WHERE id=? LIMIT 1", (thumb.stem,)).fetchone():
                thumb.unlink()
            else:
                kept.append((stat.st_mtime, stat.st_size, thumb))
        except OSError:
            continue
    total = sum(item[1] for item in kept)
    for _, size, thumb in sorted(kept, key=lambda item: item[0]):
        if total < cap:
            break
        try:
            thumb.unlink()
            total -= size
        except OSError:
            pass
    stamp.touch()


SESSION_COLUMNS = ("id", "agent", "cwd", "branch", "title", "first_prompt", "model", "first_ts", "last_ts", "cost",
                   "tokens", "prompts", "messages", "forked_from", "fork_point", "pr_url", "automated")


def session_dict(row):
    return dict(zip(SESSION_COLUMNS, row))


def filters(agent=None, project=None, days=None, automated=False):
    where, args = ["s.prompts > 0"] + ([] if automated else ["s.automated = 0"]), []
    if agent:
        where.append("s.agent = ?"); args.append(agent)
    if project:
        where.append("s.cwd = ?"); args.append(project)
    if days:
        where.append("s.last_ts >= ?"); args.append(time.time() - float(days) * 86400)
    return " AND ".join(where), args


def recent(root, agent=None, project=None, days=None, automated=False, limit=300, pinned=(), only=None):
    db = connect(root)
    where, args = filters(agent, project, days, automated)
    if only is not None:
        where += f" AND s.id IN ({','.join('?' * len(only)) or 'NULL'})"
        args += list(only)
    rows = db.execute(f"SELECT {','.join('s.' + c for c in SESSION_COLUMNS)} FROM sessions s WHERE {where} "
                      "ORDER BY s.last_ts DESC LIMIT ?", args + [limit]).fetchall()
    projects = [row[0] for row in db.execute("SELECT cwd FROM sessions WHERE prompts > 0 AND cwd IS NOT NULL "
                                              "GROUP BY cwd ORDER BY max(last_ts) DESC LIMIT 80")]
    pins = {row[0]: session_dict(row) for row in db.execute(
        f"SELECT {','.join(SESSION_COLUMNS)} FROM sessions WHERE id IN ({','.join('?' * len(pinned))})", list(pinned))} if pinned else {}
    db.close()
    return {"sessions": [session_dict(row) for row in rows], "projects": projects, "pinned": [pins[i] for i in pinned if i in pins]}


def fts_query(text):
    """Every word must appear; each is quoted so FTS5 syntax in the input is just text. Trigrams
    need three characters, so shorter words are matched separately."""
    words = [word for word in text.split() if word]
    long = [word for word in words if len(word) >= 3]
    return " ".join('"' + word.replace('"', '""') + '"' for word in long), [word for word in words if len(word) < 3]


def search(root, text, agent=None, project=None, days=None, automated=False, limit=60):
    """Sessions matching every word, best first, each with up to three highlighted snippets.
    Snippet highlights are marked with \\x02 and \\x03."""
    db = connect(root)
    query, short = fts_query(text)
    where, args = filters(agent, project, days, automated)
    if query:
        # Every word must appear somewhere in the conversation, not all in one message.
        words = query.split('" "')
        # Joining sessions here makes SQLite run the full-text match once per session; filter in Python instead.
        allowed = {row[0] for row in db.execute(f"SELECT s.id FROM sessions s WHERE {where}", args)}
        source, column = sources(db)
        sessions_with = None
        for word in words:
            word = '"' + word.strip('"') + '"'
            # CROSS JOIN keeps the match as the outer loop, so it runs once.
            found = {row[0] for row in db.execute(
                f"SELECT DISTINCT {column} FROM {source} WHERE msgs MATCH ?", [word])} & allowed
            sessions_with = found if sessions_with is None else sessions_with & found
            if not sessions_with:
                break
        keep = sessions_with or set()
        match = " OR ".join('"' + w.strip('"') + '"' for w in words)
        ranked = [(rowid, score) for rowid, session, score in db.execute(
            f"SELECT m.rowid, {column}, bm25(msgs) FROM {source} WHERE msgs MATCH ? ORDER BY bm25(msgs)",
            [match]) if session in keep][:800] if keep else []
        # Snippets are the costly part, so only the best messages get one.
        scores = dict(ranked)
        details = db.execute(
            "SELECT rowid, session, uuid, role, ts, snippet(msgs, 0, char(2), char(3), '…', 64) FROM msgs "
            f"WHERE msgs MATCH ? AND rowid IN ({','.join('?' * len(scores))})", [match] + list(scores)).fetchall() if scores else []
        hits = sorted(((r[1], r[2], r[3], r[4], r[5], scores[r[0]]) for r in details), key=lambda hit: hit[5])
    else:
        pattern = "%" + " ".join(short).replace("%", "").replace("_", "") + "%"
        # One- and two-letter words can't use trigrams; scanning text is costly, so only the 200 newest conversations.
        recent_ids = [row[0] for row in db.execute(f"SELECT s.id FROM sessions s WHERE {where} ORDER BY s.last_ts DESC LIMIT 200", args)]
        source, column = sources(db)
        source = "rows r CROSS JOIN msgs m ON m.rowid = r.id" if column == "r.session" else source
        hits = db.execute(
            "SELECT m.session, m.uuid, m.role, m.ts, substr(m.text, max(instr(lower(m.text), lower(?)) - 60, 1), 160), 0 "
            f"FROM {source} WHERE {column} IN ({','.join('?' * len(recent_ids))}) AND m.text LIKE ? LIMIT 600",
            [pattern.strip("%")] + recent_ids + [pattern]).fetchall() if recent_ids else []
    grouped = {}
    words = [word for word in text.split() if word] or [text]
    for session, uuid, role, ts, snippet, score in hits:
        if short and query and not all(word.casefold() in snippet.replace("\x02", "").replace("\x03", "").casefold() for word in short):
            continue
        entry = grouped.setdefault(session, {"score": 0.0, "hits": 0, "snippets": []})
        entry["hits"] += 1
        # bm25 is negative, lower is better. A message holding every word beats many holding one,
        # so a session ranks by its best message, not by how often a common word appears.
        plain = snippet.replace("\x02", "").replace("\x03", "").casefold()
        coverage = sum(word.casefold() in plain for word in words) / len(words)
        value = (-score if query else 1) * (1 + 2 * coverage) * {"title": 3, "user": 1.5, "assistant": 1, "subagent": 0.6, "tool": 0.5}.get(role, 1)
        best = value > entry["score"]
        entry["score"] = max(entry["score"], value)
        if role != "title":
            found = {"uuid": uuid, "role": role, "ts": ts, "text": " ".join(snippet.split())}
            entry["snippets"] = ([found] + entry["snippets"] if best else entry["snippets"] + [found])[:3]
    if not grouped:
        db.close()
        return {"sessions": []}
    marks = ",".join("?" * len(grouped))
    meta = {row[0]: session_dict(row) for row in db.execute(
        f"SELECT {','.join(SESSION_COLUMNS)} FROM sessions WHERE id IN ({marks})", list(grouped))}
    db.close()
    now = time.time()
    results = []
    for session, entry in grouped.items():
        if session not in meta:
            continue
        age = max(now - (meta[session]["last_ts"] or 0), 0) / 86400
        results.append({**meta[session], "hits": entry["hits"], "snippets": entry["snippets"],
                        "score": entry["score"] * (1 + 0.1 * math.log1p(entry["hits"])) / (1 + age / 30)})
    results.sort(key=lambda item: -item["score"])
    return {"sessions": results[:limit]}


def transcript_path(root, session_id):
    db = connect(root)
    row = db.execute("SELECT path, agent FROM sessions WHERE id=?", (session_id,)).fetchone()
    db.close()
    if row and Path(row[0]).exists():
        return Path(row[0]), row[1]
    if not AGENT_ID.fullmatch(session_id or ""):
        return None, None
    for path in (Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"):
        return path, "claude"
    for home in codex_homes(root):
        for path in (home / "sessions").glob(f"**/rollout-*{session_id}.jsonl") if (home / "sessions").is_dir() else ():
            return path, "codex"
    return None, None


def head_of(path):
    """The opening bytes identify a transcript, so one rewritten in place is rebuilt rather than appended to."""
    with open(path, "rb") as stream:
        return stream.read(512).hex()


TEXT_CUT = 6000
OUTPUT_CUT = 4000
INPUT_CUT = 64 << 10
DIFF_LINES = 2000
WHOLE = 1 << 20
# A row has to stay well under a megabyte on the wire: each tool is squeezed to TOOL_BUDGET and a run of
# tool calls splits every TOOLS_PER_ROW.
TOOL_BUDGET = 96 << 10
TOOLS_PER_ROW = 8
CALLS_KEPT = 200
DENIED = ("The user doesn't want to proceed with this tool use", "The user doesn't want to take this action",
          "Permission to use ", "User rejected tool use")
SHELLS = ("sh", "bash", "zsh", "fish", "dash")
HUNK = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class Changed(Exception):
    """The transcript line a row points at isn't the one it was read from any more."""


def clip(value, limit=INPUT_CUT):
    if isinstance(value, str):
        return value[:limit]
    if isinstance(value, list):
        return [clip(item, limit) for item in value]
    if isinstance(value, dict):
        return {key: clip(item, limit) for key, item in value.items()}
    return value


def cut_text(text, whole=False):
    if whole or len(text) <= TEXT_CUT:
        return text, False
    return text[:TEXT_CUT], True


def cut_output(text, whole=False):
    if len(text) <= (WHOLE if whole else OUTPUT_CUT):
        return text, False
    return (text[:WHOLE], True) if whole else (text[:3000] + "\n…\n" + text[-900:], True)


def result_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") in ("text", "input_text", "output_text")) \
        if isinstance(content, list) else ""


def file_diff(path, change, hunks, old_path=None, cap=DIFF_LINES, deletions=None):
    """protocol's FileDiff. Counts are taken before the cut."""
    lines = [line for hunk in hunks for line in hunk["lines"]]
    diff = {"path": path, "old_path": old_path, "change": change, "additions": sum(line.startswith("+") for line in lines),
            "deletions": sum(line.startswith("-") for line in lines) if deletions is None else deletions, "truncated": False, "hunks": hunks}
    if cap is not None and len(lines) > cap:
        kept, left = [], cap
        for hunk in hunks:
            if left <= 0:
                break
            kept.append({**hunk, "lines": hunk["lines"][:left]})
            left -= len(hunk["lines"])
        diff["hunks"], diff["truncated"] = kept, True
    return diff


def hunk(old_start, old_count, new_start, new_count, lines):
    return {"old_start": old_start, "old_count": old_count, "new_start": new_start, "new_count": new_count, "lines": lines}


def added(path, content, cap=DIFF_LINES):
    whole = cap is None
    lines = ["+" + line for line in content[:WHOLE].splitlines()]
    diff = file_diff(path, "added", [hunk(0, 0, 1, len(lines), lines)], cap=cap)
    diff["truncated"] = diff["truncated"] or (whole and len(content) > WHOLE)
    return diff


def replacement(old, new):
    old, new = old.splitlines(), new.splitlines()
    return hunk(0, len(old), 0, len(new), ["-" + line for line in old] + ["+" + line for line in new])


def diff_of(name, value, result, cap=DIFF_LINES):
    """The file changes of a Claude Edit, MultiEdit or Write: from its result's structuredPatch when it has
    one, else from the call itself (a rejected call, older Claude Code), with unknown line numbers as 0."""
    value = value if isinstance(value, dict) else {}
    if isinstance(result, dict) and ("structuredPatch" in result or result.get("type") == "create"):
        path = result.get("filePath") or value.get("file_path") or ""
        if result.get("type") == "create":
            return [added(path, result.get("content") or value.get("content") or "", cap)]
        patch = [h for h in result.get("structuredPatch") or [] if isinstance(h, dict)]
        return [file_diff(path, "modified", [hunk(h.get("oldStart", 0), h.get("oldLines", 0), h.get("newStart", 0), h.get("newLines", 0),
                                                  [str(line) for line in h.get("lines") or []]) for h in patch], cap=cap)] if patch else []
    path = value.get("file_path") or ""
    if name == "Edit" and isinstance(value.get("old_string"), str):
        return [file_diff(path, "modified", [replacement(value["old_string"], value.get("new_string") or "")], cap=cap)]
    if name == "MultiEdit" and isinstance(value.get("edits"), list):
        edits = [edit for edit in value["edits"] if isinstance(edit, dict)]
        return [file_diff(path, "modified", [replacement(str(e.get("old_string") or ""), str(e.get("new_string") or "")) for e in edits], cap=cap)]
    return []


def unified(text):
    """Hunks of a unified diff, each line kept with its prefix, `\\ No newline` included."""
    hunks, current, old_left, new_left = [], None, 0, 0
    for line in text.splitlines():
        match = HUNK.match(line)
        if match:
            a, b, c, d = (int(group) if group is not None else 1 for group in match.groups())
            current = hunk(a, b, c, d, [])
            hunks.append(current)
            old_left, new_left = b, d
        elif current is not None and (old_left > 0 or new_left > 0 or line.startswith("\\")):
            if line.startswith("\\"):
                current["lines"].append(line)
                continue
            line = line if line[:1] in ("+", "-", " ") else " " + line
            current["lines"].append(line)
            old_left -= line[0] in (" ", "-")
            new_left -= line[0] in (" ", "+")
    return hunks


def codex_diffs(changes, cap=DIFF_LINES):
    diffs = []
    for path, change in (changes or {}).items() if isinstance(changes, dict) else ():
        change = change if isinstance(change, dict) else {}
        if change.get("type") == "add":
            diffs.append(added(path, change.get("content") or "", cap))
        elif change.get("type") == "delete":
            diffs.append(file_diff(path, "deleted", [], cap=cap, deletions=len((change.get("content") or "").splitlines())))
        else:
            moved = change.get("move_path")
            diffs.append(file_diff(moved or path, "renamed" if moved else "modified", unified(change.get("unified_diff") or ""),
                                   old_path=path if moved else None, cap=cap))
    return diffs


def todos_of(name, value):
    value = value if isinstance(value, dict) else {}
    if name == "TodoWrite" and isinstance(value.get("todos"), list):
        return [{"content": t.get("content"), "status": t.get("status"), "active_form": t.get("activeForm")} for t in value["todos"] if isinstance(t, dict)]
    if name == "TaskCreate":
        return [{"content": value.get("subject") or value.get("description") or value.get("content"), "status": value.get("status") or "pending",
                 "active_form": value.get("activeForm")}]
    if name == "TaskUpdate":
        return [{"id": value.get("taskId"), "content": value.get("subject"), "status": value.get("status"), "active_form": value.get("activeForm")}]
    if name == "update_plan" and isinstance(value.get("plan"), list):
        return [{"content": step.get("step"), "status": step.get("status"), "active_form": None} for step in value["plan"] if isinstance(step, dict)]
    return None


def new_tool(call, name, value, ts, src, whole=False):
    value = value if isinstance(value, dict) else {}
    tool = {"id": call or "", "name": name, "summary": tool_summary(name, value), "input": clip(value, WHOLE if whole else INPUT_CUT),
            "status": "running", "started_at": ts, "ended_at": None, "output": None, "output_truncated": False, "diffs": [], "images": [],
            "subagent": None, "agent_id": None, "todos": todos_of(name, value), "plan": None, "src": [src]}
    if name in ("Task", "Agent") and isinstance(value.get("description"), str):
        tool["subagent"] = value["description"]
    if name == "ExitPlanMode" and isinstance(value.get("plan"), str):
        tool["plan"] = tool["input"]["plan"]
    if name in ("Edit", "MultiEdit"):
        tool["diffs"] = diff_of(name, value, None, None if whole else DIFF_LINES)
    return tool


def fit(tool):
    """Squeezes a tool under TOOL_BUDGET: long input strings, then long diff lines, then diff lines from the end."""
    if len(json.dumps(tool)) <= TOOL_BUDGET:
        return tool
    tool["input"] = clip(tool["input"], 4096)
    for diff in tool["diffs"]:
        for item in diff["hunks"]:
            item["lines"] = [line[:400] for line in item["lines"]]
    while len(json.dumps(tool)) > TOOL_BUDGET and any(item["lines"] for diff in tool["diffs"] for item in diff["hunks"]):
        for diff in tool["diffs"]:
            for item in diff["hunks"]:
                if item["lines"]:
                    item["lines"] = item["lines"][:len(item["lines"]) // 2]
            diff["truncated"] = True
    return tool


def trim(result):
    """A Claude toolUseResult without what a row never needs: the whole file before an edit, image bytes, huge output."""
    if not isinstance(result, dict):
        return result
    result = {key: value for key, value in result.items() if key != "originalFile"}
    if isinstance(result.get("content"), str) and len(result["content"]) > WHOLE:
        del result["content"]
    if isinstance(result.get("file"), dict):
        result["file"] = {key: value for key, value in result["file"].items() if key != "base64"}
    for key in ("stdout", "stderr"):
        if isinstance(result.get(key), str) and len(result[key]) > INPUT_CUT:
            del result[key]
    return result


def claude_result(tool, part, result, images, ts, whole=False):
    text = result_text(part.get("content"))
    rejected = isinstance(result, str) and result.startswith("User rejected")
    tool["status"] = "denied" if rejected or text.startswith(DENIED) else "failed" if part.get("is_error") else "ok"
    tool["ended_at"] = ts
    tool["output"], tool["output_truncated"] = cut_output(text, whole)
    if tool["name"] == "Read" and isinstance(tool["input"].get("file_path"), str):
        images = [{**image, "name": os.path.basename(tool["input"]["file_path"])} for image in images]
    tool["images"] = images
    result = trim(result)
    if isinstance(result, dict):
        if "structuredPatch" in result or result.get("type") == "create":
            tool["diffs"] = diff_of(tool["name"], tool["input"], result, None if whole else DIFF_LINES)
        if isinstance(result.get("newTodos"), list):
            tool["todos"] = todos_of("TodoWrite", {"todos": result["newTodos"]})
        if isinstance(result.get("agentId"), str):
            tool["agent_id"] = result["agentId"]
    return tool


def command_text(command):
    if isinstance(command, list):
        words = [str(word) for word in command]
        if len(words) >= 3 and os.path.basename(words[0]) in SHELLS and words[1] in ("-c", "-lc"):
            return words[2]
        import shlex
        return " ".join(shlex.quote(word) for word in words)
    return str(command or "")


def codex_input(payload):
    raw = payload.get("arguments") or payload.get("input") or ""
    if payload.get("type") == "custom_tool_call":
        return {"code": raw} if isinstance(raw, str) else raw, {"command": str(raw)}
    try:
        value = json.loads(raw) if isinstance(raw, str) and raw.startswith("{") else {"command": str(raw)}
    except ValueError:
        value = {"command": str(raw)}
    return value, value


def codex_call(payload, ts, src, whole=False):
    value, shown = codex_input(payload)
    tool = new_tool(payload.get("call_id"), payload.get("name") or "tool", value, ts, src, whole)
    tool["summary"] = tool_summary(tool["name"], shown)
    return tool


def codex_output(tool, payload, images, ts, whole=False):
    output, failed = payload.get("output"), False
    if isinstance(output, str) and output.startswith("{"):
        try:
            parsed = json.loads(output)
            if isinstance(parsed, dict) and "output" in parsed:
                failed = bool((parsed.get("metadata") or {}).get("exit_code"))
                output = parsed["output"]
        except ValueError:
            pass
    tool["status"], tool["ended_at"], tool["images"] = "failed" if failed else "ok", ts, images
    tool["output"], tool["output_truncated"] = cut_output(result_text(output), whole)
    return tool


def mcp_text(result):
    if isinstance(result, dict):
        inner = result.get("Ok") if isinstance(result.get("Ok"), dict) else result
        content = inner.get("content")
        if isinstance(content, list):
            return result_text(content)
        return json.dumps(result)
    return result if isinstance(result, str) else json.dumps(result) if result is not None else ""


def codex_item(item, payload, images, ts, src, whole=False):
    """A finished Codex item (CommandExecution, McpToolCall, FileChange, ImageView, Extension) as a tool."""
    kind = item.get("type")
    started = payload.get("started_at_ms")
    ended = epoch(payload["completed_at_ms"]) if payload.get("completed_at_ms") else ts
    output, failed, diffs = None, item.get("status") == "failed", []
    if kind == "CommandExecution":
        name, value = "exec_command", {"command": command_text(item.get("command")), "cwd": item.get("cwd")}
        output = item.get("aggregated_output") or ""
        failed = failed or bool(item.get("exit_code"))
    elif kind == "McpToolCall":
        arguments = item.get("arguments")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except ValueError:
                arguments = {"arguments": arguments}
        name, value = f"mcp__{item.get('server')}__{item.get('tool')}", arguments if isinstance(arguments, dict) else {}
        output = mcp_text(item.get("result"))
        failed = failed or bool(isinstance(item.get("result"), dict) and (item["result"].get("isError") or item["result"].get("Err")))
    elif kind == "FileChange":
        changes = item.get("changes") if isinstance(item.get("changes"), dict) else {}
        name, value = "apply_patch", {"path": next(iter(changes), None), "paths": list(changes)}
        diffs = codex_diffs(changes, None if whole else DIFF_LINES)
    elif kind == "ImageView":
        name, value = "view_image", {"path": item.get("path")}
    else:
        name, value = item.get("kind") or kind or "tool", {key: item[key] for key in ("query", "revisedPrompt", "savedPath") if isinstance(item.get(key), str)}
        failed = failed or bool(item.get("failure"))
    tool = new_tool(item.get("id"), name, value, epoch(started) if started else ts, src, whole)
    tool.update({"status": "failed" if failed else "ok", "ended_at": ended, "diffs": diffs, "images": images})
    if output is not None:
        tool["output"], tool["output_truncated"] = cut_output(output, whole)
    return tool


def message_row(role, uuid, ts, text=None, inherited=False, model=None, images=(), src=None, duration=None):
    text, cut = cut_text(text) if text is not None else (None, False)
    return {"role": role, "uuid": uuid, "ts": ts, "model": model, "inherited": inherited, "text": text, "text_truncated": cut,
            "images": list(images), "tools": [], "duration_ms": duration, "src": src}


def thinking_time(start, end):
    """Milliseconds between two timestamps in seconds, or None when either is missing or they're out of order."""
    return int(round((end - start) * 1000)) if start and end and end >= start else None


class Rows:
    """What read_messages builds: rows appended from seq `start` on, and older rows loaded through
    `fetch` when a tool result lands on them. `calls` maps each running tool call to its row's seq."""

    def __init__(self, start=0, seed=(), fetch=None, calls=None):
        self.start, self.new, self.old, self.fetch = start, list(seed), {}, fetch
        self.calls = {} if calls is None else calls
        # When the line before the current one was written: Claude's thinking took from then to its own line.
        self.last_ts = self.new[-1]["ts"] if self.new and self.new[-1] else None

    def get(self, seq):
        if seq >= self.start:
            return self.new[seq - self.start] if seq - self.start < len(self.new) else None
        if seq not in self.old:
            self.old[seq] = self.fetch(seq) if self.fetch else None
        return self.old[seq]

    def add(self, row):
        self.new.append(row)
        return self.start + len(self.new) - 1

    def tool(self, call):
        row = self.get(self.calls[call]) if call in self.calls else None
        return next((tool for tool in row["tools"] if tool["id"] == call), None) if row else None

    def name_of(self, call):
        tool = self.tool(call)
        return tool["name"] if tool else None

    def add_tool(self, tool, uuid, ts, inherited=False):
        last = self.new[-1] if self.new else None
        if last and last["role"] == "tools" and last["inherited"] == inherited and len(last["tools"]) < TOOLS_PER_ROW:
            last["tools"].append(fit(tool))
            if uuid and uuid != last["uuid"] and uuid not in last.setdefault("also", []):
                last["also"].append(uuid)
            seq = self.start + len(self.new) - 1
        else:
            row = message_row("tools", uuid, ts, inherited=inherited)
            row["tools"].append(fit(tool))
            seq = self.add(row)
        if tool["status"] == "running" and tool["id"]:
            self.calls[tool["id"]] = seq
        return seq


def read_claude(rows, entry, line, at, refs_of, sub=False):
    kind = entry.get("type")
    src = [at, len(line)]
    ts = epoch(entry.get("timestamp"))
    before, rows.last_ts = rows.last_ts, ts or rows.last_ts
    inherited = bool(entry.get("forkedFrom"))
    if kind == "system" and entry.get("subtype") == "compact_boundary":
        rows.add(message_row("compact", entry.get("uuid") or "", ts, "Conversation compacted", src=src))
        return
    if entry.get("isSidechain") and not sub:
        return
    if kind == "attachment":
        prompt = queued_prompt(entry)
        if prompt is not None:
            refs = refs_of()
            images = [refs[n] for n in sorted(refs)]
            text = prompt_text(text_of(prompt))
            if text or images:
                rows.add(message_row("user", entry.get("uuid") or "", ts, text, inherited, images=images, src=src))
        return
    if kind not in ("user", "assistant"):
        return
    message = entry.get("message") or {}
    uuid = entry.get("uuid") or ""
    content = message.get("content")
    if kind == "user":
        if entry.get("isMeta") or entry.get("isCompactSummary"):
            return
        refs = refs_of()
        block, pasted, results = 0, [], []
        for part in content if isinstance(content, list) else []:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "image":
                pasted += [refs[block]] if block in refs else []
                block += 1
            elif part.get("type") == "tool_result":
                inner = [item for item in part.get("content") or [] if isinstance(item, dict) and item.get("type") == "image"] \
                    if isinstance(part.get("content"), list) else []
                results.append((part, [refs[n] for n in range(block, block + len(inner)) if n in refs]))
                block += len(inner)
        text = prompt_text(text_of(content))
        if text or pasted:
            rows.add(message_row("user", uuid, ts, text, inherited, images=pasted, src=src))
        for part, images in results:
            call = part.get("tool_use_id")
            tool = rows.tool(call)
            if tool is None:
                continue
            fit(claude_result(tool, part, entry.get("toolUseResult"), images, ts))
            tool["src"].append(src)
            del rows.calls[call]
        return
    model = message.get("model")
    for index, part in enumerate(content if isinstance(content, list) else []):
        if not isinstance(part, dict):
            continue
        if part.get("type") in ("thinking", "redacted_thinking"):
            # Claude Code often keeps only the signature, so the text can be empty; the row still says it thought.
            rows.add(message_row("thinking", uuid, ts, part.get("thinking") or "", inherited, src=src + [index],
                                 duration=thinking_time(before, ts)))
        elif part.get("type") == "text" and part.get("text", "").strip():
            role = "error" if entry.get("isApiErrorMessage") else "assistant"
            rows.add(message_row(role, uuid, ts, part["text"], inherited, model if role == "assistant" and model and not model.startswith("<") else None,
                                 src=src + [index]))
        elif part.get("type") == "tool_use":
            rows.add_tool(new_tool(part.get("id"), part.get("name", "tool"), part.get("input"), ts, src), uuid, ts, inherited)


def owning_exec(rows):
    """The `exec` call a finished Codex item belongs to: the newest one still waiting for its output, else the
    last one in the newest row (some items are written just after the output)."""
    for call in reversed(list(rows.calls)):
        if rows.name_of(call) == "exec":
            return call
    last = rows.new[-1] if rows.new else None
    if last and last["role"] == "tools":
        return next((tool["id"] for tool in reversed(last["tools"]) if tool["name"] == "exec" and tool["id"]), None)
    return None


def read_codex(rows, entry, line, at, refs_of):
    payload = entry.get("payload") or {}
    kind = payload.get("type")
    ts = epoch(entry.get("timestamp"))
    src = [at, len(line)]
    if entry.get("type") == "compacted":
        rows.add(message_row("compact", "", ts, "Conversation compacted", src=src))
    elif entry.get("type") == "response_item":
        if kind == "message" and payload.get("role") in ("user", "assistant"):
            text = text_of(payload.get("content")).strip()
            refs = refs_of() if payload["role"] == "user" else {}
            if text.startswith(CODEX_NOISE) or not (text or refs):
                return
            rows.add(message_row(payload["role"], payload.get("id") or "", ts, text, images=[refs[n] for n in sorted(refs)], src=src + [0]))
        elif kind in ("function_call", "custom_tool_call"):
            rows.add_tool(codex_call(payload, ts, src), payload.get("call_id") or "", ts)
        elif kind in ("function_call_output", "custom_tool_call_output"):
            call = payload.get("call_id")
            tool = rows.tool(call)
            if tool is not None:
                refs = refs_of()
                fit(codex_output(tool, payload, [refs[n] for n in sorted(refs)], ts))
                tool["src"].append(src)
                del rows.calls[call]
    elif entry.get("type") == "event_msg":
        if kind == "item_completed":
            item = payload.get("item") or {}
            if item.get("type") in ("CommandExecution", "McpToolCall", "FileChange", "ImageView", "Extension"):
                if item.get("type") == "McpToolCall" and any(rows.name_of(call) == item.get("tool") for call in rows.calls):
                    return  # the function_call that made it is already a tool, and its output follows
                refs = refs_of()
                tool = fit(codex_item(item, payload, [refs[n] for n in sorted(refs)], ts, src))
                parent = owning_exec(rows)
                if parent is None:
                    rows.add_tool(tool, item.get("id") or "", ts)
                    return
                row = rows.get(rows.calls[parent]) if parent in rows.calls else rows.new[-1]
                tool["parent"] = parent
                at_end = max(n for n, other in enumerate(row["tools"]) if other["id"] == parent or other.get("parent") == parent)
                row["tools"].insert(at_end + 1, tool)
                row["tools"][next(n for n, other in enumerate(row["tools"]) if other["id"] == parent)]["group"] = True
            elif item.get("type") == "Reasoning":
                summary = item.get("summary_text")
                text = "\n\n".join(str(part) for part in summary) if isinstance(summary, list) else str(summary or "")
                started, ended = payload.get("started_at_ms"), payload.get("completed_at_ms")
                rows.add(message_row("thinking", item.get("id") or "", epoch(started) if started else ts, text, src=src,
                                     duration=int(ended - started) if started and ended and ended >= started else None))
            elif item.get("type") == "UserMessage":
                refs = refs_of()
                last = next((row for row in reversed(rows.new) if row["role"] == "user"), None)
                if refs and last is not None and not last["images"]:
                    last["images"] = [refs[n] for n in sorted(refs)]
        elif kind == "task_complete" and payload.get("error"):
            error = payload["error"]
            text = error.get("message") if isinstance(error, dict) else str(error)
            rows.add(message_row("error", payload.get("turn_id") or "", ts, text or "The turn failed", src=src))


def view_skipped(line):
    """Lines the viewer never shows, told apart before parsing. A long line is a screenshot or a big result,
    where scanning megabytes for every marker costs more than parsing it blanked; read_claude drops the rest."""
    if len(line) > BIG_LINE:
        return b'"type":"api-request-blob"' in line[:4096]
    return any(marker in line for marker in VIEW_SKIP) or (b'"type":"attachment"' in line and b'"queued_command"' not in line)


def read_messages(path, agent, offset=0, rows=None, refs=None, sub=False):
    """Reads one transcript from `offset` into `rows`, one row per displayed message: prompts (queued ones
    too), replies, runs of tool calls with their results, compactions and errors. `refs(line, at, entry,
    name_of)` names each line's images by block; without it they're decoded here and not kept."""
    rows = Rows() if rows is None else rows
    marked = (b'"type":"base64"',) if agent == "claude" else IMAGE_MARKERS + FILE_MARKERS
    def images_of(line, at, entry):
        if not any(marker in line for marker in marked):
            return {}
        if refs is not None:
            return refs(line, at, entry, rows.name_of)
        found = claude_images(line, at, entry, rows.name_of) if agent == "claude" else codex_images(line, at, entry, rows.name_of)
        return {image["block"]: ref(image) for image in found}
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            at = offset
            offset += len(line)
            if agent == "claude" and view_skipped(line):
                continue
            entry = parse(line)
            if entry is None:
                continue
            lazy = lambda line=line, at=at, entry=entry: images_of(line, at, entry)
            if agent == "codex":
                read_codex(rows, entry, line, at, lazy)
            else:
                read_claude(rows, entry, line, at, lazy, sub)
    return rows, offset


def update_view(db, session_id, path, agent, sub=False, owner=None):
    """Keeps the viewer's rows for one conversation in the index, reading only lines added since last time.
    Every row written gets the session's next revision; a rebuild from the start gets a new generation.
    Returns how many rows it holds and the seqs of older rows it rewrote."""
    size = path.stat().st_size
    head = head_of(path)
    owner = owner or (session_id, None)
    db.execute("BEGIN IMMEDIATE")
    try:
        state = db.execute("SELECT path, offset, head, count, generation, rev, calls FROM view_state WHERE session=?", (session_id,)).fetchone()
        # A transcript under 512 bytes grows its head as it's appended to; only a different start means a rewrite.
        if state and state[0] == str(path) and head.startswith(state[2] or "-") and state[1] <= size and state[4]:
            offset, count, generation, rev, calls = state[1], state[3], state[4], state[5] or 0, json.loads(state[6] or "{}")
            if offset == size:
                db.execute("UPDATE view_state SET used=? WHERE session=?", (time.time(), session_id))
                db.commit()
                return count, []
        else:
            db.execute("DELETE FROM views WHERE session=?", (session_id,))
            offset, count, generation, rev, calls = 0, 0, secrets.token_hex(6), 0, {}
        stored = {}
        def fetch(seq):
            found = db.execute("SELECT uuids, data FROM views WHERE session=? AND seq=?", (session_id, seq)).fetchone()
            if not found:
                return None
            stored[seq] = found
            return {**json.loads(found[1]), "also": found[0].split()[1:]}
        # The last row can still grow: a tool call merges into the tool row before it.
        seed = fetch(count - 1) if count else None
        rows = Rows(count - 1 if seed else count, [seed] if seed else [], fetch, {k: int(v) for k, v in calls.items()})
        rows, offset = read_messages(path, agent, offset, rows, image_refs(db, path, agent, *owner), sub)
        changed, written = [], []
        for seq, row in sorted([(rows.start + n, row) for n, row in enumerate(rows.new)] + list(rows.old.items()), key=lambda item: item[0]):
            if row is None:
                continue
            also = row.pop("also", None) or []
            record = (" ".join([row["uuid"]] + also), json.dumps(row))
            if seq in stored and stored[seq] == record:
                continue
            rev += 1
            written.append((session_id, seq, *record, rev))
            if seq < count:
                changed.append(seq)
        db.executemany("INSERT OR REPLACE INTO views VALUES(?,?,?,?,?)", written)
        count = rows.start + len(rows.new)
        calls = dict(list(rows.calls.items())[-CALLS_KEPT:])
        db.execute("INSERT OR REPLACE INTO view_state VALUES(?,?,?,?,?,?,?,?,?,?)",
                   (session_id, str(path), offset, head, count, time.time(), generation, rev, json.dumps(calls), owner[1]))
        db.commit()
        return count, changed
    except BaseException:
        db.rollback()
        raise


def image_refs(db, path, agent, session, agent_id):
    """Names a line's images from the image index, scanning the line and filling the index when the
    indexer hasn't reached it yet."""
    def refs(line, at, entry, name_of):
        found = db.execute("SELECT block, id, mime, bytes, width, height, source, file FROM images WHERE path=? AND line_offset=?",
                           (str(path), at)).fetchall()
        if found:
            return {row[0]: ref(dict(zip(("block", "id", "mime", "bytes", "width", "height", "source", "file"), row))) for row in found}
        images = claude_images(line, at, entry, name_of) if agent == "claude" else codex_images(line, at, entry, name_of)
        item = ((entry or {}).get("payload") or {}).get("item") or {}
        if item.get("type") != "UserMessage":  # the indexer decides which pasted copies to keep
            add_images(db, [{**image, "session": session, "agent_id": agent_id, "path": str(path), "line_offset": at,
                             "line_length": len(line)} for image in images])
        return {image["block"]: ref(image) for image in images}
    return refs


def merged(messages):
    """Runs of tool rows as one, as the viewer has always shown them."""
    joined = []
    for message in messages:
        if joined and message["role"] == "tool" and joined[-1]["role"] == "tool" and joined[-1]["inherited"] == message["inherited"]:
            joined[-1]["tools"] += message["tools"]
        else:
            joined.append(message)
    return joined


def viewer_row(data):
    """A stored row in the viewer's own shape (SessionMessage): tool rows as one summary line per call."""
    row = json.loads(data)
    tools = [tool["summary"] for tool in row["tools"] if not tool.get("parent")]
    return {"role": "tool" if row["role"] == "tools" else row["role"], "text": "" if row["role"] == "tools" else row["text"] or "",
            "tools": tools, "uuid": row["uuid"], "ts": row["ts"], "inherited": row["inherited"], "model": row["model"]}


def remote_row(seq, data):
    """A stored row as Remote's bridge DTO: the transcript message with its seq, without source offsets."""
    row = json.loads(data)
    row.pop("src", None)
    row["tools"] = [{key: value for key, value in tool.items() if key != "src"} for tool in row["tools"]]
    return {"seq": seq, **row}


def show(root, session_id, limit=4000, around=None):
    """One session's conversation for the viewer: prompts, replies, tool calls as one line each,
    compactions, and what it was forked from and into. Copied parent history is marked inherited.
    `around` opens at a message instead of the newest ones: a page from shortly before it, with `later` counting
    the newer messages left out."""
    path, agent = transcript_path(root, session_id)
    if not path:
        raise ValueError("That session's transcript is gone; Claude Code removes transcripts after 30 days by default.")
    db = connect(root)
    count, _ = update_view(db, session_id, path, agent)
    # Counts and pages are in messages as this format shows them: thinking rows left out, and a run of
    # tool rows (split for Remote, or around a thinking row) one message. `starts` is each one's first seq.
    starts, inherited_at, previous = [], [], None
    for seq, role, from_parent in db.execute("SELECT seq, json_extract(data, '$.role'), json_extract(data, '$.inherited') FROM views "
                                             "WHERE session=? ORDER BY seq", (session_id,)):
        if role == "thinking":
            continue
        if not (role == "tools" and previous == ("tools", from_parent)):
            starts.append(seq)
            inherited_at.append(bool(from_parent))
        previous = (role, from_parent)
    total = len(starts)
    first, last, focus = max(total - limit, 0), total, None
    if around:
        hit = db.execute("SELECT seq, uuids FROM views WHERE session=? AND instr(uuids, ?) > 0 AND json_extract(data, '$.role') != 'thinking' "
                         "ORDER BY seq LIMIT 1", (session_id, around)).fetchone()
        if hit:
            focus = hit[1].split()[0]
            index = bisect.bisect_right(starts, hit[0]) - 1
            if index < first:
                first = max(index - 40, 0)
                last = first + limit if first + limit < total - 20 else total
    start = starts[first] if first < total else count
    end = starts[last] if last < total else count
    # Thinking rows are Remote's; leaving them out also lets the tool calls around them merge as before.
    messages = merged([message for message in (viewer_row(row[0]) for row in db.execute(
        "SELECT data FROM views WHERE session=? AND seq>=? AND seq<? ORDER BY seq", (session_id, start, end))) if message["role"] != "thinking"])
    meta = db.execute(f"SELECT {','.join(SESSION_COLUMNS)} FROM sessions WHERE id=?", (session_id,)).fetchone()
    session = session_dict(meta) if meta else {"id": session_id, "agent": agent}
    forks = [session_dict(row) for row in db.execute(
        f"SELECT {','.join(SESSION_COLUMNS)} FROM sessions WHERE forked_from=? ORDER BY first_ts", (session_id,))]
    parent = None
    if session.get("forked_from"):
        row = db.execute(f"SELECT {','.join(SESSION_COLUMNS)} FROM sessions WHERE id=?", (session["forked_from"],)).fetchone()
        parent = session_dict(row) if row else {"id": session["forked_from"]}
    inherited = sum(inherited_at[:first]) if parent else 0
    db.close()
    return {"session": session, "messages": messages, "truncated": first, "forks": forks, "parent": parent,
            "focus": focus, "later": total - last, "inherited_before": inherited}


AGENT_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")


def view_target(root, session_id, agent_id=None):
    """The cache key, transcript and agent of a conversation, or of one of its subagents."""
    path, agent = transcript_path(root, session_id)
    if not path:
        raise ValueError("That session's transcript is gone; Claude Code removes transcripts after 30 days by default.")
    if not agent_id:
        return session_id, path, agent, False
    if not AGENT_ID.fullmatch(agent_id):
        raise ValueError("Unknown subagent")
    if agent == "claude":
        path = path.parent / session_id / "subagents" / f"agent-{agent_id}.jsonl"
    else:
        path, child = transcript_path(root, agent_id)
        if child != "codex":
            path = None
    if not path or not path.exists():
        raise ValueError("That subagent's transcript is gone.")
    return f"{session_id}/{agent_id}", path, agent, agent == "claude"


def parse_cursor(cursor):
    try:
        generation, seq, rev = cursor.split(".")
        return generation, int(seq), int(rev)
    except (AttributeError, ValueError):
        raise ValueError("Bad cursor") from None


def page(root, session_id, limit=None, before=None, after=None, around=None, agent_id=None):
    """A page of one conversation as Remote's bridge DTO. Cursors are `<generation>.<seq>.<rev>`: `after`
    returns the rows past it plus, in `replaced`, every row at or before it rewritten since. A cursor from
    an older generation gets the newest page with `reset`."""
    if before and after:
        raise ValueError("Use one cursor")
    limit = min(max(limit or 50, 1), 200)
    cursor = parse_cursor(before or after) if before or after else None
    key, path, agent, sub = view_target(root, session_id, agent_id)
    db = connect(root)
    try:
        count, _ = update_view(db, key, path, agent, sub, (session_id, agent_id))
        generation, rev = db.execute("SELECT generation, rev FROM view_state WHERE session=?", (key,)).fetchone()
        reset = bool(cursor) and cursor[0] != generation
        start, end, replaced = max(count - limit, 0), count, []
        if cursor and not reset:
            if after:
                start = min(max(cursor[1] + 1, 0), count)
                end = min(start + limit, count)
                replaced = [remote_row(seq, data) for seq, data in db.execute(
                    "SELECT seq, data FROM views WHERE session=? AND seq<=? AND rev>? ORDER BY seq", (key, cursor[1], cursor[2]))]
            else:
                end = min(max(cursor[1], 0), count)
                start = max(end - limit, 0)
        elif around and not cursor:
            hit = db.execute("SELECT seq FROM views WHERE session=? AND instr(uuids, ?) > 0 ORDER BY seq LIMIT 1", (key, around)).fetchone()
            if hit:
                start = max(hit[0] - 40, 0)
                end = min(start + limit, count)
        messages = [remote_row(seq, data) for seq, data in db.execute(
            "SELECT seq, data FROM views WHERE session=? AND seq>=? AND seq<? ORDER BY seq", (key, start, end))]
        inherited = db.execute("SELECT count(*) FROM views WHERE session=? AND seq<? AND data LIKE '%\"inherited\": true%'",
                               (key, start)).fetchone()[0] if start else 0
    finally:
        db.close()
    return {"session_id": session_id, "agent_id": agent_id, "generation": generation, "messages": messages, "replaced": replaced,
            "before": f"{generation}.{start}.{rev}" if start > 0 else None, "after": f"{generation}.{end - 1}.{rev}",
            "has_more_after": end < count, "count": count, "inherited_before": inherited, "reset": reset}


def line_at(path, src, token):
    """The parsed transcript line a row was read from, checked by the id it must still contain."""
    with open(path, "rb") as stream:
        stream.seek(src[0])
        line = stream.read(src[1])
    if not line.endswith(b"\n") or (token and json.dumps(token).encode() not in line):
        raise Changed
    entry = parse(line)
    if entry is None:
        raise Changed
    return entry


def whole_tool(tool, agent, path):
    """A tool with nothing cut, re-read from its call and result lines."""
    tool = dict(tool)
    srcs = tool.get("src") or []
    if agent == "claude":
        if srcs:
            entry = line_at(path, srcs[0], tool["id"])
            part = next((p for p in (entry.get("message") or {}).get("content") or [] if isinstance(p, dict) and p.get("id") == tool["id"]), None)
            if part is None:
                raise Changed
            tool["input"] = clip(part.get("input") if isinstance(part.get("input"), dict) else {}, WHOLE)
            if tool["name"] in ("Edit", "MultiEdit"):
                tool["diffs"] = diff_of(tool["name"], tool["input"], None, None)
        for src in srcs[1:]:
            entry = line_at(path, src, tool["id"])
            part = next((p for p in (entry.get("message") or {}).get("content") or []
                         if isinstance(p, dict) and p.get("type") == "tool_result" and p.get("tool_use_id") == tool["id"]), None)
            if part is None:
                raise Changed
            claude_result(tool, part, entry.get("toolUseResult"), tool["images"], tool["ended_at"], whole=True)
        return tool
    if not srcs:
        return tool
    entry = line_at(path, srcs[0], tool["id"])
    payload = entry.get("payload") or {}
    if payload.get("type") == "item_completed":
        whole = codex_item(payload.get("item") or {}, payload, tool["images"], tool["started_at"], srcs[0], whole=True)
        return {**whole, **{key: tool[key] for key in ("parent", "group") if key in tool}}
    tool.update({key: value for key, value in codex_call(payload, tool["started_at"], srcs[0], whole=True).items()
                 if key in ("input", "summary", "todos", "plan")})
    for src in srcs[1:]:
        codex_output(tool, (line_at(path, src, tool["id"]).get("payload") or {}), tool["images"], tool["ended_at"], whole=True)
    return tool


def whole_text(row, agent, path):
    src = row.get("src")
    if not src or not row["text_truncated"]:
        return row["text"]
    entry = line_at(path, src, row["uuid"])
    if agent == "codex":
        payload = entry.get("payload") or {}
        if payload.get("type") == "item_completed":
            summary = (payload.get("item") or {}).get("summary_text")
            return "\n\n".join(str(part) for part in summary) if isinstance(summary, list) else str(summary or "")
        return text_of(payload.get("content")).strip()
    if entry.get("type") == "attachment":
        return prompt_text(text_of(queued_prompt(entry)))
    content = (entry.get("message") or {}).get("content")
    if entry.get("type") == "user":
        return prompt_text(text_of(content))
    part = content[src[2]] if isinstance(content, list) and len(src) > 2 and src[2] < len(content) else {}
    return (part.get("text") or part.get("thinking") or "") if isinstance(part, dict) else None


def message(root, session_id, seq, generation, agent_id=None):
    """One row with nothing cut: text whole, tool output up to 1 MiB, every diff line, Write's whole new file.
    `{"error": "changed"}` when the generation moved on or the transcript no longer has the row's lines."""
    key, path, agent, sub = view_target(root, session_id, agent_id)
    db = connect(root)
    try:
        update_view(db, key, path, agent, sub, (session_id, agent_id))
        state = db.execute("SELECT generation FROM view_state WHERE session=?", (key,)).fetchone()
        found = db.execute("SELECT data FROM views WHERE session=? AND seq=?", (key, seq)).fetchone()
    finally:
        db.close()
    if not state or state[0] != generation or not found:
        return {"error": "changed"}
    row = json.loads(found[0])
    try:
        row["text"] = whole_text(row, agent, path)
        row["text_truncated"] = False
        row["tools"] = [whole_tool(tool, agent, path) for tool in row["tools"]]
    except (Changed, OSError):
        return {"error": "changed"}
    return remote_row(seq, json.dumps(row))


STUCK_AFTER = 600
BLOATED_AT = 150_000
TAIL = 262144


def activity(name, value):
    """The step a session is on, as a short phrase."""
    value = value if isinstance(value, dict) else {}
    target = next((value[key].strip() for key in ("file_path", "path", "notebook_path") if isinstance(value.get(key), str) and value[key].strip()), None)
    base = os.path.basename(target) if target else None
    if name == "Bash" and isinstance(value.get("command"), str):
        return "Running " + " ".join(value["command"].split())[:160]
    if name in ("Edit", "MultiEdit", "Write", "NotebookEdit") and base:
        return f"Editing {base}"
    if name == "Read" and base:
        return f"Reading {base}"
    if name in ("Grep", "Glob"):
        return "Searching" + (f" for {value['pattern'][:80]}" if isinstance(value.get("pattern"), str) else "")
    if name == "WebSearch":
        return "Searching the web"
    if name == "WebFetch":
        return "Reading a web page"
    if name in ("Task", "Agent"):
        return "Running a subagent" + (f": {value['description'][:80]}" if isinstance(value.get("description"), str) else "")
    return tool_summary(name, value)[:160]


def prompt_uuid(entry):
    """The uuid of a transcript line that starts a turn, by read_claude's rule for user rows: a prompt typed, queued
    while Claude worked, or sent from Side A, with words or a pasted image; None for anything else."""
    kind = entry.get("type")
    if kind == "attachment":
        prompt = queued_prompt(entry)
        pasted = isinstance(prompt, list) and any(isinstance(part, dict) and part.get("type") == "image" for part in prompt)
        return entry.get("uuid") if prompt is not None and (prompt_text(text_of(prompt)) or pasted) else None
    if kind != "user" or entry.get("isMeta") or entry.get("isCompactSummary"):
        return None
    content = (entry.get("message") or {}).get("content")
    pasted = isinstance(content, list) and any(isinstance(part, dict) and part.get("type") == "image" for part in content)
    return entry.get("uuid") if prompt_text(text_of(content)) or pasted else None

# A transcript's tail, read once per size and modification time: live() runs on every change to any transcript,
# and most running sessions' transcripts have not moved since the last one.
TAILS = {}


def tail_facts(lines):
    """What health() needs from a transcript's last lines, none of it depending on the time or the session's status."""
    calls, failures, context, step, mode, turn, compacted = [], 0, None, None, None, None, None
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        # Claude Code writes a permission-mode record at each change and stamps every prompt with the mode.
        if entry.get("type") in ("permission-mode", "user") and isinstance(entry.get("permissionMode"), str):
            mode = entry["permissionMode"]
        turn = prompt_uuid(entry) or turn
        # When the conversation was last compacted, so a typed /compact can be seen to have happened.
        if entry.get("type") == "system" and entry.get("subtype") == "compact_boundary":
            compacted = epoch(entry.get("timestamp")) or compacted
        if entry.get("type") not in ("user", "assistant"):
            continue
        message = entry.get("message") or {}
        content = message.get("content")
        parts = [part for part in content if isinstance(part, dict)] if isinstance(content, list) else []
        if entry["type"] == "assistant":
            usage = message.get("usage") or {}
            if usage.get("input_tokens") is not None:
                context = sum(int(usage.get(key) or 0) for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            for part in parts:
                if part.get("type") == "tool_use":
                    calls.append(json.dumps([part.get("name"), part.get("input")], sort_keys=True))
                    step = activity(part.get("name", "tool"), part.get("input"))
                elif part.get("type") == "text" and part.get("text", "").strip():
                    step = "Writing a reply"
        else:
            for part in parts:
                if part.get("type") == "tool_result":
                    failures = failures + 1 if part.get("is_error") else 0
                elif part.get("type") == "text" and prompt_text(part.get("text", "")):
                    step, failures = "Reading your message", 0
            if isinstance(content, str) and prompt_text(content):
                step, failures = "Reading your message", 0
    return calls[-6:], failures, context, step, mode, turn, compacted


def health(path, status):
    """What a running session is doing from its transcript's tail, and the one thing most worth flagging:
    no progress, the same step over and over, a run of failures, or a context that every step re-reads."""
    try:
        stamp = os.stat(path)
        key = (stamp.st_size, stamp.st_mtime_ns)
        if TAILS.get(str(path), (None,))[0] != key:
            with open(path, "rb") as stream:
                stream.seek(max(0, stamp.st_size - TAIL))
                lines = stream.read().splitlines()
            if len(TAILS) >= 512:
                TAILS.clear()
            TAILS[str(path)] = (key, tail_facts(lines))
    except OSError:
        return {}
    recent, failures, context, step, mode, turn, compacted = TAILS[str(path)][1]
    quiet = time.time() - stamp.st_mtime
    repeats = max((recent.count(call) for call in recent), default=0)
    flag = None
    if status == "busy" and quiet >= STUCK_AFTER:
        flag = {"kind": "stuck", "text": f"No progress for {int(quiet // 60)} min"}
    elif status == "busy" and repeats >= 3:
        flag = {"kind": "loop", "text": f"Repeated the same step {repeats} times"}
    elif status == "busy" and failures >= 4:
        flag = {"kind": "failing", "text": f"{failures} failed steps in a row"}
    elif context and context >= BLOATED_AT:
        flag = {"kind": "bloated", "text": f"Context is {round(context / 1000)}k tokens"}
    return {"activity": step if status == "busy" else None, "context": context, "flag": flag, "mode": mode, "turnID": turn,
            "compactedAt": compacted}


def process_tree():
    """Each process's resident memory in MB, its children and its start time, from one ps call; empty when ps fails.
    The start time tells a process from a later one that reuses its pid, before Side A signals it."""
    import subprocess
    try:
        listing = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,lstart=,args="], capture_output=True, text=True, timeout=10,
                                 env={**os.environ, "LC_ALL": "C"}).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}, {}, {}, {}
    memory, children, started, args = {}, {}, {}, {}
    for line in listing.splitlines():
        # lstart is five fields ("Sat Oct 17 10:00:00 2026"), then the command line.
        parts = line.split(None, 8)
        if len(parts) >= 8 and all(part.isdigit() for part in parts[:3]):
            pid, parent, rss = map(int, parts[:3])
            memory[pid] = rss / 1024
            children.setdefault(parent, []).append(pid)
            args[pid] = parts[8] if len(parts) > 8 else ""
            at = start_time(" ".join(parts[3:8]))
            if at is not None:
                started[pid] = at
    return memory, children, started, args


STARTS = {}


def start_time(text):
    """ps's lstart as epoch seconds, None when it isn't a date. Kept, since the same processes come back on every call."""
    if text not in STARTS:
        if len(STARTS) >= 8192:
            STARTS.clear()
        try:
            STARTS[text] = int(time.mktime(time.strptime(text, "%a %b %d %H:%M:%S %Y")))
        except (ValueError, OverflowError):
            STARTS[text] = None
    return STARTS[text]


def descendants(pid, memory, children):
    """A session's process and everything it started (tools, MCP servers, shells, dev servers)."""
    if pid <= 1:
        return set()  # pid 0 and launchd would be every process on the Mac
    seen, stack = set(), [pid]
    while stack:
        current = stack.pop()
        if current in seen or current not in memory:
            continue
        seen.add(current)
        stack.extend(children.get(current, []))
    return seen


def footprint(pid, memory, children):
    """Memory in MB of a session and everything it started, and how many processes."""
    seen = descendants(pid, memory, children)
    return round(sum(memory[p] for p in seen)), len(seen)


def parse_listening(output):
    """pid -> [{port, pid, command}] from `lsof -F pcn` output for listening TCP sockets."""
    ports, pid, command = {}, None, None
    for line in output.splitlines():
        field, value = line[:1], line[1:]
        if field == "p":
            pid, command = int(value) if value.isdigit() else None, None
        elif field == "c":
            command = value
        elif field == "n" and pid is not None:
            port = value.rsplit(":", 1)[-1]
            entry = {"port": int(port), "pid": pid, "command": command} if port.isdigit() else None
            if entry and entry not in ports.setdefault(pid, []):
                ports[pid].append(entry)
    return ports


# lsof walks every process on the Mac, seconds of work when many sessions run, so its answer is kept this long.
PORTS_FRESH = 15
PORTS = {"at": 0.0, "found": {}}


def listening():
    """Listening TCP ports by pid from one lsof call, at most every PORTS_FRESH seconds; empty when lsof is missing or slow."""
    import subprocess
    if time.monotonic() - PORTS["at"] < PORTS_FRESH:
        return PORTS["found"]
    try:
        output = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"],
                                capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        # A slow lsof isn't asked again on every poll.
        PORTS.update(at=time.monotonic(), found={})
        return PORTS["found"]
    PORTS.update(at=time.monotonic(), found=parse_listening(output))
    return PORTS["found"]


CODEX_NOT_SESSIONS = ("app-server", "exec", "login", "logout", "mcp", "mcp-server", "completion")
TURN_EVENTS = (b'"task_started"', b'"task_complete"', b'"turn_aborted"')


def is_codex_session(command):
    """A `codex` process someone is talking to, not a one-shot command or Side A's own app server."""
    words = (command or "").split()
    return bool(words) and os.path.basename(words[0]) == "codex" and (len(words) < 2 or words[1] not in CODEX_NOT_SESSIONS)


def codex_open(pids):
    """pid -> {"rollouts": [...], "cwd": ...} from one lsof call over every Codex process."""
    import subprocess
    if not pids:
        return {}
    try:
        output = subprocess.run(["lsof", "-nP", "-p", ",".join(map(str, pids)), "-Fpfn"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found, pid, fd = {}, None, None
    for line in output.splitlines():
        field, value = line[:1], line[1:]
        if field == "p":
            pid = int(value) if value.isdigit() else None
            if pid is not None:
                found[pid] = {"rollouts": [], "cwd": None}
        elif field == "f":
            fd = value
        elif field == "n" and pid is not None:
            if fd == "cwd":
                found[pid]["cwd"] = value
            elif "/sessions/" in value and os.path.basename(value).startswith("rollout-") and value.endswith(".jsonl"):
                found[pid]["rollouts"].append(value)
    return found


def rollouts_since(root, since):
    """Rollouts in the dated folders (sessions/YYYY/MM/DD) from `since` to today, so live doesn't list them all."""
    days = []
    for offset in range(0, min(int((time.time() - since) // 86400) + 2, 32)):
        day = time.localtime(since + offset * 86400)
        days.append(time.strftime("%Y/%m/%d", day))
    for home in codex_homes(root):
        for name in dict.fromkeys(days):
            folder = home / "sessions" / name
            if folder.is_dir():
                yield from folder.glob("rollout-*.jsonl")


def first_entry(path):
    try:
        with open(path, "rb") as stream:
            return parse(stream.readline()) or {}
    except OSError:
        return {}


def codex_tail(path):
    """The parsed entries at the end of a rollout: the last 256 KB, or the last 4 MB when that has no turn event."""
    entries = []
    try:
        with open(path, "rb") as stream:
            for size in (TAIL, 16 * TAIL):
                stream.seek(0, os.SEEK_END)
                end = stream.tell()
                stream.seek(max(0, end - size))
                data = stream.read()
                if any(marker in data for marker in TURN_EVENTS) or end <= size or size > TAIL:
                    break
    except OSError:
        return [], False
    lines = data.split(b"\n")
    if len(data) < end:
        lines = lines[1:]  # the first line was cut by the seek
    entries = [entry for entry in (parse(line) for line in lines if line) if entry]
    return entries, len(data) >= end


def codex_status(entries, whole, mtime):
    """busy, idle, waiting or unknown from a rollout's tail, with since, the open question and the pending call."""
    turn, since, outputs, calls, policy, model = None, None, set(), [], None, None
    for entry in entries:
        payload = entry.get("payload") or {}
        kind = payload.get("type")
        if entry.get("type") == "turn_context":
            policy, model = payload.get("approval_policy", policy), payload.get("model") or model
        elif kind == "task_started":
            turn, since, calls = "busy", epoch(payload.get("started_at")) or epoch(entry.get("timestamp")), []
        elif kind in ("task_complete", "turn_aborted"):
            turn, since = "idle", epoch(payload.get("completed_at")) or epoch(entry.get("timestamp"))
        elif kind in ("function_call", "custom_tool_call"):
            calls.append((payload.get("call_id"), payload.get("name") or "tool", epoch(entry.get("timestamp"))))
        elif kind in ("function_call_output", "custom_tool_call_output"):
            outputs.add(payload.get("call_id"))
    if turn is None:
        # No turn event in reach: an empty rollout is idle, a long one we can't place is unknown, never idle.
        return {"status": "idle" if whole else "unknown", "since": mtime, "waitingFor": None, "pending_call": None, "model": model}
    status, waiting, pending = turn, None, None
    open_calls = [call for call in calls if call[0] not in outputs]
    if turn == "busy" and any(name.startswith("request_user_input") for _, name, _ in open_calls):
        status, waiting = "waiting", "question"
    elif turn == "busy" and open_calls and calls[-1][0] not in outputs and policy not in (None, "never"):
        pending = {"name": calls[-1][1], "since": calls[-1][2]}
    return {"status": status, "since": since or mtime, "waitingFor": waiting, "pending_call": pending, "model": model}


def codex_health(entries, status, quiet):
    """health's step, context and flag, read from Codex items."""
    commands, exits, context, step = [], [], None, None
    for entry in entries:
        payload = entry.get("payload") or {}
        kind = payload.get("type")
        if kind == "token_count":
            usage = (payload.get("info") or {}).get("last_token_usage") or {}
            if usage:
                context = int(usage.get("input_tokens") or 0) + int(usage.get("cached_input_tokens") or 0)
        elif kind == "item_completed":
            item = payload.get("item") or {}
            if item.get("type") == "CommandExecution":
                command = command_text(item.get("command"))
                commands.append(command)
                exits.append(item.get("exit_code"))
                step = activity("Bash", {"command": command})
            elif item.get("type") == "McpToolCall":
                step = tool_summary(f"{item.get('server')}: {item.get('tool')}", {})[:160]
            elif item.get("type") == "AgentMessage":
                step = "Writing a reply"
        elif kind == "custom_tool_call" and payload.get("name") == "exec":
            step = "Running code"
        elif kind == "message" and payload.get("role") == "assistant":
            step = "Writing a reply"
    recent = commands[-6:]
    repeats = max((recent.count(command) for command in recent), default=0)
    failures = 0
    for code in reversed(exits):
        if not code:
            break
        failures += 1
    flag = None
    if status == "busy" and quiet >= STUCK_AFTER:
        flag = {"kind": "stuck", "text": f"No progress for {int(quiet // 60)} min"}
    elif status == "busy" and repeats >= 3:
        flag = {"kind": "loop", "text": f"Repeated the same step {repeats} times"}
    elif status == "busy" and failures >= 4:
        flag = {"kind": "failing", "text": f"{failures} failed steps in a row"}
    elif context and context >= BLOATED_AT:
        flag = {"kind": "bloated", "text": f"Context is {round(context / 1000)}k tokens"}
    return {"activity": step if status == "busy" else None, "context": context, "flag": flag}


def tmux_panes(root):
    """pane pid -> tmux session name on Side A's own tmux server; empty when it isn't running."""
    import hosting
    return hosting.panes(root)


def hosted_by(pid, parents, panes):
    """The Side A tmux session a process runs under, walking up through its ancestors."""
    seen = set()
    while pid and pid > 1 and pid not in seen:
        if pid in panes:
            return panes[pid]
        seen.add(pid)
        pid = parents.get(pid)
    return None


def live_codex(root, memory, children, started, ports, parents, args):
    """Running Codex sessions in the shape of live's Claude rows: each process mapped to the rollout it
    has open, its status from the rollout's tail."""
    pids = [pid for pid, command in args.items() if is_codex_session(command)]
    pids = [pid for pid in pids if not any(hosted_by(parents.get(pid), parents, {other: True}) for other in pids if other != pid)]
    if not pids:
        return []
    opened = codex_open(pids)
    threads = codex_threads(root)
    db = connect(root)
    rows = []
    for pid in pids:
        info = opened.get(pid) or {"rollouts": [], "cwd": None}
        main, subagents = None, 0
        for path in info["rollouts"]:
            if (first_entry(path).get("payload") or {}).get("parent_thread_id"):
                subagents += 1
            elif main is None:
                main = path
        if main is None and info["cwd"]:
            # Between turns some versions close the rollout: the newest one for this folder since the process started.
            newest = 0
            for path in rollouts_since(root, started.get(pid) or time.time() - 86400):
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime > newest and mtime >= (started.get(pid) or 0) and (first_entry(path).get("payload") or {}).get("cwd") == info["cwd"]:
                    main, newest = str(path), mtime
        if main is None:
            continue
        meta = first_entry(main).get("payload") or {}
        entries, whole = codex_tail(main)
        try:
            mtime = os.path.getmtime(main)
        except OSError:
            continue
        status = codex_status(entries, whole, mtime)
        thread = meta.get("id")
        row = db.execute("SELECT title, model FROM sessions WHERE id=?", (thread,)).fetchone() if thread else None
        rows.append({"agent": "codex", **codex_health(entries, status["status"], time.time() - mtime), "pid": pid, "id": thread, "name": None,
                     "title": (row[0] if row else None) or (threads.get(thread) or {}).get("title") or None, "cost": None,
                     "cwd": meta.get("cwd") or info["cwd"], "status": status["status"], "waitingFor": status["waitingFor"],
                     "since": status["since"], "kind": None,
                     **dict(zip(("memory", "processes"), footprint(pid, memory, children) if memory else (None, None))),
                     "ports": sorted(({**entry, "started": started.get(p)} for p in descendants(pid, memory, children) - {pid}
                                      for entry in ports.get(p, [])), key=lambda e: e["port"]),
                     "started": started.get(pid), "model": status["model"] or (row[1] if row else None), "subagents": subagents,
                     "pending_call": status["pending_call"], "path": main})
    db.close()
    return rows


SETTINGS_KEEP = 7 * 86400


def saved(path):
    """A JSON object Side A's statusline or hooks wrote, and when; (None, 0) when it's missing or half-written."""
    try:
        with open(path) as stream:
            at = os.fstat(stream.fileno()).st_mtime
            value = json.load(stream)
    except (OSError, ValueError):
        return None, 0
    return (value, at) if isinstance(value, dict) else (None, 0)


def newest(*readings):
    """The value of the newest (value, time) reading that has one."""
    return max(((at, value) for value, at in readings if value is not None), default=(0, None), key=lambda r: r[0])[1]


def prune_settings(root, running):
    """Drops what sessions long gone saved, copies a statusline or hook stopped mid-write, and the background work of
    any session no longer running: nothing would end it in the count otherwise."""
    now = time.time()
    for folder in (root / "runtime" / "live" / "s", root / "runtime" / "state"):
        for path in folder.iterdir() if folder.is_dir() else ():
            try:
                age = now - path.stat().st_mtime
                if age > SETTINGS_KEEP or (age > 60 and not path.name.endswith(".json")) or \
                        (path.name.endswith(".tasks.json") and path.name[:-len(".tasks.json")] not in running):
                    path.unlink()
            except OSError:
                continue


def claude_settings(root, session_id, mode=None, mode_at=0):
    """What a running Claude session last reported about itself: model, effort, fast mode, context and cost from its
    statusline (when Side A wraps it), mode and effort from any of Side A's hooks, a model switch from PostModelSwitch,
    background work from its last Stop, and the mode in its transcript's tail. The newest reading of each wins."""
    if not session_id or not AGENT_ID.fullmatch(session_id):
        return {}
    line, line_at = saved(root / "runtime" / "live" / "s" / f"{session_id}.json")
    state = root / "runtime" / "state"
    hook, hook_at = saved(state / f"{session_id}.hook.json")
    switch, switch_at = saved(state / f"{session_id}.model.json")
    tasks, _ = saved(state / f"{session_id}.tasks.json")
    line, hook, switch = line or {}, hook or {}, switch or {}
    model = (line.get("model") or {}).get("id") if isinstance(line.get("model"), dict) else None
    effort = (line.get("effort") or {}).get("level") if isinstance(line.get("effort"), dict) else None
    window = line.get("context_window") if isinstance(line.get("context_window"), dict) else {}
    cost = line.get("cost") if isinstance(line.get("cost"), dict) else {}
    settings = {
        "model": newest((model, line_at), (switch.get("model"), switch_at)),
        "effort": newest((effort, line_at), (hook.get("effort"), hook_at)),
        "mode": newest((mode, mode_at), (hook.get("mode"), hook_at)),
        "fast": line["fast_mode"] if isinstance(line.get("fast_mode"), bool) else None,
        "contextPercent": window["used_percentage"] if isinstance(window.get("used_percentage"), (int, float)) else None,
        "cost": cost["total_cost_usd"] if isinstance(cost.get("total_cost_usd"), (int, float)) else None,
        "backgroundTasks": tasks.get("tasks") if tasks and isinstance(tasks.get("tasks"), list) else None,
    }
    return {key: value for key, value in settings.items() if value is not None and not (isinstance(value, str) and not value)}


TRANSCRIPTS = {}


def claude_transcript(session_id):
    """A Claude session's transcript, found once: the search reads every project folder."""
    if not session_id:
        return None
    known = TRANSCRIPTS.get(session_id)
    if known is None or not known.exists():
        known = next((Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"), None)
        if known is None:
            TRANSCRIPTS.pop(session_id, None)
        else:
            TRANSCRIPTS[session_id] = known
    return known


def live(root):
    """Running Claude Code and Codex sessions, waiting on you first, then working, then idle, with each
    one's memory, process count, the TCP ports its processes listen on and the Side A tmux session hosting it."""
    sessions = []
    memory, children, started, *rest = process_tree()
    args = rest[0] if rest else {}
    parents = {child: parent for parent, kids in children.items() for child in kids}
    ports = listening() if memory else {}
    panes = tmux_panes(root) if memory else {}
    folder = Path.home() / ".claude" / "sessions"
    db = connect(root)
    for path in folder.glob("*.json") if folder.is_dir() else []:
        try:
            data = json.loads(path.read_text())
            pid = int(data["pid"])
            if pid <= 1:
                continue
            os.kill(pid, 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue  # not running, or a half-written file
        if data.get("cwd") == str(root):
            continue  # Side A's own window priming
        row = db.execute("SELECT title, cost FROM sessions WHERE id=?", (data.get("sessionId"),)).fetchone()
        status = data.get("status") or "idle"
        path = claude_transcript(data.get("sessionId"))
        found = health(path, status) if path else {}
        if path and not found.get("turnID"):
            # A turn longer than the tail started earlier: its prompt is the newest user row the viewer cached.
            newest = db.execute("SELECT data FROM views WHERE session=? AND data LIKE ? ORDER BY seq DESC LIMIT 1",
                                (data.get("sessionId"), '{"role": "user"%')).fetchone()
            found["turnID"] = json.loads(newest[0]).get("uuid") if newest else None
        with contextlib.suppress(OSError):
            found.update(claude_settings(root, data.get("sessionId"), found.get("mode"), os.path.getmtime(path) if path else 0))
        sessions.append({"agent": "claude", "cost": row[1] if row else None, **found, "pid": pid, "id": data.get("sessionId"), "name": data.get("name"),
                         "title": row[0] if row else None, "cwd": data.get("cwd"), "status": status,
                         "waitingFor": data.get("waitingFor"), "since": epoch(data.get("statusUpdatedAt") or 0),
                         "kind": data.get("kind"),
                         **dict(zip(("memory", "processes"), footprint(pid, memory, children) if memory else (None, None))),
                         # Claude Code itself listens on a port; only what it started counts as a server.
                         "ports": sorted(({**entry, "started": started.get(p)} for p in descendants(pid, memory, children) - {pid}
                                          for entry in ports.get(p, [])), key=lambda e: e["port"]),
                         "started": started.get(pid)})
    db.close()
    prune_settings(root, {session["id"] for session in sessions})
    for row in live_codex(root, memory, children, started, ports, parents, args) if args else []:
        row.pop("path")
        sessions.append(row)
    import hosting
    # A hosted session runs under one of the panes of Side A's tmux server; when several reach one pane, the closest keeps it.
    hosting.match(sessions, parents, panes)
    order = {"waiting": 0, "busy": 1}
    sessions.sort(key=lambda s: (order.get(s["status"], 2), -(s["since"] or 0)))
    return {"sessions": sessions}


TURN_NOTE = "Edits made with Claude's file tools; shell changes aren't shown."
TURN_FILES = 500


def claude_busy(session_id):
    """Whether a running Claude session is mid-turn, by Claude Code's session registry."""
    folder = Path.home() / ".claude" / "sessions"
    for path in folder.glob("*.json") if folder.is_dir() else ():
        try:
            data = json.loads(path.read_text())
            if data.get("sessionId") == session_id:
                os.kill(int(data["pid"]), 0)
                return data.get("status") in ("busy", "waiting")
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return False


def rename_live(session_id, name, timeout=2.0):
    """Gives a running Claude session a new title through its own inbox, the socket Claude Code 2.1.3xx opens at
    `messagingSocketPath` in its registry record. Claude takes a `rename` control the way its session list's rename
    does: the prompt border, the terminal's title, /resume and the registry all change, and Claude writes the
    custom-title row itself, so Side A never edits a transcript. The `session_id` makes Claude drop it if that pid
    now runs another conversation. Returns whether a live session took it; Codex, a closed session or an older
    Claude without an inbox gets False and keeps Side A's own name."""
    import socket
    import stat
    title = " ".join(str(name or "").split())
    if not session_id or not title:
        return {"renamed": False, "reason": "empty"}
    folder = Path.home() / ".claude" / "sessions"
    for path in folder.glob("*.json") if folder.is_dir() else ():
        try:
            data = json.loads(path.read_text())
            if data.get("sessionId") != session_id:
                continue
            pid = int(data["pid"])
            if pid <= 1:
                continue
            os.kill(pid, 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue
        address = data.get("messagingSocketPath")
        if not isinstance(address, str) or not os.path.isabs(address):
            return {"renamed": False, "reason": "no-inbox"}
        try:
            info = os.lstat(address)
        except OSError:
            return {"renamed": False, "reason": "no-inbox"}
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            return {"renamed": False, "reason": "no-inbox"}
        lines = []
        # macOS doesn't require the auth line, but a session that published its key gets it.
        key = folder / f"{pid}.{hashlib.sha256(address.encode()).hexdigest()}.key"
        with contextlib.suppress(OSError, ValueError, TypeError, AttributeError):
            token = json.loads(key.read_text()).get("peerToken")
            if isinstance(token, str) and token:
                lines.append({"type": "auth", "token": token})
        lines.append({"type": "control", "action": "rename", "name": title[:200], "session_id": session_id})
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(timeout)
                connection.connect(address)
                connection.sendall("".join(json.dumps(line) + "\n" for line in lines).encode())
                connection.shutdown(socket.SHUT_WR)
                # Claude closes its end once it has read the lines; waiting for that keeps the rename ahead of a refresh.
                with contextlib.suppress(OSError):
                    connection.recv(1)
        except OSError:
            return {"renamed": False, "reason": "unreachable"}
        return {"renamed": True}
    return {"renamed": False, "reason": "not-running"}


def turn_diff(root, session_id, turn=None):
    """What one turn of a Claude session changed with its file tools: every edit that went through, in order, from the
    turn's prompt to the next. Edits to one file stay separate, each hunk numbered as that edit saw the file, since
    merging them would invent a diff. `turn` is the prompt's uuid, the newest turn when it's left out."""
    key, path, agent, _ = view_target(root, session_id)
    if agent != "claude":
        raise ValueError("Codex reports its own turn diffs")
    db = connect(root)
    try:
        count, _ = update_view(db, key, path, agent, owner=(session_id, None))
        prompts = [(seq, json.loads(data).get("uuid")) for seq, data in db.execute(
            "SELECT seq, data FROM views WHERE session=? AND data LIKE ? ORDER BY seq", (key, '{"role": "user"%'))]
        at = next((n for n, (_, uuid) in enumerate(prompts) if uuid == turn), None) if turn else len(prompts) - 1 if prompts else None
        if at is None:
            raise ValueError("That turn isn't in this conversation" if turn else "This conversation has no turn yet")
        start, end = prompts[at][0] + 1, prompts[at + 1][0] if at + 1 < len(prompts) else count
        files = [diff for (data,) in db.execute("SELECT data FROM views WHERE session=? AND seq>=? AND seq<? ORDER BY seq", (key, start, end))
                 for tool in json.loads(data)["tools"] if tool.get("status") == "ok" for diff in tool.get("diffs") or []]
    finally:
        db.close()
    last = at == len(prompts) - 1
    return {"session_id": session_id, "turn_id": prompts[at][1], "files": files[:TURN_FILES], "omitted": max(len(files) - TURN_FILES, 0),
            "running": last and claude_busy(session_id), "note": TURN_NOTE}


def image(root, image_id, recheck=False):
    """Where an image's bytes are, for the app to read; the bridge never sends them. `recheck` re-scans
    the line of the newest locator after its bytes failed to match the id, fixing or dropping its rows."""
    if not re.fullmatch(r"[0-9a-f]{40}", image_id or ""):
        return {"error": "gone"}
    db = connect(root)
    try:
        for _ in range(8):
            located = locate(db, image_id)
            if located is None or not recheck:
                return located or {"error": "gone"}
            if rescan(db, located, image_id):
                return locate(db, image_id) or {"error": "gone"}
        return {"error": "gone"}
    finally:
        db.close()


def locate(db, image_id):
    columns = ("path", "line_offset", "line_length", "block", "data_offset", "data_length", "file", "source", "mime", "bytes", "width", "height")
    for row in db.execute(f"SELECT {','.join(columns)} FROM images WHERE id=? ORDER BY ts DESC", (image_id,)).fetchall():
        found = dict(zip(columns, row))
        located = {"id": image_id, **{key: found[key] for key in ("mime", "bytes", "width", "height", "source")}}
        if found["file"]:
            try:
                with open(found["file"], "rb") as stream:
                    if not sniff(stream.read(16)):
                        continue  # a transcript must not point the server at anything but an image
            except OSError:
                continue
            return {**located, "kind": "file", "file": found["file"], "path": found["path"]}
        try:
            size = os.path.getsize(found["path"])
        except OSError:
            continue
        if found["data_offset"] is not None and size >= found["data_offset"] + found["data_length"]:
            return {**located, "kind": "inline", "path": found["path"], "data_offset": found["data_offset"], "data_length": found["data_length"]}
        if found["data_offset"] is None and size >= found["line_offset"] + found["line_length"]:
            return {**located, "kind": "line", "path": found["path"], "line_offset": found["line_offset"],
                    "line_length": found["line_length"], "block": found["block"]}
    return None


def rescan(db, located, image_id):
    """Re-reads the line a stale locator points at and replaces its rows. True when the id was found again there."""
    path = located["path"]
    rows = db.execute("SELECT line_offset, line_length, session, agent_id FROM images WHERE id=? AND path=?", (image_id, path)).fetchall()
    found = False
    for offset, length, session, agent_id in rows:
        db.execute("DELETE FROM images WHERE path=? AND line_offset=?", (path, offset))
        try:
            with open(path, "rb") as stream:
                stream.seek(offset)
                line = stream.readline()
        except OSError:
            continue
        entry = parse(line) if line.endswith(b"\n") else None
        agent = "codex" if is_codex_path(path) else "claude"
        images = (claude_images if agent == "claude" else codex_images)(line, offset, entry, lambda call: None)
        add_images(db, [{**item, "session": session, "agent_id": agent_id, "path": path, "line_offset": offset,
                         "line_length": len(line)} for item in images])
        found = found or any(item["id"] == image_id for item in images)
    db.commit()
    return found


def images(root, session_id, limit=200, before=None):
    """A session's images, newest first, for a gallery: each with the transcript row it sits in when that's cached."""
    db = connect(root)
    try:
        found = db.execute("SELECT id, mime, bytes, width, height, source, file, uuid, ts, agent_id FROM images WHERE session=?"
                           + (" AND ts < ?" if before is not None else "") + " ORDER BY ts DESC LIMIT ?",
                           (session_id, float(before), limit) if before is not None else (session_id, limit)).fetchall()
        result = []
        for id_, mime, size, width, height, source, file, uuid, ts, agent_id in found:
            key = f"{session_id}/{agent_id}" if agent_id else session_id
            hit = db.execute("SELECT seq FROM views WHERE session=? AND instr(uuids, ?) > 0 ORDER BY seq LIMIT 1", (key, uuid)).fetchone() if uuid else None
            result.append({**ref({"id": id_, "mime": mime, "bytes": size, "width": width, "height": height, "source": source, "file": file}),
                           "seq": hit[0] if hit else None, "uuid": uuid, "ts": ts, "agent_id": agent_id})
    finally:
        db.close()
    return {"images": result}
