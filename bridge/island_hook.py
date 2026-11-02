"""side-a-island: hands a permission request to Side A's island and prints the answer, and tells it
when a session has finished its work. A note or a stop the user sends a working session from Side A
is handed over at its next tool call.

Claude Code and Codex run this as a PermissionRequest hook. It sends the request to Side A over a
private Unix socket and waits. Whatever goes wrong (Side A closed, socket missing, no answer), it
exits quietly and the CLI asks in the terminal as usual. Claude Code keeps its own prompt open
meanwhile but leaves this hook running when the prompt is answered there, so Side A watches Claude
Code's session registry and releases the hook (an "ask") once the session stops waiting. Codex asks
the hook before its own reviewer, so the hook steps aside when Codex settles the call itself.

Standard library only; run with -I -S so nothing from the session's folder is imported.
"""
import contextlib
import json
import os
import socket
import sys
import time

READ_LIMIT = 1 << 20


def slot():
    """The Keychain slot the session reads its login from, by Claude Code's rule; "mac" for the Mac login."""
    store = os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
    if store is None:
        store = os.environ.get("CLAUDE_CONFIG_DIR") or ""
    return os.path.basename(store.rstrip("/")) if store else "mac"


def output(answer, agent):
    """The hook's stdout for Side A's answer, or None to leave the decision to the terminal."""
    behavior = answer.get("behavior") if isinstance(answer, dict) else None
    if behavior == "allow":
        decision = {"behavior": "allow"}
        # Codex fails closed on updatedPermissions, so rules are only ever sent to Claude Code.
        if agent == "claude" and isinstance(answer.get("permissions"), list) and answer["permissions"]:
            decision["updatedPermissions"] = answer["permissions"]
        # "Allow and switch mode": the session leaves the prompt in that mode, as Shift+Tab would put it.
        mode = answer.get("mode")
        if agent == "claude" and isinstance(mode, str) and 0 < len(mode) <= 32 and mode.isalpha():
            decision["updatedPermissions"] = decision.get("updatedPermissions", []) + [{"type": "setMode", "mode": mode, "destination": "session"}]
        # Questions and plans are answered by sending their input back with the answer.
        if agent == "claude" and isinstance(answer.get("input"), dict):
            decision["updatedInput"] = answer["input"]
    elif behavior == "deny":
        decision = {"behavior": "deny", "message": str(answer.get("message") or "Denied in Side A.")}
        if agent == "claude" and answer.get("interrupt") is True:
            decision["interrupt"] = True
    else:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


def tell(path, message):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(2)
        connection.connect(path)
        connection.sendall(json.dumps(message).encode() + b"\n")
    finally:
        connection.close()


def ask(path, message, settled=None):
    """Sends one line and reads one line back; None when Side A isn't there or hands it back, or once `settled`
    says the request was answered elsewhere, which closes it so the island drops it."""
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(2)
        connection.connect(path)
        connection.sendall(json.dumps(message).encode() + b"\n")
        # Wait as long as the CLI lets the hook run; Side A answers or closes.
        connection.settimeout(WATCH_POLL if settled else None)
        data = b""
        while not data.endswith(b"\n") and len(data) < READ_LIMIT:
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                if settled():
                    return None
                continue
            if not chunk:
                return None
            data += chunk
        return json.loads(data)
    finally:
        connection.close()


STOP_HOLD = 10


def read_note(path):
    with open(path) as stream:
        note = json.load(stream)
    return note if isinstance(note, dict) else None


def stop(folder, pid):
    """A stop stays a few seconds so every tool call of the response it ends is denied, not only the first."""
    path = os.path.join(folder, f"{pid}.json")
    try:
        note = read_note(path)
    except OSError:
        return False
    except ValueError:
        # Side A writes whole files; a stop is being stamped, so it counts unless it was left broken.
        try:
            return time.time() - os.path.getmtime(path) < STOP_HOLD
        except OSError:
            return False
    if not note or note.get("kind") != "stop":
        return False
    since = note.get("since")
    if not isinstance(since, (int, float)):
        stamped = f"{path}.{os.getpid()}"
        with contextlib.suppress(OSError):
            with open(stamped, "w") as stream:
                json.dump({"kind": "stop", "since": time.time()}, stream)
            os.replace(stamped, path)
        return True
    if time.time() - since < STOP_HOLD:
        return True
    with contextlib.suppress(OSError):
        os.unlink(path)
    return False


def take(folder, pid):
    """Claims the note Side A left for this session; parallel tool calls race for it, and the one
    that wins reads what it claimed, so a note Side A replaced meanwhile is never lost."""
    path = os.path.join(folder, f"{pid}.json")
    try:
        note = read_note(path)
    except (OSError, ValueError):
        return None
    if not note or note.get("kind") != "note":
        return None
    claimed = f"{path}.{os.getpid()}"
    try:
        os.rename(path, claimed)
        note = read_note(claimed)
    except (OSError, ValueError):
        return None
    if not note or note.get("kind") != "note":
        # A stop replaced the note between the read and the claim: put it back.
        with contextlib.suppress(OSError):
            os.link(claimed, path)
    with contextlib.suppress(OSError):
        os.unlink(claimed)
    return note if note and note.get("kind") == "note" else None


def mail(folder, pid, event, agent="claude"):
    """Side A's Stop ends the turn before the next tool runs; a note joins the context after a tool finishes.
    Codex 0.163 fails a PreToolUse hook that says continue:false and runs the tool anyway, so it only gets the deny."""
    if event == "PreToolUse" and stop(folder, pid):
        deny = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                       "permissionDecisionReason": "The user stopped this session from Side A."}}
        return deny if agent == "codex" else {"continue": False, "stopReason": "Stopped from Side A.", **deny}
    if event in ("PostToolUse", "PostToolUseFailure"):
        note = take(folder, pid)
        text = note.get("text") if note else None
        if isinstance(text, str) and text.strip():
            return {"hookSpecificOutput": {"hookEventName": event, "additionalContext":
                    "While you work, the user sent this note from Side A. Take it into account from here on:\n\n" + text.strip()}}
    return None


INBOX_POLL = 0.25
INBOX_PREAMBLE = "The user sent you this from Side A:\n\n"


def write_atomic(path, text):
    staged = f"{path}.{os.getpid()}"
    with open(staged, "w") as stream:
        stream.write(text)
    os.replace(staged, path)


def inbox(folder, pid):
    """Claude Code runs this at SessionStart and every Stop with asyncRewake: it waits in the background for a message
    Side A leaves in inbox/<pid>.json and exits 2 with it, which wakes even an idle session and joins a working one
    at its next step. Claude Code keeps every earlier one running, so the newest takes over <pid>.watcher and the
    others leave; so does one whose session is gone (a crash leaves it to launchd)."""
    owner = os.path.join(folder, f"{pid}.watcher")
    box = os.path.join(folder, f"{pid}.json")
    parent = os.getppid()
    me = str(os.getpid())
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        write_atomic(owner, me)
    except OSError:
        return None
    while True:
        try:
            with open(owner) as stream:
                if stream.read().strip() != me:
                    return None
        except OSError:
            return None
        if os.getppid() != parent:
            with contextlib.suppress(OSError):
                os.unlink(owner)
            return None
        claimed = f"{box}.{me}"
        try:
            os.rename(box, claimed)
        except OSError:
            time.sleep(INBOX_POLL)
            continue
        try:
            note = read_note(claimed)
        except (OSError, ValueError):
            note = None
        with contextlib.suppress(OSError):
            os.unlink(claimed)
        text = note.get("text") if isinstance(note, dict) else None
        if isinstance(text, str) and text.strip():
            # Side A reads this to know it arrived; the watcher that wakes the session leaves the role to the next.
            with contextlib.suppress(OSError):
                write_atomic(os.path.join(folder, f"{pid}.delivered"), json.dumps({"id": note.get("id"), "at": time.time()}))
            with contextlib.suppress(OSError):
                os.unlink(owner)
            return text.strip()


TAIL_CHUNK = 1 << 20
REVIEW_REACH = 16 << 20


def lines_backward(path, reach):
    """A JSONL file's lines from its end, newest first, within its last `reach` bytes."""
    with open(path, "rb") as stream:
        size = end = stream.seek(0, os.SEEK_END)
        carry = b""
        while end > 0 and size - end < reach:
            start = max(0, end - TAIL_CHUNK)
            stream.seek(start)
            lines = (stream.read(end - start) + carry).split(b"\n")
            # The first line may be cut by the seek; it joins the next chunk back.
            carry, lines = (lines[0], lines[1:]) if start else (b"", lines)
            yield from reversed(lines)
            end = start


def entry_payload(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return None, None
    payload = entry.get("payload") if isinstance(entry, dict) else None
    return (entry, payload) if isinstance(payload, dict) else (None, None)


def output_text(output):
    if isinstance(output, dict):
        output = output.get("content")
    if isinstance(output, list):
        return "".join(part.get("text") or "" for part in output if isinstance(part, dict))
    return output if isinstance(output, str) else ""


REVIEW_MARKERS = (b'"approvals_reviewer"', b'"task_started"', b"strict_auto_review", b'"request_permissions"')


def codex_review(transcript):
    """What a Codex rollout says about who answers this thread's approvals: the reviewer its newest turn_context or
    thread_settings_applied names ("user", "auto_review" for the app's Approve for me, or None when it doesn't
    say), and whether a permission grant in the running turn asked for strict auto-review, which sends every
    later command of the turn to Codex's reviewer even when the thread's reviewer is the user."""
    reviewer, strict, grants, in_turn = None, False, {}, True
    if not isinstance(transcript, str) or not transcript:
        return None, False
    try:
        for line in lines_backward(transcript, REVIEW_REACH):
            if not any(marker in line for marker in REVIEW_MARKERS):
                continue
            entry, payload = entry_payload(line)
            if payload is None:
                continue
            kind = payload.get("type")
            if reviewer is None:
                found = (payload.get("approvals_reviewer") if entry.get("type") == "turn_context"
                         else (payload.get("thread_settings") or {}).get("approvals_reviewer") if kind == "thread_settings_applied"
                         else None)
                if isinstance(found, str):
                    reviewer = found
            if in_turn:
                if kind == "task_started":
                    in_turn = False
                elif kind == "function_call_output" and b"strict_auto_review" in line:
                    grants[payload.get("call_id")] = output_text(payload.get("output"))
                elif kind == "function_call" and payload.get("name") == "request_permissions" and payload.get("call_id") in grants:
                    try:
                        grant = json.loads(grants[payload["call_id"]])
                    except ValueError:
                        grant = None
                    if isinstance(grant, dict) and grant.get("strict_auto_review") is True:
                        strict, in_turn = True, False
            if reviewer is not None and not in_turn:
                break
    except OSError:
        pass
    return reviewer, strict


def toml(text):
    try:
        import tomllib
    except ImportError:
        return {}
    try:
        value = tomllib.loads(text)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def read_toml(path):
    try:
        with open(path, encoding="utf-8") as stream:
            return toml(stream.read())
    except (OSError, UnicodeDecodeError):
        return {}


def managed_requirements():
    """Codex's administrator requirements on this Mac: /etc/codex/requirements.toml and the forced
    requirements_toml_base64 of the com.openai.codex managed preferences."""
    import base64
    import plistlib
    layers = [read_toml("/etc/codex/requirements.toml")]
    user = os.environ.get("USER") or ""
    for path in ("/Library/Managed Preferences/com.openai.codex.plist",
                 os.path.join("/Library/Managed Preferences", user, "com.openai.codex.plist") if user else None):
        if not path:
            continue
        try:
            with open(path, "rb") as stream:
                prefs = plistlib.load(stream)
            encoded = prefs.get("requirements_toml_base64") if isinstance(prefs, dict) else None
            if isinstance(encoded, str):
                layers.append(toml(base64.b64decode(encoded.strip()).decode()))
        except (OSError, ValueError, UnicodeDecodeError, plistlib.InvalidFileException):
            continue
    return [layer for layer in layers if layer]


def required_review(model):
    """Managed requirements hand every approval to Codex's reviewer when they don't allow the user to review, or
    name this model in [auto_review].required_on_models."""
    slug = model.split("/", 1)[1] if isinstance(model, str) and model.count("/") == 1 else model
    for layer in managed_requirements():
        allowed = layer.get("allowed_approvals_reviewers")
        if isinstance(allowed, list) and "user" not in allowed:
            return True
        review = layer.get("auto_review")
        models = review.get("required_on_models") if isinstance(review, dict) else None
        if isinstance(models, list) and slug in models:
            return True
    return False


APPS_PREFIX = "mcp__codex_apps__"


def app_reviewer(tool, home):
    """Codex Apps tools take their reviewer from [apps.<app>] or [apps._default] in config.toml before the
    thread's. The hook's tool name doesn't carry the connector id, so an app counts only when the name is its key
    or starts with its key and an underscore."""
    if not isinstance(tool, str) or not tool.startswith(APPS_PREFIX):
        return None
    apps = read_toml(os.path.join(home, "config.toml")).get("apps")
    if not isinstance(apps, dict):
        return None
    name = tool[len(APPS_PREFIX):].lower()
    keys = {key: key.lower().replace("-", "_") for key in apps if key != "_default"}
    named = [apps[key] for key, slug in keys.items() if name == slug or name.startswith(slug + "_")]
    for app in named + [apps.get("_default")]:
        found = app.get("approvals_reviewer") if isinstance(app, dict) else None
        if isinstance(found, str):
            return found
    return None


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def codex_decides(request):
    """Codex asks hooks before anything else, so it asks about calls the user would never see: under
    approval_policy never (bypassPermissions) it settles what's left itself, and when its auto-reviewer reviews
    the call (the thread's setting, a strict turn, an app's setting, or an administrator's requirement), that
    reviewer decides. Stepping aside is always safe: Codex then goes on as if the hook weren't there."""
    if request.get("permission_mode") == "bypassPermissions":
        return True
    reviewer, strict = codex_review(request.get("transcript_path"))
    # An app's own reviewer replaces the thread's for its tools, "user" included.
    reviewer = app_reviewer(request.get("tool_name"), codex_home()) or reviewer
    if strict or reviewer not in (None, "user"):
        return True
    return required_review(request.get("model"))


THREAD_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
SESSION_APPROVAL = "codexSession"
APPROVAL_TTL = 12 * 3600
PATCH_FILE = ("*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: ")


def approval_keys(request):
    """What Codex's own "for this session" remembers for a patch: each file it touches, resolved in the turn's folder.
    Commands aren't kept: the hook gets the turn's folder, not the command's workdir or sandbox permissions, and a
    network approval arrives as the same command, so a kept command could pass where Codex would ask again. A patch
    that deletes a file, or whose headers aren't written plainly (Codex trims them, so an indented one still
    counts), always asks."""
    tool, cwd, tool_input = request.get("tool_name"), request.get("cwd"), request.get("tool_input")
    if tool != "apply_patch" or not isinstance(tool_input, dict) or not isinstance(cwd, str) or not os.path.isabs(cwd):
        return []
    patch = tool_input.get("command")
    if not isinstance(patch, str):
        return []
    lines = patch.split("\n")
    if any(line.strip().startswith("***") and line != line.strip() for line in lines):
        return []
    if any(line.startswith("*** Delete File:") for line in lines):
        return []
    files = [line[len(prefix):] for line in lines for prefix in PATCH_FILE if line.startswith(prefix)]
    if not files or any(not file or file != file.strip() for file in files):
        return []
    return [["patch", os.path.normpath(os.path.join(cwd, file))] for file in files]


def approvals_path(state, request):
    thread = request.get("session_id")
    if not isinstance(thread, str) or not 0 < len(thread) <= 128 or not set(thread) <= THREAD_CHARS:
        return None
    return os.path.join(state, "codex-approved", f"{thread}.json")


def read_approvals(path):
    try:
        with open(path) as stream:
            stored = json.load(stream)
    except (OSError, ValueError):
        return []
    entries = stored.get("keys") if isinstance(stored, dict) else None
    now = time.time()
    return [entry for entry in entries or [] if isinstance(entry, dict) and isinstance(entry.get("at"), (int, float))
            and now - entry["at"] < APPROVAL_TTL and isinstance(entry.get("key"), list)]


def approved(state, request):
    """True when the user allowed every one of this call's keys for the session from Side A."""
    path, keys = approvals_path(state, request), approval_keys(request)
    if not path or not keys:
        return False
    held = [entry["key"] for entry in read_approvals(path)]
    return all(key in held for key in keys)


def remember_approval(state, request, answer):
    """Codex can't be told "for this session" by a hook, so Side A keeps the approval and gives the answer itself."""
    permissions = answer.get("permissions") if isinstance(answer, dict) and answer.get("behavior") == "allow" else None
    if not isinstance(permissions, list) or not any(isinstance(rule, dict) and rule.get("type") == SESSION_APPROVAL for rule in permissions):
        return
    path, keys = approvals_path(state, request), approval_keys(request)
    if not path or not keys:
        return
    import fcntl
    now = time.time()
    folder = os.path.dirname(path)
    with contextlib.suppress(OSError):
        os.makedirs(folder, mode=0o700, exist_ok=True)
        # Parallel calls of one thread answered at once each merge into the file in turn.
        with open(f"{path}.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            entries = [entry for entry in read_approvals(path) if entry["key"] not in keys] + [{"key": key, "at": now} for key in keys]
            write_atomic(path, json.dumps({"keys": entries[-500:]}))
        # Threads end without saying so; their approvals go once they've lapsed.
        for name in os.listdir(folder):
            other = os.path.join(folder, name)
            with contextlib.suppress(OSError):
                if other not in (path, f"{path}.lock") and now - os.path.getmtime(other) > APPROVAL_TTL:
                    os.unlink(other)


CALL_REACH = 4 << 20
WATCH_POLL = 0.5


def claude_transcript(request):
    """The transcript a Claude call is written to: a subagent's own, beside the session's, or the session's."""
    transcript = request.get("transcript_path")
    if not isinstance(transcript, str) or not transcript:
        return None
    agent = request.get("agent_id")
    if isinstance(agent, str) and agent and set(agent) <= SESSION_CHARS:
        own = os.path.join(os.path.splitext(transcript)[0], "subagents", f"agent-{agent}.jsonl")
        if os.path.exists(own):
            return own
    return transcript


def blocks(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return []
    message = entry.get("message") if isinstance(entry, dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


AMBIGUOUS = object()


def call_state(transcript, tool, tool_input, call=None):
    """(call id, settled): the tool_use of this tool and input that has no result yet, or with `call`, whether that
    one has its result now. Two such calls at once (parallel calls alike) can't be told apart, so neither is
    watched: AMBIGUOUS."""
    results, found = set(), None
    try:
        for line in lines_backward(transcript, CALL_REACH):
            if b'"tool_result"' in line:
                results.update(block.get("tool_use_id") for block in blocks(line) if block.get("type") == "tool_result")
                if call in results:
                    return call, True
            elif b'"tool_use"' in line:
                for block in reversed(blocks(line)):
                    if block.get("type") != "tool_use":
                        continue
                    if call is not None and block.get("id") == call:
                        return call, False
                    if call is None and block.get("name") == tool and block.get("input") == tool_input and block.get("id") not in results:
                        if found is not None:
                            return AMBIGUOUS, False
                        found = block.get("id")
    except OSError:
        pass
    return (found, False) if call is None else (call, False)


def watch_transcript(request):
    """For a Claude request, a check that's true once the call was settled without the island: an SDK host's own
    callback, which runs alongside the hook, or a background subagent's denial. The tool's result is written then."""
    transcript = claude_transcript(request)
    if not transcript:
        return None
    tool, tool_input, seen = request.get("tool_name"), request.get("tool_input"), {"call": None, "size": -1}

    def settled():
        try:
            size = os.path.getsize(transcript)
        except OSError:
            return False
        if size == seen["size"] or seen["call"] is AMBIGUOUS:
            return False
        seen["size"] = size
        seen["call"], done = call_state(transcript, tool, tool_input, seen["call"])
        return done
    # Found now, before the island is asked, so a host that settles it before the first poll still counts.
    settled()
    return settled


SESSION_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
TASK_KEYS = ("id", "type", "status", "description")


def remember(folder, request):
    """What a Claude hook's input says about its session, for the session's row: the mode and effort every hook
    gets, the model SessionStart and PostModelSwitch carry, and the background work a Stop leaves running.
    Each kind is its own file, so hooks running at once never overwrite each other's."""
    session = request.get("session_id")
    # A subagent's hooks carry the session's id but the subagent's own model and effort.
    if not (isinstance(session, str) and 0 < len(session) <= 128 and set(session) <= SESSION_CHARS) or request.get("agent_id"):
        return
    event = request.get("hook_event_name")
    effort = request.get("effort").get("level") if isinstance(request.get("effort"), dict) else None
    found = {}
    if isinstance(request.get("permission_mode"), str) or isinstance(effort, str):
        found["hook"] = {"mode": request.get("permission_mode"), "effort": effort}
    model = request.get("to_model") if event == "PostModelSwitch" else request.get("model") if event == "SessionStart" else None
    if isinstance(model, dict):
        model = model.get("id")
    if isinstance(model, str) and model:
        found["model"] = {"model": model}
    if event == "Stop":
        tasks = request.get("background_tasks") if isinstance(request.get("background_tasks"), list) else []
        found["tasks"] = {"tasks": [{key: str(task[key])[:200] for key in TASK_KEYS if task.get(key) is not None}
                                    for task in tasks[:50] if isinstance(task, dict)]}
    if not found:
        return
    with contextlib.suppress(OSError):
        os.makedirs(folder, mode=0o700, exist_ok=True)
        for kind, value in found.items():
            write_atomic(os.path.join(folder, f"{session}.{kind}.json"), json.dumps(value))


def main(argv):
    if len(argv) < 2:
        return
    path, agent = argv[0], argv[1]
    state = os.path.join(os.path.dirname(path), "state")
    if argv[2:] == ["inbox"]:
        with contextlib.suppress(ValueError, OSError):
            request = json.loads(sys.stdin.read(READ_LIMIT) or "{}")
            if isinstance(request, dict):
                remember(state, request)
        pid = os.environ.get("CLAUDE_PID", "")
        text = inbox(os.path.join(os.path.dirname(path), "inbox"), int(pid) if pid.isdigit() else os.getppid())
        if text:
            sys.stderr.write(INBOX_PREAMBLE + text + "\n")
            sys.exit(2)
        return
    try:
        request = json.loads(sys.stdin.read(READ_LIMIT) or "{}")
    except ValueError:
        return
    if not isinstance(request, dict):
        return
    event = request.get("hook_event_name")
    if agent == "claude":
        remember(state, request)
    if event == "PostModelSwitch":
        return
    pid = os.environ.get("CLAUDE_PID", "")
    message = {"v": 1, "agent": agent, "pid": int(pid) if pid.isdigit() else os.getppid(),
               "slot": slot() if agent == "claude" else None,
               # `claude -p` and SDK runs: nobody is at a prompt, so an unanswered request is denied.
               "headless": os.environ.get("CLAUDE_CODE_ENTRYPOINT", "cli").startswith("sdk"),
               # A session Side A hosts in tmux has nobody at its terminal; a Codex home names its account.
               "hosted": os.environ.get("SIDE_A_HOSTED") or None,
               "home": os.environ.get("CODEX_HOME") or None if agent == "codex" else None,
               "request": request}
    if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
        folder = os.path.join(os.path.dirname(path), "mail")
        if agent == "codex":
            # By thread id: the hook runs in the TUI, or in the app server every TUI on it shares.
            thread = request.get("session_id")
            if not isinstance(thread, str) or not thread or not all(c.isalnum() or c == "-" for c in thread):
                return
            result = mail(os.path.join(folder, "codex"), thread, event, agent)
        else:
            result = mail(folder, message["pid"], event, agent)
        if result:
            sys.stdout.write(json.dumps(result))
            sys.stdout.flush()
        return
    if event == "Stop":
        # A turn waiting on background work isn't the session being done. stop_hook_active is no sign of that:
        # Claude Code sets it on the Stop that ends a turn a follow-up woke, so skipping it lost every later reply.
        if request.get("background_tasks") or request.get("session_crons"):
            return
        if agent != "claude":
            with contextlib.suppress(OSError):
                tell(path, message)
            return
        # Claude Code runs this one with asyncRewake: it waits in the background, and exit code 2 wakes the
        # idle session with stderr as its next instruction. Side A answers with the user's follow-up or a release.
        try:
            answer = ask(path, {**message, "wait": True})
        except (OSError, ValueError):
            return
        text = answer.get("followUp") if isinstance(answer, dict) else None
        if isinstance(text, str) and text.strip():
            sys.stderr.write("The user sent you their next request from Side A's island:\n\n" + text.strip() + "\n")
            sys.exit(2)
        return
    if event != "PermissionRequest":
        return
    if agent == "codex":
        if codex_decides(request):
            return
        if approved(state, request):
            sys.stdout.write(json.dumps(output({"behavior": "allow"}, agent)))
            sys.stdout.flush()
            return
    try:
        answer = ask(path, message, watch_transcript(request) if agent == "claude" else None)
    except (OSError, ValueError):
        return
    if agent == "codex":
        remember_approval(state, request, answer)
    result = output(answer, agent)
    if result:
        sys.stdout.write(json.dumps(result))
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        pass
