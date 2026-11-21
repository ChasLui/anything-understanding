#!/usr/bin/env bash
# Repository inventory: what is in this repo before you read any of it.
#   repo-map.sh [path]            # human summary
#   repo-map.sh [path] --json     # machine-readable
#   repo-map.sh [path] --churn 500
#
# Answers: languages and their weight, entry points, manifests, test layout,
# generated/vendored areas to skip, largest files, and the files that change
# most (read those first). It does not parse code; pair it with symbols.sh or
# an LSP for structure. JSON is assembled by python3, so no jq is required.
set -euo pipefail
root=${1:-.}
[ $# -gt 0 ] && shift || true
churn_window=200
as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    --churn)
      churn_window=${2:-200}
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done
cd "$root"
root=$(pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/repo-map.XXXXXX")
trap 'rm -r "$tmp"' EXIT

is_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && is_git=1
list_files() {
  find . \( -path ./.git -o -path ./node_modules -o -path ./vendor -o -path ./dist -o -path ./build \) -prune \
    -o -type f -print | sed 's|^\./||'
}
# --cached --others: tracked plus untracked-but-not-ignored, so an unborn branch
# and a fresh work tree report the same files a human sees in the editor.
git -c core.quotepath=false ls-files --cached --others --exclude-standard >"$tmp/files" 2>/dev/null || true
[ -s "$tmp/files" ] || list_files >"$tmp/files"
file_count=$(wc -l <"$tmp/files" | tr -d ' ')

# One pass for line counts; binary files are skipped (grep -I).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  printf '%s\t%s\n' "$(wc -l <"$f" | tr -d ' ')" "$f"
done <"$tmp/files" >"$tmp/loc"

awk -F'\t' '{n=split($2,a,"."); if (n>1) {loc[a[n]]+=$1; files[a[n]]++}}
  END {for (e in files) printf "%d\t%d\t%s\n", loc[e], files[e], e}' "$tmp/loc" |
  sort -rn | head -12 >"$tmp/ext"
sort -rn "$tmp/loc" | head -10 >"$tmp/largest"

manifests=""
for m in package.json pyproject.toml setup.py requirements.txt go.mod Cargo.toml \
  pom.xml build.gradle Gemfile composer.json Makefile Justfile Dockerfile \
  compose.yaml tsconfig.json; do
  [ -f "$m" ] && manifests+="$m "
done

entries=""
for f in package.json main.py app.py manage.py cli.py __main__.py server.py \
  index.ts index.js src/index.ts src/main.ts src/main.rs; do
  [ -f "$f" ] && entries+="$f "
done
while IFS= read -r f; do
  entries+="$f "
done < <(find . -maxdepth 4 -name main.go -not -path './vendor/*' 2>/dev/null | sed 's|^\./||' | head -5)

test_files=$(grep -cE '(^|/)(tests?|__tests__|spec)/|(_test|\.test|\.spec|_spec)\.|(^|/)selftest\.sh$' "$tmp/files" || true)
generated=$(grep -cE '(\.min\.(js|css)$|_pb2\.py$|\.generated\.|\.lock$)' "$tmp/files" || true)
vendored=$(grep -oE '^(vendor|third_party|node_modules|dist|build|target|\.next)/' "$tmp/files" | sed 's|/$||' | sort -u | paste -sd, - || true)

git_line="not a git work tree"
churn_file=""
if [ "$is_git" = 1 ]; then
  # Unborn branches and empty repos must not trip `set -e -o pipefail`.
  head=$(git rev-parse --short HEAD 2>/dev/null || true)
  branch=$(git branch --show-current 2>/dev/null || true)
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)
  last=$(git log -1 --format=%cI 2>/dev/null || true)
  git_line="${branch:-no-branch} @ ${head:-no-commit}, ${dirty:-0} dirty, last ${last:-never}"
  churn_file="$tmp/churn"
  {
    git -c core.quotepath=false log --format= --name-only -n "$churn_window" 2>/dev/null || true
  } | grep -v '^$' | sort | uniq -c | sort -rn | head -10 |
    awk '{count = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print count "\t" $0}' >"$churn_file" || true
fi

if [ "$as_json" = 1 ]; then
  ROOT="$root" FILE_COUNT="$file_count" MANIFESTS="$manifests" ENTRIES="$entries" \
    TESTS="$test_files" GENERATED="$generated" VENDORED="$vendored" \
    IS_GIT="$is_git" GIT_LINE="$git_line" CHURN="$([ -n "$churn_file" ] && cat "$churn_file" || true)" \
    python3 - "$tmp/loc" "$tmp/ext" "$tmp/largest" <<'PY'
import json, os, sys

loc_path, ext_path, largest_path = sys.argv[1:4]

def rows(path):
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line:
                out.append(line.split("\t"))
    return out

git = None
if os.environ.get("IS_GIT") == "1":
    line = os.environ.get("GIT_LINE", "")
    branch, _, rest = line.partition(" @ ")
    head, _, tail = rest.partition(", ")
    dirty, _, last = tail.partition(", last ")
    git = {"head": head, "branch": branch,
           "dirty_files": int(dirty.split()[0] or 0), "last_commit": last}

churn = [{"commits": int(c), "file": f}
         for c, f in (ln.split("\t") for ln in os.environ.get("CHURN", "").splitlines() if ln)]

report = {
    "root": os.environ["ROOT"],
    "files": int(os.environ["FILE_COUNT"]),
    "manifests": os.environ["MANIFESTS"].split(),
    "entry_points": os.environ["ENTRIES"].split(),
    "test_files": int(os.environ["TESTS"] or 0),
    "generated_suspects": int(os.environ["GENERATED"] or 0),
    "vendored_dirs": [d for d in os.environ["VENDORED"].split(",") if d],
    "extensions": [{"ext": e, "lines": int(l), "files": int(n)} for l, n, e in (r for r in rows(ext_path))],
    "largest": [{"lines": int(l), "file": f} for l, f in rows(largest_path)],
    "churn": churn,
    "git": git,
}
print(json.dumps(report, indent=2))
PY
  exit 0
fi

clean() { LC_ALL=C sed 's/[[:cntrl:]]/?/g'; }
echo "root: $root" | clean
echo "git: $git_line"
echo "files: $file_count"
echo "weights (lines/files): $(awk -F'\t' '{printf "%s(%d/%d) ", $3, $1, $2}' "$tmp/ext")"
echo "entry points: ${entries:-none found}" | clean
echo "manifests: ${manifests:-none}"
echo "tests: ${test_files} files"
echo "skip: ${generated} generated/lock files, vendored: ${vendored:-none}"
echo "largest files:"
awk -F'\t' '{printf "  %6d  %s\n", $1, $2}' "$tmp/largest" | clean
if [ -n "$churn_file" ] && [ -s "$churn_file" ]; then
  echo "hotspots (last $churn_window commits):"
  awk -F'\t' '{printf "  %3d  %s\n", $1, $2}' "$churn_file" | clean
fi
