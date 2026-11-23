#!/usr/bin/env bash
# Repo gate: every skill self-test, then the engineering checks.
#
#   bash verify.sh                 # all skills + all linters
#   bash verify.sh --lint-only     # no self-tests (CI on Linux)
#   bash verify.sh 2d              # skills whose name contains "2d"
#   bash verify.sh --lint-only 2d  # both
#
# Self-tests are macOS-first (sips/afinfo/swiftc/ffmpeg/whisper/FreeCAD…); the
# lint stage is portable and is what CI runs. Exit 0 only when everything ran
# and passed; missing optional tools are reported as SKIP, never as PASS.
set -uo pipefail

root=$(cd "$(dirname "$0")" && pwd)
cd "$root" || exit 1
lint_only=0
filter=""
for arg in "$@"; do
  case $arg in
    --lint-only) lint_only=1 ;;
    -*)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
    *) filter=$arg ;;
  esac
done

fail=0
ran=0
mark() { printf '  %-20s %s\n' "$1" "$2"; }
run_check() { # run_check <label> <command...>
  local label=$1 out
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/verify-check.XXXXXX") || {
    mark "$label" FAIL
    fail=1
    return
  }
  if "$@" >"$out" 2>&1; then
    mark "$label" PASS
  else
    mark "$label" FAIL
    sed 's/^/    /' "$out" | tail -20
    fail=1
  fi
  rm -f "$out"
}

# Existing shell and markdown files, so absent optional dirs never break a glob.
# Arrays are filled with while-read loops: mapfile is bash 4 and stock macOS
# /bin/bash is 3.2 (scripts/check_shell_compat.py enforces this repo-wide).
sh_files=()
while IFS= read -r path; do
  [ -n "$path" ] && sh_files+=("$path")
done < <(
  find skills scripts .githooks -name '*.sh' 2>/dev/null
  [ -f verify.sh ] && echo verify.sh
)
md_files=()
while IFS= read -r path; do
  [ -n "$path" ] && md_files+=("$path")
done < <(find . -path ./.git -prune -o -path ./.ruff_cache -prune -o -name '*.md' -print 2>/dev/null | sort)
yml_files=()
while IFS= read -r path; do
  [ -n "$path" ] && yml_files+=("$path")
done < <(find .github -name '*.yml' -o -name '*.yaml' 2>/dev/null | sort)

printf '== self-tests ==\n'
if [ "$lint_only" = 1 ]; then
  mark self-tests "SKIP (--lint-only)"
else
  for skill in "$root"/skills/*/; do
    name=$(basename "$skill")
    case $name in *"$filter"*) ;; *) continue ;; esac
    test_script="$skill/references/selftest.sh"
    if [ ! -f "$test_script" ]; then
      mark "$name" "SKIP (no selftest.sh)"
      continue
    fi
    ran=$((ran + 1))
    if out=$(bash "$test_script" 2>&1); then
      mark "$name" PASS
    else
      mark "$name" FAIL
      if [ "${VERIFY_VERBOSE:-0}" = 1 ]; then
        printf '%s\n' "$out" | tail -120 | sed 's/^/    /'
      else
        printf '%s\n' "$out" | grep -E '^FAIL|selftest FAILED' | sed 's/^/    /'
      fi
      fail=1
    fi
  done
  if [ "$ran" -eq 0 ]; then
    echo "no matching skill self-tests" >&2
    exit 1
  fi
fi

printf '\n== engineering ==\n'
run_check contract python3 scripts/check_contract.py "$filter"

if command -v shellcheck >/dev/null; then
  run_check shellcheck shellcheck -S warning "${sh_files[@]}"
else
  mark shellcheck "SKIP (not installed)"
fi

if command -v shfmt >/dev/null; then
  run_check shfmt shfmt -d -s -i 2 -ci "${sh_files[@]}"
else
  mark shfmt "SKIP (not installed)"
fi

if command -v ruff >/dev/null; then
  run_check ruff ruff check skills scripts
  run_check ruff-format ruff format --check skills scripts
else
  mark ruff "SKIP (not installed)"
  mark ruff-format "SKIP (not installed)"
fi

run_check shell-compat python3 scripts/check_shell_compat.py

if command -v markdownlint-cli2 >/dev/null; then
  run_check markdownlint markdownlint-cli2 "${md_files[@]}"
else
  mark markdownlint "SKIP (not installed)"
fi

swift_src=skills/2d-understanding/references/ocr.swift
if [ "$(uname -s)" != Darwin ]; then
  mark swift-typecheck "SKIP (AppKit/Vision are macOS-only)"
elif command -v swiftc >/dev/null; then
  run_check swift-typecheck swiftc -typecheck "$swift_src"
else
  mark swift-typecheck "SKIP (not installed)"
fi

if [ "${#yml_files[@]}" -gt 0 ]; then
  if command -v yamllint >/dev/null; then
    run_check yamllint yamllint "${yml_files[@]}"
  else
    mark yamllint "SKIP (not installed)"
  fi
  if [ -d .github/workflows ] && command -v actionlint >/dev/null; then
    # actionlint only understands workflow files; issue templates are not workflows.
    run_check actionlint actionlint .github/workflows/*.yml
  elif [ -d .github/workflows ]; then
    mark actionlint "SKIP (not installed)"
  fi
fi

echo
if [ "$fail" = 0 ]; then
  echo "verify: all green"
else
  echo "verify: FAILED" >&2
  exit 1
fi
