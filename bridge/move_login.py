"""A login that goes to another computer with a session (docs/moving-sessions-prd.md, section 4.9).

A login lives on one computer at a time. Both CLIs replace the refresh token when they renew, so a
copy left in use behind a moved session would sign one of the two computers out. The sender
therefore takes the login out of its slot before it is sent (`hold`), and either deletes that copy
on the receiver's word that it has it (`release`) or puts it back (`restore`). The Mac's own login,
which every terminal on it uses, never leaves.
"""
from __future__ import annotations
import contextlib
import json
import os
from pathlib import Path
import subprocess

import codex_bridge
import sidea_bridge as common

HELD = "Side A login held"


class Refused(ValueError):
    """Why a login stays where it is, as a sentence for the person moving the session."""


def held_service(account):
    return f"{HELD} {account['id']}"


def find(root, identifier):
    config = common.read_json(root / "config.json", {}) or {}
    account = next((a for a in config.get("accounts", []) if a.get("id") == identifier), None)
    if account is None:
        raise Refused("That account isn't on this computer.")
    return config, account


def is_codex(account):
    return common.provider_of(account) == "codex"


def codex_file(root, account):
    return codex_bridge.prepare_profile(root, account["id"]) / "auth.json"


def held_file(root, account):
    return root / "runtime" / "moves" / "logins" / f"{account['id']}.json"


def delete_item(service):
    subprocess.run(["security", "delete-generic-password", "-a", common.keychain_user(), "-s", service],
                   capture_output=True, timeout=15, check=False)
    common.read_secret.cache_clear()


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".part")
    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as handle:
        json.dump(value, handle)
    temporary.replace(path)


def can(root, identifier):
    """Whether this account's login may leave with a session."""
    _, account = find(root, identifier)
    if is_codex(account):
        if codex_bridge.is_mac_login(account):
            return {"can": False, "why": f"{account['name']} is this computer's own Codex login."}
        ready = codex_bridge.login_email(codex_bridge.read_auth(codex_file(root, account).parent)) == account.get("email", "").casefold()
        return {"can": ready, "why": "" if ready else f"{account['name']} isn't signed in here."}
    if common.home_slot(root, account) == "mac":
        return {"can": False, "why": f"{account['name']} is this computer's own Claude Code login."}
    return {"can": True, "why": ""}


def hold(root, identifier):
    """Takes the login out of use here and returns it for sending. Until `release` or `restore` it sits where
    no session and no renewal reads it."""
    _, account = find(root, identifier)
    verdict = can(root, identifier)
    if not verdict["can"]:
        raise Refused(verdict["why"])
    if is_codex(account):
        path = codex_file(root, account)
        login = codex_bridge.read_auth(path.parent)
        if not login:
            raise Refused(f"{account['name']} isn't signed in here.")
        write_private(held_file(root, account), login)
        path.unlink(missing_ok=True)
    else:
        service = common.home_service(root, account)
        # Claude Code's own lock, so no session on this login renews it between the read and the delete.
        folder = common.slot_selector(root, common.home_slot(root, account))
        with common.selection_lock(root), common.claude_refresh_lock(Path(folder)):
            common.read_secret.cache_clear()
            login = common.owned_login(root, account, idle_ok=True)
            common.write_secret(held_service(account), login)
            delete_item(service)
            # A backup would be put back into the empty slot by the next repair.
            common.forget_backup(account)
    return {"provider": common.provider_of(account), "email": account.get("email", ""), "name": account["name"], "login": login}


def held(root, account):
    if is_codex(account):
        return common.read_json(held_file(root, account), None) if held_file(root, account).exists() else None
    common.read_secret.cache_clear()
    return common.read_secret(held_service(account))


def forget_held(root, account):
    if is_codex(account):
        held_file(root, account).unlink(missing_ok=True)
    else:
        delete_item(held_service(account))


def release(root, identifier):
    """The other computer holds the login: the copy kept aside here is deleted."""
    _, account = find(root, identifier)
    forget_held(root, account)
    return {"released": True}


def restore(root, identifier):
    """The login did not leave after all: it goes back into its slot."""
    _, account = find(root, identifier)
    login = held(root, account)
    if not login:
        return {"restored": False}
    store(root, account, login)
    forget_held(root, account)
    return {"restored": True}


def store(root, account, login):
    if is_codex(account):
        if codex_bridge.login_email(login) != account.get("email", "").casefold():
            raise Refused("That login belongs to another account.")
        write_private(codex_file(root, account), login)
        return
    if not isinstance(login, dict) or "claudeAiOauth" not in login:
        raise Refused("That isn't a Claude Code login.")
    common.prepare_profile(root, account["id"])
    slot = common.home_slot(root, account)
    if slot == "mac":
        raise Refused(f"{account['name']} is this computer's own Claude Code login.")
    with common.selection_lock(root):
        common.write_secret(common.slot_service(root, slot), login)


def confirm_owner(root, account, login):
    """A Claude login that arrives is taken only when the profile endpoint says it is the account's: the label the
    sender put on it is not proof. An answer that can't be had (offline, or a login whose access token has expired)
    is not a yes either, so nothing is stored and the sender keeps its copy."""
    if not isinstance(login, dict) or "claudeAiOauth" not in login:
        raise Refused("That isn't a Claude Code login.")
    owner = common.token_email(root, login)
    if not owner:
        raise Refused(f"Side A couldn't confirm that the login that came is {account['name']}'s, so it wasn't stored.")
    if owner != account.get("email", "").casefold():
        raise Refused("That login belongs to another account.")


def receive(root, identifier, login):
    """Stores a login that arrived with a session into the account's slot on this computer."""
    config, account = find(root, identifier)
    if not is_codex(account):
        confirm_owner(root, account, login)
    store(root, account, login)
    with contextlib.suppress(ValueError, OSError, subprocess.TimeoutExpired):
        if not is_codex(account):
            common.write_pins(root, config)
    return {"stored": True}


def remove(root, identifier):
    """Deletes a login that arrived with a move that then did not start, so it exists only where it came from."""
    _, account = find(root, identifier)
    if is_codex(account):
        if not codex_bridge.is_mac_login(account):
            codex_file(root, account).unlink(missing_ok=True)
    elif common.home_slot(root, account) != "mac":
        # Never this computer's own login, whatever account the request names.
        delete_item(common.home_service(root, account))
        common.forget_backup(account)
    return {"removed": True}


def run(request):
    root = Path(request["root"])
    action, account = request["action"], request.get("account", "")
    try:
        if action == "login-can":
            return can(root, account)
        if action == "login-hold":
            return hold(root, account)
        if action == "login-release":
            return release(root, account)
        if action == "login-restore":
            return restore(root, account)
        if action == "login-receive":
            return receive(root, account, request["login"])
        if action == "login-remove":
            return remove(root, account)
    except (Refused, common.SignInAgain, common.Unconfirmed, common.KeychainBusy) as error:
        return {"refused": str(error)}
    except (subprocess.TimeoutExpired, OSError, KeyError) as error:
        return {"refused": f"The login could not be handed over: {error}"}
    raise ValueError(f"Unknown move action: {action}")
