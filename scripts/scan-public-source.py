#!/usr/bin/env python3
"""Refuses a source snapshot holding private keys, tokens, real home paths or real tailnet names.

Prints where and what kind, never the value. Exit 1 when anything is found.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

# Known-answer vectors: keys generated for the protocol tests, never used anywhere real (also in .gitguardian.yaml).
TEST_VECTORS = "Packages/SideAProtocol/Sources/SideAProtocolFixtures/Fixtures/"
MAX_SIZE = 8 << 20

# Made-up people in fixtures, demo data and doc examples. Anything else under /Users is someone's real folder.
FIXTURE_USERS = {
    "you", "demo", "alex", "a", "b", "x", "me", "arne", "name", "test", "user", "username", "someone", "example", "dev", "tester", "me2",
    "shared", "person", "foo", "bob", "alice", "jane", "john", "tmp", "runner", "project", "work", "home", "ci", "admin",
}

PRIVATE_KEY = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:\\n|\s)*[A-Za-z0-9+/=]{40,}")
SECRETS = {
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "AWS key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "Slack token": re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{20,}\b"),
    "Anthropic key": re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),
    "OpenAI key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{32,}\b"),
    "Google key": re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    "Stripe key": re.compile(r"\b[sr]k_live_[A-Za-z0-9]{20,}\b"),
    "PostHog personal key": re.compile(r"\bphx_[A-Za-z0-9]{30,}\b"),
    "npm token": re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"),
    "tailnet name": re.compile(r"\b[a-z0-9-]+\.tail(?!1234\b)[0-9a-f]{4,}\.ts\.net\b"),
}
HOME_PATH = re.compile(r"/(?:Users|home)/([A-Za-z0-9._-]+)")
SECRET_FILES = re.compile(r"(^|/)(\.env|\.env\.local|\.env\.production|\.dev\.vars|id_rsa|id_ed25519|AuthKey_[^/]*|[^/]*\.(p8|p12|pfx|mobileprovision))$")


def own_email():
    try:
        email = subprocess.run(["git", "config", "user.email"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""
    return "" if email.endswith("@users.noreply.github.com") else email


def scan_text(text, relative, own_user, email):
    findings = [f"{relative}:{text.count(chr(10), 0, match.start()) + 1}: private key" for match in PRIVATE_KEY.finditer(text)]
    for number, line in enumerate(text.splitlines(), 1):
        for kind, pattern in SECRETS.items():
            if pattern.search(line):
                findings.append(f"{relative}:{number}: {kind}")
        for match in HOME_PATH.finditer(line):
            name = match.group(1)
            if name not in FIXTURE_USERS or name == own_user:
                findings.append(f"{relative}:{number}: real home path")
        if email and email in line:
            findings.append(f"{relative}:{number}: the publisher's email")
    return findings


def scan(root):
    root = Path(root)
    home = Path.home().name
    email = own_email()
    findings = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if ".git" in path.relative_to(root).parts or not path.is_file() or path.is_symlink():
            continue
        if SECRET_FILES.search(relative):
            findings.append(f"{relative}: secret file")
            continue
        if relative.startswith(TEST_VECTORS) or path.stat().st_size > MAX_SIZE:
            continue
        data = path.read_bytes()
        if b"\0" in data[:4096]:
            continue
        findings.extend(scan_text(data.decode("utf-8", "replace"), relative, home, email))
    return findings


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: scan-public-source.py <folder>")
    findings = scan(sys.argv[1])
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        sys.exit(f"Refusing to publish: {len(findings)} finding(s) above. Values are not printed.")
    print("Public source scan: clean.")


if __name__ == "__main__":
    main()
