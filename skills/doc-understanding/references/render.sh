#!/usr/bin/env bash
# Render a PDF page to PNG so a human or Vision OCR can look at it.
#   render.sh scan.pdf --page 1 --dpi 150 --out page1.png
#   render.sh deck.pdf --page 2                 # prints the output path
#
# Use this on pages probe.py listed as "scanned" (no text layer): a rendered
# page at 150-200 dpi is what 2d-understanding's ocr.sh expects. Rendered size
# is width_pt/72*dpi x height_pt/72*dpi, so a 150 dpi A4 page is ~1240x1754.
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "usage: render.sh <file.pdf> [--page N] [--dpi 150] [--out path.png]" >&2
  exit 1
fi
file=$1
shift
page=1
dpi=150
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --page)
      page=${2:?}
      shift
      ;;
    --dpi)
      dpi=${2:?}
      shift
      ;;
    --out)
      out=${2:?}
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done
[ -f "$file" ] || {
  echo "no such file: $file" >&2
  exit 1
}
if ! command -v python3 >/dev/null; then
  echo "render.sh needs python3 + PyMuPDF" >&2
  exit 1
fi
[ -n "$out" ] || out="page-${page}.png"
python3 - "$file" "$page" "$dpi" "$out" <<'PY'
import sys
import fitz

path, page, dpi, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with fitz.open(path) as doc:
    if not (1 <= page <= doc.page_count):
        sys.exit(f"page {page} out of range 1..{doc.page_count}")
    pix = doc[page - 1].get_pixmap(dpi=dpi)
    pix.save(out)
    print(f"{out}\t{pix.width}x{pix.height}\tpage {page}/{doc.page_count} @ {dpi}dpi")
PY
echo "next: ../2d-understanding/references/ocr.sh $out --json   # run from the skill directory" >&2
