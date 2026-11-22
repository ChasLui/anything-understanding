# Contributing

This repo ships skills that make an agent **measure an artifact before it talks
about it**. Everything here is checked by a script, so "it worked on my machine"
is not an acceptable claim: a change is done when a command in this file printed
`PASS` or `ok` on your machine.

## The repo contract

A skill is not a folder of prose. To be accepted it needs all of the following:

1. **A named evidence channel** — a real parser or CLI (ffprobe, PyMuPDF,
   ast-grep, Vision OCR, …), not a model's impression. If there is no channel
   for a question, the skill says *cannot answer* and why.
2. **A gate** — one command plus the check that decides whether an answer is
   possible at all (for example: did the PDF expose a text layer or not).
3. **Measured fields instead of adjectives** — `transparent_ratio = 0.8139`,
   `integrated_lufs = -16.4`, not "mostly transparent" / "fairly loud".
4. **A self-test that asserts those measured values** on generated fixtures —
   not `exit 0`, but the numbers. `references/selftest.sh` is mandatory.
5. **A refusal rule** for each playbook: what the skill will not claim from the
   evidence it has.

## Add a skill

```text
skills/<name>/
├── SKILL.md              # frontmatter + body (Chinese body, English code)
└── references/
    ├── *.py|*.sh|*.swift # the tools
    └── selftest.sh       # asserts measured fields on fixtures it builds
```

The body of `SKILL.md` is written in Chinese with English technical terms. Code,
comments and every other file in this repo are English.

### Frontmatter rules

```yaml
---
name: <name>                # must equal the directory name, exactly
description: Use when …     # one plain YAML scalar, states WHEN to use it
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---
```

- `name` must equal the directory name. `python3 scripts/check_contract.py`
  enforces that; `verify.sh` enforces that the block parses and is non-empty.
- `description` is what an agent matches on, so it answers *when to use this
  skill*, not *what this skill knows*. State the artifact types and the tasks.
- `description` must be a **valid YAML scalar**. A colon followed by a space
  inside a plain scalar starts a mapping and breaks the file — write
  `Covers the PNG/JPEG/SVG cases` rather than `Covers: PNG/JPEG/SVG`. If you
  genuinely need a colon followed by a space, or a `#`, use a folded block:

  ```yaml
  description: >-
    Use when a task involves subtitle files (SRT/VTT) and you must
    check timing: gaps, overlaps, reading speed.
  ```

- `metadata.version` is required; bump it when behaviour changes.
- Two sections are enforced by `scripts/check_contract.py`: `## 失败模式` and
  `## 脚本与依赖`. Add them; do not rename them.

### Rules of the road

- **No command you have not run** may appear in a skill. Run it on a real
  artifact, paste the real output, then document it.
- **No feature without an artifact** that proves it works.
- **No absolute paths** that only exist on your machine (`/Users/…`, `/home/…`,
  a `$HOME` that the reader might not have). Paths in skills are relative to the
  skill directory, written as `references/…`. `check_contract.py` rejects them.
- **No placeholders**: `TODO`, `FIXME`, `TBD` fail the contract check.
- A limitation is documented, never papered over. If a channel cannot see
  something, the skill says so.

## Run the checks

```bash
bash verify.sh                     # every skill self-test + all linters
bash verify.sh --lint-only         # static gate, no self-tests (CI uses this)
bash verify.sh 2d                  # skills matching a substring
bash skills/2d-understanding/references/selftest.sh   # one self-test directly
python3 scripts/check_contract.py  # contract: names, sections, paths, doc links
bash scripts/setup-dev.sh          # enable pre-commit + commit-msg hooks once
```

`bash verify.sh` exits 0 only when everything passes. A tool that is not
installed prints `SKIP (not installed)` instead of failing, so read the output:
a wall of skips is not a green run. Run the full form before you open a PR.

`--lint-only` is what CI runs: the repo contract, shellcheck, shfmt, ruff
(including `ruff format --check`), the bash 3.2 compatibility check,
markdownlint, yamllint and actionlint, with the self-tests skipped. Everything
else is **macOS-first**: `sips`, `afinfo`, the Swift `swiftc` Vision OCR, ffmpeg
and PyMuPDF are expected. Heavy optional dependencies (FreeCAD, assimp, a whisper
model, Godot) skip themselves when absent, and print the skip.

All scripts must run on stock macOS `/bin/bash` 3.2. `scripts/check_shell_compat.py`
rejects bash 4+ constructs (`mapfile`, `${var,,}`, associative arrays, …);
`swiftc -typecheck` runs in `verify.sh` when Swift is installed.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope)`,
then a colon, then an imperative summary. Scope is the skill name (or `repo` /
the file area for tooling).

```text
feat(2d-understanding): cross-check EXIF orientation against displayed size
fix(doc-understanding): refuse table claims when the PDF has no text layer
test(audio-understanding): assert true peak on a clipped fixture
docs: state the macOS-only OCR dependency in the install table
ci: lint docs on ubuntu, self-tests only on workflow_dispatch
chore(repo): drop the unused render helper
```

One skill per commit where possible. Never commit generated fixtures, OCR
binaries or `__pycache__` (see `.gitignore`).

## Git hooks

Enable the hooks once per checkout:

```bash
bash scripts/setup-dev.sh    # git config core.hooksPath .githooks
```

`.githooks/pre-commit` runs the contract check plus shellcheck, shfmt, the bash
compatibility check, `ruff check`/`ruff format --check` and markdownlint on
staged files. `.githooks/commit-msg` rejects non-Conventional-Commit subjects
(merge and `fixup!`/`squash!` messages pass). To bypass once for a
work-in-progress commit, use `git commit --no-verify` and say why in the PR.

Only enable hooks in checkouts you trust: `.githooks/*` comes from the
checked-out branch, so a branch can change the code that runs on your next
commit. Review `.githooks/` and `scripts/` before committing in a new branch.

## Pull requests

- **Small PRs.** One skill per change; unrelated cleanup goes in its own PR.
- **Evidence in the description.** Paste the commands you ran and their real
  output — the self-test for the touched skill, plus `bash verify.sh`. Numbers,
  not adjectives.
- **Redact evidence.** Replace `/Users/<you>/…` paths, private CSV headers,
  OCR text and transcripts with `<artifact>` / `<redacted>` before pasting into
  a public issue or PR; the tool output is local measurement, not publishable
  content. The issue and PR templates repeat this rule.
- **No docs drift.** If a command changed, the doc line changed in the same PR.
- **Portability.** No machine-specific absolute paths in committed files; skills
  and their self-tests must run from the repo root.
- Fill in `.github/pull_request_template.md`; the checklist is the review gate.

CI runs the lint pass on `ubuntu-latest` for every push to `main` and every PR.
The macOS self-test job only runs on `workflow_dispatch`, because it needs the
macOS toolchain.

## Code of conduct

Participation is covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

Contributions are under the MIT license in [`LICENSE`](LICENSE).
