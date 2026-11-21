#!/usr/bin/env bash
# Inventory of app bundles in the standard install locations.
#   apps.sh                  # table: name / bundle id / version / category
#   apps.sh --count          # number only (after --filter)
#   apps.sh --filter summer  # case-insensitive substring on name or bundle id
#   apps.sh --json           # array of objects
#
# Cost control: each app costs exactly one PlistBuddy call that prints the three
# fields we need. No codesign/spctl/du here - those are per-app deep checks and
# belong in appinfo.sh. Bundles without a usable Info.plist (missing, or a
# stray non-directory *.app) are counted separately on stderr, never dropped
# silently.
#
# Exit codes: 0 ok | 1 usage | 2 nothing found (never for an empty scan) |
#             3 tool missing.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: apps.sh [--json | --count] [--filter SUBSTR]

  Scans /Applications, ~/Applications, /System/Applications and
  /System/Applications/Utilities (one level deep) for *.app bundles and reads
  name (file name), CFBundleIdentifier, CFBundleShortVersionString and
  LSApplicationCategoryType from each Contents/Info.plist.

  --filter SUBSTR  case-insensitive match on app name or bundle id
  --count          print only the number of matches
  --json           print a JSON array

exit: 0 ok | 1 usage | 2 no app bundles found | 3 required tool missing
EOF
}

as_json=0
count_only=0
filter=""
while [ $# -gt 0 ]; do
  case $1 in
    --json) as_json=1 ;;
    --count) count_only=1 ;;
    --filter)
      shift
      if [ $# -eq 0 ]; then
        echo "apps.sh: --filter needs a substring" >&2
        exit 1
      fi
      filter=$1
      ;;
    --filter=*) filter=${1#*=} ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "apps.sh: unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

[ -x /usr/libexec/PlistBuddy ] || {
  echo "apps.sh: needs /usr/libexec/PlistBuddy" >&2
  exit 3
}
for tool in python3 find; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "apps.sh: needs $tool" >&2
    exit 3
  }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/apps.XXXXXX")
trap 'rm -r "$tmp"' EXIT
: >"$tmp/rows"
: >"$tmp/broken"
: >"$tmp/dirs"
# Bundle-derived and filename-derived text is untrusted: strip control
# characters so no value can forge a new \x1f record or emit terminal escapes.
san() {
  local v=${1//[[:cntrl:]]/ }
  printf '%s' "$v"
}

dirs=(
  /Applications
  "${HOME:-/nonexistent}/Applications"
  /System/Applications
  /System/Applications/Utilities
)

total=0
for dir in "${dirs[@]}"; do
  [ -d "$dir" ] || continue
  printf '%s\n' "$dir" >>"$tmp/dirs"
  while IFS= read -r -d '' app; do
    total=$((total + 1))
    plist="$app/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
      printf '%s\0' "$app" >>"$tmp/broken"
      continue
    fi

    # One process per app. A missing key makes PlistBuddy exit non-zero after
    # printing the keys it did find, so the stdout lines are matched against
    # the "Does Not Exist" errors on stderr rather than assumed positional.
    pb_out=$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleIdentifier' \
      -c 'Print :CFBundleShortVersionString' \
      -c 'Print :LSApplicationCategoryType' \
      "$plist" 2>"$tmp/pb.err") || true

    values=()
    if [ -n "$pb_out" ]; then
      while IFS= read -r line; do
        values+=("$line")
      done <<<"$pb_out"
    fi

    idx=0
    bundle_id=""
    version=""
    category=""
    for key in CFBundleIdentifier CFBundleShortVersionString LSApplicationCategoryType; do
      value=""
      if ! grep -qF "\":$key\"" "$tmp/pb.err"; then
        value=${values[$idx]:-}
        idx=$((idx + 1))
      fi
      case $key in
        CFBundleIdentifier) bundle_id=$value ;;
        CFBundleShortVersionString) version=$value ;;
        *) category=$value ;;
      esac
    done

    if [ -z "$bundle_id" ]; then
      printf '%s\0' "$app" >>"$tmp/broken"
      continue
    fi

    base=${app%/}
    base=${base##*/}
    name=${base%.app}
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$(san "$name")" "$(san "$app")" "$(san "$bundle_id")" \
      "$(san "$version")" "$(san "$category")" >>"$tmp/rows"
  done < <(find "$dir" -maxdepth 1 -name '*.app' -print0 2>/dev/null)
done

if [ "$total" -eq 0 ]; then
  echo "apps.sh: no app bundles found in the standard directories" >&2
  exit 2
fi

broken=$(tr -cd '\0' <"$tmp/broken" | wc -c | tr -d ' ')

while IFS= read -r -d '' app; do
  printf 'apps.sh: note: unreadable app bundle (no usable Info.plist): %s\n' \
    "$(san "$app")" >&2
done <"$tmp/broken"
if [ "$broken" -gt 0 ]; then
  printf 'apps.sh: note: %s of %s bundles unreadable; excluded from the list\n' \
    "$broken" "$total" >&2
fi

python3 - "$tmp" "$as_json" "$count_only" "$filter" "$total" "$broken" <<'PY'
import json
import os
import sys

tmp, as_json, count_only, filter_text, total, broken = sys.argv[1:7]
as_json = as_json == "1"
count_only = count_only == "1"
total = int(total)
broken = int(broken)


def read(name):
    path = os.path.join(tmp, name)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def category_label(raw):
    if not raw:
        return None
    prefix = "public.app-category."
    if raw.startswith(prefix):
        return raw[len(prefix):].replace("-", " ").replace("_", " ")
    return raw


home = os.path.expanduser("~")


def display_path(value):
    return "~" + value[len(home):] if value == home or value.startswith(home + os.sep) else value


rows = []
for line in read("rows").splitlines():
    if "\x1f" not in line:
        continue
    parts = line.split("\x1f")
    if len(parts) != 5:
        print(
            "apps.sh: note: malformed inventory row skipped: %r" % line,
            file=sys.stderr,
        )
        continue
    name, path, bundle_id, version, category = parts
    rows.append(
        {
            "name": name,
            "bundle_id": bundle_id,
            "version": version or None,
            "category": category or None,
            "category_label": category_label(category),
            "path": display_path(path),
        }
    )

rows.sort(key=lambda row: (row["name"].casefold(), row["path"]))

if filter_text:
    needle = filter_text.casefold()
    rows = [
        row
        for row in rows
        if needle in row["name"].casefold() or needle in row["bundle_id"].casefold()
    ]

if count_only:
    print(len(rows))
    raise SystemExit(0)

if as_json:
    payload = [
        {
            "name": row["name"],
            "bundle_id": row["bundle_id"],
            "version": row["version"],
            "category": row["category"],
            "category_label": row["category_label"],
            "path": row["path"],
        }
        for row in rows
    ]
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)

home = os.path.expanduser("~")
dirs = []
for line in read("dirs").splitlines():
    if line.startswith(home + "/"):
        line = "~" + line[len(home):]
    dirs.append(line)
footer = "scanned: %s | %d apps | %d unreadable" % (", ".join(dirs), total - broken, broken)
if filter_text:
    footer += " | filter %r: %d match%s" % (
        filter_text,
        len(rows),
        "" if len(rows) == 1 else "es",
    )

if not rows:
    if filter_text:
        print("no match for filter %r" % filter_text)
    print(footer)
    raise SystemExit(0)

width_name = max([len("name")] + [len(row["name"]) for row in rows])
width_id = max([len("bundle id")] + [len(row["bundle_id"]) for row in rows])
width_ver = max([len("version")] + [len(row["version"] or "-") for row in rows])
sys.stdout.write(
    "%-*s  %-*s  %-*s  %s\n"
    % (width_name, "name", width_id, "bundle id", width_ver, "version", "category")
)
for row in rows:
    sys.stdout.write(
        "%-*s  %-*s  %-*s  %s\n"
        % (
            width_name,
            row["name"],
            width_id,
            row["bundle_id"],
            width_ver,
            row["version"] or "-",
            row["category_label"] or "-",
        )
    )

print(footer)
PY
