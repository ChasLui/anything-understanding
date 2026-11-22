#!/usr/bin/env python3
"""Document content extraction with explicit provenance.

    python3 extract.py report.pdf                 # per-page text, page markers
    python3 extract.py report.pdf --layout         # pdftotext -layout (columns)
    python3 extract.py report.pdf --pages 1-3
    python3 extract.py report.pdf --tables out/    # CSV per table + markdown preview
    python3 extract.py deck.pptx --markdown        # pandoc -> GitHub markdown
    python3 extract.py scan.pdf --text             # names pages that need OCR

A page that yields no text is printed as `[page N: no text layer — OCR needed]`
instead of silence, and summarised on stderr. Extraction never invents content:
what a converter drops (columns, footnotes, headers) is a limit of the channel,
not something to fill in from context.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

TEXT_SUFFIXES = {".md", ".markdown", ".txt", ".rst", ".csv", ".log"}
PANDOC_SUFFIXES = {".html", ".htm", ".rtf", ".docx", ".odt", ".epub", ".doc"}
# openpyxl sizes its iteration rectangle from the furthest cell; one cell at
# XFD1048576 would otherwise allocate 17e9 Cell objects from a 5 KB file.
XLSX_MAX_ROWS = 50_000
XLSX_MAX_COLS = 128


def parse_pages(spec: str | None, total: int) -> list[int]:
    if not spec:
        return list(range(1, total + 1))
    out: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        elif part:
            out.append(int(part))
    return [p for p in out if 1 <= p <= total]


# --- pdf -------------------------------------------------------------------
def pdf_text(path: Path, pages_spec: str | None, layout: bool) -> str:
    import fitz

    try:
        opened = fitz.open(path)
    except Exception as exc:
        sys.exit(f"extract.py: cannot open {path} as PDF: {type(exc).__name__}: {exc}")
    with opened as doc:
        if doc.needs_pass:
            sys.exit("extract.py: PDF is password protected")
        pages = parse_pages(pages_spec, doc.page_count)
        if not pages:
            sys.exit(f"extract.py: --pages {pages_spec} selects no pages (1..{doc.page_count})")
        contiguous = pages == list(range(pages[0], pages[-1] + 1))
        if layout and contiguous and shutil.which("pdftotext"):
            first, last = pages[0], pages[-1]
            proc = subprocess.run(
                ["pdftotext", "-layout", "-f", str(first), "-l", str(last), str(path), "-"],
                capture_output=True,
                text=True,
            )
            if proc.returncode == 0:
                return proc.stdout
        chunks: list[str] = []
        empty: list[int] = []
        for number in pages:
            page = doc[number - 1]
            text = page.get_text("text").strip()
            if text:
                chunks.append(f"--- page {number} ---\n{text}")
            else:
                empty.append(number)
                chunks.append(f"[page {number}: no text layer — OCR needed]")
        if empty:
            print(
                f"extract.py: {len(empty)} page(s) without a text layer: "
                f"{empty[:10]}{'…' if len(empty) > 10 else ''} "
                "(render + OCR, see SKILL.md)",
                file=sys.stderr,
            )
        return "\n\n".join(chunks)


def pdf_tables(path: Path, outdir: Path, pages_spec: str | None) -> str:
    import pdfplumber

    outdir.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    with pdfplumber.open(path) as pdf:
        pages = parse_pages(pages_spec, len(pdf.pages))
        for number in pages:
            for index, table in enumerate(pdf.pages[number - 1].extract_tables(), start=1):
                if not table:
                    continue
                csv_path = outdir / f"page{number}-table{index}.csv"
                with csv_path.open("w", newline="") as fh:
                    writer = csv.writer(fh)
                    writer.writerows(table)
                rows = len(table)
                cols = max((len(r) for r in table), default=0)
                lines.append(f"--- page {number} table {index} ({rows}x{cols}) -> {csv_path}")
                for row in table[:6]:
                    lines.append("| " + " | ".join((c or "").replace("\n", " ") for c in row) + " |")
    return "\n".join(lines) if lines else "[no tables detected]"


# --- office ----------------------------------------------------------------
def docx_text(path: Path) -> str:
    import docx

    d = docx.Document(str(path))
    chunks = [p.text for p in d.paragraphs if p.text.strip()]
    for i, table in enumerate(d.tables, start=1):
        rows = [[cell.text.strip() for cell in row.cells] for row in table.rows]
        chunks.append(f"--- table {i} ({len(rows)}x{max((len(r) for r in rows), default=0)}) ---")
        chunks.extend(" | ".join(row) for row in rows)
    return "\n".join(chunks)


def pptx_text(path: Path) -> str:
    from pptx import Presentation

    prs = Presentation(str(path))
    chunks: list[str] = []
    for number, slide in enumerate(prs.slides, start=1):
        chunks.append(f"--- slide {number} ---")
        for shape in slide.shapes:
            if shape.has_text_frame and shape.text_frame.text.strip():
                chunks.append(shape.text_frame.text.strip())
        if slide.has_notes_slide:
            notes = slide.notes_slide.notes_text_frame.text.strip()
            if notes:
                chunks.append(f"[notes] {notes}")
    return "\n".join(chunks)


def xlsx_rows(ws, values_only: bool = True):
    """Yield at most XLSX_MAX_ROWS rows; callers slice columns."""
    for index, row in enumerate(ws.iter_rows(values_only=values_only)):
        if index >= XLSX_MAX_ROWS:
            break
        yield row


def xlsx_tables(path: Path, outdir: Path) -> str:
    import openpyxl

    outdir.mkdir(parents=True, exist_ok=True)
    wb = openpyxl.load_workbook(str(path), data_only=True, read_only=True)
    lines: list[str] = []
    for ws in wb.worksheets:
        csv_path = outdir / f"{ws.title}.csv"
        with csv_path.open("w", newline="") as fh:
            writer = csv.writer(fh)
            for row in xlsx_rows(ws):
                writer.writerow(["" if v is None else v for v in row[:XLSX_MAX_COLS]])
        suffix = " (truncated)" if ws.max_row > XLSX_MAX_ROWS or ws.max_column > XLSX_MAX_COLS else ""
        lines.append(f"--- sheet {ws.title} ({ws.max_row}x{ws.max_column}){suffix} -> {csv_path}")
    return "\n".join(lines)


def xlsx_text(path: Path) -> str:
    import openpyxl

    wb = openpyxl.load_workbook(str(path), data_only=True, read_only=True)
    chunks: list[str] = []
    for ws in wb.worksheets:
        suffix = " (truncated)" if ws.max_row > XLSX_MAX_ROWS or ws.max_column > XLSX_MAX_COLS else ""
        chunks.append(f"--- sheet {ws.title} ({ws.max_row}x{ws.max_column}){suffix} ---")
        for row in xlsx_rows(ws):
            if any(v is not None for v in row):
                chunks.append("\t".join("" if v is None else str(v) for v in row[:XLSX_MAX_COLS]))
    return "\n".join(chunks)


# --- converters ------------------------------------------------------------
def pandoc(path: Path, to: str) -> str:
    if not shutil.which("pandoc"):
        sys.exit("extract.py: pandoc not installed")
    proc = subprocess.run(
        ["pandoc", str(path), "-t", to, "--wrap=none"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"extract.py: pandoc failed: {proc.stderr.strip()[:300]}")
    return proc.stdout.rstrip("\n")


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}GB"


ARCHIVE_EXPANSION_LIMIT = 200 * 1024 * 1024
ARCHIVE_SUFFIXES = {".docx", ".pptx", ".xlsx", ".xlsm", ".odt", ".odp", ".ods", ".epub"}


def guard_archive(path: Path) -> None:
    """Refuse zip-based documents that inflate past the limit (zip bombs)."""
    if path.suffix.lower() not in ARCHIVE_SUFFIXES:
        return
    try:
        with zipfile.ZipFile(path) as z:
            expansion = sum(item.file_size for item in z.infolist())
    except (zipfile.BadZipFile, OSError):
        return
    limit = ARCHIVE_EXPANSION_LIMIT
    if expansion > limit:
        sys.exit(
            f"extract.py: {path.name} expands to {expansion // (1024 * 1024)} MB "
            f"(limit {limit // (1024 * 1024)} MB); not parsed"
        )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("path", type=Path)
    parser.add_argument("--text", action="store_true", help="text extraction (default)")
    parser.add_argument("--layout", action="store_true", help="PDF: pdftotext -layout")
    parser.add_argument("--tables", type=Path, metavar="OUTDIR")
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--formulas", action="store_true", help="xlsx: print formulas, not values")
    parser.add_argument("--pages", help="e.g. 1-3,7 (PDF text/table extraction only)")
    args = parser.parse_args(argv)

    path: Path = args.path
    if not path.is_file():
        sys.exit(f"extract.py: no such file: {path}")
    guard_archive(path)
    suffix = path.suffix.lower()

    if args.formulas:
        if suffix not in {".xlsx", ".xlsm"}:
            sys.exit(f"extract.py: --formulas supports xlsx, not {suffix}")
        import openpyxl
        from openpyxl.worksheet.formula import ArrayFormula

        wb = openpyxl.load_workbook(str(path), data_only=False, read_only=True)
        for ws in wb.worksheets:
            for row in xlsx_rows(ws, values_only=False):
                for cell in row[:XLSX_MAX_COLS]:
                    value = cell.value
                    if isinstance(value, ArrayFormula):
                        print(f"{ws.title}!{value.ref}\t{value.text}")
                    elif isinstance(value, str) and value.startswith("="):
                        print(f"{ws.title}!{cell.coordinate}\t{value}")
        return 0

    if args.tables:
        if suffix == ".pdf":
            print(pdf_tables(path, args.tables, args.pages))
        elif suffix in {".xlsx", ".xlsm"}:
            print(xlsx_tables(path, args.tables))
        else:
            sys.exit(f"extract.py: --tables supports pdf/xlsx, not {suffix}")
        return 0

    if args.markdown:
        if suffix in PANDOC_SUFFIXES:
            print(pandoc(path, "gfm"))
            return 0
        if suffix == ".pdf":
            sys.exit("extract.py: pandoc cannot read PDF; use --text (or --layout) for PDF")
        print(path.read_text(encoding="utf-8", errors="replace"))
        return 0

    # default: text
    if suffix == ".pdf":
        print(pdf_text(path, args.pages, args.layout))
    elif suffix == ".docx":
        print(docx_text(path))
    elif suffix == ".pptx":
        print(pptx_text(path))
    elif suffix in {".xlsx", ".xlsm"}:
        print(xlsx_text(path))
    elif suffix in PANDOC_SUFFIXES:
        print(pandoc(path, "plain"))
    elif suffix in TEXT_SUFFIXES or suffix == "":
        print(path.read_text(encoding="utf-8", errors="replace"))
    else:
        sys.exit(f"extract.py: no text channel for {suffix}; try --markdown or pandoc")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
