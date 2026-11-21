#!/usr/bin/env python3
"""Document structure probe: what is in this file before you read any of it.

    python3 probe.py report.pdf
    python3 probe.py contract.docx --json
    python3 probe.py deck.pptx sheet.xlsx notes.md

Answers, per kind: size/shape (pages, slides, sheets), whether a PDF has a real
text layer or is a scan, which fonts are embedded, how many images/links/forms,
and the document-level counters that matter (tables, comments, tracked changes).
Everything printed is measured; a field that could not be measured is null and
the reason is in notes.

Requires: PyMuPDF (pdf), python-docx, python-pptx, openpyxl. Missing libraries
degrade one kind at a time instead of failing the whole run.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

PDF_SUFFIXES = {".pdf"}
DOCX_SUFFIXES = {".docx"}
PPTX_SUFFIXES = {".pptx"}
XLSX_SUFFIXES = {".xlsx", ".xlsm"}
ZIP_DOC_SUFFIXES = {".odt", ".odp", ".ods", ".epub"}
TEXT_SUFFIXES = {".md", ".markdown", ".txt", ".rst"}
HTML_SUFFIXES = {".html", ".htm"}
RTF_SUFFIXES = {".rtf", ".doc"}


def kind_of(path: Path) -> str:
    s = path.suffix.lower()
    if s in PDF_SUFFIXES:
        return "pdf"
    if s in DOCX_SUFFIXES:
        return "docx"
    if s in PPTX_SUFFIXES:
        return "pptx"
    if s in XLSX_SUFFIXES:
        return "xlsx"
    if s in ZIP_DOC_SUFFIXES:
        return "zipdoc"
    if s in HTML_SUFFIXES:
        return "html"
    if s in RTF_SUFFIXES:
        return "rtf"
    if s in TEXT_SUFFIXES:
        return "text"
    return "other"


ARCHIVE_EXPANSION_LIMIT = 200 * 1024 * 1024


def archive_expansion(path: Path) -> int | None:
    """Total uncompressed size of a zip-based document, or None if unreadable."""
    try:
        with zipfile.ZipFile(path) as z:
            return sum(item.file_size for item in z.infolist())
    except (zipfile.BadZipFile, OSError):
        return None


# --- pdf -------------------------------------------------------------------
def probe_pdf(path: Path, notes: list[str]) -> dict:
    import fitz  # PyMuPDF

    out: dict = {
        "pages": None,
        "pdf_version": None,
        "encrypted": None,
        "page_size_pt": None,
        "tagged": None,
        "producer": None,
        "creator": None,
        "title": None,
        "author": None,
        "created": None,
        "chars_total": 0,
        "pages_with_text": 0,
        "scanned_pages": [],
        "fonts": [],
        "images_total": 0,
        "annotations_total": 0,
        "links_total": 0,
        "form_fields_total": 0,
        "per_page": [],
    }
    with fitz.open(path) as doc:
        out["encrypted"] = bool(doc.needs_pass)
        if doc.needs_pass:
            notes.append("password protected: metadata only, content not read")
            return out
        out["pages"] = doc.page_count
        out["pdf_version"] = (doc.metadata.get("format") or "").replace("PDF ", "") or None
        meta = doc.metadata or {}
        for key in ("producer", "creator", "title", "author", "creationDate"):
            out["created" if key == "creationDate" else key] = meta.get(key) or None
        out["tagged"] = bool(doc.is_pdf and doc.xref_get_key(doc.pdf_catalog(), "MarkInfo")[0] != "null")
        fonts: dict[tuple[str, bool, str], int] = {}
        font_ext: dict[int, str] = {}
        for index, page in enumerate(doc, start=1):
            text = page.get_text("text")
            chars = len(text.strip())
            images = len(page.get_images(full=True))
            links = len(page.get_links())
            annots = sum(1 for _ in page.annots()) if page.first_annot else 0
            out["per_page"].append({"page": index, "chars": chars, "images": images, "links": links})
            out["chars_total"] += chars
            out["images_total"] += images
            out["links_total"] += links
            out["annotations_total"] += annots
            if chars:
                out["pages_with_text"] += 1
            else:
                out["scanned_pages"].append(index)
            for f in page.get_fonts(full=True):
                xref, ftype, basefont = f[0], f[2], f[3]
                ext = font_ext.setdefault(xref, doc.extract_font(xref)[1] if xref else "n/a")
                embedded = xref != 0 and ext != "n/a"
                fonts[(basefont, embedded, ftype)] = fonts.get((basefont, embedded, ftype), 0) + 1
        if doc.page_count:
            first = doc[0].rect
            out["page_size_pt"] = [round(first.width, 1), round(first.height, 1)]
        try:
            out["form_fields_total"] = sum(len(list(page.widgets())) for page in doc)
        except Exception:
            out["form_fields_total"] = None
        out["fonts"] = [
            {"name": name, "embedded": embedded, "type": ftype, "pages": count}
            for (name, embedded, ftype), count in sorted(fonts.items(), key=lambda kv: -kv[1])[:12]
        ]
    if out["scanned_pages"] and out["pages_with_text"]:
        notes.append(
            f"mixed: {len(out['scanned_pages'])} page(s) without a text layer "
            f"({out['scanned_pages'][:8]}{'…' if len(out['scanned_pages']) > 8 else ''})"
        )
    elif out["scanned_pages"]:
        notes.append("no text layer on any page: this is a scan; text needs OCR")
    if any(not f["embedded"] for f in out["fonts"]):
        notes.append("non-embedded fonts present: rendering depends on the viewer's fonts")
    return out


# --- docx ------------------------------------------------------------------
def probe_docx(path: Path, notes: list[str]) -> dict:
    out: dict = {
        "paragraphs": None,
        "tables": None,
        "images": None,
        "sections": None,
        "headers": None,
        "footers": None,
        "styles": None,
        "words": None,
        "comments": 0,
        "tracked_insertions": 0,
        "tracked_deletions": 0,
    }
    try:
        import docx
    except ImportError:
        notes.append("python-docx not installed: structural counts unavailable")
        return out
    d = docx.Document(str(path))
    out["paragraphs"] = len(d.paragraphs)
    out["tables"] = len(d.tables)
    out["images"] = len(d.inline_shapes)
    out["sections"] = len(d.sections)
    out["headers"] = sum(1 for s in d.sections if not s.header.is_linked_to_previous)
    out["footers"] = sum(1 for s in d.sections if not s.footer.is_linked_to_previous)
    out["styles"] = len(d.styles)
    text = "\n".join(p.text for p in d.paragraphs)
    out["words"] = len(text.split())
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        if "word/comments.xml" in names:
            out["comments"] = len(re.findall(rb"<w:comment[ >]", z.read("word/comments.xml")))
        document = z.read("word/document.xml")
        out["tracked_insertions"] = len(re.findall(rb"<w:ins[ >]", document))
        out["tracked_deletions"] = len(re.findall(rb"<w:del[ >]", document))
    if out["tracked_insertions"] or out["tracked_deletions"]:
        notes.append("contains tracked changes: extracted text is the current view, not the accepted text")
    if out["comments"]:
        notes.append(f"{out['comments']} comment(s) are not part of the body text")
    return out


# --- pptx ------------------------------------------------------------------
def probe_pptx(path: Path, notes: list[str]) -> dict:
    out: dict = {
        "slides": None,
        "shapes": None,
        "pictures": None,
        "notes": None,
        "text_runs": None,
        "words": None,
    }
    try:
        from pptx import Presentation
        from pptx.enum.shapes import MSO_SHAPE_TYPE
    except ImportError:
        notes.append("python-pptx not installed: structural counts unavailable")
        return out
    prs = Presentation(str(path))
    out["slides"] = len(prs.slides)
    shapes = pictures = notes_count = runs = words = 0
    for slide in prs.slides:
        for shape in slide.shapes:
            shapes += 1
            if shape.shape_type == MSO_SHAPE_TYPE.PICTURE:
                pictures += 1
            if shape.has_text_frame:
                for para in shape.text_frame.paragraphs:
                    for run in para.runs:
                        runs += 1
                        words += len(run.text.split())
        if slide.has_notes_slide and slide.notes_slide.notes_text_frame.text.strip():
            notes_count += 1
    out.update(shapes=shapes, pictures=pictures, notes=notes_count, text_runs=runs, words=words)
    if not pictures:
        notes.append("no picture shapes: slides may rely on fonts/placeholders only")
    return out


# --- xlsx ------------------------------------------------------------------
def probe_xlsx(path: Path, notes: list[str], formula_scan_limit: int = 200_000) -> dict:
    out: dict = {"sheets": [], "sheet_count": 0, "charts": 0, "defined_names": 0}
    try:
        import openpyxl
    except ImportError:
        notes.append("openpyxl not installed: workbook counts unavailable")
        return out
    from openpyxl.worksheet.formula import ArrayFormula

    wb = openpyxl.load_workbook(str(path), read_only=False, data_only=False)
    out["sheet_count"] = len(wb.sheetnames)
    scanned = 0
    for ws in wb.worksheets:
        formulas = 0
        for row in ws.iter_rows():
            for cell in row:
                scanned += 1
                if isinstance(cell.value, ArrayFormula) or (isinstance(cell.value, str) and cell.value.startswith("=")):
                    formulas += 1
            if scanned > formula_scan_limit:
                notes.append(f"formula scan stopped at {formula_scan_limit} cells")
                break
        out["sheets"].append(
            {
                "name": ws.title,
                "dims": ws.dimensions,
                "rows": ws.max_row,
                "cols": ws.max_column,
                "formulas": formulas,
                "merged": len(ws.merged_cells.ranges),
            }
        )
    out["charts"] = sum(1 for ws in wb.worksheets for _ in getattr(ws, "_charts", []))
    out["defined_names"] = len(getattr(wb, "defined_names", {}) or {})
    if any(s["formulas"] for s in out["sheets"]):
        notes.append("formulas present: cell values loaded with data_only=False are formulas, not results")
    return out


# --- text-ish --------------------------------------------------------------
def probe_zipdoc(path: Path, notes: list[str]) -> dict:
    out: dict = {"zip_entries": None, "mimetype": None}
    with zipfile.ZipFile(path) as z:
        out["zip_entries"] = len(z.namelist())
        if "mimetype" in z.namelist():
            out["mimetype"] = z.read("mimetype").decode("ascii", "replace")
    notes.append("open-document/epub container: convert with pandoc for content")
    return out


def probe_textish(path: Path, notes: list[str], kind: str) -> dict:
    raw = path.read_text(encoding="utf-8", errors="replace")
    out: dict = {
        "words": len(raw.split()),
        "lines": raw.count("\n") + 1,
        "headings": None,
        "links": None,
        "tables": None,
        "code_blocks": None,
    }
    if kind == "text":
        out["headings"] = len(re.findall(r"^#{1,6} ", raw, re.M))
        out["links"] = len(re.findall(r"\[[^\]]*\]\([^)]+\)", raw))
        out["tables"] = len(re.findall(r"^\|[-: ]+\|", raw, re.M))
        out["code_blocks"] = raw.count("```") // 2
    elif kind == "html":
        out["headings"] = len(re.findall(r"<h[1-6][ >]", raw, re.I))
        out["links"] = len(re.findall(r"<a\s[^>]*href=", raw, re.I))
        out["tables"] = len(re.findall(r"<table[ >]", raw, re.I))
        notes.append("html: counts only, use pandoc for content")
    else:
        notes.append("rtf/doc: counts only, convert with textutil or pandoc")
    return out


def probe(path: Path) -> dict:
    notes: list[str] = []
    kind = kind_of(path)
    report: dict = {
        "file": str(path.resolve()),
        "bytes": path.stat().st_size,
        "kind": kind,
        "details": None,
        "notes": notes,
    }
    handler = {
        "pdf": probe_pdf,
        "docx": probe_docx,
        "pptx": probe_pptx,
        "xlsx": probe_xlsx,
        "zipdoc": probe_zipdoc,
    }.get(kind)
    try:
        if handler is not None and kind != "pdf":
            expansion = archive_expansion(path)
            if expansion is not None and expansion > ARCHIVE_EXPANSION_LIMIT:
                notes.append(
                    f"archive expands to {expansion // (1024 * 1024)} MB; not parsed "
                    f"(limit {ARCHIVE_EXPANSION_LIMIT // (1024 * 1024)} MB)"
                )
                return report
        if handler is not None:
            report["details"] = handler(path, notes)
        elif kind in {"text", "html", "rtf"}:
            report["details"] = probe_textish(path, notes, kind)
        else:
            notes.append(f"unsupported suffix {path.suffix!r}: no structural parser")
    except Exception as exc:  # keep one bad file from killing the run
        notes.append(f"probe failed: {type(exc).__name__}: {exc}")
    return report


def human(report: dict) -> str:
    d = report["details"] or {}
    lines = [f"{report['file']} ({report['bytes']} bytes, {report['kind']})"]
    if report["kind"] == "pdf" and d.get("encrypted"):
        lines.append("  encrypted: content not read (password required)")
        for note in report["notes"]:
            lines.append(f"  ! {note}")
        return "\n".join(lines)
    if report["kind"] == "pdf":
        lines.append(
            f"  {d.get('pages')} page(s), pdf {d.get('pdf_version')}, "
            f"page size {d.get('page_size_pt')} pt, encrypted={d.get('encrypted')}"
        )
        lines.append(
            f"  text layer: {d.get('pages_with_text')}/{d.get('pages')} pages, "
            f"chars={d.get('chars_total')}, scanned pages={d.get('scanned_pages')}"
        )
        lines.append(
            f"  images={d.get('images_total')} links={d.get('links_total')} "
            f"annotations={d.get('annotations_total')} forms={d.get('form_fields_total')}"
        )
        if d.get("fonts"):
            lines.append(
                "  fonts: "
                + ", ".join(f"{f['name']}{'' if f['embedded'] else ' (not embedded)'}" for f in d["fonts"][:6])
            )
    elif report["kind"] == "xlsx":
        for sheet in d.get("sheets", []):
            lines.append(
                f"  {sheet['name']}  {sheet['dims']}  {sheet['rows']}x{sheet['cols']}  "
                f"formulas={sheet['formulas']} merged={sheet['merged']}"
            )
        lines.append(f"  sheets={d.get('sheet_count')} charts={d.get('charts')} defined_names={d.get('defined_names')}")
    elif report["kind"] in {"docx", "pptx", "text", "html", "rtf", "zipdoc"}:
        for key, value in d.items():
            lines.append(f"  {key}: {value}")
    for note in report["notes"]:
        lines.append(f"  ! {note}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    reports = [probe(p) for p in args.paths]
    if args.json:
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2))
    else:
        print("\n".join(human(r) for r in reports))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
