#!/usr/bin/env bash
# Self-test for the two 3D tools in this skill.
# Usage: bash selftest.sh [-v]
# Part 1 always runs (pure Python glTF math). Part 2 runs when FreeCAD exists.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/3d-selftest.XXXXXX")
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

# --- Part 1: glTF math (instancing, bounds, matrix layout) ----------------
cat >"$work/inst.gltf" <<'EOF'
{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
 "nodes":[{"mesh":0,"translation":[0,0,0]},{"mesh":0,"translation":[10,0,0]}],
 "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1}}]}],
 "accessors":[{"count":3,"type":"VEC3","componentType":5126,"min":[0,0,0],"max":[1,1,1]},
              {"count":3,"type":"VEC3","componentType":5126,"min":[0,0,0],"max":[0,0,1]}]}
EOF

report=$(python3 "$here/glb-inspect.py" "$work/inst.gltf" --json)
counts=$(printf '%s' "$report" | python3 -c 'import json,sys; c=json.load(sys.stdin)["counts"]; print(c["triangles"], c["vertices"], c["primitives"])')
check "instanced triangles/vertices/primitives" "$counts" "2 6 2"
bounds=$(printf '%s' "$report" | python3 -c 'import json,sys; b=json.load(sys.stdin)["bounds"]; print(" ".join(str(round(v,1)) for v in b["max"]))')
check "world bounds max (translation applied)" "$bounds" "11.0 1.0 1.0"

# --- Part 2: STEP round trip (needs FreeCAD) ------------------------------
app=/Applications/FreeCAD.app
cmd=${FREECAD_CMD:-}
if [ -z "$cmd" ] && [ -x "$app/Contents/MacOS/FreeCADCmd" ]; then
  cmd="$app/Contents/MacOS/FreeCADCmd"
fi
if [ -z "$cmd" ]; then
  cmd=$(command -v FreeCADCmd 2>/dev/null || true)
fi

if [ -n "$cmd" ] && [ -x "$cmd" ]; then
  py=""
  run=("$cmd")
elif [ -x "$app/Contents/Resources/bin/python" ]; then
  py="$app/Contents/Resources/bin/python"
  run=(env "PYTHONPATH=$app/Contents/Resources/lib" "$py")
else
  echo "skip STEP round trip: FreeCAD not installed"
fi

if [ -n "$cmd" ] || [ -n "$py" ]; then
  cat >"$work/mk.py" <<'PY'
import sys
import FreeCAD, Part, Import
out = sys.argv[-1]
doc = FreeCAD.newDocument("t")
box = Part.makeBox(40, 30, 20)
hole = Part.makeCylinder(5, 20, FreeCAD.Vector(20, 15, 0))
obj = doc.addObject("Part::Feature", "plate")
obj.Shape = box.cut(hole)
doc.recompute()
Import.export([obj], out)
print("volume=%.2f" % obj.Shape.Volume)
PY
  "${run[@]}" "$work/mk.py" "$work/plate.step" | tail -1 >"$work/mk.out"
  expected=$(sed 's/volume=//' "$work/mk.out")

  bash "$here/step-views.sh" "$work/plate.step" "$work/views" >/dev/null
  actual=$(python3 -c 'import json,sys; print("%.2f" % json.load(open(sys.argv[1]))["totals"]["volume_mm3"])' "$work/views/metrics.json")
  check "STEP round-trip volume mm3" "$actual" "$expected"

  views=$(grep -o '<title>' "$work/views/views.svg" | wc -l | tr -d ' ')
  check "view count" "$views" "14"
  failed=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["unprojected_views"]))' "$work/views/metrics.json")
  check "unprojected views" "$failed" "0"
fi

# --- Part 3: OBJ conversion through assimp (skipped if absent) ------------
if command -v assimp >/dev/null 2>&1; then
  cat >"$work/tri.obj" <<'EOF'
v 0 0 0
v 1 0 0
v 0 1 0
v 1 1 0
f 1 2 4
f 1 4 3
EOF
  obj=$(bash "$here/model-inspect.sh" "$work/tri.obj" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["counts"]["triangles"], d.get("converted_by"))')
  check "OBJ conversion triangles/via" "$obj" "2 assimp"
  # default keeps the source's missing normals; --gn fixes them
  plain=$(bash "$here/model-inspect.sh" "$work/tri.obj" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["issues"]))')
  check "OBJ default keeps missing-NORMAL issue" "$plain" "1"
  gen=$(bash "$here/model-inspect.sh" "$work/tri.obj" --gn --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["issues"]))')
  check "OBJ --gn clears NORMAL issue" "$gen" "0"
else
  echo "skip OBJ conversion: assimp not installed"
fi

# --- conversion stub, instancing, truncated BIN, bad min/max (review regressions) ---
if command -v assimp >/dev/null 2>&1; then
  printf 'this is not an obj file {{{\n' >"$work/garbage.obj"
  set +e
  bash "$here/model-inspect.sh" "$work/garbage.obj" >/dev/null 2>&1
  rc_stub=$?
  set -e
  check "assimp stub conversion rejected" "$rc_stub" "1"
fi

cat >"$work/dag.gltf" <<'JSON'
{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],"nodes":[{"name":"a","children":[2],"translation":[0,0,0]},{"name":"b","children":[2],"translation":[100,0,0]},{"name":"wheel","mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"count":3,"type":"VEC3","componentType":5126,"min":[0,0,0],"max":[1,1,1]}]}
JSON
out=$(python3 "$here/glb-inspect.py" "$work/dag.gltf" --json)
check "instanced node bounds include both parents" \
  "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["bounds"]["size"][0])' "$out")" "101.0"

python3 - "$work/nobin.glb" <<'PY'
import json, struct, sys
j = json.dumps({"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"buffers":[{"byteLength":36}],"accessors":[{"count":3,"type":"VEC3","componentType":5126,"min":[0,0,0],"max":[1,1,1]}]}).encode()
open(sys.argv[1], "wb").write(b"glTF" + struct.pack("<II", 2, 12 + 8 + len(j)) + struct.pack("<II", len(j), 0x4E4F534A) + j)
PY
out=$(python3 "$here/glb-inspect.py" "$work/nobin.glb" --json)
check "truncated BIN reported" \
  "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(any("BIN" in i for i in d["issues"]))' "$out")" "True"

cat >"$work/badmin.gltf" <<'JSON'
{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"count":3,"type":"VEC3","componentType":5126,"min":[0,0],"max":[1,1,1]}]}
JSON
out=$(python3 "$here/glb-inspect.py" "$work/badmin.gltf" --json)
check "invalid min/max reported" \
  "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["bounds"] is None and any("min/max" in i for i in d["issues"]))' "$out")" "True"

if [ "$fail" -ne 0 ]; then
  echo "selftest FAILED" >&2
  exit 1
fi
echo "selftest passed"
