#!/usr/bin/env python3
"""Reject bash 4+ constructs: every script must run on macOS /bin/bash 3.2.

`#!/usr/bin/env bash` on stock macOS (and the GitHub `macos-*` runners) is bash
3.2, so a bash-4 feature that works in a developer's Homebrew shell breaks CI and
every fresh Mac. The `skills/3d-understanding` `${ext,,}` incident is the reason
this check exists.

    python3 scripts/check_shell_compat.py            # whole repo
    python3 scripts/check_shell_compat.py path.sh    # specific files

Exit 1 on any hit. Quoted strings and trailing comments are ignored; here-doc
bodies are still scanned, so literal examples belong in comments or quotes.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".ruff_cache", "__pycache__"}

RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bmapfile\b"), "mapfile is bash 4"),
    (re.compile(r"\breadarray\b"), "readarray is bash 4"),
    (re.compile(r"\bdeclare\s+-[A-Za-z]*A"), "associative arrays are bash 4"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(?:,,|\^\^)"), "case modification is bash 4"),
    (re.compile(r"&>>|\|&"), "&>> / |& are bash 4"),
    (re.compile(r"\blocal\s+-n\b"), "nameref is bash 4.3"),
    (re.compile(r"\bwait\s+-n\b"), "wait -n is bash 4.3"),
    (re.compile(r"\bcoproc\b"), "coprocesses are bash 4"),
    (re.compile(r"\bshopt\s+-s\s+globstar\b"), "globstar is bash 4"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Za-z]\}"), "${var@op} is bash 4.4"),
]


def shell_files() -> list[Path]:
    files = [ROOT / "verify.sh", *sorted((ROOT / ".githooks").glob("*"))]
    for path in ROOT.rglob("*.sh"):
        if SKIP_DIRS.isdisjoint(path.relative_to(ROOT).parts):
            files.append(path)
    return sorted({p for p in files if p.is_file()})


def code_part(line: str) -> str:
    """Drop quoted strings and trailing comments so examples cannot fire."""
    out: list[str] = []
    quote = ""
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < len(line):
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            i += 1
            continue
        if ch == "\\" and i + 1 < len(line):
            out.append(line[i + 1])
            i += 2
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;|&("):
            break
        out.append(ch)
        i += 1
    return "".join(out)


def check(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    if "bash" not in text.splitlines()[0] and path.suffix != ".sh":
        return errors
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        code = code_part(line)
        if not code.strip():
            continue
        for pattern, reason in RULES:
            if pattern.search(code):
                try:
                    shown = path.relative_to(ROOT)
                except ValueError:
                    shown = path
                errors.append(f"{shown}:{number}: {reason}: {stripped}")
    return errors


def selftest() -> list[str]:
    """Rules must fire on bash-4 samples and stay quiet on bash-3.2 code."""
    bad = {
        "mapfile -t x < <(echo hi)": "mapfile",
        "readarray -t x < <(echo hi)": "readarray",
        "declare -A map": "associative",
        "x=${path,,}": "case modification",
        "x=${path^^}": "case modification",
        "cmd &>> log": "&>>",
        "cmd |& cat": "|&",
        "local -n ref=$1": "nameref",
        "wait -n": "wait -n",
        "coproc cat": "coprocess",
        "shopt -s globstar": "globstar",
        "x=${v@Q}": "${var@op}",
    }
    errors = []
    for sample, needle in bad.items():
        hits = [reason for pattern, reason in RULES if pattern.search(sample)]
        if not any(needle in reason for reason in hits):
            errors.append(f"selftest: rule missed {sample!r}")
    good = [
        "mapfile_path=1",
        "# mapfile in a comment",
        "arr=(a b)",
        "echo ${arr[0]}",
        'echo "a |& b"',
        "cmd | # mapfile is bash 4",
    ]
    for sample in good:
        code = code_part(sample)
        hits = [reason for pattern, reason in RULES if pattern.search(code)]
        if hits:
            errors.append(f"selftest: false positive {sample!r}: {hits[0]}")
    return errors


def main(argv: list[str]) -> int:
    failures = selftest()
    files = [Path(arg) for arg in argv] if argv else shell_files()
    for path in files:
        if not path.is_file():
            failures.append(f"{path}: not a file")
            continue
        failures.extend(check(path.resolve()))
    if failures:
        print("\n".join(failures))
        return 1
    print(f"shell compat ok: {len(files)} file(s) on bash 3.2 rules")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
