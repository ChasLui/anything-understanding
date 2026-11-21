#!/usr/bin/env bash
# Symbol outline via ast-grep's bundled tree-sitter parsers (no grammar build).
#   symbols.sh src/                 # TSV: file:line:kind:<first line of node>
#   symbols.sh src/ --json          # {symbols_total, by_kind, skipped_files, symbols}
#   symbols.sh src/ --lang python
#
# Supported (kinds verified against ast-grep 0.50): python, typescript/tsx,
# javascript, go, rust, java. Anything else is reported as skipped, never
# silently dropped. This is a definition outline, not a call graph: for
# references/implementations use an LSP, and label grep results as approximate.
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "usage: symbols.sh <path...> [--json] [--lang L]" >&2
  exit 1
fi
if ! command -v ast-grep >/dev/null; then
  echo "symbols.sh needs ast-grep (brew install ast-grep)" >&2
  exit 1
fi
targets=()
as_json=0
force_lang=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    --lang)
      force_lang=${2:-}
      shift
      ;;
    *) targets+=("$1") ;;
  esac
  shift
done

kinds_for() { # kinds_for <lang> -> space-separated ast-grep kind names
  case "$1" in
    python) echo "function_definition class_definition" ;;
    typescript | tsx) echo "function_declaration class_declaration interface_declaration method_definition" ;;
    javascript) echo "function_declaration class_declaration method_definition" ;;
    go) echo "function_declaration method_declaration type_declaration" ;;
    rust) echo "function_item struct_item impl_item" ;;
    java) echo "method_declaration class_declaration" ;;
    *) echo "" ;;
  esac
}

lang_for() { # lang_for <file> -> ast-grep lang id or empty
  case "${1##*.}" in
    py | pyi) echo python ;;
    ts) echo typescript ;;
    tsx) echo tsx ;;
    js | jsx | mjs | cjs) echo javascript ;;
    go) echo go ;;
    rs) echo rust ;;
    java) echo java ;;
    *) echo "" ;;
  esac
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/symbols.XXXXXX")
trap 'rm -r "$tmp"' EXIT
: >"$tmp/out.tsv"
: >"$tmp/skipped.txt"

for target in "${targets[@]}"; do
  if [ -d "$target" ]; then
    files=$(find "$target" -type f -print 2>/dev/null)
  elif [ -f "$target" ]; then
    files=$target
  else
    echo "no such path: $target" >&2
    continue
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    natural=$(lang_for "$f")
    if [ -z "$natural" ]; then
      echo "$f" >>"$tmp/skipped.txt"
      continue
    fi
    if [ -n "$force_lang" ] && [ "$natural" != "$force_lang" ]; then
      # --lang restricts the scan; files of other languages are listed, not dropped.
      echo "$f" >>"$tmp/skipped.txt"
      continue
    fi
    if ! iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
      # ast-grep exits nonzero on invalid UTF-8; record it instead of dropping it.
      echo "$f" >>"$tmp/skipped.txt"
      continue
    fi
    lang=${force_lang:-$natural}
    for kind in $(kinds_for "$lang"); do
      ast-grep run --kind "$kind" --lang "$lang" --json=stream "$f" 2>/dev/null |
        jq -r --arg kind "$kind" --arg f "$f" \
          'def clean: gsub("\t"; " ") | gsub("[[:cntrl:]]"; "?");
           (.lines | split("\n")[0] | gsub("^\\s+|\\s+$"; "") | .[0:100] | clean) as $first |
           "\($f | clean)\t\(.range.start.line + 1)\t\($kind)\t\($first)"' \
          >>"$tmp/out.tsv" || true
    done
  done <<<"$files"
done

skipped_unique=$(sort -u "$tmp/skipped.txt" 2>/dev/null || true)
skipped_count=$(printf '%s\n' "$skipped_unique" | grep -c . || true)
symbol_count=$(wc -l <"$tmp/out.tsv" | tr -d ' ')

if [ "$as_json" = 1 ]; then
  symbols=$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") |
    {file: .[0], line: (.[1] | tonumber), kind: .[2], text: .[3]})' <"$tmp/out.tsv")
  counts=$(cut -f3 "$tmp/out.tsv" 2>/dev/null | sort | uniq -c |
    awk '{printf "%s\"%s\":%d", sep, $2, $1; sep=","} END {print ""}')
  skipped_json=$(printf '%s\n' "$skipped_unique" |
    jq -R . | jq -sc 'map(select(. != ""))')
  printf '{"symbols_total":%s,"by_kind":{%s},"skipped_files":%s,"symbols":%s}\n' \
    "$symbol_count" "$counts" "$skipped_json" "$symbols"
  exit 0
fi

cut -f1-4 "$tmp/out.tsv" | LC_ALL=C tr '\033' '?'
if [ "$skipped_count" -gt 0 ]; then
  echo "--- skipped ${skipped_count} files (no bundled parser; use grep or an LSP):" >&2
  printf '%s\n' "$skipped_unique" | head -10 | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/    /' >&2
fi
echo "--- ${symbol_count} definitions" >&2
