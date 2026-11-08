"""Codex adapter: CLI-owned credentials, read through the app-server protocol.

Rate limits come from official RPCs. Side A reads a login's id_token to name its account and,
for pool mode, its access token; no login is ever copied or written, and Codex does its own renewing.
"""
from __future__ import annotations
import base64
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time

MAX_MESSAGE = 32 * 1024 * 1024


class SignInAgain(ValueError):
    code = "signin"


class RateLimited(ValueError):
    code = "rate-limited"


class RPC:
    """Short-lived stdio client used only for identity and saved-thread checks."""
    def __init__(self, command, env, cwd):
        self.process = subprocess.Popen(command, env=env, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buffer = b""
        self.sequence = 0
        self.deadline = time.monotonic() + 25
        try:
            self.call("initialize", {"clientInfo": {"name": "side_a", "version": "0.3.0"}})
            self.send({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def call(self, method, params=None):
        self.sequence += 1
        identifier = self.sequence
        self.send({"id": identifier, "method": method, "params": params or {}})
        while time.monotonic() < self.deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                response = json.loads(line)
                if response.get("id") == identifier and "method" not in response:
                    if "error" in response:
                        message = str((response.get("error") or {}).get("message") or "")
                        # Keep only what the app acts on: revoked logins need sign-in, rate limits back off.
                        # Revocation first: its message also says "failed to fetch codex rate limits".
                        if "401" in message or "token_revoked" in message:
                            raise SignInAgain("Sign in again: Codex rejected this login.")
                        if "429" in message or "too many requests" in message.lower():
                            raise RateLimited("Codex usage is rate-limited (429).")
                        raise ValueError("Codex could not complete the account check. Update Codex and retry.")
                    return response["result"]
            if select.select([self.process.stdout], [], [], .1)[0]:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    break
                self.buffer += data
                if len(self.buffer) > MAX_MESSAGE:
                    break
        raise ValueError("Codex did not respond to the account or conversation check.")

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            # EOF lets app-server flush conversation state before termination.
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            raise ValueError("Codex did not shut down gracefully.") from None
        finally:
            if self.process.stdout:
                self.process.stdout.close()

    def __enter__(self): return self
    def __exit__(self, *_): self.close()



def codex_binary():
    for path in [Path.home()/".local/bin/codex", Path.home()/".npm-global/bin/codex", Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")]:
        if path.is_file() and os.access(path, os.X_OK): return str(path)
    raise ValueError("Install Codex CLI first: https://developers.openai.com/codex/cli")


def prepare_profile(root, identifier):
    import sidea_bridge as common
    profile = common.profile_dir(root, identifier)
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(profile, 0o700)
    shared = root / "codex-conversations"
    shared.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Current Codex keeps its history index in sqlite_home, rollout bodies in
    # sessions, and writer coordination in thread-writer-locks. Auth stays private.
    for name in ("sessions", "archived_sessions", "thread-writer-locks"):
        target, link = shared / name, profile / name
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
        if link.is_symlink():
            if link.resolve() != target.resolve():
                raise ValueError("Unexpected Codex conversation directory. Profile left untouched.")
        elif link.exists():
            raise ValueError("An independent Codex conversation directory exists. Profile left untouched.")
        else:
            link.symlink_to(target, target_is_directory=True)
    return profile


def command(root, binary=None):
    return [binary or codex_binary(), "-c", 'cli_auth_credentials_store="file"',
            "-c", 'forced_login_method="chatgpt"', "-c", 'model_provider="openai"',
            "-c", "sqlite_home=" + json.dumps(str(root / "codex-conversations"))]


def environment(root, account):
    import sidea_bridge as common
    env = common.clean_environment(prepare_profile(root, account["id"]))
    env["CODEX_HOME"] = env.pop("CLAUDE_CONFIG_DIR")
    return env


def is_mac_login(account):
    return bool(account.get("email")) and global_email() == account["email"].casefold()


def invocation(root, account, binary=None):
    """Command and environment for the account's one home: ~/.codex for the Mac's own
    Codex login (run as the user normally would), its profile otherwise."""
    env = environment(root, account)
    if is_mac_login(account):
        env["CODEX_HOME"] = str(global_home())
        return [binary or codex_binary()], env
    return command(root, binary), env


def owned(root, account):
    """Refuses a profile holding another account's login, e.g. a copy left by Side A 0.4."""
    if is_mac_login(account):
        return
    email = login_email(read_auth(prepare_profile(root, account["id"])))
    if email != account.get("email", "").casefold():
        raise SignInAgain(f"Sign in to {account['name']} again; its saved login belongs to another account."
                         if email else f"Sign in to {account['name']} again.")


def account_status(root, account, binary=None):
    base, env = invocation(root, account, binary)
    with RPC(base + ["app-server"], env, root) as rpc:
        data = rpc.call("account/read", {"refreshToken": False})
    identity = data.get("account") or {}
    email = identity.get("email")
    method = identity.get("type", "")
    return {"loggedIn": method == "chatgpt" and isinstance(email, str) and bool(email.strip()),
            "email": email if isinstance(email, str) else "", "authMethod": method}


def global_home():
    return Path.home() / ".codex"


def mail_hooks_trust(root, home):
    """Whether Codex runs the island's mail hooks in `home`, as its own hooks/list says: "trusted", "review" while the user
    hasn't trusted one (new or changed), or "unknown" when Codex couldn't say. It only reads; trust is the user's to give."""
    try:
        with RPC([codex_binary(), "app-server"], {**os.environ, "CODEX_HOME": str(home)}, root) as rpc:
            data = rpc.call("hooks/list", {"cwds": [str(Path.home())]})
    except (OSError, ValueError):
        return "unknown"
    statuses = [hook.get("trustStatus") for entry in data.get("data") or [] for hook in entry.get("hooks") or []
                if "island-codex-mail.sh" in str(hook.get("command", ""))]
    if not statuses:
        return "unknown"
    return "trusted" if all(status in ("trusted", "managed") for status in statuses) else "review"


def login_email(auth):
    # The email claim of the id_token payload; the signature is irrelevant for matching.
    token = ((auth or {}).get("tokens") or {}).get("id_token") or ""
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return ""
    return (claims.get("email") or "").casefold()


def global_email():
    return login_email(read_auth(global_home()))


def read_auth(home):
    try:
        return json.loads((home / "auth.json").read_text())
    except (FileNotFoundError, ValueError):
        return None



def global_account(config):
    email = global_email()
    return next((a for a in config.get("accounts", []) if a.get("provider") == "codex"
                 and email and a.get("email", "").casefold() == email), None)


def adopt(root, account):
    """Record the Mac's own Codex login as an account. Its login stays in ~/.codex."""
    email = global_email()
    if not email:
        raise ValueError("No Codex login was found on this Mac.")
    prepare_profile(root, account["id"])
    return {"email": email}


def usage(root, account):
    import sidea_bridge as common
    owned(root, account)
    base, env = invocation(root, account)
    with RPC(base + ["app-server"], env, root) as rpc:
        data = rpc.call("account/rateLimits/read")
    limits = data.get("rateLimits") or {}
    windows = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        if not window:
            continue
        minutes = window.get("windowDurationMins") or 0
        if minutes <= 0:
            continue
        label = "5-hour" if minutes == 300 else "Weekly" if minutes == 10080 else f"{minutes // 60}-hour"
        windows.append({"id": "five_hour" if minutes == 300 else "seven_day" if minutes == 10080 else key,
                        "label": label, "percent": common.percent(window.get("usedPercent")),
                        "resetsAt": common.epoch(window.get("resetsAt"))})
    return {"windows": windows, "stale": False}


def prime(root, account):
    owned(root, account)
    base, env = invocation(root, account)
    result = subprocess.run(base + ["exec", "--skip-git-repo-check", "-s", "read-only", "Reply with OK."],
        env=env, cwd=root, capture_output=True, timeout=180, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ValueError(f"{account['name']} could not start its 5-hour window.")


def token_claims(token):
    try:
        payload = (token or "").split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}


def token_hash(token):
    import hashlib
    return hashlib.sha256((token or "").encode()).hexdigest()[:16]


def pool_token(root, account, refused=None, binary=None):
    """The access token and workspace Side A's pool sends for a Codex account. The login stays in the
    account's own CODEX_HOME: when it is due, Codex itself renews it there (account/read with
    refreshToken), so Side A never writes a login or holds a second copy of its refresh token."""
    owned(root, account)
    base, env = invocation(root, account, binary)
    home = Path(env["CODEX_HOME"])

    def current():
        tokens = (read_auth(home) or {}).get("tokens") or {}
        return tokens.get("access_token") or "", tokens.get("account_id") or ""

    token, workspace = current()
    due = lambda value: token_claims(value).get("exp", 0) - time.time() < 300 or (refused is not None and token_hash(value) == refused)
    # The desktop app holds its own copy of the Mac's login and OpenAI revokes a refresh token used twice, so that
    # one is only ever re-read here; Codex itself renews it. A token lasts about ten days.
    if (not token or due(token)) and not is_mac_login(account):
        with RPC(base + ["app-server"], env, root) as rpc:
            rpc.call("account/read", {"refreshToken": True})
        token, workspace = current()
    if not token or token_claims(token).get("exp", 0) <= time.time():
        if is_mac_login(account):
            raise ValueError(f"{account['name']}'s login is due for renewal; open Codex once outside the pool.")
        raise SignInAgain(f"Sign in to {account['name']} again: Codex couldn't renew its login.")
    return {"accessToken": token, "accountId": workspace or None,
            "expiresAt": token_claims(token).get("exp", 0) * 1000, "hash": token_hash(token)}


POOL_STAMP = ".side-a-pool"
# What a session shares with the user's own Codex. Not everything: ~/.codex also holds the desktop app's
# control sockets and locks, and a second process reaching those isn't a plain CLI run any more.
POOL_SHARED = ("sessions", "archived_sessions", "thread-writer-locks", "history.jsonl", "hooks.json", ".hook-trust", "AGENTS.md",
               "agents", "skills", "rules", "prompts", "memories", "plugins", "installation_id", "shell_snapshots", "keybindings.json")


def pool_home(root, remote=False):
    return root / "runtime" / ("codex-pool-remote" if remote else "codex-pool")


def pool_config(source_text, url, sqlite_home):
    """The user's own Codex config with Side A's pool as the model provider. Top-level keys must come
    before the first table, so the provider choice goes first and its table last."""
    # tomllib needs Python 3.11; Side A runs on 3.9 too, where the text is used unchecked.
    try:
        import tomllib
    except ImportError:
        tomllib = None
    lines = source_text.splitlines()
    # The first table header outside a multi-line value; brackets inside strings don't count.
    first_table, depth = len(lines), 0
    for index, line in enumerate(lines):
        bare = re.sub(r"\"[^\"]*\"|'[^']*'|#.*", "", line)
        if depth == 0 and line.lstrip().startswith("["):
            first_table = index
            break
        depth += bare.count("[") - bare.count("]")
    key = lambda line: line.split("=")[0].strip().strip("\"'")
    if tomllib:
        try:
            tomllib.loads(source_text)
        except tomllib.TOMLDecodeError:
            lines, first_table = [], 0
    top = [line for line in lines[:first_table] if key(line) not in ("model_provider", "openai_base_url")]
    # A profile that picks its own provider would leave the pool, in a home with no login to fall back on.
    rest, table = [], ""
    for line in lines[first_table:]:
        if line.lstrip().startswith("["):
            table = line.strip()
        if not (table.startswith("[profiles.") and key(line) == "model_provider"):
            rest.append(line)
    head = ["# Written by Side A for pool mode. Edit ~/.codex/config.toml instead; this copy follows it.",
            'model_provider = "sidea"']
    if not any(key(line) == "sqlite_home" for line in top):
        head.append("sqlite_home = " + json.dumps(str(sqlite_home)))
    provider = ["", "[model_providers.sidea]", 'name = "Side A pool"', "base_url = " + json.dumps(url.rstrip("/") + "/codex"),
                'env_key = "SIDE_A_POOL_KEY"', 'wire_api = "responses"']
    text = "\n".join(head + top + rest + provider) + "\n"
    try:
        if tomllib:
            tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        text = "\n".join(head[:2] + ["sqlite_home = " + json.dumps(str(sqlite_home))] + provider) + "\n"
    return text


def sync_pool_home(root, url=None, remote=False, source=None):
    """A CODEX_HOME for pooled `codex` commands: the user's ~/.codex by symlink (POOL_SHARED), their config plus the pool provider, and no login of its own. Without `url` it is switched off
    by removing its config, which is what the shell checks; anything Codex wrote there stays."""
    source = source or global_home()
    home = pool_home(root, remote)
    config = home / "config.toml"
    if not url:
        config.unlink(missing_ok=True)
        (home / POOL_STAMP).unlink(missing_ok=True)
        return None
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(home, 0o700)
    for name in POOL_SHARED:
        link = home / name
        if (source / name).exists() and not link.exists() and not link.is_symlink():
            link.symlink_to(source / name)
    for link in home.iterdir():
        if link.is_symlink() and (link.name not in POOL_SHARED or not link.exists()):
            link.unlink()
    source_config = source / "config.toml"
    text = pool_config(source_config.read_text() if source_config.is_file() else "", url, source)
    stamp = json.dumps({"url": url, "source": source_config.stat().st_mtime if source_config.is_file() else 0})
    if not config.is_file() or config.read_text() != text:
        temporary = home / ".config.toml.tmp"
        temporary.write_text(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, config)
    (home / POOL_STAMP).write_text(stamp)
    return str(home)


def refresh_pool_homes(root, source=None):
    """Follows edits to ~/.codex/config.toml into pool homes that are on."""
    source = source or global_home()
    for remote in (False, True):
        try:
            stamp = json.loads((pool_home(root, remote) / POOL_STAMP).read_text())
        except (OSError, ValueError):
            continue
        source_config = source / "config.toml"
        if stamp.get("source") != (source_config.stat().st_mtime if source_config.is_file() else 0):
            sync_pool_home(root, stamp.get("url"), remote, source)
