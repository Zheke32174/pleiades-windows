#!/usr/bin/env python3
"""Review the public tree and reachable Git history for sensitive material."""

from __future__ import annotations

import hashlib
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

MAX_BLOB_BYTES = 2 * 1024 * 1024
SELF_PATH = "ci/scan_public_repo.py"


@dataclass(frozen=True)
class Rule:
    name: str
    expression: re.Pattern[str]


def joined(*parts: str) -> str:
    return "".join(parts)


RULES = [
    Rule("private-key-header", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    Rule("github-classic-token", re.compile(re.escape(joined("gh", "p_")) + r"[A-Za-z0-9]{20,}")),
    Rule("github-fine-grained-token", re.compile(re.escape(joined("github", "_pat_")) + r"[A-Za-z0-9_]{20,}")),
    Rule("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    Rule("google-api-key", re.compile(re.escape(joined("AI", "za")) + r"[A-Za-z0-9_-]{24,}")),
    Rule("tailscale-auth-key", re.compile(re.escape(joined("ts", "key-")) + r"[A-Za-z0-9_-]{12,}")),
    Rule("generic-secret-assignment", re.compile(r"(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|private[_-]?key)\b\s*[:=]\s*['\"]?[A-Za-z0-9+/_.=-]{12,}")),
    Rule("linux-user-home", re.compile(r"(?<![A-Za-z0-9])/(?:home|Users)/[A-Za-z0-9._-]+/")),
    Rule("windows-user-home", re.compile(r"(?i)\b[A-Z]:\\Users\\[A-Za-z0-9._ -]+\\")),
    Rule("tailnet-hostname", re.compile(r"\b[a-z0-9-]+\.[a-z0-9-]+\.ts\.net\b", re.IGNORECASE)),
    Rule("carrier-grade-private-address", re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(?:\.[0-9]{1,3}){2}\b")),
]


def git(root: pathlib.Path, *args: str, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=root, check=False, capture_output=True, text=text)


def decode_text(data: bytes) -> str | None:
    if len(data) > MAX_BLOB_BYTES or b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def scan_text(scope: str, identity: str, path: str, text: str) -> list[str]:
    if path == SELF_PATH:
        return []
    findings: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for rule in RULES:
            if rule.expression.search(line):
                digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:12]
                findings.append(f"{scope}: {identity}:{path}:{line_number}: {rule.name} line_sha256={digest}")
    return findings


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    findings: list[str] = []

    listed = git(root, "ls-files", "-z", text=False)
    if listed.returncode != 0:
        raise SystemExit(listed.stderr.decode("utf-8", errors="replace"))
    for raw_path in listed.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8")
        text = decode_text((root / path).read_bytes())
        if text is not None:
            findings.extend(scan_text("current", "HEAD", path, text))

    objects = git(root, "rev-list", "--objects", "--all")
    if objects.returncode != 0:
        raise SystemExit(objects.stderr)
    visited: set[str] = set()
    for line in objects.stdout.splitlines():
        sha, separator, path = line.partition(" ")
        if not separator or not path or sha in visited or path == SELF_PATH:
            continue
        visited.add(sha)
        kind = git(root, "cat-file", "-t", sha)
        size = git(root, "cat-file", "-s", sha)
        if kind.returncode != 0 or kind.stdout.strip() != "blob" or size.returncode != 0 or int(size.stdout.strip()) > MAX_BLOB_BYTES:
            continue
        content = git(root, "cat-file", "blob", sha, text=False)
        if content.returncode != 0:
            continue
        text = decode_text(content.stdout)
        if text is not None:
            findings.extend(scan_text("history", sha, path, text))

    if findings:
        print("Public repository sensitivity scan requires review:", file=sys.stderr)
        for finding in sorted(set(findings)):
            print(f"  {finding}", file=sys.stderr)
        return 1
    print("PASS: no configured sensitive patterns found in current tree or reachable Git history")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
