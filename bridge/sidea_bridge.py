#!/usr/bin/env python3
"""Side A's stdlib-only account bridge.

Every login lives in exactly one place. The account this Mac is signed in to keeps the
CLI's default Keychain item; every other account keeps its own profile slot. Side A never
copies a login between places: refresh tokens rotate, and two holders of one token
eventually invalidate each other. (A trade's copy, kept for an hour in case a session undoes it,
is only ever written back into an item the trade emptied; see heal_trades.) "Using" an account records which slot new `claude`
commands should read (CLAUDE_SECURESTORAGE_CONFIG_DIR, set by a small shell function).
Tokens are never logged or printed.
"""
from __future__ import annotations
import argparse
import contextlib
import datetime
import fcntl
import functools
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import uuid

# The bridge and its siblings live inside the signed app; a __pycache__ beside them breaks its seal.
sys.dont_write_bytecode = True

GLOBAL_SERVICE = "Claude Code-credentials"
# Endpoints Claude Code itself calls with the same login (CLI 2.1.292).
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
WINDOW_LABELS = {"five_hour": "5-hour", "seven_day": "Weekly", "seven_day_opus": "Weekly Opus",
                 "seven_day_sonnet": "Weekly Sonnet"}


def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def account_by_id(config, identifier):
    # Require canonical UUIDs before using any profile identifier as a path.
    if str(uuid.UUID(identifier)).lower() != identifier.lower():
        raise ValueError("Invalid account identifier")
    return next(a for a in config["accounts"] if a["id"] == identifier)


def provider_of(account):
    provider = account.get("provider", "claude")
    if provider not in {"claude", "codex"}: raise ValueError("Unsupported agent. Update Side A.")
    return provider


def profile_dir(root, identifier):
    uuid.UUID(identifier)
    return root / "profiles" / identifier


def prepare_profile(root, identifier):
    profile = profile_dir(root, identifier)
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(profile, 0o700)
    shared = root / "conversations"
    shared.mkdir(parents=True, exist_ok=True, mode=0o700)
    projects = profile / "projects"
    if projects.is_symlink():
        if projects.resolve() != shared.resolve():
            raise ValueError("Unexpected conversation directory. Profile left untouched.")
    elif projects.exists():
        raise ValueError("An independent conversation directory already exists. Profile left untouched.")
    else:
        projects.symlink_to(shared, target_is_directory=True)
    return profile


def clean_environment(profile):
    # Avoid inherited API keys, OAuth overrides, nested-session markers, or cloud
    # provider settings silently authenticating a different account.
    env = {k: os.environ[k] for k in (
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM",
        "COLORTERM", "SSH_AUTH_SOCK", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"
    ) if k in os.environ}
    env["PATH"] = os.pathsep.join([
        str(Path.home() / ".local/bin"), str(Path.home() / ".npm-global/bin"), "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ])
    env["CLAUDE_CONFIG_DIR"] = str(profile)
    return env


def claude_binary():
    for path in [Path.home()/".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude")]:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise ValueError("Install Claude Code first: https://code.claude.com/docs/en/setup")


def auth_status(root, account, binary=None):
    if provider_of(account) == "codex":
        from codex_bridge import account_status
        return account_status(root, account, binary)
    profile = prepare_profile(root, account["id"])
    env = clean_environment(profile)
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = selector_for(root, account)
    result = subprocess.run([binary or claude_binary(), "auth", "status", "--json"],
        env=env, capture_output=True, timeout=25, text=True)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError("Claude did not return a valid account status. Update Claude Code and retry.") from None
    if not isinstance(data, dict):
        raise ValueError("Claude returned an unsupported account-status shape.")
    logged_in = result.returncode == 0 and data.get("loggedIn") is True
    # Only subscription OAuth identities belong here. The token, not the config file, names the owner.
    method = data.get("authMethod", "")
    email = token_email(root, read_secret(home_service(root, account))) or data.get("email") or ""
    return {"loggedIn": logged_in and method == "claude.ai" and bool(email),
            "email": email, "authMethod": method}


def profile_service(root, identifier):
    # Mirrors the CLI: suffix = sha256 of the NFC config-dir path, first 8 hex chars.
    path = str(profile_dir(root, identifier))
    return f"{GLOBAL_SERVICE}-{hashlib.sha256(unicodedata.normalize('NFC', path).encode()).hexdigest()[:8]}"


def keychain_user():
    return os.environ.get("USER") or "claude-code-user"


class KeychainBusy(ValueError):
    """The Keychain didn't answer. Says nothing about whether a login is there."""


class SignInAgain(ValueError):
    code = "signin"


class LoginIdle(ValueError):
    code = "idle"


class RateLimited(ValueError):
    code = "rate-limited"


class Unconfirmed(ValueError):
    code = "unconfirmed"


# What `security` exits with when the item really isn't there (errSecItemNotFound).
KEYCHAIN_NOT_FOUND = 44


@functools.lru_cache(maxsize=None)
def read_secret(service):
    # Logins are only written by renew(), under Claude Code's refresh lock. Only "no such item" is
    # an empty slot: anything else read as empty could put a backup over a live login.
    problem = ""
    for limit in (15, 45):
        try:
            result = subprocess.run(["security", "find-generic-password", "-a", keychain_user(), "-s", service, "-w"],
                                    capture_output=True, text=True, timeout=limit)
        except subprocess.TimeoutExpired:
            problem = f"no answer in {limit}s"
            continue
        if result.returncode == 0:
            break
        if result.returncode == KEYCHAIN_NOT_FOUND:
            return None
        problem = f"exit {result.returncode}"
        time.sleep(0.5)
    else:
        raise KeychainBusy(f"The Keychain didn't answer ({problem}); retrying later.")
    raw = result.stdout.strip()
    if not raw.startswith("{"):
        raw = bytes.fromhex(raw).decode()
    return json.loads(raw)


@contextlib.contextmanager
def selection_lock(root, name="selection.lock"):
    runtime = root / "runtime"
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(runtime / name, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def expired(blob, margin=60):
    return ((blob or {}).get("claudeAiOauth") or {}).get("expiresAt", 0) / 1000 < time.time() + margin


_identities = {}


def token_email(root, blob):
    """Who a stored login belongs to, from the profile endpoint. Cached on disk per token;
    a failed lookup is retried after ten minutes, never on every poll."""
    token = ((blob or {}).get("claudeAiOauth") or {}).get("accessToken")
    if not token:
        return ""
    key = hashlib.sha256(token.encode()).hexdigest()[:24]
    if key in _identities:
        return _identities[key]
    path = root / "runtime" / "identity-cache.json"
    cache = read_json(path, {}) or {}
    entry = cache.get(key)
    if isinstance(entry, str) or (isinstance(entry, dict) and entry.get("retry", 0) > time.time()) or expired(blob):
        _identities[key] = entry if isinstance(entry, str) else ""
        return _identities[key]
    try:
        data = post_json(PROFILE_URL, None, {"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20"}, method="GET")
        email = ((data.get("account") or {}).get("email") or "").casefold()
    except (urllib.error.URLError, ValueError, OSError):
        email = ""
    # Bridges run in parallel; re-read under a lock so one lookup never drops another's result.
    with selection_lock(root, "identity.lock"):
        cache = read_json(path, {}) or {}
        cache = dict(list(cache.items())[-50:])
        cache[key] = email or {"retry": time.time() + 600}
        atomic_json(path, cache)
    _identities[key] = email
    return email


def mac_email(root):
    """The account the Mac's default login belongs to."""
    return token_email(root, read_secret(GLOBAL_SERVICE))


def account_for_email(config, email, provider="claude"):
    return next((a for a in config.get("accounts", []) if provider_of(a) == provider
                 and email and a.get("email", "").casefold() == email), None)


def homes_path(root):
    return root / "runtime" / "homes.json"


def home_slot(root, account):
    """Where the account's login lives: "mac" for the Mac login, else a profile id. A swap moves
    logins between slots, so an account's slot can be another account's profile."""
    email = account.get("email", "").casefold()
    if email and mac_email(root) == email:
        return "mac"
    homes = read_json(homes_path(root), {}) or {}
    slot = homes.get(account["id"])
    if slot and slot != "mac":
        profile_dir(root, slot)  # validates the id
        return slot
    # Its own profile may hold a login another account moved in (say its login was in the Mac
    # item, which was then signed in to someone else); it then takes the slot that account left.
    slot, seen = account["id"], set()
    while slot not in seen:
        seen.add(slot)
        mover = next((other for other, held in homes.items() if held == slot and other != account["id"]), None)
        if not mover:
            return slot
        slot = mover
    raise SignInAgain(f"Sign in to {account['name']} again.")


def slot_service(root, slot):
    return GLOBAL_SERVICE if slot == "mac" else profile_service(root, slot)


def slot_selector(root, slot):
    return "" if slot == "mac" else str(profile_dir(root, slot))


def home_service(root, account):
    """The one Keychain item that holds this account's login."""
    return slot_service(root, home_slot(root, account))


def owned_login(root, account, idle_ok=False):
    """The account's login, refusing a slot that holds someone else's or one not yet verified.
    An expired login is only returned unverified when the caller treats it as idle."""
    blob = read_secret(home_service(root, account))
    if not blob or "claudeAiOauth" not in blob:
        raise SignInAgain(f"Sign in to {account['name']} again.")
    owner = token_email(root, blob)
    if owner == account.get("email", "").casefold() and owner:
        return blob
    if not owner and expired(blob) and idle_ok:
        return blob
    if not owner:
        raise Unconfirmed("Can't confirm whose login this is yet; retrying later.")
    raise SignInAgain(f"Sign in to {account['name']} again; its saved login is now {owner}'s.")


def selection_path(root):
    return root / "runtime" / "claude-selector"


def selector_for(root, account):
    """CLAUDE_SECURESTORAGE_CONFIG_DIR for an account: empty selects the Mac login."""
    return slot_selector(root, home_slot(root, account))


def write_selector(root, value):
    path = selection_path(root)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".selector-")
    with os.fdopen(fd, "w") as stream:
        stream.write(value + "\n")
    os.replace(temp, path)


def global_account(config, root):
    """The account new `claude` commands use. One file is the source of truth: the selected
    profile path, or empty for the Mac login. A selection whose login no longer belongs
    to its account is ignored, so the answer always matches what the shell launches."""
    mac = account_for_email(config, mac_email(root))
    path = selection_path(root)
    chosen = path.read_text().strip() if path.exists() else ""
    if not chosen:
        return mac
    account = next((a for a in config.get("accounts", []) if provider_of(a) == "claude" and selector_for(root, a) == chosen), None)
    if account and token_email(root, read_secret(home_service(root, account))) in ("", account["email"].casefold()):
        # An unknown owner (lookup failing) keeps the choice; reads still refuse it until verified.
        return account
    return mac


def repair_selection(root, config):
    """Points the selector at what global_account reports, e.g. after the Mac login changed."""
    with selection_lock(root):
        # Fresh reads: a trade may have just moved logins.
        read_secret.cache_clear()
        write_pins(root, config)
        account = global_account(config, root)
        wanted = selector_for(root, account) if account else ""
        path = selection_path(root)
        if (path.read_text().strip() if path.exists() else "") != wanted:
            write_selector(root, wanted)
    return account


def post_json(url, body, headers=None, method="POST"):
    import urllib.request  # ssl and http.client cost Python's startup a fifth of a second; the session viewer never needs them
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
        method=method, headers={"Content-Type": "application/json", "User-Agent": "claude-cli (side-a)", **(headers or {})})
    # A refresh token is spent once the endpoint answers, so a slow answer is worth waiting for.
    with urllib.request.urlopen(request, timeout=60 if url == TOKEN_URL else 20) as response:
        return json.load(response)


def epoch(value):
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        # Milliseconds would put the reset thousands of years out.
        return float(value) / 1000 if value > 1e11 else float(value)
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def percent(value):
    """A usage reading within 0-100. Past the cap, as once paid credits run, Claude reports more than 100."""
    value = float(value or 0)
    return min(max(value, 0.0), 100.0) if math.isfinite(value) else 0.0


def claude_usage(root, config, account):
    blob = owned_login(root, account, idle_ok=True)
    if expired(blob):
        # Nobody has used this login since it expired, so its last reading still holds.
        raise LoginIdle("Login idle; its last reading still applies.")
    oauth = blob["claudeAiOauth"]
    token = oauth["accessToken"]
    try:
        data = post_json(USAGE_URL, None, {"Authorization": f"Bearer {token}",
                                           "anthropic-beta": "oauth-2025-04-20"}, method="GET")
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise SignInAgain(f"Sign in to {account['name']} again; the login was rejected.") from None
        raise (RateLimited if error.code == 429 else ValueError)(f"Usage is unavailable right now (HTTP {error.code}).") from None
    windows = [{"id": key, "label": label, "percent": percent(data[key].get("utilization")),
                "resetsAt": epoch(data[key].get("resets_at"))}
               for key, label in WINDOW_LABELS.items() if isinstance(data.get(key), dict)]
    # Per-model weekly caps now arrive as scoped entries in `limits`, e.g. {"model": {"display_name": "Fable"}}.
    for limit in data.get("limits") or []:
        if not isinstance(limit, dict):
            continue
        model = ((limit.get("scope") or {}).get("model") or {}).get("display_name")
        if limit.get("kind") == "weekly_scoped" and model:
            windows.append({"id": "model:" + model.casefold(), "label": "Weekly " + model,
                            "percent": percent(limit.get("percent")), "resetsAt": epoch(limit.get("resets_at"))})
    return {"windows": windows, "stale": False, "capacity": plan_capacity(oauth), "extra": extra_usage(data)}


def extra_usage(data):
    """Paid usage past the plan limits: whether it is on and what this month has cost, in dollars."""
    spend = data.get("spend") if isinstance(data.get("spend"), dict) else {}
    money = lambda value: (value.get("amount_minor") or 0) / 10 ** (value.get("exponent") or 0) if isinstance(value, dict) else None
    legacy = data.get("extra_usage") if isinstance(data.get("extra_usage"), dict) else {}
    enabled = bool(spend.get("enabled", legacy.get("is_enabled")))
    used = money(spend.get("used"))
    if used is None:
        used = float(legacy.get("used_credits") or 0) / 100
    limit = money(spend.get("limit"))
    if limit is None and legacy.get("monthly_limit") is not None:
        limit = float(legacy["monthly_limit"]) / 100
    return {"enabled": enabled, "used": used, "limit": limit,
            "currency": (spend.get("used") or {}).get("currency") or legacy.get("currency") or "USD"}


def plan_capacity(oauth):
    # Relative quota size, so 1% of an Ultra (formerly Max 20x) account outweighs 1% of a Pro account.
    tier = f"{oauth.get('rateLimitTier') or ''} {oauth.get('subscriptionType') or ''}".lower()
    return 20.0 if "20x" in tier or "ultra" in tier else 5.0 if "5x" in tier or "max" in tier else 1.0


def usage(root, config, account):
    if provider_of(account) == "codex":
        import codex_bridge
        return codex_bridge.usage(root, account)
    return claude_usage(root, config, account)


def activate(root, config, account):
    """Point new `claude` commands at `account`'s own login. No login is copied or written."""
    if provider_of(account) == "codex":
        raise ValueError("Codex accounts are tracked here; switch Codex with `codex login`.")
    blob = owned_login(root, account)
    if token_email(root, blob) != account.get("email", "").casefold():
        raise ValueError(f"Use {account['name']} once so Side A can confirm its login, then try again.")
    with selection_lock(root):
        write_selector(root, selector_for(root, account))


def adopt(root, account):
    """Record the Mac's own login as an account. Its login stays where it is."""
    if provider_of(account) == "codex":
        import codex_bridge
        return codex_bridge.adopt(root, account)
    email = mac_email(root)
    if not email:
        raise ValueError("No Claude login was found on this Mac.")
    profile = prepare_profile(root, account["id"])
    data = read_json(Path.home() / ".claude.json", {}) or {}
    if (data.get("oauthAccount") or {}).get("emailAddress", "").casefold() == email:
        atomic_json(profile / ".claude.json", {"oauthAccount": data["oauthAccount"], "hasCompletedOnboarding": True})
    return {"email": email}


SHELL_MARK = "# side-a shell integration"


def login_stamps(root, config):
    """When each Claude account's stored login expires. A new value means a sign-in or refresh
    happened, so the app re-reads that account at once instead of waiting out a back-off."""
    stamps = {}
    for account in config.get("accounts", []):
        if provider_of(account) == "claude" and account.get("ready"):
            stamps[account["id"]] = ((read_secret(home_service(root, account)) or {}).get("claudeAiOauth") or {}).get("expiresAt") or 0
    return stamps


def login_ends(root, config):
    """When each Claude sign-in stops renewing (ms). Refreshes do not move it, so a new sign-in
    is needed about monthly; the app warns ahead of it."""
    ends = {}
    for account in config.get("accounts", []):
        if provider_of(account) == "claude" and account.get("ready"):
            end = ((read_secret(home_service(root, account)) or {}).get("claudeAiOauth") or {}).get("refreshTokenExpiresAt")
            if end:
                ends[account["id"]] = end
    return ends


def pool_path(root):
    """Written by the app while pool mode runs: its URL, the key Claude Code sends and the app's pid."""
    return root / "runtime" / "pool"


def remote_pool_path(root):
    """Another Mac's shared pool (`sidea pool join`): its URL and key, used while this Mac runs none."""
    return root / "runtime" / "pool-remote"


def pins_path(root):
    return root / "runtime" / "accounts"


def pin_name(name):
    """What `sidea use <name>` accepts for an account: its name, lowercased, dashes for the rest."""
    # ponytail: two accounts whose names slug alike share one pin; rename one if that ever matters.
    return re.sub(r"[^a-z0-9]+", "-", name.casefold()).strip("-") or "account"


def write_pins(root, config):
    """One file per Claude account holding its selector, so a terminal can stay on one account
    with `sidea use <name>` while Autopilot moves the rest. A slot holding another account's
    login gets no pin."""
    folder = pins_path(root)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    wanted = {}
    for account in config.get("accounts", []):
        if provider_of(account) != "claude" or not account.get("ready"):
            continue
        if token_email(root, read_secret(home_service(root, account))) in ("", account.get("email", "").casefold()):
            wanted[pin_name(account["name"])] = selector_for(root, account)
    for path in folder.iterdir():
        if path.name not in wanted:
            path.unlink(missing_ok=True)
    for name, value in wanted.items():
        path = folder / name
        if not path.exists() or path.read_text().strip() != value:
            path.write_text(value + "\n")


# Subcommands that read or change Codex's own login or config, so they need the real ~/.codex: `codex login` in
# the pool's home would leave the login there.
CODEX_OWN_LOGIN = "login|logout|mcp|mcp-server|plugin|app-server|app|remote-control|completion|update|doctor|sandbox|debug|apply|a|cloud|exec-server|features|agents|help"


def shell_snippet(root):
    selector = shlex.quote(str(root / "runtime" / "claude-selector"))
    pins = shlex.quote(str(pins_path(root)))
    host = shlex.quote(str(root / "runtime" / "sidea-tmux"))
    pool = shlex.quote(str(pool_path(root)))
    remote = shlex.quote(str(remote_pool_path(root)))
    codex_pool = shlex.quote(str(root / "runtime" / "codex-pool"))
    codex_remote = shlex.quote(str(root / "runtime" / "codex-pool-remote"))
    # A preexec hook, not a `claude` function: an alias to a path (claude=~/.claude/local/claude)
    # would skip a function, but every command runs after preexec. One line, so removal stays simple.
    # SIDE_A_PIN, set by `sidea use`, keeps one terminal on one account. Files are read with $(<f),
    # not cat, which may be aliased; ${x:-} keeps it working under `set -u`. It also runs once when
    # sourced: for `source ~/.zshrc && claude`, preexec fired before the hook existed.
    # Pool mode, while the app that wrote the pool file runs, sends an unpinned terminal's `claude`
    # through it; only claude gets the key (the SDKs read the same variables), and a base URL or token
    # the user set is theirs. preexec passes the line as typed and expanded; sourcing passes none.
    # `codex` the same way, by a pool-only CODEX_HOME: it takes no base URL from the environment under a ChatGPT login.
    return (f"{SHELL_MARK}\n"
            f"_side_a_select() {{ local f={selector} u= k i w h c= x= y= p= mine= cmine= cc= xc= src=; [ $# -eq 0 ] && c=1; "
            f"for w in ${{(z)${{1:-}}}} ${{(z)${{3:-}}}}; do [[ $w == (*/|)claude ]] && c=1; [[ $w == (*/|)codex ]] && x=1; [[ $p == (*/|)codex && $w == ({CODEX_OWN_LOGIN}) ]] && y=1; p=$w; done; "
            f"[ -n \"${{SIDE_A_POOL:-}}\" ] && [ \"${{ANTHROPIC_BASE_URL:-}}\" = \"${{_side_a_url:-}}\" ] && mine=1; "
            f"[ -n \"${{_side_a_codex:-}}\" ] && [ \"${{CODEX_HOME:-}}\" = \"$_side_a_codex\" ] && cmine=1; "
            f"[ -n \"$c\" ] && [ -z \"${{SIDE_A_PIN:-}}\" ] && {{ [ -n \"$mine\" ] || [ -z \"${{ANTHROPIC_BASE_URL:-}}${{ANTHROPIC_AUTH_TOKEN:-}}\" ]; }} && cc=1; "
            f"[ -n \"$x\" ] && [ -z \"$y\" ] && {{ [ -n \"$cmine\" ] || [ -z \"${{CODEX_HOME:-}}\" ]; }} && xc=1; "
            f"if [ -n \"$cc$xc\" ]; then if [ -f {pool} ] && read -r u k i < {pool} && kill -0 \"$i\" 2>/dev/null; then src={codex_pool}; "
            f"elif [ -f {remote} ] && read -r u k < {remote} && h=${{${{u#*://}}%%[:/]*}} && /usr/bin/nc -z -G 1 \"${{h//[\\[\\]]/}}\" \"${{${{${{u##*:}}%%/*}}:-80}}\" 2>/dev/null; then src={codex_remote}; else u=; fi; fi; "
            f"if [ -n \"$xc\" ] && [ -n \"$u\" ] && [ -f \"$src\"/config.toml ]; then export CODEX_HOME=\"$src\" SIDE_A_POOL_KEY=\"$k\"; _side_a_codex=\"$src\"; "
            f"elif [ -n \"$cmine\" ]; then unset CODEX_HOME SIDE_A_POOL_KEY; fi; "
            f"if [ -n \"$cc\" ] && [ -n \"$u\" ]; then "
            f"export ANTHROPIC_BASE_URL=\"$u\" ANTHROPIC_AUTH_TOKEN=\"$k\" SIDE_A_POOL=1; _side_a_url=\"$u\" _side_a_key=\"$k\"; unset CLAUDE_SECURESTORAGE_CONFIG_DIR; return; fi; "
            f"[ -n \"$mine\" ] && unset ANTHROPIC_BASE_URL; [ -n \"${{_side_a_key:-}}\" ] && [ \"${{ANTHROPIC_AUTH_TOKEN:-}}\" = \"$_side_a_key\" ] && unset ANTHROPIC_AUTH_TOKEN; unset SIDE_A_POOL; "
            f"[ -n \"${{SIDE_A_PIN:-}}\" ] && [ -f {pins}/\"$SIDE_A_PIN\" ] && f={pins}/\"$SIDE_A_PIN\"; "
            f"[ -f \"$f\" ] && export CLAUDE_SECURESTORAGE_CONFIG_DIR=\"$(<\"$f\")\" || unset CLAUDE_SECURESTORAGE_CONFIG_DIR; }}; "
            f"sidea() {{ local p=\"${{${{${{2:-}}:l}}// /-}}\"; if [ \"${{1:-}}\" = use ] && [ -f {pins}/\"$p\" ]; then export SIDE_A_PIN=\"$p\"; echo \"This terminal now uses $p.\"; "
            f"elif [ \"${{1:-}}\" = auto ]; then unset SIDE_A_PIN; echo \"This terminal follows Side A again.\"; "
            f"elif [ \"${{1:-}}\" = attach ] || [ \"${{1:-}}\" = ls ]; then {host} \"$@\"; "
            f"elif [ \"${{1:-}}\" = pool ] && [ \"${{2:-}}\" = join ] && [[ \"${{3:-}}\" == http://* ]] && [ -n \"${{4:-}}\" ]; then "
            f"(umask 077; print -r -- \"$3 $4\" > {remote}) && echo \"claude and codex here now use that Mac's pool while it's reachable.\"; "
            f"elif [ \"${{1:-}}\" = pool ] && [ \"${{2:-}}\" = leave ]; then rm -f {remote}; echo \"claude and codex here use this Mac's own logins again.\"; "
            f"else echo \"sidea use <account> keeps this terminal on one account; sidea auto follows Side A; sidea attach [name] opens a hosted session; sidea ls lists them. Accounts: $(ls {pins} 2>/dev/null | tr '\\n' ' ')\"; fi; }}; "
            f"autoload -Uz add-zsh-hook && add-zsh-hook preexec _side_a_select && _side_a_select\n")


HOST_MARK = "# side-a host terminal sessions"
# Interactive claude and codex outside tmux start hosted and attach this tab (docs/remote/hosting.md).
# An alias would win over a function, so it is taken over: remembered, then removed. A remembered
# alias that runs the same name (claude='claude --flag') goes through `command`, or it would call
# the function again. The flag file is checked live, so turning the setting off works at once.
HOST_LINE = r"""typeset -gA _side_a_real; _side_a_hostbin=@BIN@; _side_a_hostflag=@FLAG@; _side_a_tui() { local agent=$1 a; shift; for a in "$@"; do case $a in (-p|--print|-v|--version|-V|-h|--help|--output-format|--output-format=*|--input-format|--input-format=*) return 1;; esac; done; case $agent:${1:-} in (claude:(mcp|config|doctor|update|upgrade|install|migrate-installer|setup-token|plugin|plugins|auth|agents)) return 1;; (codex:(exec|e|review|login|logout|mcp|mcp-server|plugin|app-server|remote-control|app|completion|update|doctor|sandbox|debug|apply|a|queue|archive|delete|unarchive|migrate-rollouts|cloud|exec-server|features|agents|help)) return 1;; esac; return 0; }; _side_a_host() { local agent=$1 real; shift; if [[ -o interactive && -t 0 && -t 1 && -z ${TMUX:-} && -z ${SIDE_A_HOSTED:-} && -z ${SIDE_A_NO_HOST:-} && -f $_side_a_hostflag && -x $_side_a_hostbin ]] && _side_a_tui $agent "$@"; then "$_side_a_hostbin" host $agent --cwd "$PWD" --origin terminal ${SIDE_A_PIN:+--pin} ${SIDE_A_PIN:+"$SIDE_A_PIN"} -- "$@"; else real=${_side_a_real[$agent]:-$agent}; [[ ${real%% *} == $agent ]] && real="command $real"; eval "$real \"\$@\""; fi; }; for _side_a_a in claude codex; do if (( $+aliases[$_side_a_a] )); then _side_a_real[$_side_a_a]=${aliases[$_side_a_a]}; unalias $_side_a_a; fi; eval "function $_side_a_a { _side_a_host $_side_a_a \"\$@\"; }"; done; unset _side_a_a"""


def host_flag(root):
    return root / "runtime" / "host-terminal"


def host_snippet(root):
    return (f"{HOST_MARK}\n" + HOST_LINE.replace("@BIN@", shlex.quote(str(root / "runtime" / "sidea-tmux")))
            .replace("@FLAG@", shlex.quote(str(host_flag(root)))) + "\n")


def rewrite_zshrc(root, shell=None, host=None):
    """Side A's marked ~/.zshrc lines, each one marker plus one line; None keeps a line as it is.
    The hosting line goes after the switching line, and both after the user's own aliases."""
    path = Path.home() / ".zshrc"
    text = path.read_text() if path.exists() else ""
    shell = SHELL_MARK in text if shell is None else shell
    host = HOST_MARK in text if host is None else host
    lines = text.splitlines(keepends=True)
    kept, skip = [], False
    for line in lines:
        if line.startswith((SHELL_MARK, HOST_MARK)):
            skip = True
            continue
        if skip:
            skip = False
            continue
        kept.append(line)
    text = "".join(kept)
    if len(kept) < len(lines):
        # Drop the blank separator line that was added with the function.
        text = text.rstrip("\n") + "\n" if text.strip() else ""
    added = (shell_snippet(root) if shell else "") + (host_snippet(root) if host else "")
    if added:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + added
    path = path.resolve()  # a symlinked dotfile stays a symlink
    temp = path.with_name(".zshrc.side-a")
    temp.write_text(text)
    if path.exists():
        os.chmod(temp, path.stat().st_mode & 0o777)
    os.replace(temp, path)


def set_shell(root, enabled):
    """Adds or removes the ~/.zshrc line that points each command at Side A's choice."""
    if not enabled:
        # Shells already open keep the hook; with no selector it leaves their commands alone.
        with selection_lock(root):
            selection_path(root).unlink(missing_ok=True)
    rewrite_zshrc(root, shell=enabled)


def set_host_terminal(root, enabled):
    """Adds or removes the claude and codex wrappers that host terminal sessions. The flag goes
    first when turning off, so shells already open stop hosting at their next command."""
    flag = host_flag(root)
    if enabled:
        flag.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        flag.touch()
    else:
        flag.unlink(missing_ok=True)
    rewrite_zshrc(root, host=enabled)


def host_terminal_installed(root):
    path = Path.home() / ".zshrc"
    text = path.read_text() if path.exists() else ""
    if HOST_MARK in text and (host_snippet(root) not in text or not host_flag(root).exists()):
        set_host_terminal(root, True)
    return HOST_MARK in text


def shell_installed(root):
    """Whether switching is on; an older snippet is upgraded in place."""
    path = Path.home() / ".zshrc"
    text = path.read_text() if path.exists() else ""
    if SHELL_MARK in text and shell_snippet(root) not in text:
        rewrite_zshrc(root)
    return SHELL_MARK in text


@contextlib.contextmanager
def claude_refresh_lock(folder, timeout=30):
    """Holds Claude Code's own refresh lock for one login while Side A renews it. Claude Code keeps
    it in the login's storage folder (CLAUDE_SECURESTORAGE_CONFIG_DIR, or ~/.claude for the Mac
    login), so every session on that login waits for it, and the server never sees a refresh token
    used twice. Same format as Claude Code's lock library: a directory, stale after 60 s idle. Claude
    Code takes this one, then `<folder>.lock`, the only one a session from an older version knows."""
    path = Path(folder) / ".oauth_refresh.lock"
    legacy = Path(f"{os.path.realpath(folder)}.lock")
    deadline = time.time() + timeout
    def take(lock):
        while True:
            try:
                lock.mkdir()
                return
            except FileExistsError:
                try:
                    if time.time() - lock.stat().st_mtime > 60:
                        lock.rmdir()
                        continue
                except OSError:
                    pass
                if time.time() > deadline:
                    raise ValueError("Claude Code is refreshing a login right now; Side A will try again shortly.") from None
                time.sleep(0.5)
            except FileNotFoundError:
                lock.parent.mkdir(parents=True, exist_ok=True)
    take(path)
    try:
        take(legacy)
    except ValueError:
        with contextlib.suppress(OSError):
            path.rmdir()
        raise
    stop = threading.Event()
    def keep_fresh():
        while not stop.wait(5):
            for lock in (path, legacy):
                with contextlib.suppress(OSError):
                    os.utime(lock)
    threading.Thread(target=keep_fresh, daemon=True).start()
    keep = False
    try:
        yield
    except TradeStuck:
        # Both logins may sit in both items: the lock stays, so sessions wait until it goes stale
        # (60 s) instead of refreshing a shared login, and the next bridge run finishes the trade.
        keep = True
        raise
    finally:
        stop.set()
        if not keep:
            for lock in (legacy, path):
                with contextlib.suppress(OSError):
                    lock.rmdir()


def run_as(root, account, args, timeout):
    """Runs claude as the account's own login with clean settings. The child takes the login's
    refresh lock itself, so Side A must not hold it here."""
    env = clean_environment(prepare_profile(root, account["id"]))
    # The profile's clean settings keep the user's hooks and CLAUDE.md out; the selector
    # picks the account's own login, which the CLI refreshes itself if needed.
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = selector_for(root, account)
    return subprocess.run([claude_binary(), *args], env=env, cwd=root, capture_output=True,
                          text=True, timeout=timeout, stdin=subprocess.DEVNULL)


# Claude Code's own OAuth client and token endpoint: renewing here is the same request Claude Code makes.
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


SWAP_JOURNAL = "Side A swap journal"
# The logins a recent trade moved, kept so a trade a session undid can be put right (heal_trades).
TRADE_WATCH = "Side A trade watch"
WATCH_SECONDS = 3600


class TradeStuck(ValueError):
    """A trade between two running logins that could neither finish nor be undone."""


def swapped_path(root):
    return root / "runtime" / "swapped.json"


def trade(login, item):
    """`login` placed in `item`: MCP logins belong to the item's sessions, so they stay."""
    moved = {k: v for k, v in login.items() if k != "mcpOAuth"}
    if item and "mcpOAuth" in item:
        moved["mcpOAuth"] = item["mcpOAuth"]
    return moved


def same_login(root, blob, login):
    """`blob` is `login`'s account: the same tokens, or, once a session renewed it, the same owner."""
    mine, theirs = (blob or {}).get("claudeAiOauth") or {}, (login or {}).get("claudeAiOauth") or {}
    if not mine or not theirs:
        return False
    if mine.get("refreshToken") and mine.get("refreshToken") == theirs.get("refreshToken"):
        return True
    owner = token_email(root, blob)
    return bool(owner) and owner == token_email(root, login)


def swap_locks(root, slots):
    # A lock that can't be taken releases the ones already held.
    with contextlib.ExitStack() as stack:
        for slot in slots:
            stack.enter_context(claude_refresh_lock(slot_selector(root, slot) or str(Path.home() / ".claude")))
        return stack.pop_all()


def slot_owner(root, config, slot):
    """The library account whose verified login is in `slot`, if any."""
    return account_for_email(config, token_email(root, read_secret(slot_service(root, slot))))


def swap(root, config, slot, other, share=False):
    """Moves every session reading `slot` to `other`'s login: the login in `slot` and `other`'s
    trade Keychain items. Running sessions re-read their item within about 30 s. Nothing is
    copied: a journal is saved first, and finish_swap() completes the trade from it, now or
    after a crash. `share` lets `other`'s own sessions continue on the login from `slot`; the app
    asks for it only when that login still has room for every one of them."""
    if provider_of(other) != "claude":
        raise ValueError("Only Claude accounts trade logins.")
    if slot != "mac":
        profile_dir(root, slot)  # validates the id
    with selection_lock(root), selection_lock(root, "renew.lock"):
        read_secret.cache_clear()
        finish_swap(root)
        # Resolved under the locks, so a trade that just finished is seen.
        account = slot_owner(root, config, slot)
        target = home_slot(root, other)
        if not account or account["id"] == other["id"] or target == slot:
            raise ValueError("These two logins can't trade places.")
        slots = [slot, target]
        if any(signing_in(root, s) for s in slots):
            raise ValueError("An account is signing in; trading later.")
        with swap_locks(root, slots):
            # Checked last, right before the writes, not from the app's last look: a session started
            # meanwhile must not get the full login.
            processes = slot_processes(root, config)
            if processes is None:
                raise ValueError(f"Running sessions couldn't be listed ({listing_problem}); trading later.")
            busy = set(processes.values())
            if target in busy and not share:
                raise ValueError("A session is using that account now.")
            # A share hands `other`'s sessions the login whose Fable share is spent: only while none of them runs Fable.
            if share and target in busy:
                models = slot_models({pid: s for pid, s in processes.items() if s == target}).get(target) or [None]
                if any(model is None or "fable" in model.lower() for model in models):
                    raise ValueError("A session on that account may use Fable now; trading later.")
            read_secret.cache_clear()
            logins = [read_secret(slot_service(root, slot)), owned_login(root, other)]
            if token_email(root, logins[0]) != account.get("email", "").casefold():
                raise Unconfirmed("Can't confirm whose login this is yet; retrying later.")
            # Where each account's own login ends up. A second sign-in of the same account
            # (not its home) is moved without becoming its home.
            moves = {other["id"]: slot}
            if home_slot(root, account) == slot:
                moves[account["id"]] = target
            # With sessions on both sides, a trade half done would leave both on one login, refreshing
            # it separately. Both items are rewritten as they are first, so a Keychain that refuses
            # writes stops the trade before anything moves.
            both = share and target in busy
            if both:
                for service, login in zip((slot_service(root, slot), slot_service(root, target)), logins):
                    write_secret(service, read_secret(service) or login)
            # Each account back in the slot it left, should a session undo the trade (heal_trades).
            undo = {other["id"]: target, **({account["id"]: slot} if moves.get(account["id"]) else {})}
            write_secret(SWAP_JOURNAL, {"slots": slots, "moves": moves, "undo": undo,
                                        "logins": [trade(login, None) for login in logins]})
            # Finished while the refresh locks still hold, so no session refreshes a login that is
            # briefly in both items; a failure that outlasts this is finished by the next bridge run.
            attempts = 10 if both else 3
            for attempt in range(attempts):
                try:
                    finish_swap(root, locked=True)
                    break
                except (ValueError, OSError, subprocess.TimeoutExpired):
                    if attempt == attempts - 1:
                        if both:
                            try:
                                undo_swap(root, slots, logins)
                            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                                raise TradeStuck("The trade couldn't finish or be undone; Side A finishes it on its next run.") from error
                        raise
                    time.sleep(2 if both else 1)


def undo_swap(root, slots, logins):
    """Puts both logins back where they were and drops the journal, for a trade between two running
    logins that couldn't finish. Called under the refresh locks, so neither login was renewed
    meanwhile. If even this fails, the journal stays and the next bridge run finishes the trade."""
    read_secret.cache_clear()
    services = [slot_service(root, slot) for slot in slots]
    items = [read_secret(service) for service in services]
    # Once both logins have moved, nothing is shared: the journal stays so the next run records the
    # trade (homes and limits) the way finish_swap does.
    if same_login(root, items[0], logins[1]) and same_login(root, items[1], logins[0]):
        return
    for service, item, login in zip(services, items, logins):
        if item != login:
            write_secret(service, login)
    subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", SWAP_JOURNAL],
                   capture_output=True, timeout=15)
    read_secret.cache_clear()


def finish_swap(root, locked=False):
    """Completes a trade from its journal. Always forward, never back, using the newest copy of each
    login (a session may have renewed one), so each login ends in exactly one item. Callers hold
    selection.lock and renew.lock; the refresh locks are taken here unless `locked`."""
    read_secret.cache_clear()  # a journal read before the locks may already be finished
    journal = read_secret(SWAP_JOURNAL)
    if not journal:
        return
    slots, moves, logins = journal["slots"], journal["moves"], journal["logins"]
    with contextlib.ExitStack() as stack:
        if not locked:
            stack.enter_context(swap_locks(root, slots))
        services = [slot_service(root, slot) for slot in slots]
        read_secret.cache_clear()
        items = [read_secret(service) for service in services]
        # Only the two journaled logins are in these slots. What the trade wrote carries the journal's
        # tokens, so an item matching neither was never written: it is that slot's original login,
        # renewed by a session (its owner may not be looked up yet).
        def which(index, item):
            if same_login(root, item, logins[0]):
                return 0
            if same_login(root, item, logins[1]):
                return 1
            return index if item and item.get("claudeAiOauth") else None
        firsts = [item for i, item in enumerate(items) if which(i, item) == 0]
        seconds = [item for i, item in enumerate(items) if which(i, item) == 1]
        newest = lambda copies: max(copies, key=lambda blob: blob["claudeAiOauth"].get("expiresAt") or 0)
        wanted = [trade(newest([logins[1]] + seconds), items[0]), trade(newest([logins[0]] + firsts), items[1])]
        for service, item, blob in zip(services, items, wanted):
            if item != blob:
                write_secret(service, blob)
        homes = read_json(homes_path(root), {}) or {}
        homes.update(moves)
        # The Mac login is found by its owner, so only moves into other profiles are recorded.
        atomic_json(homes_path(root), {k: v for k, v in homes.items() if v not in (k, "mac")})
        # A statusline that was mid-write keeps its old file time, so readings from before are dropped.
        swapped = read_json(swapped_path(root), {}) or {}
        atomic_json(swapped_path(root), {**swapped, **{slot: time.time() for slot in slots}})
        for slot in slots:
            (live_dir(root) / f"{slot}.json").unlink(missing_ok=True)
        if "undo" in journal:
            # Optional: a trade that can't be watched still finished.
            with contextlib.suppress(ValueError, OSError, subprocess.TimeoutExpired):
                watch_trade(root, slots, [wanted[1], wanted[0]], journal["undo"])
        deleted = subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", SWAP_JOURNAL],
                                 capture_output=True, timeout=15)
        read_secret.cache_clear()
        if deleted.returncode != 0 and read_secret(SWAP_JOURNAL):
            raise ValueError("The trade finished but its journal could not be removed; retrying.")


def watch_path(root):
    return root / "runtime" / "trade-watch.json"


def watch_service(entry):
    # One item per trade keeps each write small enough for stdin, out of process lists.
    return f"{TRADE_WATCH} {entry['id']}"


def forget_trade(root, entry):
    with selection_lock(root, "watch.lock"):
        index = read_json(watch_path(root), {}) or {}
        atomic_json(watch_path(root), {"trades": [e for e in index.get("trades", []) if e["id"] != entry["id"]]})
        subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", watch_service(entry)],
                       capture_output=True, timeout=15)
    read_secret.cache_clear()


def watch_trade(root, slots, logins, homes):
    """Keeps the two logins a trade moved, `logins[k]` being the one that left `slots[k]`, for heal_trades."""
    with selection_lock(root, "watch.lock"):
        index = read_json(watch_path(root), {}) or {}
        old = [e for e in index.get("trades", []) if set(e["slots"]) & set(slots) or time.time() - e["at"] >= WATCH_SECONDS]
        for entry in old:
            subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", watch_service(entry)],
                           capture_output=True, timeout=15)
        entry = {"id": os.urandom(6).hex(), "at": time.time(), "slots": slots, "homes": homes}
        write_secret(watch_service(entry), {"logins": [{"claudeAiOauth": login["claudeAiOauth"]} for login in logins]})
        atomic_json(watch_path(root), {"trades": [e for e in index.get("trades", []) if e not in old] + [entry]})


def heal_trades(root, config):
    """A session that kept the login a trade moved out of its slot can save that login back there,
    over the login the trade moved in: one account then sits in both slots and the other has none,
    so it asks for a sign-in. Within an hour of a trade, that is undone. The overwritten account goes
    back into the slot it came from and each account is home again where it was. Returns what was
    put right, in words."""
    healed = []
    for entry in (read_json(watch_path(root), {}) or {}).get("trades", []):
        if time.time() - entry["at"] >= WATCH_SECONDS:
            forget_trade(root, entry)
        elif line := heal_trade(root, config, entry):
            healed.append(line)
    return healed


def heal_trade(root, config, entry):
    read_secret.cache_clear()
    saved = (read_secret(watch_service(entry)) or {}).get("logins")
    if not saved:
        return forget_trade(root, entry)
    slots = entry["slots"]
    services = [slot_service(root, slot) for slot in slots]
    items = [read_secret(service) for service in services]
    owners = [token_email(root, item) for item in items]
    before = [token_email(root, login) for login in saved]
    refresh = lambda blob: ((blob or {}).get("claudeAiOauth") or {}).get("refreshToken")
    expiry = lambda blob: ((blob or {}).get("claudeAiOauth") or {}).get("expiresAt") or 0
    if not all(before) or not all(owners):
        return None
    if owners == [before[1], before[0]]:
        # As traded. The copies follow renewals, so a login put back is its newest one.
        if any(expiry(item) > expiry(copy) for item, copy in zip((items[1], items[0]), saved)):
            with selection_lock(root, "watch.lock"):
                write_secret(watch_service(entry), {"logins": [{"claudeAiOauth": max(copy, item, key=expiry)["claudeAiOauth"]}
                                                               for copy, item in zip(saved, (items[1], items[0]))]})
        return None
    if owners[0] != owners[1] or owners[0] not in before:
        return None
    stayed = before.index(owners[0])
    lost = 1 - stayed
    # Only the copy the trade left in the lost slot is replaced, and only by a newer one in the other:
    # if the lost slot's copy was renewed since, it may be the one live login, so nothing is touched.
    if refresh(items[lost]) != refresh(saved[stayed]) or expiry(items[stayed]) <= expiry(items[lost]):
        return None
    processes = slot_processes(root, config)
    # Sessions started on that slot since run on the other login now, and a sign-in may be writing it.
    if processes is None or slots[lost] in set(processes.values()) or any(signing_in(root, slot) for slot in slots):
        return None
    with selection_lock(root), selection_lock(root, "renew.lock"), swap_locks(root, slots):
        read_secret.cache_clear()
        if [read_secret(service) for service in services] != items:
            return None
        write_secret(services[lost], trade(saved[lost], items[lost]))
        known = {account["id"] for account in config.get("accounts", [])}
        homes = read_json(homes_path(root), {}) or {}
        homes.update({k: v for k, v in entry["homes"].items() if k in known})
        atomic_json(homes_path(root), {k: v for k, v in homes.items() if v not in (k, "mac")})
        swapped = read_json(swapped_path(root), {}) or {}
        atomic_json(swapped_path(root), {**swapped, **{slot: time.time() for slot in slots}})
        for slot in slots:
            (live_dir(root) / f"{slot}.json").unlink(missing_ok=True)
    forget_trade(root, entry)
    name = lambda email: (account_for_email(config, email) or {}).get("name") or email
    return (f"A session saved {name(owners[0])}'s login over {name(before[lost])}'s after a trade; "
            f"the trade was undone and {name(before[lost])}'s login put back.")


BACKUP = "Side A login backup"


def backup_service(account):
    return f"{BACKUP} {account['id']}"


def rehome(root, config):
    """Points every Claude account at the slot that actually holds its login, from what the slots
    hold now rather than from homes.json. A `/login` typed in a session, or a session saving an old
    login back, changes a slot behind Side A's back; trusting the record then leaves accounts
    pointing at each other's logins (or two at one slot), and sign-ins refuse those slots.

    An account whose login is gone gets a free slot, and its newest login is put back there from
    its backup when no slot holds that login: overwriting a slot keeps no other copy, and the backup
    is a dormant copy that is never refreshed. Returns what was put right, in words."""
    # Signed out (not ready) accounts are left alone: putting their backup back would sign them in again.
    accounts = [a for a in config.get("accounts", []) if provider_of(a) == "claude" and a.get("email") and a.get("ready")]
    email = lambda account: account["email"].casefold()
    oauth = lambda blob: (blob or {}).get("claudeAiOauth") or {}
    with selection_lock(root), selection_lock(root, "renew.lock"):
        read_secret.cache_clear()
        if read_secret(SWAP_JOURNAL):
            return []
        homes = read_json(homes_path(root), {}) or {}
        current = {}
        for account in accounts:
            with contextlib.suppress(ValueError):
                current[account["id"]] = home_slot(root, account)
        slots = {"mac", *(a["id"] for a in accounts), *homes.values(), *current.values()}
        if any(signing_in(root, slot) for slot in slots):
            return []
        items = {slot: read_secret(slot_service(root, slot)) for slot in slots}
        # "" for an empty slot, None for a login whose owner can't be looked up now (expired or offline).
        owners = {slot: (token_email(root, blob) or None) if oauth(blob) else "" for slot, blob in items.items()}
        final, taken = {}, set()
        def claim(account, slot):
            final[account["id"]] = slot
            taken.add(slot)
        mac = owners["mac"]
        for account in accounts:
            if mac and email(account) == mac:
                claim(account, "mac")
        taken.add("mac")
        for account in accounts:
            slot = current.get(account["id"])
            if account["id"] not in final and slot not in taken and owners.get(slot) == email(account):
                claim(account, slot)
        for account in accounts:
            if account["id"] not in final:
                found = [slot for slot in slots if slot not in taken and owners[slot] == email(account)]
                if found:
                    claim(account, max(found, key=lambda slot: oauth(items[slot]).get("expiresAt") or 0))
        for account in accounts:
            slot = current.get(account["id"])
            if account["id"] not in final and slot and slot not in taken and owners.get(slot) is None:
                claim(account, slot)
        restored = []
        # A trade's saved copies may still go back into a slot (heal_trades), so they count as held too.
        watched = [read_secret(watch_service(entry)) for entry in (read_json(watch_path(root), {}) or {}).get("trades", [])]
        live = {oauth(blob).get("refreshToken") for blob in [*items.values(), *(login for entry in watched for login in (entry or {}).get("logins", []))]} - {None}
        for account in accounts:
            if account["id"] in final:
                continue
            slot = current.get(account["id"])
            if slot in taken or owners.get(slot) != "":
                slot = account["id"] if account["id"] not in taken and owners.get(account["id"], "") == "" else str(uuid.uuid4())
            claim(account, slot)
            prepare_profile(root, slot)
            backup = read_secret(backup_service(account))
            if oauth(backup).get("refreshToken") and oauth(backup)["refreshToken"] not in live:
                with contextlib.suppress(ValueError, OSError, subprocess.TimeoutExpired):
                    write_secret(slot_service(root, slot), backup)
                    restored.append(account)
        for account in accounts:
            blob = items.get(final[account["id"]])
            if owners.get(final[account["id"]]) == email(account) and oauth(blob).get("refreshToken"):
                saved = read_secret(backup_service(account))
                if oauth(saved).get("refreshToken") != oauth(blob)["refreshToken"] and \
                        (oauth(blob).get("expiresAt") or 0) >= (oauth(saved).get("expiresAt") or 0):
                    with contextlib.suppress(ValueError, OSError, subprocess.TimeoutExpired):
                        write_secret(backup_service(account), {"claudeAiOauth": oauth(blob)})
        others = {k: v for k, v in homes.items() if k not in final and v not in taken}
        # A spare copy of a login another item holds is spent the day it refreshes: the server then
        # rejects the other copy's refresh token. One that no running session reads goes.
        refresh = lambda slot: oauth(items.get(slot)).get("refreshToken")
        held = {refresh(slot) for slot in final.values()} - {None}
        spare = [slot for slot in slots if slot not in taken and slot not in others.values() and refresh(slot) in held]
        processes = slot_processes(root, config) if spare else {}
        if processes is not None:
            for slot in set(spare) - set(processes.values()):
                subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", slot_service(root, slot)],
                               capture_output=True, timeout=15)
        wanted = {**others, **{account_id: slot for account_id, slot in final.items() if slot not in (account_id, "mac")}}
        moved = [a for a in accounts if a["id"] in current and current[a["id"]] != final[a["id"]]]
        if wanted == homes and not restored:
            return []
        atomic_json(homes_path(root), wanted)
        changed = {current[a["id"]] for a in moved} | {final[a["id"]] for a in moved}
        swapped = read_json(swapped_path(root), {}) or {}
        atomic_json(swapped_path(root), {**swapped, **{slot: time.time() for slot in changed}})
        for slot in changed:
            (live_dir(root) / f"{slot}.json").unlink(missing_ok=True)
        read_secret.cache_clear()
    found = lambda a: owners.get(final[a["id"]]) == email(a)
    return ([f"{a['name']} found its login in another slot." for a in moved if a not in restored and found(a)]
            + [f"{a['name']}'s login was overwritten; sign in to it again." for a in moved if a not in restored and not found(a)]
            + [f"{a['name']}'s login was overwritten; Side A put back its last one." for a in restored])


def forget_backup(account):
    subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", backup_service(account)],
                   capture_output=True, timeout=15)
    read_secret.cache_clear()


# Why the last process_environment() of each pid came back empty, for the log.
environment_failures = {}


def process_environment(pid):
    """A process's argv[0] and environment, exactly as the kernel holds them (what ps -E prints,
    without the ambiguity of argv text that looks like an environment variable). None when the kernel
    refuses: EINVAL for a zombie or a process that's exiting, and for another user's process."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        environment_failures[pid] = os.strerror(ctypes.get_errno())
        return None
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        environment_failures[pid] = os.strerror(ctypes.get_errno())
        return None
    raw = buffer.raw[:size.value]
    argc = int.from_bytes(raw[:4], "little")
    parts = [part for part in raw[4:].split(b"\0") if part]
    # parts: executable path, argv[0..argc-1], then environment entries.
    if len(parts) < argc + 1:
        environment_failures[pid] = "cut short"
        return None
    env = dict(entry.decode(errors="replace").split("=", 1) for entry in parts[argc + 1:] if b"=" in entry)
    return parts[1].decode(errors="replace") if argc else parts[0].decode(errors="replace"), env


def busy_slots(root, config):
    """The slots running claude processes read their login from, from each process's environment
    (Claude Code's own rule: CLAUDE_SECURESTORAGE_CONFIG_DIR, else CLAUDE_CONFIG_DIR, empty is the
    Mac login). None when processes can't be listed, so nothing is traded blind."""
    processes = slot_processes(root, config)
    return None if processes is None else set(processes.values())


# Why slot_processes() last answered None, in words safe for the log.
listing_problem = ""
# The first limit suits a calm Mac; under a load of hundreds `ps` needs more.
PS_LIMITS = (10, 40)
# Waits before reading an unreadable process again: most are exiting or between fork and exec.
ENVIRONMENT_RETRIES = (0.2, 1.0)


def listed_processes():
    """`ps` output for this user's processes, or None with listing_problem set."""
    global listing_problem
    for limit in PS_LIMITS:
        try:
            listing = subprocess.run(["ps", "-o", "pid=,comm=", "-U", keychain_user()], capture_output=True, text=True, timeout=limit)
        except subprocess.TimeoutExpired:
            listing_problem = f"ps took over {limit}s"
            continue
        except OSError as error:
            listing_problem = f"ps failed: {error.strerror or 'unknown'}"
            continue
        if listing.returncode == 0:
            return listing.stdout
        listing_problem = f"ps exit {listing.returncode}"
    return None


def process_state(pid):
    """What `ps` calls a process: "" when gone. Z is a zombie, and E in the flags means it's exiting."""
    try:
        os.kill(pid, 0)
    except OSError:
        return ""
    try:
        found = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return found.stdout.strip() if found.returncode == 0 else ""


def finished(state):
    return not state or state.startswith("Z") or "E" in state


def slot_processes(root, config):
    """Each running claude process's pid with the slot it reads its login from; None when unknown,
    with the reason in listing_problem. One process that stays unreadable could be reading either side
    of a trade, so it holds up every trade: a process that has finished can't read anything."""
    global listing_problem
    listing_problem = ""
    output = listed_processes()
    if output is None:
        return None
    # Every profile on disk, not only listed accounts: a removed account's profile may hold a moved login.
    profiles = [p.name for p in (root / "profiles").glob("*") if p.is_dir()]
    services = {profile_service(root, slot): slot for slot in profiles + [a["id"] for a in config.get("accounts", [])]
                if is_uuid(slot)}
    services[GLOBAL_SERVICE] = "mac"
    busy = {}
    for line in output.splitlines():
        pid, _, command = line.strip().partition(" ")
        program = Path(command.strip())
        if not pid.isdigit() or (program.name != "claude" and program.parent.name != "versions"):
            continue
        pid = int(pid)
        found = process_environment(pid)
        for wait in ENVIRONMENT_RETRIES:
            if found is not None or finished(process_state(pid)):
                break
            time.sleep(wait)
            found = process_environment(pid)
        if found is None:
            state = process_state(pid)
            if finished(state):
                continue
            listing_problem = f"process {pid} ({state}) unreadable: {environment_failures.get(pid, 'unknown')}"
            return None
        env = found[1]
        # A pool session reaches Anthropic through Side A and reads no login.
        if env.get("SIDE_A_POOL") == "1":
            continue
        store = env.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        if store is None:
            store = env.get("CLAUDE_CONFIG_DIR") or ""
        service = GLOBAL_SERVICE if not store else \
            f"{GLOBAL_SERVICE}-{hashlib.sha256(unicodedata.normalize('NFC', store).encode()).hexdigest()[:8]}"
        if service in services:
            busy[int(pid)] = services[service]
    return busy


# What Claude Code's rate_limit reply calls each limit ("You've hit your session limit · resets 1pm"),
# checked in this order: a monthly spend cap reply names the plan limit after it.
LIMIT_PHRASES = (("model:fable", "fable limit"), ("seven_day", "weekly limit"), ("five_hour", "session limit"))


def session_limit(session_id):
    """The limit a session's latest main-thread reply says it hit, and when, or None. Claude Code
    writes the API's rate_limit error as a synthetic reply: direct proof the account is out, even
    while the usage endpoint answers 429 for it."""
    for path in (Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"):
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 131072))
            lines = stream.read().splitlines()
        for line in reversed(lines):
            if b'"assistant"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue  # the first, partial line of the tail
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            if not (entry.get("isApiErrorMessage") and entry.get("error") == "rate_limit"):
                return None
            content = (entry.get("message") or {}).get("content")
            text = (content if isinstance(content, str) else " ".join(
                part.get("text", "") for part in content or [] if isinstance(part, dict))).casefold()
            limit = next((window for window, phrase in LIMIT_PHRASES if phrase in text), None)
            return {"limit": limit, "at": epoch(entry.get("timestamp"))} if limit and entry.get("timestamp") else None
    return None


def session_model(session_id):
    """Model of the session's latest main-thread reply. Long tool output can fill the usual tail,
    so a wider one is read only when needed (from brandedDaniel's fork)."""
    for path in (Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"):
        for size in (262144, 8 << 20):
            with open(path, "rb") as stream:
                stream.seek(0, os.SEEK_END)
                stream.seek(max(0, stream.tell() - size))
                lines = stream.read().splitlines()
            for line in reversed(lines):
                if b'"assistant"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "assistant" or entry.get("isSidechain"):
                    continue
                model = (entry.get("message") or {}).get("model")
                if model and not model.startswith("<"):
                    return model
        return None
    return None


def slot_models(processes):
    """For each slot running sessions read, the model each session last answered with (None when unknown)."""
    found = {}
    for pid, slot in (processes or {}).items():
        model = None
        with contextlib.suppress(OSError, ValueError, KeyError, TypeError):
            record = read_json(Path.home() / ".claude" / "sessions" / f"{pid}.json", {}) or {}
            if is_uuid(record.get("sessionId")):
                model = session_model(record["sessionId"])
        found.setdefault(slot, []).append(model)
    return found


def slot_quiet(processes):
    """For each slot running sessions read, seconds since any of its sessions last wrote to its transcript."""
    quiet = {}
    now = time.time()
    for pid, slot in (processes or {}).items():
        with contextlib.suppress(OSError, ValueError, KeyError, TypeError, StopIteration):
            record = read_json(Path.home() / ".claude" / "sessions" / f"{pid}.json", {}) or {}
            if is_uuid(record.get("sessionId")):
                path = next((Path.home() / ".claude" / "projects").glob(f"*/{record['sessionId']}.jsonl"))
                quiet[slot] = min(quiet.get(slot, float("inf")), max(now - path.stat().st_mtime, 0))
    return quiet


def limit_errors(root, config, processes):
    """Per account, the newest limit a running session on it reported hitting. Sessions are found
    through Claude Code's registry (~/.claude/sessions/<pid>.json); an error from before the slot's
    last trade belonged to the login that was in it then."""
    swapped = read_json(swapped_path(root), {}) or {}
    owners, found = {}, {}
    for pid, slot in (processes or {}).items():
        try:
            record = read_json(Path.home() / ".claude" / "sessions" / f"{pid}.json", {}) or {}
            hit = session_limit(record["sessionId"]) if is_uuid(record.get("sessionId")) else None
        except (OSError, ValueError, AttributeError):
            continue
        if not hit or hit["at"] <= swapped.get(slot, 0):
            continue
        if slot not in owners:
            owners[slot] = (slot_owner(root, config, slot) or {}).get("id")
        account = owners[slot]
        if not account:
            continue
        sessions = found.get(account, {}).get("sessions", []) + [record["sessionId"]]
        found[account] = {**(hit if hit["at"] > found.get(account, {}).get("at", 0) else found[account]), "sessions": sessions}
    return found


def is_uuid(value):
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError):
        return False


def sign_in_slot(root, config, account):
    """The slot a sign-in writes: the account's own. Another account's login there blocks it while
    that is the other account's only good copy. A stray second copy (from a `/login` typed in a
    session, or a session that saved an old login over a trade) is signed in over, once the other
    account's home holds its own login, at least as new."""
    read_secret.cache_clear()
    slot = home_slot(root, account)
    blob = read_secret(slot_service(root, slot))
    held = token_email(root, blob)
    owner = account_for_email(config, held) if held and held != account.get("email", "").casefold() else None
    if owner:
        home = home_slot(root, owner)
        kept = read_secret(slot_service(root, home)) if home != slot else None
        expiry = lambda login: ((login or {}).get("claudeAiOauth") or {}).get("expiresAt") or 0
        if home == slot or token_email(root, kept) != held or expiry(kept) < expiry(blob):
            raise ValueError(f"{account['name']}'s slot holds {owner['name']}'s login; sign in again after Side A frees it.")
    return slot


def signing_in_path(root, slot):
    return root / "runtime" / f"signing-in-{slot}"


def signing_in(root, slot):
    """A sign-in child is writing this slot; its pid is in the marker."""
    try:
        os.kill(int(signing_in_path(root, slot).read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


def busy_logins(root, config, processes):
    """Each slot a running claude reads, with the library account whose login is in it."""
    if processes is None:
        return None
    return [{"slot": slot, "account": (slot_owner(root, config, slot) or {}).get("id")} for slot in sorted(set(processes.values()))]


def verify_idle_owner(root, account, blob):
    """An expired login can't be looked up until it is renewed; until then the CLI's own
    record of who signed in must name this account."""
    if not token_email(root, blob) and (not account.get("email") or
            auth_status(root, account).get("email", "").casefold() != account["email"].casefold()):
        raise SignInAgain(f"Sign in to {account['name']} again.")


# security -i reads commands in chunks; Claude Code writes through stdin up to this length, argv beyond.
STDIN_LIMIT = 4032


def write_secret(service, blob):
    """Replaces a stored login exactly as Claude Code writes it: hex through stdin when it fits,
    so the token stays out of process lists, else as an argument like Claude Code does."""
    hexed = json.dumps(blob, separators=(",", ":")).encode().hex()
    command = f'add-generic-password -U -a "{keychain_user()}" -s "{service}" -X "{hexed}" '
    for _ in range(3):
        # A timeout's own text carries the arguments, which here can hold the token: it stops here.
        with contextlib.suppress(subprocess.TimeoutExpired, KeychainBusy):
            if len(command) <= STDIN_LIMIT:
                result = subprocess.run(["security", "-i"], input=command + "\n", capture_output=True, text=True, timeout=15)
            else:
                result = subprocess.run(["security", "add-generic-password", "-U", "-a", keychain_user(), "-s", service, "-X", hexed],
                                        capture_output=True, text=True, timeout=15)
            read_secret.cache_clear()
            if result.returncode == 0 and "error" not in result.stderr.lower() and read_secret(service) == blob:
                return
        time.sleep(0.5)
    raise KeychainBusy("The login could not be saved to the Keychain; retrying later.")


def renew(root, config, account, due=expired):
    """Renews an expired login exactly as Claude Code does, so its limits stay readable around the
    clock at no cost. Under Claude Code's refresh lock, and re-read inside it: if a session renewed
    the login first, that one is used, so a refresh token is never spent twice. `due` says which
    logins need it; the pool also renews one Anthropic just refused."""
    service = home_service(root, account)
    if not due(read_secret(service)):
        return
    verify_idle_owner(root, account, owned_login(root, account, idle_ok=True))
    # One Side A renewal or trade at a time; a trade in between moves the login, so re-resolve.
    with selection_lock(root, "renew.lock"):
        read_secret.cache_clear()
        if home_service(root, account) != service:
            return
        folder = selector_for(root, account) or str(Path.home() / ".claude")
        with claude_refresh_lock(folder):
            _renew(root, account, service, due, config)


def autopilot_note(root, line):
    """One line in autopilot.log, in the app's format. Never carries token material."""
    with contextlib.suppress(OSError):
        descriptor = os.open(root / "runtime" / "autopilot.log", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(descriptor, "a") as stream:
            stream.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} {line}\n")


@contextlib.contextmanager
def termination_held():
    """Keeps SIGTERM (the app's watchdog) from ending this process inside the block. A refresh token
    is spent when the endpoint answers, so dying before the answer is saved loses the login."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    pending = []
    previous = signal.signal(signal.SIGTERM, lambda *_: pending.append(True))
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)
        if pending:
            sys.exit(143)


class RenewalRefused(ValueError):
    """The token endpoint turned a refresh down: its HTTP status and OAuth error code only."""

    def __init__(self, status, code, on_hold):
        super().__init__(f"Renewing the login was refused (HTTP {status}, {code}); retrying later.")
        self.status, self.code = status, code
        # Claude Code's rule: only invalid_grant on 400 or 401 means the token is dead. A 403, or any
        # other code, can be a block or an outage that passes.
        self.ended = status in (400, 401) and code == "invalid_grant" and not on_hold


def refusal(error):
    """What a 4xx from the token endpoint said. The body is parsed for its code and nothing else is kept."""
    try:
        data = json.loads(error.read() or b"{}")
    except (ValueError, OSError, AttributeError):
        data = {}
    found = data.get("error") if isinstance(data, dict) else None
    code = found.get("type") if isinstance(found, dict) else found
    code = code if isinstance(code, str) and re.fullmatch(r"[a-z0-9_]{1,40}", code) else "none"
    return RenewalRefused(error.code, code, isinstance(data, dict) and bool(data.get("error_uri")))


def expiry_of(blob):
    return ((blob or {}).get("claudeAiOauth") or {}).get("expiresAt") or 0


def refresh_of(blob):
    return ((blob or {}).get("claudeAiOauth") or {}).get("refreshToken") or ""


def slot_label(slot):
    return slot if slot == "mac" else slot[:8]


def login_generations(root, config, account, service):
    """Every other copy of this account's login Side A may spend, newest first: other slots no running
    session reads, its backup, and a recent trade's saved copies. Each is (source, slot, blob), slot
    None for a dormant copy. A slot whose owner can't be confirmed is never spent."""
    processes = slot_processes(root, config)
    running = None if processes is None else set(processes.values())
    email = account.get("email", "").casefold()
    homes = read_json(homes_path(root), {}) or {}
    profiles = [p.name for p in (root / "profiles").glob("*") if p.is_dir() and is_uuid(p.name)]
    slots = {"mac", *profiles, *[slot for slot in homes.values() if is_uuid(slot)]}
    held = {slot: read_secret(slot_service(root, slot)) for slot in slots if slot_service(root, slot) != service}
    found = []
    for slot, blob in held.items():
        if refresh_of(blob) and token_email(root, blob) == email and running is not None and slot not in running:
            found.append((f"slot {slot_label(slot)}", slot, blob))
    # Spending a dormant copy of a token some slot still reads would end that slot's copy.
    live = {refresh_of(blob) for blob in held.values()} - {""}
    backup = read_secret(backup_service(account))
    if refresh_of(backup) and refresh_of(backup) not in live and token_email(root, backup) in ("", email):
        found.append(("backup", None, backup))
    # A trade's copies hold both accounts' logins, so one with no readable owner may be the other account's.
    dormant = []
    for entry in (read_json(watch_path(root), {}) or {}).get("trades", []):
        dormant += [("trade copy", login) for login in (read_secret(watch_service(entry)) or {}).get("logins", [])]
    for source, blob in dormant:
        if refresh_of(blob) and refresh_of(blob) not in live and token_email(root, blob) == email:
            found.append((source, None, blob))
    return sorted(found, key=lambda item: expiry_of(item[2]), reverse=True)


def session_running(root, config, slot):
    processes = slot_processes(root, config)
    return "unknown" if processes is None else "yes" if slot in processes.values() else "no"


def _renew(root, account, service, due=expired, config=None):
    # Fresh from the Keychain, not this run's cache: a session may have renewed it meanwhile.
    read_secret.cache_clear()
    blob = read_secret(service)
    if not due(blob):
        return
    config = config or {"accounts": [account]}
    slot = home_slot(root, account)
    note = lambda text: autopilot_note(root, f"{account['name']}: renewal {text} slot={slot_label(slot)}")
    # A save that failed last time left the only live copy in the backup: an older token is not sent.
    saved = read_secret(backup_service(account))
    spend = saved if (saved or {}).get("rescued") and expiry_of(saved) > expiry_of(blob) else blob
    with termination_held():
        refused = "status=none error=no_refresh_token"
        if refresh_of(spend):
            try:
                save_renewal(account, service, blob, spend, request_renewal(spend, note), note)
                note(f"ok status=200 {generation_age(spend)}")
                return
            except RenewalRefused as error:
                refused = f"status={error.status} error={error.code}"
                if not error.ended:
                    note(f"refused {refused} {generation_age(spend)} session-running={session_running(root, config, slot)}")
                    raise
        retry_generation(root, config, account, service, slot, due, blob, spend, refused, note)


def generation_age(login):
    return f"expired={int((time.time() - expiry_of(login) / 1000) // 60)}m"


def retry_generation(root, config, account, service, slot, due, blob, spent, refused, note):
    """The endpoint says `spent` is dead. Before the login counts as ended: a session may have renewed
    the slot meanwhile, and another copy Side A holds may be newer. An older copy is never sent, since
    a server that spots a reused token may end the whole login. One retry."""
    ended = f"Sign in to {account['name']} again; its login ended."
    read_secret.cache_clear()
    current = read_secret(service)
    changed = refresh_of(current) and refresh_of(current) != refresh_of(spent)
    if changed and not due(current):
        note(f"recovered by=session after {refused}")
        return
    others = login_generations(root, config, account, service)
    if changed:
        others.insert(0, ("slot again", None, current))
    newer = [other for other in others if expiry_of(other[2]) > expiry_of(spent) and refresh_of(other[2]) != refresh_of(spent)]
    facts = (f"{refused} {generation_age(spent)} session-running={session_running(root, config, slot)} "
             f"other-generations={len(others)} newer={len(newer)}")
    if not newer:
        note(f"ended {facts}")
        raise SignInAgain(ended)
    source, other_slot, login = max(newer, key=lambda other: expiry_of(other[2]))
    folder = (slot_selector(root, other_slot) or str(Path.home() / ".claude")) if other_slot else None
    with claude_refresh_lock(folder) if folder else contextlib.nullcontext():
        if other_slot:
            # Read before the lock: a session may have started on this slot, or spent this token, since.
            read_secret.cache_clear()
            if refresh_of(read_secret(slot_service(root, other_slot))) != refresh_of(login) or session_running(root, config, other_slot) != "no":
                note(f"retry-skipped from={source} copy-changed {facts}")
                raise RenewalRefused(0, "copy_changed", False)
        try:
            data = request_renewal(login, note)
        except RenewalRefused as error:
            note(f"retry-failed from={source} status={error.status} error={error.code} {facts}")
            if error.ended:
                raise SignInAgain(ended) from None
            raise
        note(f"recovered by={source} {facts}")
        save_renewal(account, service, blob, login, data, note)
        # The copy it came from was spent with this; only a slot no account calls home is cleared.
        if other_slot and other_slot not in (read_json(homes_path(root), {}) or {}).values():
            subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", slot_service(root, other_slot)],
                           capture_output=True, timeout=15)
            read_secret.cache_clear()


def request_renewal(login, note):
    """One spend of `login`'s refresh token. Raises RenewalRefused on a 400, 401 or 403."""
    oauth = login["claudeAiOauth"]
    body = {"grant_type": "refresh_token", "refresh_token": oauth["refreshToken"], "client_id": CLIENT_ID}
    if oauth.get("scopes"):
        body["scope"] = " ".join(oauth["scopes"])
    try:
        data = post_json(TOKEN_URL, body)
    except urllib.error.HTTPError as error:
        if error.code in (400, 401, 403):
            raise refusal(error) from None
        note(f"failed status={error.code} error=none {generation_age(login)}")
        raise ValueError(f"Renewing the login failed (HTTP {error.code}); retrying later.") from None
    except OSError as error:
        # The token may have rotated with its answer lost; a later invalid_grant reads against this line.
        note(f"unanswered status=none error={type(error).__name__} {generation_age(login)}")
        raise
    if not data.get("access_token") or not data.get("expires_in"):
        raise ValueError("Renewing the login returned an unexpected answer; retrying later.")
    return data


def save_renewal(account, service, blob, login, data, note):
    """The answer holds the only live refresh token now, so a failed save tries again, then the backup,
    where the next renewal finds it."""
    oauth = dict(login["claudeAiOauth"])
    oauth.update(accessToken=data["access_token"], refreshToken=data.get("refresh_token") or oauth["refreshToken"],
                 expiresAt=int((time.time() + float(data["expires_in"])) * 1000))
    if data.get("refresh_token_expires_in"):
        oauth["refreshTokenExpiresAt"] = int((time.time() + float(data["refresh_token_expires_in"])) * 1000)
    for attempt in range(2):
        try:
            # Only the Claude login is replaced: MCP logins a session saved meanwhile are kept.
            read_secret.cache_clear()
            write_secret(service, {**(read_secret(service) or blob or {}), "claudeAiOauth": oauth})
            return
        except (ValueError, OSError, subprocess.TimeoutExpired):
            time.sleep(1 + attempt)
    note("save-failed status=200 error=keychain")
    write_secret(backup_service(account), {"claudeAiOauth": oauth, "rescued": True})
    raise KeychainBusy("The renewed login is in Side A's backup until the Keychain answers; retrying later.")


def token_hash(blob):
    token = ((blob or {}).get("claudeAiOauth") or {}).get("accessToken") or ""
    return hashlib.sha256(token.encode()).hexdigest()[:16]


def pool_token(root, config, account, refused=None):
    """The access token Side A's pool sends for `account`. It goes only to the app over this
    process's stdout; the login stays in its slot, refreshed under Claude Code's lock, so the pool
    never holds a second copy that could rotate the slot's one away. Renewed five minutes early, so
    no request starts on a token about to lapse, and when Anthropic refused the one whose hash is
    `refused` (unless a session renewed it meanwhile)."""
    if provider_of(account) != "claude":
        raise ValueError("Only Claude accounts join the pool.")
    renew(root, config, account, due=lambda blob: expired(blob, 300) or (refused is not None and token_hash(blob) == refused))
    read_secret.cache_clear()
    oauth = owned_login(root, account)["claudeAiOauth"]
    return {"accessToken": oauth["accessToken"], "expiresAt": oauth.get("expiresAt") or 0, "hash": token_hash({"claudeAiOauth": oauth})}


def prime(root, config, account):
    """Send one tiny message so the account's 5-hour window starts now instead of at first real use."""
    if provider_of(account) == "codex":
        from codex_bridge import prime as codex_prime
        return codex_prime(root, account)
    verify_idle_owner(root, account, owned_login(root, account, idle_ok=True))
    result = run_as(root, account, ["-p", "Reply with OK.", "--model", "haiku", "--max-turns", "1"], 120)
    if result.returncode != 0:
        raise ValueError(f"{account['name']} could not start its 5-hour window.")


def scan_transcript(path, previous=None):
    """Token totals per (local day, project, model) for one transcript, plus responses per
    local hour of each day. Transcripts are append-only, so a grown file is read from where
    the previous scan stopped; only complete lines are counted."""
    previous = previous if previous and previous.get("offset", 0) <= path.stat().st_size else None
    totals = {key: list(values) for key, values in (previous or {}).get("totals", {}).items()}
    hours = {day: list(counts) for day, counts in (previous or {}).get("hours", {}).items()}
    # Duplicates of one response are adjacent, so the last few keys cover the seam.
    seen = {tuple(key) for key in (previous or {}).get("tail", [])}
    recent = list((previous or {}).get("tail", []))
    offset = (previous or {}).get("offset", 0)
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            offset += len(line)
            if b'"usage"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            message = entry.get("message") or {}
            usage = message.get("usage") if isinstance(message, dict) else None
            if not isinstance(usage, dict) or not entry.get("timestamp"):
                continue
            # Streaming writes one line per content block; count each API response once.
            key = (message.get("id"), entry.get("requestId"))
            if key != (None, None):
                if key in seen:
                    continue
                seen.add(key)
                recent = (recent + [list(key)])[-20:]
            moment = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).astimezone()
            day = moment.date().isoformat()
            hours.setdefault(day, [0] * 24)[moment.hour] += 1
            bucket = totals.setdefault(f"{day}\t{entry.get('cwd') or ''}\t{message.get('model') or ''}", [0, 0, 0, 0])
            for index, field in enumerate(("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")):
                bucket[index] += int(usage.get(field) or 0)
    return {"totals": totals, "hours": hours, "offset": offset, "tail": recent}


def scan_codex(path, previous=None):
    """Token totals for one Codex session log, in the same shape as scan_transcript.
    Each token_count event carries the session's running total; counting the change
    between events keeps a repeated event from being counted twice."""
    previous = previous if previous and previous.get("offset", 0) <= path.stat().st_size else None
    totals = {key: list(values) for key, values in (previous or {}).get("totals", {}).items()}
    hours = {day: list(counts) for day, counts in (previous or {}).get("hours", {}).items()}
    state = dict((previous or {}).get("codex") or {"model": "", "cwd": "", "last": [0, 0, 0, 0]})
    offset = (previous or {}).get("offset", 0)
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            offset += len(line)
            if b'"turn_context"' not in line and b'"session_meta"' not in line and b'"token_count"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            payload = entry.get("payload") or {}
            if entry.get("type") in ("turn_context", "session_meta"):
                state["model"] = payload.get("model") or state["model"]
                state["cwd"] = payload.get("cwd") or state["cwd"]
                continue
            info = (payload.get("info") or {}) if payload.get("type") == "token_count" else {}
            total, last = info.get("total_token_usage") or {}, info.get("last_token_usage") or {}
            if not (total or last) or not entry.get("timestamp"):
                continue
            # Input includes cached input; split it so cached reads count as cache reads.
            vector = lambda usage: [int(usage.get("input_tokens") or 0) - int(usage.get("cached_input_tokens") or 0),
                                    int(usage.get("output_tokens") or 0), int(usage.get("cache_write_input_tokens") or 0),
                                    int(usage.get("cached_input_tokens") or 0)]
            now = vector(total) if total else None
            # Like ccusage: the turn's own usage when the running total moved (it can restart after
            # compaction), else the growth of the total. A repeated event moves nothing.
            if last and (now is None or now != state["last"]):
                delta = vector(last)
            else:
                delta = [max(a - b, 0) for a, b in zip(now or state["last"], state["last"])]
            if now is not None:
                state["last"] = now
            if not any(delta):
                continue
            moment = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).astimezone()
            day = moment.date().isoformat()
            hours.setdefault(day, [0] * 24)[moment.hour] += 1
            bucket = totals.setdefault(f"{day}\t{state['cwd']}\t{state['model']}", [0, 0, 0, 0])
            for index, value in enumerate(delta):
                bucket[index] += value
    return {"totals": totals, "hours": hours, "offset": offset, "codex": state}


def recent_model(within=1800):
    """Model of the newest Claude Code response in the last half hour, so Autopilot can plan
    around a model-specific cap. Only the newest session counts."""
    # ponytail: newest session wins; per-terminal models would need the shell hook to report them.
    cutoff, newest = time.time() - within, None
    folder = Path.home() / ".claude" / "projects"
    for path in folder.glob("*/*.jsonl") if folder.is_dir() else []:
        try:
            stat = path.stat()
        except OSError:
            continue
        if stat.st_mtime > cutoff and (newest is None or stat.st_mtime > newest[0]):
            newest = (stat.st_mtime, path, stat.st_size)
    if not newest:
        return None
    # Read backwards in chunks: a large tool result can follow the last response.
    end, carry = newest[2], b""
    with open(newest[1], "rb") as stream:
        while end > 0 and newest[2] - end < 8 * 262144:
            start = max(end - 262144, 0)
            stream.seek(start)
            lines = (stream.read(end - start) + carry).split(b"\n")
            carry, end = (lines.pop(0) if start else b""), start
            for line in reversed(lines):
                if b'"assistant"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                    model = (entry.get("message") or {}).get("model")
                    moment = epoch(entry.get("timestamp"))
                except (ValueError, AttributeError, TypeError):
                    continue
                if model and not model.startswith("<"):
                    return model if moment and moment > cutoff else None
    return None


def machine_identity(root):
    """A stable id per Mac, so reinstalling never leaves an old copy of this Mac's totals counted twice."""
    try:
        hardware = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, timeout=5).stdout
        hardware = next(line.split('"')[-2] for line in hardware.splitlines() if "IOPlatformUUID" in line)
    except (OSError, subprocess.TimeoutExpired, StopIteration, IndexError):
        hardware = ""
    path = root / "machine-id"
    if hardware:
        path.write_text(hashlib.sha256(("side-a:" + hardware).encode()).hexdigest()[:32])
    elif not path.exists():
        path.write_text(str(uuid.uuid4()))
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        name = ""
    return path.read_text().strip(), name or "This Mac"


def sync_machines(root, folder, merged, hours, since, days):
    """Shares this Mac's token totals and activity through a synced folder and adds every
    other Mac's. Only counts, project paths, account names and emails are written; logins never are."""
    folder = Path(folder) / "machines"
    own, name = machine_identity(root)
    config = read_json(root / "config.json", {}) or {}
    accounts = [{"name": a["name"], "email": a.get("email", ""), "provider": provider_of(a)} for a in config.get("accounts", [])]
    mine = {"name": name, "totals": merged, "hours": hours, "accounts": accounts}
    previous = read_json(folder / f"{own}.json", None) if (folder / f"{own}.json").exists() else None
    # Unchanged totals are not rewritten, so iCloud uploads only real changes plus a daily heartbeat.
    if not isinstance(previous, dict) or time.time() - float(previous.get("updated") or 0) > 86400 \
            or {k: v for k, v in previous.items() if k != "updated"} != mine:
        atomic_json(folder / f"{own}.json", {**mine, "updated": time.time()})
    week = (datetime.date.today() - datetime.timedelta(days=6)).isoformat()
    tokens = lambda totals: sum(sum(v) for k, v in totals.items() if k.split("\t", 1)[0] >= week)
    machines = [{"name": name, "tokens": tokens(merged), "updated": time.time(), "current": True}]
    known = {(a["provider"], a["email"].casefold()) for a in accounts if a["email"]}
    elsewhere = {}
    merged = {key: list(values) for key, values in merged.items()}
    hours = {day: list(counts) for day, counts in hours.items()}
    for path in sorted(folder.glob("*.json")):
        if path.stem == own:
            continue
        # ponytail: an iCloud file evicted to a placeholder is skipped until macOS downloads it again.
        # Shared files are untrusted: a malformed one is skipped and every count is bounded.
        try:
            data = read_json(path, None)
            if not isinstance(data, dict) or time.time() - float(data.get("updated") or 0) > days * 86400:
                continue
            bound = lambda value, top: min(max(int(value), 0), top)
            totals = {str(k): [bound(v, 10**13) for v in values[:4]] + [0] * (4 - len(values[:4]))
                      for k, values in dict(data.get("totals") or {}).items() if str(k).count("\t") == 2 and str(k)[:10] >= since}
            counts = {str(day): [bound(c, 10**6) for c in list(values)[:24]] for day, values in dict(data.get("hours") or {}).items() if str(day) >= since}
            remote = [a for a in list(data.get("accounts") or []) if isinstance(a, dict)]
            updated = float(data["updated"])
        except (ValueError, TypeError, AttributeError, KeyError, OSError):
            continue
        for key, values in totals.items():
            bucket = merged.setdefault(key, [0, 0, 0, 0])
            for index, value in enumerate(values):
                bucket[index] += value
        for day, values in counts.items():
            total = hours.setdefault(day, [0] * 24)
            for hour, count in enumerate(values):
                total[hour] += count
        machines.append({"name": str(data.get("name") or "Another Mac")[:60], "tokens": tokens(totals), "updated": updated, "current": False})
        for account in remote:
            key = (account.get("provider"), str(account.get("email", "")).casefold())
            if key[1] and key[0] in ("claude", "codex") and key not in known:
                elsewhere.setdefault(key, {"name": str(account.get("name") or key[1]), "email": account["email"],
                                           "provider": key[0], "machine": machines[-1]["name"]})
    return merged, hours, machines, list(elsewhere.values())


def report(root, days=30, sync=None):
    """Per-day and per-project token use from local Claude Code and Codex logs, plus other Macs'
    totals when a sync folder is set."""
    cutoff = time.time() - days * 86400
    cache_path = root / "runtime" / "report-cache.json"
    cache = read_json(cache_path, {}) or {}
    fresh, merged, hours = {}, {}, {}
    folders = [(Path.home() / ".claude" / "projects", "*/**/*.jsonl", scan_transcript), (root / "conversations", "*/**/*.jsonl", scan_transcript),
               (Path.home() / ".codex" / "sessions", "**/*.jsonl", scan_codex)]
    for folder, pattern, scan in folders:
        for path in folder.glob(pattern) if folder.is_dir() else []:
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime < cutoff:
                continue
            signature = f"{stat.st_size}:{int(stat.st_mtime)}"
            entry = cache.get(str(path))
            if not entry or entry["signature"] != signature or "offset" not in entry:
                entry = {"signature": signature, **scan(path, entry if entry and "offset" in entry else None)}
            fresh[str(path)] = entry
            for day, counts in entry["hours"].items():
                total = hours.setdefault(day, [0] * 24)
                for hour, count in enumerate(counts):
                    total[hour] += count
            for key, values in entry["totals"].items():
                bucket = merged.setdefault(key, [0, 0, 0, 0])
                for index, value in enumerate(values):
                    bucket[index] += value
    atomic_json(cache_path, fresh)
    since = (datetime.date.today() - datetime.timedelta(days=days - 1)).isoformat()
    merged = {key: values for key, values in merged.items() if key.split("\t", 1)[0] >= since}
    hours = {day: counts for day, counts in hours.items() if day >= since}
    machines, elsewhere = [], []
    if sync:
        merged, hours, machines, elsewhere = sync_machines(root, sync, merged, hours, since, days)
    by_day, by_project, by_model, by_day_model = {}, {}, {}, {}
    for key, (inp, out, write, read) in merged.items():
        day, project, model = key.split("\t")
        if day < since or model.startswith("<"):
            continue
        for table, name in ((by_day, day), (by_project, project), (by_model, model), (by_day_model, (day, model))):
            row = table.setdefault(name, {"input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0})
            row["input"] += inp; row["output"] += out; row["cacheWrite"] += write; row["cacheRead"] += read
    rows = lambda table, label: sorted(({label: name, **value} for name, value in table.items() if name),
                                       key=lambda row: -(row["input"] + row["output"] + row["cacheWrite"] + row["cacheRead"]))
    return {"days": sorted(rows(by_day, "date"), key=lambda row: row["date"]),
            "projects": rows(by_project, "project"), "models": rows(by_model, "model"),
            # Each day split by model, for the stacked daily chart.
            "dayModels": sorted(({"date": day, "model": model, **value} for (day, model), value in by_day_model.items() if model),
                                key=lambda row: (row["date"], row["model"])),
            "activity": [{"date": day, "hours": counts} for day, counts in sorted(hours.items()) if day >= since],
            "machines": machines, "elsewhere": elsewhere}


HOOK_MARK = "side-a-limit"


def limit_marker(root):
    return root / "runtime" / "limit-hit"


def hook_command(root):
    # `touch` only: StopFailure output is ignored, and nothing is added to the conversation.
    return f"touch {shlex.quote(str(limit_marker(root)))} # {HOOK_MARK}"


def set_limit_hook(root, enabled):
    """Opt-in StopFailure hook (matcher rate_limit) in ~/.claude/settings.json for instant switching."""
    with selection_lock(root, "settings.lock"):
        _set_limit_hook(root, enabled)


def _set_limit_hook(root, enabled):
    path = Path.home() / ".claude" / "settings.json"
    settings = read_json(path, {}) or {}
    hooks = settings.setdefault("hooks", {})
    groups = [g for g in hooks.get("StopFailure", []) if not any(HOOK_MARK in h.get("command", "") for h in g.get("hooks", []))]
    if enabled:
        limit_marker(root).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        groups.append({"matcher": "rate_limit", "hooks": [{"type": "command", "command": hook_command(root), "timeout": 5}]})
    if groups:
        hooks["StopFailure"] = groups
    else:
        hooks.pop("StopFailure", None)
    if not hooks:
        settings.pop("hooks")
    write_settings(settings)


def write_settings(settings):
    path = Path.home() / ".claude" / "settings.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.resolve()  # a symlinked settings file stays a symlink
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, prefix=".side-a-") as stream:
        json.dump(settings, stream, indent=2)
        stream.write("\n")
    if path.exists():
        os.chmod(stream.name, path.stat().st_mode & 0o777)
    os.replace(stream.name, path)


LIVE_MARK = "side-a-live"
# Every Claude Code reply hands the statusline the account's limits from the response
# headers, so saving them gives a live reading without calling the rate-limited usage endpoint.
# $(cat; echo x) keeps the input byte for byte, so the user's own statusline sees it unchanged.
# Each session's copy, under s/, gives its row the model, effort, context and cost; Claude Code writes the
# input compact and session_id first, so the shell finds the id without starting a process.
LIVE_SCRIPT = """#!/bin/sh
# side-a-live: saves each session's limits for Side A, then runs the original statusline.
umask 077
input=$(cat; echo x); input=${input%x}
dir=LIVE_DIR
case $input in *'"rate_limits"'*)
  name=${CLAUDE_SECURESTORAGE_CONFIG_DIR%/}; name=${name##*/}; name=${name:-mac}
  printf '%s' "$input" > "$dir/.$name.$$" && mv -f "$dir/.$name.$$" "$dir/$name.json" ;;
esac
sid=${input#*'"session_id":"'}; sid=${sid%%'"'*}
case $sid in ''|*[!0-9A-Za-z_-]*) ;; *)
  [ ${#sid} -le 64 ] && printf '%s' "$input" 2>/dev/null > "$dir/s/.$sid.$$" && mv -f "$dir/s/.$sid.$$" "$dir/s/$sid.json" ;;
esac
[ -n "$1" ] || exit 0
printf '%s' "$input" | /bin/sh -c "$1"
"""


def live_dir(root):
    return root / "runtime" / "live"


def live_wrapped(command):
    """The user's command inside Side A's wrapper, or None when the command is not the wrapper."""
    if not (isinstance(command, str) and command.startswith("/bin/sh ") and command.endswith(f" # {LIVE_MARK}")):
        return None
    words = shlex.split(command, comments=True)
    if len(words) not in (2, 3) or not words[1].endswith("/runtime/statusline.sh"):
        return None
    return words[2] if len(words) == 3 else ""


def set_live(root, enabled):
    """Wraps the statusLine command; the user's own command is kept as the wrapper's argument."""
    with selection_lock(root, "settings.lock"):
        _set_live(root, enabled)


def _set_live(root, enabled):
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    line = settings.get("statusLine")
    # Only a command statusline (or none) is wrapped; anything else is left exactly as it is.
    if line is not None and not (isinstance(line, dict) and line.get("type", "command") == "command"):
        return
    line = line or {}
    inner = live_wrapped(line.get("command"))
    command = (line.get("command") or "") if inner is None else inner
    if not isinstance(command, str):
        return
    if enabled:
        (live_dir(root) / "s").mkdir(parents=True, exist_ok=True, mode=0o700)
        script = root / "runtime" / "statusline.sh"
        script.write_text(LIVE_SCRIPT.replace("LIVE_DIR", shlex.quote(str(live_dir(root)))))
        wrapped = f"/bin/sh {shlex.quote(str(script))}" + (f" {shlex.quote(command)}" if command else "")
        settings["statusLine"] = {**line, "type": "command", "command": f"{wrapped} # {LIVE_MARK}"}
    elif inner is None:
        return
    elif command:
        settings["statusLine"] = {**line, "command": command}
    else:
        settings.pop("statusLine")
    write_settings(settings)


def live_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    line = settings.get("statusLine") if isinstance(settings.get("statusLine"), dict) else {}
    return live_wrapped(line.get("command")) is not None


def live_limits(root, config):
    """Each Claude account's limits as its newest session last saw them, by account id."""
    found = {}
    mac = mac_email(root)
    # A file from Mac-login sessions belongs to whoever held the Mac login then; a sign-in
    # as someone else drops it rather than credit their limits to the new account.
    seen = live_dir(root) / "mac.email"
    try:
        if mac and seen.read_text() != mac:
            (live_dir(root) / "mac.json").unlink(missing_ok=True)
    except FileNotFoundError:
        pass
    if mac and live_dir(root).is_dir():
        seen.write_text(mac)
    # A statusline Claude Code stopped mid-write leaves its temporary file behind.
    for path in live_dir(root).glob(".*.*"):
        with contextlib.suppress(OSError):
            if time.time() - path.stat().st_mtime > 60:
                path.unlink()
    swapped = read_json(swapped_path(root), {}) or {}
    for path in live_dir(root).glob("*.json"):
        try:
            name = path.stem
            account = next((a for a in config.get("accounts", []) if provider_of(a) == "claude" and home_slot(root, a) == name), None)
            with open(path) as stream:
                at = os.fstat(stream.fileno()).st_mtime
                payload = json.load(stream)
            limits = payload.get("rate_limits") or {}
            # Every session on a slot writes this file, and an idle one redraws with the limits of its
            # last reply, so the reading is as old as that reply.
            with contextlib.suppress(OSError, TypeError, KeyError):
                at = min(at, os.stat(payload["transcript_path"]).st_mtime)
            windows = [{"id": key, "label": label, "percent": percent(float(limits[key]["used_percentage"])),
                        "resetsAt": epoch(limits[key].get("resets_at"))}
                       for key, label in WINDOW_LABELS.items() if isinstance(limits.get(key), dict)]
            # ponytail: a fixed 2-minute quiet period after a trade covers replies in flight and Claude
            # Code's 30 s login cache; a reply streaming longer than that can still report the old account.
            if account and windows and at > swapped.get(name, 0) + 120 and at > found.get(account["id"], {}).get("at", 0):
                found[account["id"]] = {"at": at, "windows": windows}
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            continue
    return found


def limit_hook_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    return any(HOOK_MARK in h.get("command", "") for g in (settings.get("hooks") or {}).get("StopFailure", []) for h in g.get("hooks", []))


ISLAND_MARK = "side-a-island"
ISLAND_AGENTS = ("claude", "codex")
ISLAND_TIMEOUT = 86400
ISLAND_FOLLOW_UP = 3600
# Opt-in: phone messages for Claude sessions started in a terminal, waited for in the background from SessionStart and
# every Stop. Its own mark, so the island's hooks are rewritten without touching it.
INBOX_MARK = "side-a-inbox"
INBOX_TIMEOUT = 86400
# Python exits 2 for a missing script, which asyncRewake would take as a follow-up, so both are tested first.
ISLAND_LAUNCHER = """#!/bin/sh
# side-a-island
[ -x PYTHON ] || exit 0
[ -f SCRIPT ] || exit 0
exec PYTHON -I -S SCRIPT SOCKET "$@"
"""

# Runs before and after every tool call, so it costs one test until Side A leaves this session mail.
ISLAND_MAIL_LAUNCHER = """#!/bin/sh
# side-a-island
[ -e MAIL/"${CLAUDE_PID:-$PPID}".json ] || exit 0
[ -x PYTHON ] || exit 0
[ -f SCRIPT ] || exit 0
exec PYTHON -I -S SCRIPT SOCKET "$@"
"""


# Codex runs a turn's hooks in whatever process runs the turn, so its mail goes by thread id; a look at the folder
# is all a tool call costs while none waits.
ISLAND_CODEX_MAIL_LAUNCHER = """#!/bin/sh
# side-a-island
for mail in MAIL/codex/*.json; do break; done
[ -e "$mail" ] || exit 0
[ -x PYTHON ] || exit 0
[ -f SCRIPT ] || exit 0
exec PYTHON -I -S SCRIPT SOCKET "$@"
"""


def island_socket(root):
    return root / "runtime" / "island.sock"


def island_launcher(root):
    return root / "runtime" / "island-hook.sh"


def island_mail(root):
    return root / "runtime" / "mail"


def island_mail_launcher(root, agent="claude"):
    return root / "runtime" / ("island-codex-mail.sh" if agent == "codex" else "island-mail.sh")


def island_command(root, agent, launcher=None):
    # The command never names Python or a version, so Codex keeps trusting it across updates.
    return f"/bin/sh {shlex.quote(str(launcher or island_launcher(root)))} {agent} # {ISLAND_MARK}"


def codex_hooks_path():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "hooks.json"


def island_settings(agent):
    return Path.home() / ".claude" / "settings.json" if agent == "claude" else codex_hooks_path()


def write_island_launcher(root):
    runtime = root / "runtime"
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    script = runtime / "island_hook.py"
    script.write_text(Path(__file__).with_name("island_hook.py").read_text())
    island_mail(root).mkdir(exist_ok=True, mode=0o700)
    for template, path in ((ISLAND_LAUNCHER, island_launcher(root)), (ISLAND_MAIL_LAUNCHER, island_mail_launcher(root)),
                           (ISLAND_CODEX_MAIL_LAUNCHER, island_mail_launcher(root, "codex"))):
        launcher = template.replace("PYTHON", shlex.quote(sys.executable)).replace("SCRIPT", shlex.quote(str(script)))
        path.write_text(launcher.replace("SOCKET", shlex.quote(str(island_socket(root)))).replace("MAIL", shlex.quote(str(island_mail(root)))))


# Claude Code added PostModelSwitch in 2.1.251; an older one might reject a settings file naming it.
MODEL_SWITCH_SINCE = (2, 1, 251)


@functools.lru_cache(maxsize=None)
def claude_versions():
    """The version of every claude this Mac has where Side A looks, None for one that wouldn't say. The native
    installer links claude to versions/<version>, so most are read without starting one."""
    found = []
    for path in [Path.home() / ".local/bin/claude", Path.home() / ".npm-global/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude")]:
        if not (path.is_file() and os.access(path, os.X_OK)):
            continue
        real = path.resolve()
        text = real.name if real.parent.name == "versions" else ""
        if not re.fullmatch(r"\d+\.\d+\.\d+", text):
            with contextlib.suppress(OSError, subprocess.TimeoutExpired):
                text = subprocess.run([str(path), "--version"], capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL).stdout
        match = re.search(r"\b(\d+)\.(\d+)\.(\d+)\b", text)
        found.append(tuple(int(part) for part in match.groups()) if match else None)
    return found


def model_switch_hook():
    """PostModelSwitch is installed only when every claude found is known to have it."""
    versions = claude_versions()
    return bool(versions) and all(version is not None and version >= MODEL_SWITCH_SINCE for version in versions)


def set_island(root, agent, enabled):
    """Opt-in PermissionRequest hook for Claude Code (~/.claude/settings.json) or Codex (~/.codex/hooks.json)."""
    with selection_lock(root, "settings.lock"):
        if enabled:
            write_island_launcher(root)
        path = island_settings(agent)
        settings = read_json(path, {}) or {}
        if not isinstance(settings, dict):
            raise ValueError(f"{path} isn't a settings object; Side A left it unchanged.")
        hooks = settings.setdefault("hooks", {})
        # Claude's Stop hook waits in the background for a follow-up (asyncRewake wakes the idle session);
        # Codex has no background hooks, so its Stop hook only says the session is done.
        stop = {"asyncRewake": True, "timeout": ISLAND_FOLLOW_UP} if agent == "claude" else {"timeout": 5}
        command = island_command(root, agent)
        events = [("PermissionRequest", command, {"timeout": ISLAND_TIMEOUT, "statusMessage": "Waiting for your answer in Side A"}),
                  ("Stop", command, stop)]
        # Notes and stops sent to a working session from Side A. Codex runs a new handler only once the user trusts it.
        mail = island_command(root, agent, island_mail_launcher(root, agent))
        events += [(event, mail, {"timeout": 5}) for event in mail_events(agent)]
        if agent == "claude":
            # A model changed with /model shows on the session's row now, not at its next reply.
            events.append(("PostModelSwitch", command, {"timeout": 30}) if enabled and model_switch_hook() else ("PostModelSwitch", None, {}))
        for event, command, handler in events:
            # Only Side A's own handlers go; a group the user shares with them keeps the rest.
            groups = []
            for group in hooks.get(event, []):
                if not isinstance(group, dict):
                    groups.append(group)
                    continue
                handlers = group.get("hooks", [])
                kept = [h for h in handlers if not (isinstance(h, dict) and ISLAND_MARK in str(h.get("command", "")))]
                if kept or not handlers:
                    groups.append({**group, "hooks": kept} if len(kept) != len(handlers) else group)
            if enabled and command:
                group = {"hooks": [{"type": "command", "command": command, **handler}]}
                groups.append(group if event in ("Stop", "PostModelSwitch") else {"matcher": "*", **group})
            if groups:
                hooks[event] = groups
            else:
                hooks.pop(event, None)
        if not hooks:
            settings.pop("hooks")
        if agent == "claude":
            write_settings(settings)
        elif enabled or path.exists():
            write_json_file(path, settings)


def write_json_file(path, value):
    """Like write_settings, for any JSON file the user owns: keeps its mode and a symlink."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.resolve()
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, prefix=".side-a-") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    if path.exists():
        os.chmod(stream.name, path.stat().st_mode & 0o777)
    os.replace(stream.name, path)


def mail_events(agent):
    """Where the mail hook runs: before a tool (a stop) and after one (a note). Codex has no PostToolUseFailure."""
    return ("PreToolUse", "PostToolUse", "PostToolUseFailure") if agent == "claude" else ("PreToolUse", "PostToolUse")


def island_current(agent):
    """Installed with every hook this version adds, so an update only rewrites settings when one is missing."""
    try:
        settings = read_json(island_settings(agent), {}) or {}
    except ValueError:
        return True
    if not isinstance(settings, dict):
        return True
    marked = lambda event: any(ISLAND_MARK in str(h.get("command", "")) for g in (settings.get("hooks") or {}).get(event, [])
                               for h in g.get("hooks", []))
    events = ("PermissionRequest", "Stop") + mail_events(agent)
    # PostModelSwitch comes with a Claude Code that has it and goes if that Claude Code is replaced by an older one.
    return all(marked(event) for event in events) and (agent != "claude" or marked("PostModelSwitch") == model_switch_hook())


def island_installed(agent):
    try:
        settings = read_json(island_settings(agent), {}) or {}
    except ValueError:
        return False
    groups = (settings.get("hooks") or {}).get("PermissionRequest", []) if isinstance(settings, dict) else []
    return any(ISLAND_MARK in str(h.get("command", "")) for g in groups for h in g.get("hooks", []))


def set_inbox(root, enabled):
    """Claude Code's SessionStart and Stop handlers that wait for runtime/inbox/<pid>.json (island_hook.inbox)."""
    with selection_lock(root, "settings.lock"):
        if enabled:
            write_island_launcher(root)
            (root / "runtime" / "inbox").mkdir(exist_ok=True, mode=0o700)
        settings = read_json(island_settings("claude"), {}) or {}
        if not isinstance(settings, dict):
            raise ValueError(f"{island_settings('claude')} isn't a settings object; Side A left it unchanged.")
        hooks = settings.setdefault("hooks", {})
        command = f"/bin/sh {shlex.quote(str(island_launcher(root)))} claude inbox # {INBOX_MARK}"
        for event in ("SessionStart", "Stop"):
            groups = []
            for group in hooks.get(event, []):
                handlers = group.get("hooks", []) if isinstance(group, dict) else None
                if handlers is None:
                    groups.append(group)
                    continue
                kept = [h for h in handlers if not (isinstance(h, dict) and INBOX_MARK in str(h.get("command", "")))]
                if kept or not handlers:
                    groups.append({**group, "hooks": kept} if len(kept) != len(handlers) else group)
            if enabled:
                groups.append({"hooks": [{"type": "command", "command": command, "asyncRewake": True, "timeout": INBOX_TIMEOUT}]})
            if groups:
                hooks[event] = groups
            else:
                hooks.pop(event, None)
        if not hooks:
            settings.pop("hooks")
        write_settings(settings)


def inbox_installed():
    try:
        settings = read_json(island_settings("claude"), {}) or {}
    except ValueError:
        return False
    groups = (settings.get("hooks") or {}).get("SessionStart", []) if isinstance(settings, dict) else []
    return any(INBOX_MARK in str(h.get("command", "")) for g in groups if isinstance(g, dict) for h in g.get("hooks", []) if isinstance(h, dict))


def island_state(root, agents, state):
    """Turns the hook on or off, or with "sync" rewrites the launcher so it follows Python and app updates."""
    for agent in agents:
        if state == "sync":
            if island_installed(agent):
                write_island_launcher(root)
                if not island_current(agent):
                    set_island(root, agent, True)
        elif state != "status":
            set_island(root, agent, state == "on")
            # The inbox runs through the island's launcher, so it goes with it.
            if agent == "claude" and state == "off" and inbox_installed():
                set_inbox(root, False)
    return {agent: island_installed(agent) for agent in ISLAND_AGENTS}


def run_sessions(root, args):
    import sessions
    if args.action == "index":
        result = sessions.index(root, args.seconds, args.path)
    elif args.action == "recent":
        result = sessions.recent(root, args.agent, args.project, args.days, args.automated, limit=args.limit or 300, pinned=args.pin or (),
                                 only=args.only if args.only is not None or not args.only_none else [])
    elif args.action == "search":
        result = sessions.search(root, args.text, args.agent, args.project, args.days, args.automated)
    elif args.action == "show" and args.format == "remote":
        result = sessions.page(root, args.text, args.limit, args.before, args.after, args.around, args.agent_id)
    elif args.action == "show":
        result = sessions.show(root, args.text, args.limit or 4000, args.around)
    elif args.action == "message":
        if args.seq is None or not args.generation:
            raise ValueError("message needs --seq and --generation")
        result = sessions.message(root, args.text, args.seq, args.generation, args.agent_id)
    elif args.action == "image":
        result = sessions.image(root, args.text, args.recheck)
    elif args.action == "images":
        result = sessions.images(root, args.text, min(args.limit or 200, 1000), float(args.before) if args.before else None)
    elif args.action == "turn-diff":
        result = sessions.turn_diff(root, args.text, args.turn)
    elif args.action == "rename":
        result = sessions.rename_live(args.text, args.name)
    else:
        result = sessions.live(root)
    return result


def serve_sessions(root, parser):
    """Answers one JSON request per stdin line, so the viewer skips starting Python for every keystroke
    and reopening a conversation reuses its parsed transcript. Indexing stays in its own process."""
    import sqlite3
    for line in sys.stdin:
        # A line that isn't JSON must not answer with the request before it.
        request = None
        try:
            request = json.loads(line)
            # Python 3.9 gives `text` an empty value at the first option, leaving `show --limit 1 -- <id>`
            # unrecognized; intermixed parsing reads the options first in every version.
            args = parser.parse_intermixed_args(request["args"])
            if args.action in ("index", "serve"):
                raise ValueError("Not available here")
            reply = {"id": request["id"], "result": run_sessions(root, args)}
        except SystemExit:
            reply = {"id": request.get("id") if isinstance(request, dict) else None, "error": "Invalid request"}
        except (ValueError, KeyError, TypeError, OSError, sqlite3.Error) as error:
            reply = {"id": request.get("id") if isinstance(request, dict) else None, "error": str(error)}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["login", "status", "logout", "usage", "activate", "adopt", "prime", "renew", "forget"]:
        commands.add_parser(name).add_argument("account")
    pool_command = commands.add_parser("pool-token")
    pool_command.add_argument("account")
    pool_command.add_argument("--refused")
    codex_pool_command = commands.add_parser("codex-pool-token")
    codex_pool_command.add_argument("account")
    codex_pool_command.add_argument("--refused")
    codex_home_command = commands.add_parser("codex-pool-home")
    codex_home_command.add_argument("--url")
    codex_home_command.add_argument("--remote", action="store_true")
    swap_command = commands.add_parser("swap")
    swap_command.add_argument("slot")
    swap_command.add_argument("account")
    swap_command.add_argument("--share", action="store_true")
    commands.add_parser("active")
    commands.add_parser("report").add_argument("--sync", type=Path)
    commands.add_parser("hook").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("shell").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("host-terminal").add_argument("state", choices=["on", "off", "status"])
    hosting_command = commands.add_parser("hosting")
    hosting_command.add_argument("action", choices=["install", "codex-env"])
    hosting_command.add_argument("account", nargs="?")
    hosting_command.add_argument("--bundled")
    commands.add_parser("live").add_argument("state", choices=["on", "off", "status"])
    island_command_parser = commands.add_parser("island")
    island_command_parser.add_argument("state", choices=["on", "off", "status", "sync", "trust"])
    island_command_parser.add_argument("--agent", choices=ISLAND_AGENTS, action="append")
    inbox_parser = commands.add_parser("inbox")
    inbox_parser.add_argument("state", choices=["on", "off", "status"])
    sessions_command = commands.add_parser("sessions")
    sessions_command.add_argument("action", choices=["index", "recent", "search", "show", "live", "serve", "message", "image", "images", "turn-diff", "rename"])
    sessions_command.add_argument("text", nargs="?", default="")
    sessions_command.add_argument("--agent", choices=["claude", "codex"])
    sessions_command.add_argument("--project")
    sessions_command.add_argument("--days", type=float)
    sessions_command.add_argument("--seconds", type=float, default=20)
    sessions_command.add_argument("--automated", action="store_true")
    sessions_command.add_argument("--path", action="append")
    sessions_command.add_argument("--pin", action="append")
    sessions_command.add_argument("--limit", type=int)
    sessions_command.add_argument("--around")
    sessions_command.add_argument("--format", choices=["default", "remote"], default="default")
    sessions_command.add_argument("--before")
    sessions_command.add_argument("--after")
    sessions_command.add_argument("--seq", type=int)
    sessions_command.add_argument("--generation")
    sessions_command.add_argument("--agent-id")
    sessions_command.add_argument("--recheck", action="store_true")
    sessions_command.add_argument("--turn")
    sessions_command.add_argument("--only", action="append")
    sessions_command.add_argument("--only-none", action="store_true")
    sessions_command.add_argument("--name")
    commands.add_parser("setup").add_argument("action", choices=["overview", "mcp-health"])
    cleanup_command = commands.add_parser("cleanup")
    cleanup_command.add_argument("action", choices=["disk", "archive", "restore", "worktrees", "remove-worktree"])
    cleanup_command.add_argument("path", nargs="?")
    cleanup_command.add_argument("--days", type=float, default=90)
    cleanup_command.add_argument("--keep", action="append", default=[])
    parser.sessions = sessions_command
    return parser


def main():
    # The app's watchdog sends SIGTERM; exiting normally runs the finally blocks that release
    # Claude Code's refresh lock, instead of leaving every session on that login waiting a minute.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    # Own process group, so the app's watchdog can stop any claude or codex child with us.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    parser = build_parser()
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    os.umask(0o077)
    if args.command == "report":
        print(json.dumps(report(root, sync=args.sync)))
        return
    if args.command == "hook":
        if args.state != "status":
            set_limit_hook(root, args.state == "on")
        print(json.dumps({"installed": limit_hook_installed()}))
        return
    if args.command == "live":
        if args.state != "status":
            set_live(root, args.state == "on")
        print(json.dumps({"installed": live_installed()}))
        return
    if args.command == "island":
        if args.state == "trust":
            # Codex runs a hook only once the user trusts it: whether the mail hooks are, for the line notes show.
            import codex_bridge
            trust = codex_bridge.mail_hooks_trust(root, codex_hooks_path().parent) if island_installed("codex") else "off"
            print(json.dumps({"codexMail": trust}))
            return
        print(json.dumps(island_state(root, args.agent or ISLAND_AGENTS, args.state)))
        return
    if args.command == "inbox":
        if args.state != "status":
            set_inbox(root, args.state == "on")
        print(json.dumps({"inbox": inbox_installed()}))
        return
    if args.command == "shell":
        if args.state != "status":
            set_shell(root, args.state == "on")
        print(json.dumps({"installed": shell_installed(root)}))
        return
    if args.command == "host-terminal":
        if args.state != "status":
            set_host_terminal(root, args.state == "on")
        print(json.dumps({"installed": host_terminal_installed(root)}))
        return
    if args.command == "hosting" and args.action == "install":
        import hosting
        print(json.dumps(hosting.install(root, args.bundled)))
        return
    if args.command == "setup":
        import setup
        print(json.dumps(setup.overview(root) if args.action == "overview" else setup.mcp_health()))
        return
    if args.command == "cleanup":
        import cleanup
        if args.action == "disk":
            result = cleanup.disk(root, args.days, args.keep)
        elif args.action == "archive":
            result = cleanup.archive(root, args.days, args.keep)
        elif args.action == "restore":
            result = cleanup.restore(root)
        elif args.action == "worktrees":
            result = cleanup.worktrees(root)
        elif args.path:
            result = cleanup.remove_worktree(args.path)
        else:
            raise ValueError("Name the worktree to remove.")
        print(json.dumps(result))
        return
    if args.command == "sessions" and args.action == "serve":
        serve_sessions(root, parser.sessions)
        return
    if args.command == "sessions":
        import sqlite3
        try:
            result = run_sessions(root, args)
        except sqlite3.Error as error:
            raise ValueError(f"Session search is unavailable: {error}. It needs SQLite 3.34 or later.") from None
        print(json.dumps(result))
        return
    if args.command == "codex-pool-home":
        import codex_bridge
        print(json.dumps({"home": codex_bridge.sync_pool_home(root, args.url, args.remote)}))
        return
    config = read_json(root / "config.json")
    # A trade interrupted by a crash is completed before any login is read or written.
    if read_secret(SWAP_JOURNAL):
        read_secret.cache_clear()
        with selection_lock(root), selection_lock(root, "renew.lock"):
            finish_swap(root)
    if args.command == "active":
        import codex_bridge
        try:
            healed = heal_trades(root, config)
        except (ValueError, OSError, KeyError, subprocess.TimeoutExpired):
            healed = []  # never at the cost of Autopilot's view of the logins; retried next tick
        with contextlib.suppress(ValueError, OSError, KeyError, subprocess.TimeoutExpired):
            healed += rehome(root, config)
        with contextlib.suppress(ValueError, OSError):
            codex_bridge.refresh_pool_homes(root)
        mac = mac_email(root)
        processes = slot_processes(root, config)
        print(json.dumps({"healed": healed, "busyProblem": listing_problem if processes is None else None, "accountID": (repair_selection(root, config) or {}).get("id"),
                          "email": "" if account_for_email(config, mac) else mac,
                          "codexAccountID": (codex_bridge.global_account(config) or {}).get("id"),
                          "codexEmail": codex_bridge.global_email(), "claudeModel": recent_model(),
                          "logins": login_stamps(root, config), "loginEnds": login_ends(root, config),
                          "live": live_limits(root, config), "busy": busy_logins(root, config, processes),
                          "limits": limit_errors(root, config, processes), "models": slot_models(processes), "quiet": slot_quiet(processes)}))
        return
    if args.command == "swap":
        swap(root, config, args.slot, account_by_id(config, args.account), share=args.share)
        return
    if args.command == "hosting":
        # A hosted Codex session on a picked account: the same home and flags Side A runs it with.
        import codex_bridge
        account = account_by_id(config, args.account)
        if provider_of(account) != "codex":
            raise ValueError("Pick a Codex account.")
        codex_bridge.owned(root, account)
        command, env = codex_bridge.invocation(root, account)
        print(json.dumps({"args": command[1:], "env": {"CODEX_HOME": env["CODEX_HOME"]}}))
        return
    account = account_by_id(config, args.account)
    if args.command == "usage":
        print(json.dumps(usage(root, config, account)))
    elif args.command == "activate":
        activate(root, config, account)
    elif args.command == "adopt":
        print(json.dumps(adopt(root, account)))
    elif args.command == "renew":
        renew(root, config, account)
    elif args.command == "pool-token":
        print(json.dumps(pool_token(root, config, account, refused=args.refused)))
    elif args.command == "codex-pool-token":
        import codex_bridge
        if provider_of(account) != "codex":
            raise ValueError("Pick a Codex account.")
        print(json.dumps(codex_bridge.pool_token(root, account, refused=args.refused)))
    elif args.command == "forget":
        forget_backup(account)
    elif args.command == "prime":
        prime(root, config, account)
    elif provider_of(account) == "codex":
        import codex_bridge
        if args.command == "status":
            print(json.dumps(codex_bridge.account_status(root, account)))
        else:
            sys.exit(subprocess.call(codex_bridge.command(root) + [args.command],
                env=codex_bridge.environment(root, account), cwd=root, stdin=subprocess.DEVNULL))
    elif args.command == "status":
        print(json.dumps(auth_status(root, account)))
    else:
        command = [claude_binary(), "auth", args.command]
        if args.command == "login":
            command.append("--claudeai")
            if account.get("email"):
                command += ["--email", account["email"]]
        if args.command == "logout":
            forget_backup(account)
        with contextlib.suppress(ValueError, OSError, KeyError, subprocess.TimeoutExpired):
            rehome(root, config)
        env = clean_environment(prepare_profile(root, account["id"]))
        # Into the account's own slot: its profile may hold another account's login after a swap.
        # The slot is marked under selection.lock, so no trade moves a login into it meanwhile.
        with selection_lock(root):
            slot = sign_in_slot(root, config, account)
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = slot_selector(root, slot)
            signing_in_path(root, slot).write_text(str(os.getpid()))
        try:
            code = subprocess.call(command, env=env, cwd=root, stdin=subprocess.DEVNULL)
        finally:
            signing_in_path(root, slot).unlink(missing_ok=True)
        sys.exit(code)


def failure_line(error):
    """What the app reads on stderr; a bracketed code is what it acts on, so an account's name never decides."""
    code = getattr(error, "code", None)
    return f"Side A[{code}]: {error}" if isinstance(code, str) else f"Side A: {error}"


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, StopIteration, OSError, subprocess.TimeoutExpired) as error:
        print(failure_line(error), file=sys.stderr)
        sys.exit(1)
