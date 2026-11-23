#!/usr/bin/env bash
# Self-test for the 2D tools. Builds fixtures, asserts measured fields.
#   bash selftest.sh            # OCR runs only if a compiled binary is cached
#   OCR_TEST=1 bash selftest.sh # compile + run OCR (slow on first call)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/2d-selftest.XXXXXX")
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

python3 - "$work" <<'PY'
import sys
from PIL import Image, ImageDraw
w = sys.argv[1]
rgba = Image.new("RGBA", (200, 100), (255, 255, 255, 0))
ImageDraw.Draw(rgba).rectangle([20, 20, 80, 80], fill=(255, 0, 0, 255))
rgba.save(f"{w}/alpha.png")
Image.new("RGB", (64, 48), "white").save(f"{w}/blank.jpg", quality=90)
rot = Image.new("RGB", (300, 200), "blue")
exif = Image.Exif(); exif[274] = 6
rot.save(f"{w}/rot.jpg", exif=exif)
frames = []
for i in range(3):
    im = Image.new("RGB", (64, 64), "white")
    ImageDraw.Draw(im).rectangle([i * 10, 10, i * 10 + 20, 50], fill="red")
    frames.append(im)
frames[0].save(f"{w}/anim.gif", save_all=True, append_images=frames[1:], duration=120, loop=0)
PY

# --- raster facts ---
out=$(python3 "$here/image-inspect.py" "$work/alpha.png" --json)
check "alpha size" "$(jqpy 'd["size"]' <<<"$out")" "[200, 100]"
check "alpha transparent ratio" "$(jqpy 'd["alpha"]["transparent_ratio"]' <<<"$out")" "0.8139"
check "alpha opaque bbox" "$(jqpy 'd["alpha"]["opaque_bbox"]' <<<"$out")" "[20, 20, 81, 81]"
check "two-color logo not blank" "$(jqpy 'd["pixels"]["blank"]' <<<"$out")" "False"
check "alpha content bbox" "$(jqpy 'd["content_bbox"]' <<<"$out")" "[20, 20, 81, 81]"

out=$(python3 "$here/image-inspect.py" "$work/rot.jpg" --json)
check "exif orientation" "$(jqpy 'd["exif_orientation"]' <<<"$out")" "6"
check "displayed size swapped" "$(jqpy 'd["displayed_size"]' <<<"$out")" "[200, 300]"

out=$(python3 "$here/image-inspect.py" "$work/anim.gif" --json)
check "gif frames" "$(jqpy 'd["frames"]' <<<"$out")" "3"
check "gif durations" "$(jqpy 'd["durations_ms"]' <<<"$out")" "[120, 120, 120]"

out=$(python3 "$here/image-inspect.py" "$work/blank.jpg" --json)
check "uniform image blank" "$(jqpy 'd["pixels"]["blank"]' <<<"$out")" "True"

# --- svg facts ---
cat >"$work/a.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" width="100" height="50">
  <path d="M10 10 L90 10 L90 40 Z" fill="red"/>
  <text x="10" y="30" style="font-family: Inter, sans-serif">Hello</text>
  <image href="photo.png" x="0" y="0" width="10" height="10"/>
</svg>
EOF
cat >"$work/b.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0L10 10Z"/></svg>
EOF
out=$(python3 "$here/svg-inspect.py" "$work/a.svg" --json)
check "svg viewBox" "$(jqpy 'd["viewBox"]' <<<"$out")" "0 0 100 50"
check "svg path segments" "$(jqpy 'd["path_segments"]' <<<"$out")" "4"
check "svg text" "$(jqpy 'd["text"]' <<<"$out")" "Hello"
check "svg font" "$(jqpy 'd["fonts"]' <<<"$out")" "['Inter, sans-serif']"
check "svg external ref" "$(jqpy 'len(d["external_refs"])' <<<"$out")" "1"
if command -v rsvg-convert >/dev/null; then
  check "external refs skip render" \
    "$(jqpy 'd["render"] is None and any("render skipped" in i for i in d["issues"])' <<<"$out")" "True"
  cat >"$work/c.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="red"/></svg>
EOF
  out=$(python3 "$here/svg-inspect.py" "$work/c.svg" --json)
  check "self-contained svg renders" "$(jqpy 'd["render"]["ok"]' <<<"$out")" "True"
  out=$(python3 "$here/svg-inspect.py" "$work/b.svg" --json)
  check "dimensionless svg fails render" "$(jqpy 'd["render"]["ok"]' <<<"$out")" "False"
  cat >"$work/d.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10"><image xlink:href="file:///etc/hosts" width="10" height="10"/></svg>
EOF
  out=$(python3 "$here/svg-inspect.py" "$work/d.svg" --json)
  check "file:// ref counted" "$(jqpy 'len(d["external_refs"])' <<<"$out")" "1"
  check "file:// ref skips render" "$(jqpy 'd["render"] is None' <<<"$out")" "True"
fi

# --- pixel diff ---
if command -v magick >/dev/null; then
  python3 - "$work" <<'PY'
import sys
from PIL import Image, ImageDraw
w = sys.argv[1]
a = Image.new("RGB", (100, 100), "white"); a.save(f"{w}/d1.png")
b = Image.new("RGB", (100, 100), "white")
ImageDraw.Draw(b).rectangle([0, 0, 49, 49], fill="black"); b.save(f"{w}/d2.png")
PY
  out=$(bash "$here/image-diff.sh" "$work/d1.png" "$work/d1.png" --json)
  check "diff identical rmse" "$(jqpy 'd["rmse"]' <<<"$out")" "0"
  set +e
  bash "$here/image-diff.sh" "$work/d1.png" "$work/d1.png" --json >/dev/null
  rc_same=$?
  out=$(bash "$here/image-diff.sh" "$work/d1.png" "$work/d2.png" --json)
  rc_diff=$?
  set -e
  check "diff exit code identical" "$rc_same" "0"
  check "diff exit code changed" "$rc_diff" "3"
  check "diff changed area ratio" "$(jqpy 'd["diff_ratio"]' <<<"$out")" "0.25"
else
  echo "skip image-diff (no ImageMagick)"
fi

# --- OCR (macOS Vision; compile is cached by source hash) ---
# `ls | head` under pipefail exits 1 when the cache is empty; probe without a pipe.
cached=""
for candidate in "${OCR_CACHE_DIR:-$HOME/Library/Caches/anything-understanding-ocr}"/ocr-*; do
  [ -x "$candidate" ] && {
    cached=$candidate
    break
  }
done
if command -v swiftc >/dev/null && { [ -n "$cached" ] || [ "${OCR_TEST:-0}" = 1 ]; }; then
  python3 - "$work" <<'PY'
import sys
from PIL import Image, ImageDraw
ImageDraw.Draw(im := Image.new("RGB", (560, 160), "white")).text(
    (20, 60), "Understanding 42 pixels", fill="black")
im.save(f"{sys.argv[1]}/text.png")
PY
  out=$(bash "$here/ocr.sh" "$work/text.png" --json)
  check "ocr finds text" "$(jqpy 'd["lines"][0]["text"]' <<<"$out")" "Understanding 42 pixels"
  check "ocr coords normalized" "$(jqpy 'd["lines"][0]["w"] < 1' <<<"$out")" "True"
  python3 - "$work" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
im = Image.new("RGB", (6000, 400), "white")
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 60)
except Exception:
    font = None
ImageDraw.Draw(im).text((60, 150), "Wide image OCR", fill="black", font=font)
im.save(f"{sys.argv[1]}/wide.png")
PY
  out=$(bash "$here/ocr.sh" "$work/wide.png" --json 2>/dev/null)
  check "oversized image downscaled, text still found" \
    "$(jqpy '"Wide image OCR" in d["lines"][0]["text"]' <<<"$out")" "True"
  cache=$(mktemp -d)
  hash=$(shasum -a 256 "$here/ocr.swift" | cut -c1-12)
  ln -s /bin/echo "$cache/ocr-$hash"
  set +e
  OCR_CACHE_DIR="$cache" bash "$here/ocr.sh" "$work/text.png" >/dev/null 2>&1
  rc_ocr=$?
  set -e
  rm -r "$cache"
  check "ocr cache symlink refused" "$rc_ocr" "2"
else
  echo "skip OCR (needs macOS swiftc and a cached build; run OCR_TEST=1 to compile)"
fi

# --- truncated raster, header-only huge image, JSON types (review regressions) ---
python3 - "$work" <<'PY'
import struct, sys, zlib
from PIL import Image

w = sys.argv[1]
Image.new("RGB", (64, 64), "red").save(f"{w}/ok.png")
data = open(f"{w}/ok.png", "rb").read()
open(f"{w}/trunc.png", "wb").write(data[: len(data) // 2])

def chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )

ihdr = struct.pack(">IIBBBBB", 20000, 20000, 8, 2, 0, 0, 0)
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", ihdr)
    + chunk(b"IDAT", zlib.compress(b"\x00" * 32))
    + chunk(b"IEND", b"")
)
open(f"{w}/huge.png", "wb").write(png)
open(f"{w}/notimg.png", "wb").write(b"not an image")
PY
out=$(python3 "$here/image-inspect.py" "$work/trunc.png" --json)
check "truncated png keeps JSON" "$(jqpy 'd["size"] is not None' <<<"$out")" "True"
check "truncated png names decode issue" \
  "$(jqpy 'any("cannot decode" in i for i in d["issues"])' <<<"$out")" "True"
out=$(python3 "$here/image-inspect.py" "$work/huge.png" --json)
check "huge header size without decode" "$(jqpy 'd["size"]' <<<"$out")" "[20000, 20000]"
check "huge header skips pixels" "$(jqpy 'd["pixels"] is None' <<<"$out")" "True"
set +e
python3 "$here/image-inspect.py" "$work/notimg.png" >/dev/null 2>&1
rc_human=$?
set -e
check "unreadable image human mode survives" "$rc_human" "0"
if command -v magick >/dev/null; then
  check "diff same_size is boolean" \
    "$(bash "$here/image-diff.sh" "$work/ok.png" "$work/ok.png" --json | jqpy 'type(d["same_size"]).__name__')" "bool"
else
  echo "skip image-diff same_size (no ImageMagick)"
fi

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
