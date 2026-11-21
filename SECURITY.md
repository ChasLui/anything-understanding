# Security policy

## Scope

This repo is a collection of local CLI scripts plus the `SKILL.md` prose that
tells an agent how to run them. The security surface is therefore small and
specific:

- Scripts read files the user points them at (images, media, PDFs, spreadsheets,
  SQLite databases, repositories) and print measurements.
- **No script sends data anywhere.** There is no network code, no upload, no
  telemetry, no analytics, and no auto-update path. The only URL in the repo is
  a *printed* download hint in `audio-understanding/references/transcribe.sh`;
  the script never runs it, it tells you how to fetch a whisper model yourself.
- SQLite access is read-only (`mode=ro`); the data tools never write to the
  database they inspect.
- Self-tests build throwaway fixtures in a temporary directory and delete them.

In scope: a script that executes attacker-controlled content from an inspected
file (shell injection through a filename, a crafted archive/PDF/SVG reaching a
shell, a write outside the temp directory), path traversal, unexpected network
access, or a documented command that is materially unsafe.

## Reporting

Use **GitHub Security Advisories** for this repository
(`Security` → `Report a vulnerability`). Do not open a public issue, and do not
paste a working exploit into a discussion.

Please include:

- The skill and tool involved (for example
  `skills/doc-understanding/references/extract.py`), and the version from
  `SKILL.md` frontmatter.
- The exact command, plus the input that triggers it. A minimal fixture is much
  more useful than a description.
- macOS version and the tool version reported by the script itself (`--version`
  or the header line it prints).
- What you expected versus what happened, and the impact you believe it has.

You can expect an acknowledgement within a few days and a fix or an explicit
"out of scope, here is why" after triage. Please give us a reasonable window to
ship a fix before publishing.

## Non-goals

- **Third-party tool bugs.** A vulnerability in ffmpeg, PyMuPDF, Pillow,
  librsvg, FreeCAD or whisper.cpp belongs upstream. We will pin, document or
  avoid the tool, but we cannot patch it here.
- **Malicious input rendering as data.** A script that faithfully reports a
  crafted image's dimensions is working as designed; the artifact is hostile,
  not the measurement.
- **Agent behaviour.** These skills supply evidence and refusal rules. What an
  agent does with an answer, and any tool permissions you grant it, are outside
  this repo's control.
- **Model output.** Local or hosted models used on top of the measured fields
  are optional and are not shipped here.

## Supported versions

The default branch is the only supported version until the first tagged release
(0.1.0). Security fixes are applied there.
