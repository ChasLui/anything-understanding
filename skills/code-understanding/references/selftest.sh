#!/usr/bin/env bash
# Self-test for repo-map.sh and symbols.sh. Builds a throwaway git repo.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/code-selftest.XXXXXX")
trap 'rm -r "$work"' EXIT
fail=0

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "ok   $1 = $2"
  else
    echo "FAIL $1 = $2 (expected $3)" >&2
    fail=1
  fi
}
jqpy() { python3 -c "import json,sys; print(eval(sys.argv[1], {'d': json.load(sys.stdin)}))" "$1"; }

mkdir -p "$work/repo/src/nested" "$work/repo/tests" "$work/repo/vendor"
cd "$work/repo"
git init -q .
printf 'def f(x):\n    return x+1\n\nclass K:\n    def g(self): pass\n' >src/a.py
printf 'export function h(a){return a}\nexport class C { m(){return 1} }\n' >src/b.ts
printf 'package main\n\nfunc F(a int) error { return nil }\n\ntype T struct{ X int }\n\nfunc (t T) M() {}\n\nfunc main(){}\n' >src/nested/main.go
printf 'x = 1\n' >tests/test_a.py
printf 'def r; end\n' >src/legacy.rb
echo '# doc' >README.md
echo '{"name":"x"}' >package.json
echo 'junk' >vendor/lib.min.js
git add -A
git -c user.email=t@t -c user.name=t commit -qm init
printf 'y = 2\n' >>src/a.py
git -c user.email=t@t -c user.name=t commit -qam second

# --- repo-map ---
out=$(bash "$here/repo-map.sh" . --json)
check "files counted" "$(jqpy 'd["files"]' <<<"$out")" "8"
check "git branch detected" "$(jqpy 'd["git"]["dirty_files"]' <<<"$out")" "0"
check "go entry point" "$(jqpy '"src/nested/main.go" in d["entry_points"]' <<<"$out")" "True"
check "manifest" "$(jqpy '"package.json" in d["manifests"]' <<<"$out")" "True"
check "test files heuristic" "$(jqpy 'd["test_files"]' <<<"$out")" "1"
check "generated/lock suspects" "$(jqpy 'd["generated_suspects"]' <<<"$out")" "1"
check "vendored dir" "$(jqpy 'd["vendored_dirs"]' <<<"$out")" "['vendor']"
check "python loc" "$(jqpy '[e["lines"] for e in d["extensions"] if e["ext"]=="py"][0]' <<<"$out")" "7"
check "hotspot is the twice-edited file" "$(jqpy 'd["churn"][0]["file"]' <<<"$out")" "src/a.py"
check "hotspot count" "$(jqpy 'd["churn"][0]["commits"]' <<<"$out")" "2"

# Unborn repo (git init, nothing committed): git knows no files, must not crash.
mkdir -p "$work/fresh"
cd "$work/fresh" && git init -q . && printf 'a=1\n' >x.py
out=$(bash "$here/repo-map.sh" . --json)
check "unborn repo falls back to filesystem" "$(jqpy 'd["files"]' <<<"$out")" "1"
check "unborn repo reports no commits" "$(jqpy 'd["git"]["head"]' <<<"$out")" "no-commit"
cd "$work/repo"

# Non-git copy: no churn, git null.
cp -R "$work/repo" "$work/plain"
rm -rf "$work/plain/.git"
out=$(bash "$here/repo-map.sh" "$work/plain" --json)
check "non-git has no git field" "$(jqpy 'd["git"]' <<<"$out")" "None"
check "non-git still counts files" "$(jqpy 'd["files"] > 0' <<<"$out")" "True"

# --- symbols ---
if command -v ast-grep >/dev/null; then
  out=$(bash "$here/symbols.sh" src --json)
  check "python defs" "$(jqpy 'd["by_kind"]["function_definition"]' <<<"$out")" "2"
  check "python class" "$(jqpy 'd["by_kind"]["class_definition"]' <<<"$out")" "1"
  check "function_declaration spans go+ts" "$(jqpy 'd["by_kind"]["function_declaration"]' <<<"$out")" "3"
  check "go methods" "$(jqpy 'd["by_kind"]["method_declaration"]' <<<"$out")" "1"
  check "ts class" "$(jqpy 'd["by_kind"]["class_declaration"]' <<<"$out")" "1"
  check "ruby file reported, not dropped" "$(jqpy 'd["skipped_files"]' <<<"$out")" "['src/legacy.rb']"
  check "symbol total" "$(jqpy 'd["symbols_total"]' <<<"$out")" "10"
  tsv=$(bash "$here/symbols.sh" src/a.py 2>/dev/null)
  check "tsv has file:line:kind" "$(printf '%s' "$tsv" | head -1)" "$(printf 'src/a.py\t1\tfunction_definition\tdef f(x):')"
else
  echo "skip symbols.sh (ast-grep not installed)"
fi

# --- churn filenames with spaces; --lang is a filter, not a silent drop ---
mkdir -p "$work/churn"
(
  cd "$work/churn" || exit 1
  git init -q .
  git config user.email t@t
  git config user.name t
  : >'a b.py'
  git add -A
  git commit -qm one
  echo x >>'a b.py'
  git commit -qam two
)
out=$(bash "$here/repo-map.sh" "$work/churn" --json)
check "churn keeps spaces" "$(jqpy 'd["churn"][0]["file"]' <<<"$out")" "a b.py"

mkdir -p "$work/mixed"
printf 'def f():\n    pass\n' >"$work/mixed/x.py"
printf 'def g\nend\n' >"$work/mixed/x.rb"
out=$(bash "$here/symbols.sh" "$work/mixed" --lang python --json)
check "other languages listed as skipped" \
  "$(jqpy 'any(p.endswith("x.rb") for p in d["skipped_files"])' <<<"$out")" "True"

# --- git quotepath and invalid UTF-8 (review regressions) ---
mkdir -p "$work/cjk"
(
  cd "$work/cjk" || exit 1
  git init -q .
  git config user.email t@t
  git config user.name t
  printf 'def f():\n    pass\n' >'中文文件.py'
  git add -A
  git commit -qm one
)
out=$(bash "$here/repo-map.sh" "$work/cjk" --json)
check "non-ASCII filename kept" "$(jqpy 'd["churn"][0]["file"]' <<<"$out")" "中文文件.py"

mkdir -p "$work/badutf8"
printf '# caf\xe9\ndef b(): pass\n' >"$work/badutf8/bad.py"
out=$(bash "$here/symbols.sh" "$work/badutf8" --json)
check "invalid UTF-8 listed as skipped" \
  "$(jqpy 'any(p.endswith("bad.py") for p in d["skipped_files"])' <<<"$out")" "True"

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
