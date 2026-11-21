#!/usr/bin/env python3
"""Data file probe: shape, schema, and data-quality facts before any analysis.

    python3 probe.py orders.csv
    python3 probe.py events.jsonl --json
    python3 probe.py part.parquet
    python3 probe.py app.db

Kind is decided by content (magic bytes / first non-space byte), not by suffix,
so a `.csv` that is really TSV or a `.json` that is NDJSON is reported as what it
is. Every number is measured by streaming the file; the per-column scan is
bounded (docs: `profile_rows`) and the bound is reported, never hidden.

Requires: pandas + pyarrow (parquet/json), stdlib otherwise. Missing pandas
degrades CSV/JSON to shape-only counts instead of failing.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import sys
import zipfile
from collections import Counter
from pathlib import Path

PROFILE_ROWS = 50_000
DUP_SCAN_ROWS = 200_000  # duplicate scan bound (documented in SKILL.md)
INT_RE = re.compile(r"^[+-]?\d+$")
FLOAT_RE = re.compile(r"^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$")
BOOLS = {"true", "false", "yes", "no", "t", "f"}


def sniff_kind(path: Path) -> str:
    with path.open("rb") as fh:
        head = fh.read(4096)
    if head.startswith(b"PAR1"):
        return "parquet"
    if head.startswith(b"SQLite format 3\x00"):
        return "sqlite"
    if head.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(path) as z:
                names = z.namelist()
            if any(n.startswith("xl/") for n in names):
                return "xlsx"
            if any(n.startswith("word/") for n in names):
                return "docx"
        except zipfile.BadZipFile:
            pass
    if head.startswith(b"\xff\xd8\xff") or head.startswith(b"\x89PNG"):
        return "image"
    text = head.lstrip(b"\xef\xbb\xbf").lstrip()
    if not text:
        return "empty"
    if text.startswith(b"{"):
        return "json"
    if text.startswith(b"["):
        return "json"
    first = text.splitlines()[0].decode("utf-8", "replace") if text else ""
    if first.count("\t") > first.count(","):
        return "tsv"
    if "," in first or ";" in first or "|" in first:
        return "csv"
    suffix = path.suffix.lower()
    if suffix in {".csv", ".tsv"}:
        return "tsv" if suffix == ".tsv" else "csv"
    return "text"


def detect_encoding(raw: bytes) -> str | None:
    try:
        from charset_normalizer import from_bytes

        best = from_bytes(raw).best()
        return best.encoding if best else None
    except ImportError:
        return None


def infer_type(value: str) -> str:
    v = value.strip()
    if v == "":
        return "null"
    if INT_RE.match(v):
        return "int"
    if FLOAT_RE.match(v):
        return "float"
    if DATE_RE.match(v):
        return "date"
    if v.lower() in BOOLS:
        return "bool"
    return "str"


def preamble_lines(path: Path, encoding: str) -> int:
    """Count leading blank/`#` lines before the header (CSV exports often carry a banner)."""
    count = 0
    with path.open("r", encoding=encoding, errors="replace") as fh:
        for line in fh:
            if line.strip() == "" or line.lstrip().startswith("#"):
                count += 1
                continue
            break
    return count


def profile_csv(path: Path, kind: str) -> dict:
    raw_head = path.read_bytes()[:262_144]
    encoding = detect_encoding(raw_head) or "utf-8"
    preamble = preamble_lines(path, encoding)
    notes: list[str] = []
    with path.open("r", encoding=encoding, errors="replace", newline="") as fh:
        sample_lines = []
        for _ in range(preamble):
            next(fh, None)
        for _ in range(200):
            line = fh.readline()
            if not line:
                break
            sample_lines.append(line)
        sample = "".join(sample_lines)
        fh.seek(0)
        for _ in range(preamble):
            next(fh, None)
        delimiter = "\t" if kind == "tsv" else None
        if delimiter is None:
            try:
                delimiter = csv.Sniffer().sniff(sample, delimiters=",;|\t").delimiter
            except csv.Error:
                delimiter = ","
                notes.append("delimiter not sniffable: assumed ','")
        reader = csv.reader(fh, delimiter=delimiter)
        try:
            header = next(reader)
            if header and header[0].startswith("\ufeff"):
                header[0] = header[0].lstrip("\ufeff")
        except StopIteration:
            return {"encoding": encoding, "delimiter": delimiter, "rows": 0, "columns": 0, "notes": ["empty file"]}
        if preamble:
            notes.append(f"{preamble} leading blank/# line(s) skipped before the header")
        if not header or any(h.strip() == "" for h in header):
            notes.append("header has empty names")
        rows = 0
        ragged = 0
        dup_counter: Counter[tuple[str, ...]] = Counter()
        types: list[Counter[str]] = [Counter() for _ in header]
        nulls = [0] * len(header)
        distinct: list[set[str]] = [set() for _ in header]
        for row in reader:
            rows += 1
            if len(row) != len(header):
                ragged += 1
                row = (row + [""] * len(header))[: len(header)]
            if rows <= DUP_SCAN_ROWS:
                dup_counter[tuple(row)] += 1
            limit = rows <= PROFILE_ROWS
            for i, cell in enumerate(row):
                kind_i = infer_type(cell)
                if kind_i == "null":
                    nulls[i] += 1
                if limit:
                    types[i][kind_i] += 1
                    if kind_i != "null" and len(distinct[i]) < 5000:
                        distinct[i].add(cell)
        columns = []
        for i, name in enumerate(header):
            seen = {k: v for k, v in types[i].items() if k != "null" and v}
            if seen and set(seen) <= {"int", "float"}:
                kind = "float" if len(seen) > 1 else next(iter(seen))
            elif len(seen) <= 1:
                kind = next(iter(seen)) if seen else "null"
            else:
                kind = "mixed"
            columns.append(
                {
                    "name": name.strip() or f"(unnamed#{i + 1})",
                    "type": kind,
                    "types_seen": sorted(seen),
                    "nulls": nulls[i],
                    "distinct_sample": len(distinct[i]),
                }
            )
        if rows > DUP_SCAN_ROWS:
            notes.append(f"duplicate check limited to the first {DUP_SCAN_ROWS} rows")
        duplicates = sum(c - 1 for c in dup_counter.values() if c > 1)
    if rows > PROFILE_ROWS:
        notes.append(f"per-column scan limited to the first {PROFILE_ROWS} rows")
    if ragged:
        notes.append(f"{ragged} row(s) did not match the {len(header)}-column header")
    if duplicates:
        notes.append(f"{duplicates} duplicate row(s) by exact cell match")
    mixed = [c["name"] for c in columns if c["type"] == "mixed"]
    if mixed:
        notes.append("mixed-type columns: " + ", ".join(mixed))
    return {
        "encoding": encoding,
        "delimiter": delimiter,
        "rows": rows,
        "columns": len(header),
        "header": header[:50],
        "profile": columns[:50],
        "duplicate_rows": duplicates,
        "notes": notes,
    }


def profile_json(path: Path, text: str) -> dict:
    notes: list[str] = []
    stripped = text.lstrip()
    if stripped.startswith("["):
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            return {"shape": "invalid", "notes": [f"JSON parse error: {exc.msg} at line {exc.lineno}"]}
        rows = len(data)
        keys = sorted({k for row in data if isinstance(row, dict) for k in row})
        return {"shape": "array", "rows": rows, "keys": keys, "key_count": len(keys), "notes": notes}
    if stripped.startswith("{") and "\n{" in stripped[1:]:
        return profile_jsonl_text(text, notes)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return profile_jsonl_text(text, notes)
    return {"shape": "object", "keys": sorted(data.keys())[:50], "key_count": len(data), "notes": notes}


def profile_jsonl_text(text: str, notes: list[str]) -> dict:
    rows = 0
    bad = 0
    keys: Counter[str] = Counter()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        rows += 1
        if isinstance(obj, dict):
            keys.update(obj.keys())
    if bad:
        notes.append(f"{bad} line(s) are not valid JSON")
    return {
        "shape": "jsonl",
        "rows": rows,
        "keys": [k for k, _ in keys.most_common(50)],
        "key_count": len(keys),
        "notes": notes,
    }


def profile_parquet(path: Path, notes: list[str]) -> dict:
    import pyarrow.parquet as pq

    pf = pq.ParquetFile(str(path))
    md = pf.metadata
    schema = md.schema
    columns = []
    for i in range(md.num_columns):
        col = schema.column(i)
        chunk_compression = Counter()
        for rg in range(md.num_row_groups):
            meta = md.row_group(rg).column(i)
            if meta.compression:
                chunk_compression[meta.compression] += 1
        columns.append(
            {
                "name": col.name,
                "physical": str(col.physical_type),
                "logical": str(col.logical_type),
                "compression": sorted(chunk_compression),
            }
        )
    return {
        "rows": md.num_rows,
        "columns": md.num_columns,
        "row_groups": md.num_row_groups,
        "created_by": md.created_by,
        "size_bytes": md.serialized_size,
        "schema": columns[:50],
    }


def profile_sqlite(path: Path, notes: list[str]) -> dict:
    try:
        con = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        notes.append(f"sqlite open failed: {exc}")
        return {"tables": [], "table_count": 0, "views": 0}
    try:
        tables = [
            r[0]
            for r in con.execute(
                "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name"
            )
        ]
        out_tables = []
        for name in tables[:50]:
            quoted = name.replace('"', '""')
            count = con.execute(f'select count(*) from "{quoted}"').fetchone()[0]
            cols = [(c[1], c[2]) for c in con.execute(f'pragma table_info("{quoted}")')]
            indexes = con.execute(
                "select count(*) from sqlite_master where type='index' and tbl_name=?", (name,)
            ).fetchone()[0]
            out_tables.append({"name": name, "rows": count, "columns": cols[:50], "indexes": indexes})
        if len(tables) > 50:
            notes.append(f"{len(tables)} tables, first 50 profiled")
        views = con.execute("select count(*) from sqlite_master where type='view'").fetchone()[0]
        return {"tables": out_tables, "table_count": len(tables), "views": views}
    finally:
        con.close()


JSON_INLINE_LIMIT = 256 * 1024 * 1024


def profile_json_path(path: Path, notes: list[str]) -> dict:
    """Stream JSONL line by line; only arrays and pretty-printed objects are read whole."""
    head = path.read_bytes()[:4096].lstrip(b"\xef\xbb\xbf").lstrip()
    if head.startswith(b"["):
        if path.stat().st_size > JSON_INLINE_LIMIT:
            notes.append("large JSON array: not parsed (over 256 MB)")
            return {"shape": "array", "rows": None, "keys": [], "key_count": None}
        return profile_json(path, path.read_text(encoding="utf-8-sig", errors="replace"))
    rows = 0
    bad = 0
    lines = 0
    keys: Counter[str] = Counter()
    first_obj = None
    with path.open(encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            lines += 1
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                bad += 1
                continue
            rows += 1
            if first_obj is None:
                first_obj = obj
            if isinstance(obj, dict):
                keys.update(obj.keys())
    if lines == 1 and rows == 1 and isinstance(first_obj, dict):
        return {
            "shape": "object",
            "keys": sorted(first_obj.keys())[:50],
            "key_count": len(first_obj),
            "notes": notes,
        }
    if bad and rows == 0:
        if path.stat().st_size <= JSON_INLINE_LIMIT:
            return profile_json(path, path.read_text(encoding="utf-8-sig", errors="replace"))
        notes.append("not JSONL and over 256 MB: not parsed")
        return {"shape": "invalid", "notes": notes}
    if bad:
        notes.append(f"{bad} line(s) are not valid JSON")
    return {
        "shape": "jsonl",
        "rows": rows,
        "keys": [k for k, _ in keys.most_common(50)],
        "key_count": len(keys),
        "notes": notes,
    }


def probe(path: Path) -> dict:
    kind = sniff_kind(path)
    notes: list[str] = []
    report: dict = {
        "file": str(path.resolve()),
        "bytes": path.stat().st_size,
        "kind": kind,
        "details": None,
        "notes": notes,
    }
    try:
        if kind in {"csv", "tsv"}:
            detail = profile_csv(path, kind)
            notes.extend(detail.pop("notes"))
            report["details"] = detail
        elif kind == "json":
            detail = profile_json_path(path, notes)
            notes.extend(detail.pop("notes"))
            report["details"] = detail
        elif kind == "parquet":
            report["details"] = profile_parquet(path, notes)
        elif kind == "sqlite":
            report["details"] = profile_sqlite(path, notes)
        elif kind in {"xlsx", "docx"}:
            notes.append(f"this is a {kind} file: use doc-understanding's probe.py")
        elif kind == "image":
            notes.append("image container: use 2d-understanding")
        elif kind == "empty":
            notes.append("0-byte file: nothing to profile")
        else:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            report["details"] = {"lines": len(lines), "first": lines[0][:200] if lines else None}
            notes.append("unstructured text: no schema channel")
    except Exception as exc:
        notes.append(f"probe failed: {type(exc).__name__}: {exc}")
    return report


def human(report: dict) -> str:
    d = report["details"] or {}
    kind = report["kind"]
    lines = [f"{report['file']} ({report['bytes']} bytes, {kind})"]
    if kind in {"csv", "tsv"}:
        lines.append(
            f"  {d.get('rows')} data row(s) x {d.get('columns')} column(s), "
            f"delimiter={d.get('delimiter')!r}, encoding={d.get('encoding')}"
        )
        for col in d.get("profile", []):
            lines.append(f"  {col['name']}: {col['type']}  nulls={col['nulls']}  distinct<={col['distinct_sample']}")
    elif kind in {"json", "jsonl"}:
        lines.append(f"  shape={d.get('shape')} rows={d.get('rows')} keys={d.get('key_count')}")
        lines.append("  keys: " + ", ".join(d.get("keys", [])[:20]))
    elif kind == "parquet":
        lines.append(
            f"  {d.get('rows')} row(s) x {d.get('columns')} column(s), "
            f"{d.get('row_groups')} row group(s), {d.get('size_bytes')} metadata bytes"
        )
        for col in d.get("schema", []):
            lines.append(f"  {col['name']}: {col['physical']} {col['compression']}")
    elif kind == "sqlite":
        lines.append(f"  {d.get('table_count')} table(s), {d.get('views')} view(s)")
        for table in d.get("tables", []):
            cols = ", ".join(f"{n}" for n, _ in table["columns"][:8])
            lines.append(f"  {table['name']}: {table['rows']} row(s) [{cols}] indexes={table['indexes']}")
    else:
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
    for p in args.paths:
        if not p.is_file():
            sys.exit(f"probe.py: no such file: {p}")
    reports = [probe(p) for p in args.paths]
    if args.json:
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2))
    else:
        print("\n".join(human(r) for r in reports))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
