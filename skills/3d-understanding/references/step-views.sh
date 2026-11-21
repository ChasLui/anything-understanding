#!/usr/bin/env bash
# STEP -> view sheet + metrics, headless.
# Usage: step-views.sh model.step outdir [--density 7.85] [--hidden]
#
# Interpreter resolution order:
#   1. $FREECAD_CMD (a FreeCADCmd binary)
#   2. /Applications/FreeCAD.app/Contents/MacOS/FreeCADCmd
#   3. FreeCADCmd on PATH
#   4. macOS app bundle: Contents/Resources/bin/python + PYTHONPATH=Resources/lib
#
# The macOS cask (1.1.4) ships no FreeCADCmd, so path 4 is the normal one.
# Rasterizes the sheet to PNG with QuickLook, so vision models can read it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/step-views.py"

if [ $# -lt 2 ]; then
  echo "usage: $(basename "$0") model.step outdir [--density 7.85] [--hidden]" >&2
  exit 2
fi

model=$1
outdir=$2
shift 2
mkdir -p "$outdir"

app=/Applications/FreeCAD.app
cmd=${FREECAD_CMD:-}
if [ -z "$cmd" ] && [ -x "$app/Contents/MacOS/FreeCADCmd" ]; then
  cmd="$app/Contents/MacOS/FreeCADCmd"
fi
if [ -z "$cmd" ]; then
  cmd=$(command -v FreeCADCmd 2>/dev/null || true)
fi

if [ -n "$cmd" ] && [ -x "$cmd" ]; then
  "$cmd" "$script" -- "$model" "$outdir" "$@"
elif [ -x "$app/Contents/Resources/bin/python" ]; then
  PYTHONPATH="$app/Contents/Resources/lib" \
    "$app/Contents/Resources/bin/python" "$script" -- "$model" "$outdir" "$@"
else
  echo "FreeCAD not found; install with: brew install --cask freecad" >&2
  exit 1
fi

if [ -f "$outdir/views.svg" ] && command -v qlmanage >/dev/null 2>&1; then
  qlmanage -t -s 1600 -o "$outdir" "$outdir/views.svg" >/dev/null 2>&1 || true
  if [ -f "$outdir/views.svg.png" ]; then
    mv -f "$outdir/views.svg.png" "$outdir/views.png"
  fi
fi

printf '\nartifacts:\n'
ls -1 "$outdir"
