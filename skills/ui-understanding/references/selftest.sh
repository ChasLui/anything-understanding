#!/usr/bin/env bash
# Self-test for the UI tools. Asserts contrast math against published values and
# geometry checks against hand-computed rectangles. No browser, no network.
#   bash selftest.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ui-selftest.XXXXXX")
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

# --- contrast: WCAG reference values ---
out=$(python3 "$here/contrast.py" "#000000" "#ffffff" --json)
check "black on white ratio" "$(jqpy 'd["ratio"]' <<<"$out")" "21.0"
check "black on white AA" "$(jqpy 'd["aa_text"]["pass"]' <<<"$out")" "True"

out=$(python3 "$here/contrast.py" "#777777" "#ffffff" --json)
check "grey 777 ratio" "$(jqpy 'd["ratio"]' <<<"$out")" "4.48"
check "grey 777 fails AA" "$(jqpy 'd["aa_text"]["pass"]' <<<"$out")" "False"

out=$(python3 "$here/contrast.py" "#767676" "#ffffff" --json)
check "grey 767676 passes AA" "$(jqpy 'd["aa_text"]["pass"]' <<<"$out")" "True"

out=$(python3 "$here/contrast.py" "#ff0000" "#ffffff" --json)
check "red on white ratio" "$(jqpy 'd["ratio"]' <<<"$out")" "4.0"
check "red normal fails AA" "$(jqpy 'd["aa_text"]["pass"]' <<<"$out")" "False"

out=$(python3 "$here/contrast.py" "#ff0000" "#ffffff" --font-size 24 --json)
check "red 24px is large text" "$(jqpy 'd["large_text"]' <<<"$out")" "True"
check "red large passes AA" "$(jqpy 'd["aa_text"]["pass"]' <<<"$out")" "True"
check "red large fails AAA" "$(jqpy 'd["aaa_text"]["pass"]' <<<"$out")" "False"

out=$(python3 "$here/contrast.py" "#ff0000" "#ffffff" --font-size 19 --bold --json)
check "19px bold is large" "$(jqpy 'd["large_text"]' <<<"$out")" "True"
out=$(python3 "$here/contrast.py" "#ff0000" "#ffffff" --font-size 18 --bold --json)
check "18px bold is not large" "$(jqpy 'd["large_text"]' <<<"$out")" "False"

out=$(python3 "$here/contrast.py" "rgba(0,0,0,0.54)" "#ffffff" --json)
check "54% black composites to 757575" "$(jqpy 'd["composited_foreground"]' <<<"$out")" "#757575"
check "54% black ratio" "$(jqpy 'd["ratio"]' <<<"$out")" "4.59"

out=$(python3 "$here/contrast.py" "#0b57d0" "#ffffff" --json)
check "ui colour passes AA UI" "$(jqpy 'd["aa_ui"]["pass"]' <<<"$out")" "True"

set +e
msg=$(python3 "$here/contrast.py" "not-a-color" "#ffffff" 2>&1)
rc=$?
set -e
check "bad colour rejected rc" "$rc" "1"
check "bad colour message" "$(grep -c 'unsupported color' <<<"$msg")" "1"

out=$(python3 "$here/contrast.py" "#949494" "#ffffff" --json)
check "contrast 949494 = 3.03" "$(jqpy 'd["ratio"]' <<<"$out")" "3.03"

# --- geometry: rectangles chosen so every expected number is hand-checkable ---
cat >"$work/boxes.json" <<'JSON'
{
  "unit": "css-px",
  "boxes": [
    {"name": "ok",      "x": 0,   "y": 0,  "w": 100, "h": 40},
    {"name": "tiny",    "x": 200, "y": 0,  "w": 20,  "h": 20},
    {"name": "overlap", "x": 50,  "y": 20, "w": 100, "h": 40},
    {"name": "edge",    "x": 280, "y": 150, "w": 40, "h": 40},
    {"name": "broken",  "x": 0,   "y": 0,  "w": 0,   "h": 10}
  ]
}
JSON

out=$(python3 "$here/geometry.py" "$work/boxes.json" --viewport 300x200 --json)
check "geometry boxes parsed" "$(jqpy 'len(d["boxes"])' <<<"$out")" "5"
check "geometry unit" "$(jqpy 'd["unit"]' <<<"$out")" "css-px"
check "geometry too small" "$(jqpy 'sorted(d["too_small"])' <<<"$out")" "['tiny']"
check "geometry non-positive flagged" "$(jqpy 'any(p["kind"]=="non_positive" for p in d["problems"])' <<<"$out")" "True"
check "geometry malformed flagged" "$(jqpy 'any(p["kind"]=="malformed" for p in d["problems"])' <<<"$out")" "False"
check "geometry overlap count" "$(jqpy 'len(d["overlaps"])' <<<"$out")" "1"
check "geometry overlap area" "$(jqpy 'd["overlaps"][0]["area"]' <<<"$out")" "1000.0"
check "geometry outside viewport" "$(jqpy '[o["box"] for o in d["outside_viewport"]]' <<<"$out")" "['edge']"

out=$(python3 "$here/geometry.py" "$work/boxes.json" --platform ios --json)
check "ios minimum applied" "$(jqpy 'd["minimum"]' <<<"$out")" "44.0"
check "ios flags short boxes" "$(jqpy 'sorted(d["too_small"])' <<<"$out")" "['edge', 'ok', 'overlap', 'tiny']"

python3 - "$work/bad.json" <<'PY'
import json, sys
json.dump({"unit": "pt", "boxes": [{"name": "nope", "x": 0}]}, open(sys.argv[1], "w"))
PY
out=$(python3 "$here/geometry.py" "$work/bad.json" --json)
check "malformed box flagged" "$(jqpy 'any(p["kind"]=="malformed" for p in d["problems"])' <<<"$out")" "True"

# --- invalid color values and geometry inputs (review regressions) ---
set +e
python3 "$here/contrast.py" 'rgba(0,0,0,2)' '#ffffff' >/dev/null 2>&1
rc_alpha=$?
python3 "$here/contrast.py" 'rgb(300,0,0)' '#ffffff' >/dev/null 2>&1
rc_channel=$?
python3 "$here/contrast.py" '#000000' 'rgba(255,255,255,0.5)' >/dev/null 2>&1
rc_translucent=$?
set -e
check "out-of-range alpha rejected" "$rc_alpha" "1"
check "out-of-range channel rejected" "$rc_channel" "1"
check "translucent background rejected" "$rc_translucent" "1"

python3 - "$work/hostile.json" <<'PY'
import json, sys
json.dump({"boxes": [{"name": "nan", "x": 0, "y": 0, "w": float("nan"), "h": 10}, 7]}, open(sys.argv[1], "w"))
PY
out=$(python3 "$here/geometry.py" "$work/hostile.json" --json)
check "NaN box flagged" "$(jqpy 'sum(1 for p in d["problems"] if p["kind"]=="malformed")' <<<"$out")" "2"
check "non-finite values not emitted" "$(jqpy '"NaN" not in str(d) and "Infinity" not in str(d)' <<<"$out")" "True"

# --- DPR scaling and a dict without boxes (review regressions) ---
python3 - "$work/device.json" <<'PY'
import json, sys
json.dump({"unit": "px", "boxes": [{"name": "btn", "x": 0, "y": 0, "w": 40, "h": 40}]}, open(sys.argv[1], "w"))
PY
out=$(python3 "$here/geometry.py" "$work/device.json" --dpr 2 --json)
check "device px scales the minimum" "$(jqpy 'd["minimum"]' <<<"$out")" "48.0"
set +e
python3 "$here/geometry.py" "$work/typo.json" >/dev/null 2>&1
rc_missing=1
set -e
python3 - "$work/typo.json" <<'PY'
import json, sys
json.dump({"unit": "css-px", "box": [{"name": "btn", "x": 0, "y": 0, "w": 10, "h": 10}]}, open(sys.argv[1], "w"))
PY
set +e
python3 "$here/geometry.py" "$work/typo.json" >/dev/null 2>&1
rc_missing=$?
set -e
check "missing boxes key is an error" "$rc_missing" "1"

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
