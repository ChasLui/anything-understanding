#!/usr/bin/env bash
# Compile-once Vision OCR wrapper (macOS only).
#   ocr.sh shot.png                 # TSV: confidence, x, y, w, h, text
#   ocr.sh shot.png --json          # JSON with normalized bboxes
#   ocr.sh shot.png --lang zh-Hans,en-US --json
#
# Vision can return zero lines without any error. Measured 2026-11-21 (macOS 26,
# 7680x3240 Retina screenshot, dark UI): whole image 0 lines; the same pixels
# cropped to 3700x1562 -> 57 lines; the same image *resampled* to 3700x1562 ->
# 0 lines (LANCZOS and NEAREST); 3840x900 region crops -> 19..37 lines. So this
# is not a clean edge/area limit and resampling itself can erase whole regions.
# Cropping is the reliable fix (see SKILL.md); the downscale below is only a
# guard against silent all-zero output. Bboxes stay normalized, so they still map
# onto the original image; only pixel precision drops.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ $# -lt 1 ]; then
  echo "usage: ocr.sh <image> [--lang a,b] [--json]" >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ] || ! command -v swiftc >/dev/null; then
  echo "ocr.sh needs macOS + Xcode command line tools (swiftc)" >&2
  exit 2
fi
image=$1
shift
max_edge=${OCR_MAX_EDGE:-3200}

tmp=""
cleanup() { [ -z "$tmp" ] || rm -f "$tmp"; }
trap cleanup EXIT
read -r width height <<<"$(sips -g pixelWidth -g pixelHeight "$image" 2>/dev/null |
  awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w" "h}')"
# sips prints "<nil>" for files it cannot measure; never feed that to [ -gt ].
case "${width:-}" in '' | *[!0-9]*) width="" ;; esac
case "${height:-}" in '' | *[!0-9]*) height="" ;; esac
if [ -n "${width:-}" ] && [ -n "${height:-}" ]; then
  long_edge=$width
  [ "$height" -gt "$width" ] && long_edge=$height
  if [ "$long_edge" -gt "$max_edge" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/ocr-XXXXXX.png")
    sips -Z "$max_edge" --out "$tmp" "$image" >/dev/null 2>&1
    echo "ocr: downscaled ${width}x${height} -> long edge $max_edge for Vision" >&2
    image=$tmp
  fi
fi

cache=${OCR_CACHE_DIR:-${TMPDIR:-/tmp}/anything-understanding-ocr}
mkdir -p "$cache"
bin="$cache/ocr-$(shasum -a 256 "$here/ocr.swift" | cut -c1-12)"
if [ ! -x "$bin" ] || [ "$here/ocr.swift" -nt "$bin" ]; then
  swiftc -O "$here/ocr.swift" -o "$bin" >/dev/null
fi
exec "$bin" "$image" "$@"
