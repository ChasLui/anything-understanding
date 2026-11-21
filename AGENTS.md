# AGENTS.md

Rules for any agent working **in** this repository. Rules for agents **using**
the skills live inside each `skills/<name>/SKILL.md`.

## What this repo is

A set of skills that turn "describe this artifact" into measured facts. Every
skill follows the same contract: a named evidence channel, a gate that says
whether a question is answerable, measured fields with their limits, playbooks,
failure modes, and a self-test that fails when the tooling drifts.

| Artifact | Skill |
|---|---|
| image, screenshot, icon, SVG | `2d-understanding` |
| CAD part/assembly, glTF/GLB/FBX/OBJ, Godot scene | `3d-understanding` |
| audio, loudness, speech-to-text | `audio-understanding` |
| unfamiliar repository, code locations/impact | `code-understanding` |
| CSV/JSON/Parquet/SQLite, data quality, SQL | `data-understanding` |
| PDF/DOCX/PPTX/XLSX, scans, tables | `doc-understanding` |
| web page or app screen, contrast, target sizes | `ui-understanding` |
| video file, streams, scene cuts, frames | `video-understanding` |
| the Mac itself, installed apps, signature/quarantine questions | `macos-understanding` |

## Adding or changing a skill

1. One skill per directory: `skills/<name>/SKILL.md` plus `skills/<name>/references/`.
   Tool scripts and `references/selftest.sh` live in `references/`.
2. Frontmatter must be valid YAML: `name` equals the directory name, `description`
   states **when** to use it. A `": "` inside an unquoted description breaks YAML
   and makes the skill invisible to `npx skills` — quote it or avoid it.
3. **Never document a command you have not run on this machine.** Numbers in prose
   carry the caveat you measured (tool version, units, what was not tested).
4. Prefer a handoff over a copy: if another skill already owns a channel (OCR,
   pixel diff, ffprobe), reference it with a relative path
   (`../2d-understanding/references/ocr.sh`) instead of duplicating it.
5. No machine-specific absolute paths (`/Users/...`), no placeholders
   (`TODO`/`TBD`), no network calls from tool scripts.
6. Every tool script needs a `references/selftest.sh` assertion that fails when the
   measurement breaks — fixture generation + measured-value checks, not exit codes.
7. Bodies are Chinese with English technical terms; code and comments are English.

## Checks (run before calling anything done)

```bash
bash verify.sh               # all self-tests + contract + linters
bash verify.sh --lint-only   # portable lint stage (what CI runs)
bash verify.sh <name>        # one skill
```

`scripts/check_contract.py` enforces: valid frontmatter, `name` == directory,
`metadata.version`, the `失败模式` and `脚本与依赖` sections, a `references/selftest.sh`,
no absolute home paths, no TODO markers, resolvable cross-skill references, and
relative links in repo docs.

`scripts/check_shell_compat.py` rejects bash 4+ constructs. Stock macOS
`/bin/bash` is 3.2 and the `macos-*` CI runner uses it: no `mapfile`,
`readarray`, `${var,,}`/`${var^^}`, associative arrays, `&>>`, or `|&`.

Fast gate: `bash scripts/setup-dev.sh` (sets `core.hooksPath .githooks`;
pre-commit lints staged files, commit-msg checks Conventional Commits).

## Distribution

- Canonical source: this repo. `~/.agents/skills/<name>` are symlinks to
  `skills/<name>`; `~/.agents/sync.sh` distributes them to agent directories.
- After creating or changing a skill, sync it to OpenViking:
  `ov add-skill skills/<name> --wait -y`.
- Do not move or rename this repository: it breaks every agent's skill symlink.
