# anything-understanding

[![verify](https://github.com/ChasLui/anything-understanding/actions/workflows/verify.yml/badge.svg)](https://github.com/ChasLui/anything-understanding/actions/workflows/verify.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Agent skills that make an agent **understand an artifact before it talks about it**.

Not "look at the file and describe it". Each skill here answers three questions in
order: *what can I measure*, *what does the measurement not mean*, and *what is the
smallest honest answer I can give from it*. Every tool is runnable, every claim in
the docs was measured on a real artifact, and every skill ships a self-test.

The failure this repo targets: an agent that says "看起来是深色主题", "这个模型应该能用",
"这里没人调用" — fluent, unverifiable, and wrong. Understanding is evidence first.

## Skills

| Skill | Covers | Evidence channels | Needs |
|---|---|---|---|
| [`3d-understanding`](skills/3d-understanding/SKILL.md) | CAD (STEP parts/assemblies, PMI, BOM, cost, supply impact) and game assets (glTF/GLB/FBX/OBJ, mesh budgets, materials, skeletons, import failures) | 3D backend (views + PMI + assembly tree), local geometry (FreeCAD, pure-Python GLB parser), engine import (Godot headless) | FreeCAD cask · assimp · Godot (optional) |
| [`2d-understanding`](skills/2d-understanding/SKILL.md) | screenshots, photos, icons, logos, PNG/JPEG/WebP/GIF/SVG | container facts (dimensions vs EXIF display size, DPI, ICC, frames), pixel facts (alpha, blankness, dominant colors, content bbox), Vision OCR, SVG structure + real render, pixel diff | Pillow · ImageMagick · librsvg · macOS `swiftc` (OCR only) |
| [`code-understanding`](skills/code-understanding/SKILL.md) | unfamiliar repositories: onboarding, locate an implementation, change impact, hotspots, dead-code candidates | inventory (languages, entry points, generated areas, churn), definition outlines (ast-grep bundled parsers), references (LSP), runtime (tests) | git · ast-grep · LSP (optional) |
| [`video-understanding`](skills/video-understanding/SKILL.md) | video files (MP4/MOV/MKV/WebM/AVI/TS): specs, rotation, VFR, HDR tagging, scene cuts, black/silent spans, frame extraction, contact sheets | ffprobe container/stream facts, ffmpeg timeline filters (`select` scene scores, `blackdetect`, `silencedetect`), extracted frames (text handed to 2d-understanding OCR) | ffmpeg/ffprobe |
| [`audio-understanding`](skills/audio-understanding/SKILL.md) | audio files and audio tracks: format, loudness, true peak, silence, clipping, speech-to-text | ffprobe + `afinfo` container facts, `ebur128`/`volumedetect`/`astats`/`silencedetect` signal facts, local whisper.cpp transcription | ffmpeg · whisper-cli + a real ggml model |
| [`doc-understanding`](skills/doc-understanding/SKILL.md) | PDF / DOCX / PPTX / XLSX / Markdown / HTML: inventory, text layer vs scan, embedded fonts, tables, tracked changes, formulas, render+OCR for scans | PyMuPDF + pdfplumber structure and text, `pdftotext -layout`, pandoc conversion, rendered pages handed to 2d-understanding OCR | PyMuPDF · pdfplumber · python-docx/pptx/openpyxl · pandoc · poppler |
| [`data-understanding`](skills/data-understanding/SKILL.md) | CSV/TSV, JSON/JSONL, Parquet, SQLite: shape, delimiter and encoding, per-column types and nulls, duplicates, mixed-type columns, Parquet layout, read-only SQL | content-based kind sniffing + streaming profile, Parquet footer metadata, SQLite schema, in-memory `sql.py` for CSV/JSON/Parquet and `mode=ro` for databases | pandas · pyarrow · charset_normalizer |
| [`ui-understanding`](skills/ui-understanding/SKILL.md) | web pages and app screens: contrast ratios, target sizes, overlaps, truncation, layout numbers, design-vs-implementation, native element trees | DOM + `getComputedStyle`/`getBoundingClientRect` (devtools MCP), macOS accessibility frames (`agent-desktop`), pixels + OCR as the fallback; WCAG ratio and box-geometry math computed locally | a browser (devtools MCP) · `agent-desktop` (native) · 2d-understanding (OCR) |
| [`macos-understanding`](skills/macos-understanding/SKILL.md) | the Mac itself and installed apps: host specs and OS state, app inventory, bundle id/version/category, signature and notarization verdicts, quarantine, architectures, why an app will not open | `sw_vers`/`sysctl`/`df`/`pmset`/`csrutil`/`fdesetup`, `system_profiler SPHardwareDataType`, PlistBuddy on `Contents/Info.plist`, `codesign`/`spctl`/`xattr`/`lipo`, `lsappinfo` for the running set | macOS (read-only, no `sudo`) |

Every skill here follows the same contract: a named evidence channel, a gate that says
whether an answer is possible, measured fields instead of adjectives, and a self-test
that fails when the tooling drifts.

## Install

```bash
# any agent, project-local
npx skills add ChasLui/anything-understanding

# or one skill
npx skills add ChasLui/anything-understanding --skill 2d-understanding -g
```

By hand: a skill is its directory. Copy or symlink `skills/<name>/` into whichever
directory your agent reads (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, …).
Scripts are referenced relative to the skill directory, so symlinks work.

## Verify

Each skill's self-test builds throwaway fixtures and asserts measured fields — not
"exit code 0", but `transparent_ratio = 0.8139`, `frames = 3`, `scene cuts = 1.0, 2.0`.

```bash
bash verify.sh               # every skill self-test + contract + linters
bash verify.sh --lint-only   # portable lint stage (what CI runs)
bash verify.sh 2d            # one skill (substring match on the name)
bash skills/audio-understanding/references/selftest.sh   # a single self-test directly
```

Parts that need a heavy dependency skip themselves when it is absent (FreeCAD,
assimp, a whisper model), and the skip is printed. Run this after touching a script,
and before trusting a new skill on a real task.

## Engineering

The repo is checked like a project, not a folder of prompts:

- `scripts/check_contract.py` — frontmatter valid (name == directory, description,
  `metadata.version`), the `失败模式` / `脚本与依赖` sections present, a
  `references/selftest.sh` per skill, no absolute home paths, no TODO placeholders,
  every cross-skill reference resolves to a real file, and relative links in repo
  docs point at files that exist.
- `scripts/check_shell_compat.py` — every script must run on stock macOS
  `/bin/bash` 3.2 (as on the `macos-*` CI runner): no `mapfile`, `readarray`,
  `${var,,}`, associative arrays, `&>>` or `|&`.
- Linters, run by `verify.sh`: `shellcheck` and `shfmt -d -s -i 2 -ci`, `ruff`
  (check + `format --check`), the shell compatibility check, `markdownlint-cli2`,
  `yamllint`, `actionlint`, and `swiftc -typecheck` for the Vision OCR helper.
  Missing tools report SKIP, never PASS.
- `.githooks/pre-commit` lints staged files; `.githooks/commit-msg` enforces
  Conventional Commits. Enable both with `bash scripts/setup-dev.sh`.
- CI (`.github/workflows/verify.yml`) runs `--lint-only` on Linux for every push/PR
  with concurrency cancellation and timeouts; Dependabot keeps action pins current.
  The macOS self-test job is manual (`workflow_dispatch`) because the skills depend
  on macOS tooling (Vision OCR, `afinfo`, `sips`, ffmpeg, FreeCAD, whisper.cpp).
- `.github/workflows/links.yml` — weekly [lychee](https://github.com/lycheeverse/lychee)
  check for external Markdown links; relative links are already gated in
  `check_contract.py` on every PR.
- Commits follow Conventional Commits; see `CONTRIBUTING.md`. `AGENTS.md` holds the
  rules for agents editing this repo.

## Related work

Most published `audio-understanding` / `video-understanding` skills wrap a cloud
multimodal API (Gemini, Volcengine Ark, MiMo): they upload the file and ask a model.
That is a real channel, but every answer comes back as prose you cannot re-derive.
This repo runs the other way: local tools measure first (ffprobe, ffmpeg filters,
`ebur128`, whisper.cpp, Vision OCR), the numbers are the answer, and a model — local
or remote — is optional on top. Where there is no local channel the skill says so
instead of substituting a guess.

For macOS specifically, [`jaywcjlove/awesome-mac`](https://github.com/jaywcjlove/awesome-mac)
is the reference curated catalog (120k+ stars, daily updates): a human-maintained list of
apps grouped by category. It is useful for **category vocabulary** and for discovering
what exists; it is not evidence about what is installed on this Mac. `macos-understanding`
therefore takes its categories only as a cross-check and measures the machine itself
(`Info.plist`, `codesign`, `spctl`, `lsappinfo`) — a catalog entry cannot tell you an
app's version, signature, or why it will not open.

## What a skill in this repo must contain

1. **A named evidence channel** — a real tool or parser, not a model's impression.
   If there is no channel for a question, the skill says "cannot answer" and why.
2. **A gate** — the one command and the check that decides whether an answer is
   possible at all (e.g. saw PMI or not; saw `displayed_size` or not).
3. **口径 (measurement semantics)** — what each number does and does not mean:
   sampled vs exact, storage vs display pixels, churn vs importance.
4. **Playbooks** — the few tasks that actually come up, each with its refusal rule.
5. **Grounding rules and failure modes** — how to phrase an answer that stays
   inside the evidence, and the traps already hit (EXIF rotation, assimp flags,
   IM7's inverted SSIM, format-only STEP parsing).
6. **A self-test** that asserts measured fields.
7. **Valid frontmatter** — `name` equals the directory name, `description` is a
   valid YAML scalar stating *when* to use the skill (an unquoted `": "` breaks
   the parse and the skill silently disappears from `npx skills` listing), and
   `metadata.version` is present.

Rules of the road: no untested command in a skill; no feature without a real
artifact to prove it; a limitation is documented, never papered over.

## Layout

```text
skills/<name>/
├── SKILL.md              # frontmatter: name + description (when to use it) + metadata
└── references/
    ├── *.py|*.sh|*.swift # tools
    └── selftest.sh       # asserts measured fields on generated fixtures

verify.sh                    # full gate: self-tests + contract + linters
scripts/check_contract.py    # repo contract: frontmatter, paths, doc links
scripts/check_shell_compat.py # bash 3.2 rule for every script
scripts/setup-dev.sh         # enable pre-commit + commit-msg hooks once
.githooks/                   # fast staged-file gate + commit message check
.github/                     # CI, Dependabot, issue/PR templates
```

`SKILL.md` frontmatter follows the Agent Skills convention (`name`, `description`);
`description` states *when* to use the skill, because that is what an agent matches
on. Bodies are in Chinese with English technical terms; code and comments are English.

## Verified on

macOS 26 (arm64), 2026-11-21: Pillow 10.4 · ImageMagick 7.1.2 · librsvg 2.62 ·
Swift 6.4 (Vision OCR) · ast-grep 0.50 / tree-sitter 0.26 · Python 3.13 ·
FreeCAD 1.1.4 · assimp 6.0.6 · Godot 4.7.2 mono · ffmpeg/ffprobe 9.0.2 ·
whisper.cpp 1.8.4 · PyMuPDF 1.27.2 · pdfplumber 0.11.8 · pandoc 3.9. Other
versions may shift exact numbers; the self-tests are the contract.

## Contributing

Issues and PRs are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) for
the repo contract, checks and commit convention; participation is covered by the
[Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately via
[`SECURITY.md`](SECURITY.md), not a public issue.

## License

MIT
