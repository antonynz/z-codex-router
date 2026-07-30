#!/usr/bin/env python3
"""Fail CI when source contains likely credentials or an author-home path."""
from __future__ import annotations

import os
import re
from pathlib import Path

from verify_policy_activation import verify_contract


ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", "target", "dist"}
PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"(?i)(api[_-]?key|secret|token)\\s*[:=]\\s*['\"][^'\"]{12,}"),
]
HOME = str(Path.home())


def main() -> None:
    verify_contract(ROOT / "plugins" / "z-codex-router")
    findings: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in EXCLUDED for part in path.parts):
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if HOME in text:
            findings.append(f"personal path: {path.relative_to(ROOT)}")
        if any(pattern.search(text) for pattern in PATTERNS):
            findings.append(f"possible secret: {path.relative_to(ROOT)}")
    if findings:
        raise SystemExit("\n".join(findings))


if __name__ == "__main__":
    main()
