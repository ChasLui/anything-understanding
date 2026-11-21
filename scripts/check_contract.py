#!/usr/bin/env python3
"""Contract checks for this repo's skills. Exit 1 on any violation.

A skill in this repo is not "a folder with prose": it must carry a valid
frontmatter name, a self-test, the two sections that keep answers honest
(失败模式 / 脚本与依赖), no machine-specific absolute paths, no TODO placeholders,
and every cross-skill reference it makes must point at a file that exists.

    python3 scripts/check_contract.py            # whole repo
    python3 scripts/check_contract.py 2d         # skills matching a substring

Run from anywhere; paths are resolved against the repo root.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
REQUIRED_SECTIONS = ("失败模式", "脚本与依赖")
ABS_PATH_RE = re.compile(r"(/Users/|/home/)[^\s`\"')]+")
PLACEHOLDER_RE = re.compile(r"\b(TODO|FIXME|TBD)\b")
CROSS_REF_RE = re.compile(r"\.\./([a-z0-9-]+-understanding)/references/([A-Za-z0-9._-]+)")
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
MD_FENCE_RE = re.compile(r"```.*?```", re.S)
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "tel:", "#")


def frontmatter(text: str) -> tuple[dict | None, str | None]:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return None, "no frontmatter block"
    try:
        meta = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        return None, f"invalid YAML: {str(exc).splitlines()[0]}"
    if not isinstance(meta, dict):
        return None, "frontmatter is not a mapping"
    return meta, None


def check_skill(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    name = skill_dir.name
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return [f"{name}: missing SKILL.md"]
    text = skill_md.read_text(encoding="utf-8")
    meta, problem = frontmatter(text)
    if problem:
        errors.append(f"{name}/SKILL.md: {problem}")
    else:
        assert meta is not None
        if meta.get("name") != name:
            errors.append(f"{name}/SKILL.md: frontmatter name is {meta.get('name')!r}, expected {name!r}")
        if not isinstance(meta.get("description"), str) or not meta["description"].strip():
            errors.append(f"{name}/SKILL.md: missing description")
        version = (meta.get("metadata") or {}).get("version")
        if not version:
            errors.append(f"{name}/SKILL.md: missing metadata.version")
    for section in REQUIRED_SECTIONS:
        if not re.search(rf"^##[^#].*{section}", text, re.M):
            errors.append(f"{name}/SKILL.md: missing section {section!r}")
    selftest = skill_dir / "references" / "selftest.sh"
    if not selftest.is_file():
        errors.append(f"{name}: missing references/selftest.sh")
    for path in [skill_md, *sorted((skill_dir / "references").glob("*"))]:
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8", errors="replace")
        for match in ABS_PATH_RE.finditer(content):
            line = content[: match.start()].count("\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: absolute path {match.group(0)!r}")
        for match in PLACEHOLDER_RE.finditer(content):
            line = content[: match.start()].count("\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: placeholder {match.group(1)}")
        for ref_skill, ref_file in CROSS_REF_RE.findall(content):
            target = ROOT / "skills" / ref_skill / "references" / ref_file
            if not target.is_file():
                errors.append(
                    f"{path.relative_to(ROOT)}: broken cross-skill reference {ref_skill}/references/{ref_file}"
                )
    return errors


def check_doc_links() -> list[str]:
    """Relative Markdown links in repo docs must resolve to a file."""
    errors: list[str] = []
    docs = sorted(ROOT.glob("*.md")) + sorted((ROOT / ".github").rglob("*.md"))
    for doc in docs:
        text = MD_FENCE_RE.sub("", doc.read_text(encoding="utf-8"))
        for raw in MD_LINK_RE.findall(text):
            target = raw.strip()
            if target.startswith(EXTERNAL_PREFIXES):
                continue
            path = target.split("#", 1)[0].split()[0].strip("<>")
            if not path or path.startswith("/"):
                continue
            if not (doc.parent / path).resolve().exists():
                errors.append(f"{doc.relative_to(ROOT)}: broken link {target!r}")
    return errors


def main(argv: list[str]) -> int:
    needle = argv[0] if argv else ""
    if not SKILLS.is_dir():
        print(f"check_contract: no skills directory at {SKILLS}", file=sys.stderr)
        return 1
    skill_dirs = sorted(p for p in SKILLS.iterdir() if p.is_dir())
    if needle:
        skill_dirs = [p for p in skill_dirs if needle in p.name]
    if not skill_dirs:
        print(f"check_contract: no skill matches {needle!r}", file=sys.stderr)
        return 1
    errors: list[str] = []
    for skill_dir in skill_dirs:
        errors.extend(check_skill(skill_dir))
    errors.extend(check_doc_links())
    if errors:
        print("\n".join(errors))
        return 1
    print(f"contract ok: {len(skill_dirs)} skill(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
