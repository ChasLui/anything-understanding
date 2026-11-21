#!/usr/bin/env bash
# Pixel-level image comparison: RMSE, PSNR, differing-pixel ratio, diff PNG.
#   image-diff.sh before.png after.png [diff.png]
#   image-diff.sh a.png b.png --json
# Exit 0 = compared; 1 = usage error; 3 = not byte-identical (usable in CI).
#
# Metrics are verified against ImageMagick 7.1.2: RMSE = 0 for identical files,
# AE = differing pixel count at 1% fuzz. SSIM is deliberately not reported:
# IM7's compare prints it as a dissimilarity (0 for identical), which reads
# backwards next to every other tool.
#
# Only frame 0 is compared; append [N] to the paths yourself for other frames.
set -euo pipefail
if [ $# -lt 2 ]; then
  echo "usage: image-diff.sh <a> <b> [diff.png] [--json]" >&2
  exit 1
fi
if ! command -v magick >/dev/null; then
  echo "image-diff.sh needs ImageMagick 7 (magick)" >&2
  exit 1
fi
a=$1 b=$2
shift 2
diff_out=""
as_json=0
num_or_null() { # numeric -> as-is, anything else -> null
  case "$1" in
    '' | *[!0-9.eE+-]*) echo null ;;
    *) echo "$1" ;;
  esac
}
for arg in "$@"; do
  case "$arg" in
    --json) as_json=1 ;;
    *) diff_out=$arg ;;
  esac
done

frame_a="${a}[0]"
frame_b="${b}[0]"
dim_a=$(magick identify -format '%wx%h' "$frame_a")
dim_b=$(magick identify -format '%wx%h' "$frame_b")
same_size=0
[ "$dim_a" = "$dim_b" ] && same_size=1

raw_metric() { # raw_metric <name> -> "absolute normalized" (ImageMagick stderr)
  magick compare -metric "$1" "$frame_a" "$frame_b" null: 2>&1 | head -1 || true
}

rmse=""
psnr=""
diff_ratio="null"
if [ "$same_size" = 1 ]; then
  read -r _abs rmse_norm <<<"$(raw_metric RMSE)"
  rmse=$(num_or_null "${rmse_norm//[()]/}")
  psnr=$(num_or_null "$(raw_metric PSNR | awk '{print $1}')")
  ae=$(raw_metric AE | awk '{print $1}')
  if echo "$ae" | grep -qE '^[0-9]+$'; then
    w=${dim_a%x*} h=${dim_a#*x}
    diff_ratio=$(awk -v ae="$ae" -v w="$w" -v h="$h" 'BEGIN{printf "%.6f", ae/(w*h)}')
  fi
  if [ -n "$diff_out" ]; then
    magick compare "$frame_a" "$frame_b" "$diff_out" 2>/dev/null || true
  fi
fi
identical=0
cmp -s "$a" "$b" && identical=1

if [ "$as_json" = 1 ]; then
  A="$a" B="$b" SAME="$same_size" DIMA="$dim_a" DIMB="$dim_b" IDENT="$identical" \
    RMSE="${rmse:-null}" PSNR="${psnr:-null}" RATIO="$diff_ratio" DIFF="$diff_out" \
    python3 - <<'PY'
import json
import os

def number(name):
    value = os.environ[name]
    if value == "null":
        return None
    parsed = float(value)
    return int(parsed) if parsed.is_integer() else parsed

print(
    json.dumps(
        {
            "a": os.environ["A"],
            "b": os.environ["B"],
            "same_size": bool(int(os.environ["SAME"])),
            "size_a": os.environ["DIMA"],
            "size_b": os.environ["DIMB"],
            "identical_bytes": bool(int(os.environ["IDENT"])),
            "rmse": number("RMSE"),
            "psnr": number("PSNR"),
            "diff_ratio": float(os.environ["RATIO"]),
            "diff": os.environ["DIFF"],
        }
    )
)
PY
else
  echo "a: $a ($dim_a)"
  echo "b: $b ($dim_b)"
  if [ "$same_size" = 1 ]; then
    echo "identical_bytes: $identical"
    echo "rmse(normalized 0..1): ${rmse:-unsupported}  psnr: ${psnr:-unsupported}"
    echo "diff_ratio: $diff_ratio  (pixels differing at 1% fuzz)"
    [ -n "$diff_out" ] && echo "diff image: $diff_out"
  else
    echo "! sizes differ: no pixel metrics; compare geometry/layout instead"
  fi
fi
[ "$identical" = 1 ] && exit 0 || exit 3
