#!/usr/bin/env bash
# One-time local setup: enable the repo hooks and print the check command.
# Safe to re-run; it only sets this repository's core.hooksPath.
set -euo pipefail

if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "setup-dev: run this inside a git checkout" >&2
  exit 1
fi
cd "$root"
git config core.hooksPath .githooks
echo "hooks enabled: core.hooksPath .githooks (pre-commit + commit-msg)"
echo "run: bash verify.sh"
