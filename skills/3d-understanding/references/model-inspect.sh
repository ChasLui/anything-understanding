#!/usr/bin/env bash
# Inspect any supported 3D asset with one command.
#   model-inspect.sh model.glb                 native glTF/GLB parse
#   model-inspect.sh model.fbx                 assimp -> GLB, same report
#   model-inspect.sh model.obj --gn --json     add post-processing, JSON out
#
# OBJ/FBX/DAE/STL/PLY/3DS go through assimp (brew install assimp).
# assimp applies NO post-processing by default: a missing NORMAL stays missing,
# which is the file's real state. --gn generates normals, --tri triangulates.
# Never round-trip a skinned GLB back through assimp: v6.0.6 rejects its own
# exported inverseBindMatrices. Verify converted files with this script or the
# engine import, never with `assimp info`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <model> [--json] [--gn] [--tri]" >&2
  exit 2
fi

src=$1
shift
ext=${src##*.}
# ${var,,} is bash 4; macOS /bin/bash is 3.2, so lowercase portably.
ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')

json=0
aflags=()
for arg in "$@"; do
  case $arg in
    --json) json=1 ;;
    --gn) aflags+=(-gn) ;;
    --tri) aflags+=(-tri) ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

json_args=()
[ "$json" -eq 1 ] && json_args+=(--json)

case $ext in
  glb | gltf)
    if [ ${#aflags[@]} -gt 0 ]; then
      echo "--gn/--tri only apply to formats converted through assimp" >&2
      exit 2
    fi
    exec python3 "$here/glb-inspect.py" "$src" "${json_args[@]+"${json_args[@]}"}"
    ;;
esac

if ! command -v assimp >/dev/null 2>&1; then
  echo "assimp not found; install with: brew install assimp" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/model-inspect.XXXXXX")
trap 'rm -r "$work"' EXIT
glb="$work/model.glb"
log="$work/assimp.log"

if ! assimp export "$src" "$glb" -fglb2 "${aflags[@]+"${aflags[@]}"}" >"$log" 2>&1 ||
  [ ! -s "$glb" ]; then
  echo "assimp could not convert $src:" >&2
  grep -v -E '^ *[0-9.]+ %|Launching|Validating|^$' "$log" | tail -8 >&2
  exit 1
fi

# assimp can exit 0 and still write a stub GLB for a file it failed to parse.
if ! python3 -c '
import json, struct, sys
data = open(sys.argv[1], "rb").read()
if len(data) < 20 or data[:4] != b"glTF":
    raise SystemExit(1)
length = struct.unpack_from("<I", data, 12)[0]
gltf = json.loads(data[20:20 + length])
raise SystemExit(0 if (gltf.get("meshes") or gltf.get("animations") or gltf.get("skins")) else 1)
' "$glb"; then
  echo "assimp produced no geometry from $src (conversion likely failed):" >&2
  grep -v -E '^ *[0-9.]+ %|Launching|Validating|^$' "$log" | tail -8 >&2
  exit 1
fi

if [ "$json" -eq 1 ]; then
  python3 -c '
import json, sys
report = json.load(sys.stdin)
report["converted_by"] = "assimp"
print(json.dumps(report, ensure_ascii=False, indent=2))
' < <(python3 "$here/glb-inspect.py" "$glb" --json --source "$src")
else
  echo "source: $src (converted by assimp; counts and bounds are post-conversion)"
  python3 "$here/glb-inspect.py" "$glb" --source "$src"
fi
