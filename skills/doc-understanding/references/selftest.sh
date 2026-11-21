#!/usr/bin/env bash
# Self-test for the document tools. Builds fixtures, asserts measured fields.
#   bash selftest.sh
# OCR of a rendered scan runs only when a compiled 2d OCR binary is cached.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/doc-selftest.XXXXXX")
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
import docx
import fitz
import openpyxl
import pptx
from PIL import Image, ImageDraw, ImageFont

w = sys.argv[1]

# PDF with a text layer (3 pages, A4).
doc = fitz.open()
for i in range(3):
    page = doc.new_page()
    page.insert_text((72, 100), f"Quarterly report 2026 page {i + 1}", fontsize=18)
    if i == 0:
        page.insert_text((72, 140), "Revenue grew 12 percent.", fontsize=11)
doc.save(f"{w}/text.pdf")

# Image-only PDF: no text layer at all.
im = Image.new("RGB", (800, 400), "white")
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 40)
ImageDraw.Draw(im).text((40, 60), "INVOICE 2026-0042", font=font, fill="black")
im.save(f"{w}/scan.png")
scan = fitz.open()
page = scan.new_page(width=800, height=400)
page.insert_image(fitz.Rect(0, 0, 800, 400), filename=f"{w}/scan.png")
scan.save(f"{w}/scan.pdf")

# Ruled table.
grid = fitz.open()
page = grid.new_page(width=400, height=200)
for y in (50, 90, 130):
    page.draw_line((50, y), (350, y))
for x in (50, 200, 350):
    page.draw_line((x, 50), (x, 130))
page.insert_text((60, 75), "Part", fontsize=11)
page.insert_text((210, 75), "Qty", fontsize=11)
page.insert_text((60, 115), "Bolt", fontsize=11)
page.insert_text((210, 115), "12", fontsize=11)
grid.save(f"{w}/table.pdf")

# Same table without ruling lines.
borderless = fitz.open()
page = borderless.new_page(width=400, height=200)
page.insert_text((50, 70), "Part    Qty", fontsize=11)
page.insert_text((50, 100), "Bolt    12", fontsize=11)
borderless.save(f"{w}/borderless.pdf")

# Encrypted PDF.
encrypted = fitz.open()
encrypted.new_page().insert_text((72, 72), "secret")
encrypted.save(f"{w}/enc.pdf", encryption=fitz.PDF_ENCRYPT_AES_256, owner_pw="o", user_pw="u")

# DOCX with a paragraph and a 2x2 table.
d = docx.Document()
d.add_paragraph("Contract terms")
t = d.add_table(rows=2, cols=2)
t.cell(0, 0).text = "Part"
t.cell(0, 1).text = "Qty"
t.cell(1, 0).text = "Bolt"
t.cell(1, 1).text = "12"
d.save(f"{w}/plain.docx")

# Same DOCX plus one tracked insertion (w:ins) injected into document.xml.
import zipfile
with zipfile.ZipFile(f"{w}/plain.docx") as z:
    items = {n: z.read(n) for n in z.namelist()}
xml = items["word/document.xml"].decode()
ins = ('<w:ins w:id="900" w:author="t" w:date="2026-01-01T00:00:00Z">'
       "<w:r><w:t>new clause</w:t></w:r></w:ins>")
items["word/document.xml"] = xml.replace("</w:body>", ins + "</w:body>").encode()
with zipfile.ZipFile(f"{w}/tracked.docx", "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in items.items():
        z.writestr(name, data)

# PPTX: two slides, notes on the first.
prs = pptx.Presentation()
s1 = prs.slides.add_slide(prs.slide_layouts[5])
s1.shapes.title.text = "Deck"
s1.notes_slide.notes_text_frame.text = "speaker notes"
s2 = prs.slides.add_slide(prs.slide_layouts[5])
s2.shapes.title.text = "Second"
prs.save(f"{w}/deck.pptx")

# XLSX: one sheet, one formula, one merged range.
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "Data"
ws["A1"] = "x"
ws["B2"] = "=SUM(1,2)"
ws.merge_cells("A3:B3")
wb.save(f"{w}/sheet.xlsx")

with open(f"{w}/notes.md", "w") as fh:
    fh.write("# Title\n\nSome [link](https://x.y) text.\n\n## Sub\n\n```py\nx=1\n```\n")
with open(f"{w}/page.html", "w") as fh:
    fh.write("<h1>Hi</h1><p>Body text</p>")
PY

# --- pdf ---
out=$(python3 "$here/probe.py" "$work/text.pdf" --json)
check "pdf pages" "$(jqpy 'd["details"]["pages"]' <<<"$out")" "3"
check "pdf text layer pages" "$(jqpy 'd["details"]["pages_with_text"]' <<<"$out")" "3"
check "pdf scanned pages" "$(jqpy 'd["details"]["scanned_pages"]' <<<"$out")" "[]"
check "pdf page size pt" "$(jqpy 'd["details"]["page_size_pt"]' <<<"$out")" "[595.0, 842.0]"
check "pdf version stripped" "$(jqpy 'd["details"]["pdf_version"]' <<<"$out")" "1.7"

out=$(python3 "$here/probe.py" "$work/scan.pdf" --json)
check "scan has no text" "$(jqpy 'd["details"]["chars_total"]' <<<"$out")" "0"
check "scan pages flagged" "$(jqpy 'd["details"]["scanned_pages"]' <<<"$out")" "[1]"
check "scan images" "$(jqpy 'd["details"]["images_total"]' <<<"$out")" "1"
check "scan note" "$(jqpy 'any("OCR" in n for n in d["notes"])' <<<"$out")" "True"

out=$(python3 "$here/probe.py" "$work/enc.pdf" --json)
check "encrypted flagged" "$(jqpy 'd["details"]["encrypted"]' <<<"$out")" "True"
check "encrypted pages unread" "$(jqpy 'd["details"]["pages"]' <<<"$out")" "None"
check "encrypted note" "$(jqpy 'any("password" in n for n in d["notes"])' <<<"$out")" "True"

# --- extraction ---
text=$(python3 "$here/extract.py" "$work/text.pdf")
check "pdf text extracted" "$(grep -c 'Quarterly report 2026' <<<"$text")" "3"
check "pdf page markers" "$(grep -c '^--- page ' <<<"$text")" "3"
subset=$(python3 "$here/extract.py" "$work/text.pdf" --pages 2)
check "pages flag yields one page" "$(grep -c '^--- page ' <<<"$subset")" "1"
check "pages flag keeps page number" "$(grep -c '^--- page 2 ---' <<<"$subset")" "1"

err=$(python3 "$here/extract.py" "$work/scan.pdf" 2>&1 >/dev/null)
check "scan text names OCR need" "$(grep -c 'render + OCR' <<<"$err")" "1"

python3 "$here/extract.py" "$work/table.pdf" --tables "$work/tables" >/dev/null
check "table csv written" "$(tr -d '\r' <"$work/tables/page1-table1.csv" | tr '\n' ';')" "Part,Qty;Bolt,12;"
out_tables=$(python3 "$here/extract.py" "$work/borderless.pdf" --tables "$work/t2")
check "borderless table not detected" "$out_tables" "[no tables detected]"

# --- office ---
out=$(python3 "$here/probe.py" "$work/plain.docx" --json)
check "docx paragraphs" "$(jqpy 'd["details"]["paragraphs"]' <<<"$out")" "1"
check "docx tables" "$(jqpy 'd["details"]["tables"]' <<<"$out")" "1"
out=$(python3 "$here/probe.py" "$work/tracked.docx" --json)
check "docx tracked insertion" "$(jqpy 'd["details"]["tracked_insertions"]' <<<"$out")" "1"
docx_text=$(python3 "$here/extract.py" "$work/plain.docx")
check "docx table row 1" "$(grep -c '^Part | Qty$' <<<"$docx_text")" "1"
check "docx table row 2" "$(grep -c '^Bolt | 12$' <<<"$docx_text")" "1"
xlsx_note=$(python3 -c "
import sys
sys.path.insert(0, '$here')
import probe
notes = []
probe.probe_xlsx(__import__('pathlib').Path(sys.argv[1]), notes, formula_scan_limit=1)
print(' '.join(notes))
" "$work/sheet.xlsx")
check "xlsx scan limit note" "$(grep -c 'formula scan stopped at 1 cells' <<<"$xlsx_note")" "1"

out=$(python3 "$here/probe.py" "$work/deck.pptx" --json)
check "pptx slides" "$(jqpy 'd["details"]["slides"]' <<<"$out")" "2"
check "pptx notes" "$(jqpy 'd["details"]["notes"]' <<<"$out")" "1"

out=$(python3 "$here/probe.py" "$work/sheet.xlsx" --json)
check "xlsx formulas" "$(jqpy 'd["details"]["sheets"][0]["formulas"]' <<<"$out")" "1"
check "xlsx merged ranges" "$(jqpy 'd["details"]["sheets"][0]["merged"]' <<<"$out")" "1"
check "xlsx dims" "$(jqpy 'd["details"]["sheets"][0]["dims"]' <<<"$out")" "A1:B3"
out=$(python3 "$here/extract.py" "$work/sheet.xlsx")
check "xlsx sheet marker" "$(grep -c '^--- sheet Data' <<<"$out")" "1"
check "xlsx formulas flag" "$(python3 "$here/extract.py" "$work/sheet.xlsx" --formulas)" "$(printf 'Data!B2\t=SUM(1,2)')"

out=$(python3 "$here/probe.py" "$work/notes.md" --json)
check "md headings" "$(jqpy 'd["details"]["headings"]' <<<"$out")" "2"
check "md links" "$(jqpy 'd["details"]["links"]' <<<"$out")" "1"
check "md code blocks" "$(jqpy 'd["details"]["code_blocks"]' <<<"$out")" "1"
check "html to gfm heading" "$(python3 "$here/extract.py" "$work/page.html" --markdown | head -1)" "# Hi"

# --- render (+ OCR when the 2d binary is already cached) ---
line=$(bash "$here/render.sh" "$work/scan.pdf" --page 1 --dpi 150 --out "$work/p1.png")
check "render reports size" "$(awk -F'\t' '$2=="1667x834"{print "ok"}' <<<"$line")" "ok"
check "render file exists" "$([ -s "$work/p1.png" ] && echo yes || echo no)" "yes"
sibling=$(cd "$here/../../2d-understanding/references" 2>/dev/null && pwd || true)
cached=""
for candidate in "${OCR_CACHE_DIR:-$HOME/Library/Caches/anything-understanding-ocr}"/ocr-*; do
  [ -x "$candidate" ] && {
    cached=$candidate
    break
  }
done
if [ -n "$sibling" ] && [ -x "$sibling/ocr.sh" ] && [ -n "$cached" ]; then
  out=$(bash "$sibling/ocr.sh" "$work/p1.png" --json 2>/dev/null)
  check "rendered scan OCR text" "$(jqpy 'any("INVOICE 2026-0042" in l["text"] for l in d["lines"])' <<<"$out")" "True"
else
  echo "skip rendered-scan OCR (needs the sibling 2d-understanding skill + a cached Vision build)"
fi

# --- fonts/forms/tagged/formulas/pages (review regressions) ---
out=$(python3 "$here/probe.py" "$work/text.pdf" --json)
check "helvetica not embedded" \
  "$(jqpy '[f["embedded"] for f in d["details"]["fonts"] if f["name"] == "Helvetica"][0]' <<<"$out")" "False"
check "plain pdf not tagged" "$(jqpy 'd["details"]["tagged"]' <<<"$out")" "False"

python3 - "$work/form.pdf" <<'PY'
import fitz, sys
doc = fitz.open()
page = doc.new_page()
for i in range(2):
    widget = fitz.Widget()
    widget.field_type = fitz.PDF_WIDGET_TYPE_TEXT
    widget.field_name = f"f{i}"
    widget.rect = fitz.Rect(10, 10 + i * 40, 120, 40 + i * 40)
    page.add_widget(widget)
doc.save(sys.argv[1])
PY
out=$(python3 "$here/probe.py" "$work/form.pdf" --json)
check "form fields counted" "$(jqpy 'd["details"]["form_fields_total"]' <<<"$out")" "2"

python3 - "$work/array.xlsx" <<'PY'
import sys
from openpyxl import Workbook
from openpyxl.worksheet.formula import ArrayFormula

wb = Workbook()
ws = wb.active
ws["A1"] = "=SUM(1,2)"
ws["A2"] = ArrayFormula("B2:B4", "=UNIQUE(A1:A9)")
wb.save(sys.argv[1])
PY
out=$(python3 "$here/probe.py" "$work/array.xlsx" --json)
check "array formulas counted" "$(jqpy 'd["details"]["sheets"][0]["formulas"]' <<<"$out")" "2"
check "array formula exported" \
  "$(python3 "$here/extract.py" "$work/array.xlsx" --formulas | grep -c UNIQUE)" "1"
set +e
python3 "$here/extract.py" "$work/text.pdf" --pages 99 >/dev/null 2>&1
rc_pages=$?
set -e
check "empty page selection errors" "$rc_pages" "1"

# --- far-cell xlsx must be bounded; render default must not land in CWD ---
python3 - "$work/far.xlsx" <<'PY'
import sys
from openpyxl import Workbook

wb = Workbook()
ws = wb.active
ws["A1"] = "x"
ws["A1000000"] = "far"
wb.save(sys.argv[1])
PY
out=$(python3 "$here/extract.py" "$work/far.xlsx")
check "far cell truncated" "$(grep -c '(truncated)' <<<"$out")" "1"
check "far cell bounded lines" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"

start=$PWD
cd "$work" || exit 1
line=$(bash "$here/render.sh" "$work/scan.pdf" --page 1)
check "render default not in cwd" "$(find . -maxdepth 1 -name 'page-*.png' | wc -l | tr -d ' ')" "0"
check "render default path exists" "$([ -s "$(cut -f1 <<<"$line")" ] && echo yes || echo no)" "yes"
cd "$start" || exit 1

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
