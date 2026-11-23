# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `2d-understanding` — raster images (PNG/JPEG/WebP/GIF) and SVG: exact vs
  displayed dimensions (EXIF orientation), alpha and blankness, dominant colors,
  content bbox, Vision OCR, SVG structure, pixel diffs.
- `3d-understanding` — engineering CAD (STEP parts/assemblies, PMI, BOM, cost,
  supply impact) and game assets (glTF/GLB/FBX/OBJ, meshes, materials, skeletons,
  import failures).
- `audio-understanding` — audio containers and streams (`afinfo` cross-check),
  integrated LUFS / LRA / true peak, silence, clipping, whisper.cpp transcripts.
- `code-understanding` — repository inventory, definition outlines via ast-grep,
  reference lookups via LSP, and the handoff from measured facts to code reading.
- `data-understanding` — CSV/TSV, JSON/JSONL, Parquet and SQLite: encoding and
  delimiter sniffing, per-column types and nulls, duplicates, footer metadata,
  read-only SQL.
- `doc-understanding` — PDF/DOCX/PPTX/XLSX/Markdown/HTML: text layer vs scan,
  embedded fonts, tables, tracked changes, formulas, render-and-OCR fallback.
- `macos-understanding` — host specs and OS state, installed-app inventory,
  bundle identity, signing and Gatekeeper verdicts, quarantine, architectures,
  and the running-app set from `lsappinfo`.
- `ui-understanding` — web pages and app screens: contrast ratios, target sizes,
  overlaps, truncation, layout numbers, design vs implementation, accessibility
  element trees.
- `video-understanding` — container/stream facts, rotation, VFR, HDR tagging,
  scene cuts, black and silent spans, frame extraction and contact sheets.
- `verify.sh` — runs every skill self-test plus frontmatter, shellcheck,
  markdownlint, ruff and shfmt checks; `--lint-only` for the CI gate, a
  substring argument to select one skill.
- `scripts/check_contract.py` — repo contract: frontmatter names, required
  sections, missing self-tests, absolute paths, placeholders, broken cross-skill
  references.
- `CONTRIBUTING.md`, `SECURITY.md`, issue forms, a PR template, and a GitHub
  Actions lint job.
- `scripts/check_shell_compat.py` — rejects bash 4+ constructs (`mapfile`,
  `${var,,}`, associative arrays, …) so every script runs on stock macOS
  `/bin/bash` 3.2 and the `macos-*` CI runner.
- `scripts/setup-dev.sh` and `.githooks/commit-msg` — one-command hook setup and
  Conventional Commits validation alongside the existing pre-commit gate.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1) and a Dependabot config for
  GitHub Actions.
- `check_contract.py` now rejects broken relative links in repo docs.
- `.github/workflows/links.yml` — weekly lychee check for external Markdown
  links; the contract check already gates relative links on every PR.

### Changed

- `verify.sh` and `.githooks/pre-commit` no longer use `mapfile`: the repo gate
  itself now runs on the bash 3.2 that stock macOS ships.
- `verify.sh` also enforces `ruff format --check`, the shell compatibility
  check, and `swiftc -typecheck` for the Vision OCR helper, and lints every
  Markdown file in the repo.
- CI: concurrency cancellation, job timeouts, non-persisted checkout
  credentials, and current action majors.
- The manual macOS self-test job now runs on `macos-15` (GitHub retired
  `macos-14`), installs ImageMagick and ast-grep so those checks execute instead
  of skipping, and `VERIFY_VERBOSE=1` prints the full failing self-test output.

### Fixed

- `macos-understanding` hardened after adversarial review: bundle-supplied
  strings are stripped of control characters (record forgery and terminal
  escapes), `CFBundleExecutable` must be a plain file name (no path traversal),
  symlinked bundles are only measured when the target is itself an app bundle,
  inventory parsing tolerates malformed records, and enumeration is NUL-safe.
  Self-tests now cover hostile bundles, symlinks, quarantine, broken bundles and
  exit codes.
- `3d-understanding` STEP views no longer fail with `NameError`: FreeCAD 1.1.4's
  `TechDraw` import evicts `json` and `math` from the importer's globals, so the
  script imports them inside the functions that use them.

### Security

- SVG inspection no longer renders documents with external `href`/`url()` refs:
  librsvg embedded a local PNG in the output bitmap, so the renderer could read
  arbitrary local images. Refs are still reported, rendering is skipped.
- OCR cache is per-user (`~/Library/Caches`, mode 0700) and refuses symlinked or
  non-owned binaries; a predictable `/tmp` cache name could be hijacked.
- `macos-understanding` scrubs `lipo` output (the last unsanitized terminal-escape
  path), rejects `..` in `CFBundleExecutable`, and collapses `$HOME` to `~` in
  JSON paths so the account name is not published.
- XLSX extraction caps rows/columns in read-only mode (a 4.8 KB far-cell workbook
  could allocate millions of cells); JSON/CSV probes read only the prefix they use.
- `render.sh` writes rendered scan pages to a private temp dir, not the CWD;
  `verify.sh` uses `mktemp` instead of a predictable `/tmp` name.
- `3d-understanding` documents a consent gate for the hosted backend upload, and
  `SECURITY.md` scopes the "no network" claim to the repo's scripts.
- Issue/PR templates and CONTRIBUTING require redacting paths, headers, OCR text
  and transcripts; macOS sample output no longer carries a device fingerprint.
- CI actions are pinned to commit SHAs (lychee is third-party); scheduled link
  checks skip documented example URLs and geo-blocked articles.

### Notes

- Self-tests are **macOS-first**: `sips`, `afinfo`, `swiftc` (Vision OCR),
  ffmpeg and PyMuPDF are expected, so CI runs lint only on Linux and the full
  self-test job only on `macos-15` via `workflow_dispatch`.
- Optional heavy dependencies (FreeCAD, assimp, Godot, a whisper ggml model)
  skip their checks with a printed `SKIP` when absent.
- Measured numbers can shift with tool versions. The self-tests, not the tables
  in `README.md`, are the contract.

## [0.1.0] - planned

First public release: the nine skills above, the verify and contract scripts,
and the repository scaffolding. No published tag yet.

[Unreleased]: https://github.com/ChasLui/anything-understanding/commits/main
