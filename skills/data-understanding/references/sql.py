#!/usr/bin/env python3
"""Read-only SQL over a data file.

    python3 sql.py orders.csv --query "select name, sum(score) from data group by 1"
    python3 sql.py events.jsonl --query "select x, count(*) from data group by 1 order by 2 desc"
    python3 sql.py part.parquet --query "select avg(a) from data"
    python3 sql.py app.db --query "select count(*) from users"

CSV/TSV/JSON/JSONL/Parquet are loaded into an in-memory SQLite table named
`data`; a real .db/.sqlite file is opened read-only (`mode=ro`) and queried in
place, so the file cannot be modified. Only SELECT/WITH queries are accepted.

Output is TSV by default (one header line), `--json` gives row objects. NULL is
printed as the empty string; that is why the header line matters.
"""

from __future__ import annotations

import argparse
import io
import json
import sqlite3
import sys
from pathlib import Path

ALLOWED_PREFIXES = ("select", "with", "explain")
# Statement-prefix checks cannot tell `WITH ... DELETE` from a SELECT, and the
# read-only connection can be lost (a URI-fragment filename). The authorizer is
# the enforcement; the prefix check only gives a clearer error.
DENIED_ACTIONS = {
    getattr(sqlite3, name)
    for name in (
        "SQLITE_INSERT",
        "SQLITE_UPDATE",
        "SQLITE_DELETE",
        "SQLITE_ATTACH",
        "SQLITE_DETACH",
        "SQLITE_ALTER_TABLE",
        "SQLITE_CREATE_INDEX",
        "SQLITE_CREATE_TABLE",
        "SQLITE_CREATE_TEMP_INDEX",
        "SQLITE_CREATE_TEMP_TABLE",
        "SQLITE_CREATE_TEMP_TRIGGER",
        "SQLITE_CREATE_TEMP_VIEW",
        "SQLITE_CREATE_TRIGGER",
        "SQLITE_CREATE_VIEW",
        "SQLITE_DROP_INDEX",
        "SQLITE_DROP_TABLE",
        "SQLITE_DROP_TEMP_INDEX",
        "SQLITE_DROP_TEMP_TABLE",
        "SQLITE_DROP_TEMP_TRIGGER",
        "SQLITE_DROP_TEMP_VIEW",
        "SQLITE_DROP_TRIGGER",
        "SQLITE_DROP_VIEW",
        "SQLITE_REINDEX",
        "SQLITE_ANALYZE",
        "SQLITE_SAVEPOINT",
        "SQLITE_VACUUM",
    )
    if hasattr(sqlite3, name)
}


READ_ONLY_PRAGMAS = {
    "table_info",
    "table_xinfo",
    "index_list",
    "index_info",
    "index_xinfo",
    "foreign_key_list",
    "database_list",
    "compile_options",
    "encoding",
    "collation_list",
    "function_list",
    "module_list",
    "pragma_list",
}


def read_only_guard(action, arg1=None, *_args):
    if action == sqlite3.SQLITE_PRAGMA:
        # pragma_table_info() and friends are SELECT-only metadata access.
        return sqlite3.SQLITE_OK if (arg1 or "").lower() in READ_ONLY_PRAGMAS else sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_DENY if action in DENIED_ACTIONS else sqlite3.SQLITE_OK


def sniff_kind(path: Path) -> str:
    with path.open("rb") as fh:
        head = fh.read(4096)
    if head.startswith(b"SQLite format 3\x00"):
        return "sqlite"
    if head.startswith(b"PAR1"):
        return "parquet"
    text = head.lstrip(b"\xef\xbb\xbf").lstrip()
    if text.startswith(b"[") or text.startswith(b"{"):
        return "json"
    first = text.splitlines()[0].decode("utf-8", "replace") if text else ""
    return "tsv" if first.count("\t") > first.count(",") else "csv"


def sniff_encoding(path: Path) -> str:
    raw = path.open("rb").read(262_144)
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return "utf-16"
    try:
        from charset_normalizer import from_bytes

        best = from_bytes(raw).best()
        return best.encoding if best else "utf-8"
    except Exception:
        return "utf-8"


def load_frame(path: Path, kind: str, strings: bool = False):
    import pandas as pd

    if kind == "parquet":
        return pd.read_parquet(path)
    if kind == "json":
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        stripped = raw.lstrip()
        if stripped.startswith("["):
            return pd.read_json(io.StringIO(raw))
        lines = [ln for ln in raw.splitlines() if ln.strip()]
        if len(lines) > 1 and _mostly_objects(lines):
            return pd.read_json(io.StringIO(raw), lines=True)
        return pd.json_normalize([json.loads(raw)])
    dtype = str if strings else None
    encoding = sniff_encoding(path)
    skip = _preamble(path)
    if kind == "tsv":
        return pd.read_csv(path, sep="\t", dtype=dtype, skiprows=skip, encoding=encoding)
    try:
        import csv as _csv

        with path.open(encoding=encoding, errors="replace") as fh:
            for _ in range(skip):
                next(fh, None)
            delimiter = _csv.Sniffer().sniff(fh.read(65536), delimiters=",;|\t").delimiter
    except Exception:
        delimiter = ","
    return pd.read_csv(path, sep=delimiter, dtype=dtype, skiprows=skip, encoding=encoding)


def _preamble(path: Path) -> int:
    count = 0
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.strip() == "" or line.lstrip().startswith("#"):
                count += 1
                continue
            break
    return count


def _mostly_objects(lines: list[str]) -> bool:
    hits = 0
    for line in lines[:20]:
        try:
            if isinstance(json.loads(line), dict):
                hits += 1
        except json.JSONDecodeError:
            return False
    return hits > 0


def run(con: sqlite3.Connection, query: str) -> tuple[list[str], list[tuple]]:
    cur = con.execute(query)
    columns = [d[0] for d in cur.description] if cur.description else []
    return columns, cur.fetchall()


def render(columns: list[str], rows: list[tuple], as_json: bool) -> None:
    if as_json:
        records = [dict(zip(columns, row, strict=False)) for row in rows]
        print(json.dumps(records, indent=2, default=str))
        return
    print("\t".join(columns))
    for row in rows:
        print("\t".join("" if v is None else str(v) for v in row))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("path", type=Path)
    parser.add_argument("--query", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--strings", action="store_true", help="load CSV/TSV cells as text (keeps leading zeros in IDs)"
    )
    args = parser.parse_args(argv)

    path: Path = args.path
    if not path.is_file():
        sys.exit(f"sql.py: no such file: {path}")
    query = args.query.strip()
    if not query.lower().startswith(ALLOWED_PREFIXES):
        sys.exit("sql.py: only SELECT/WITH/EXPLAIN queries are allowed")

    kind = sniff_kind(path)
    if kind == "sqlite":
        # as_uri() percent-encodes '?', '#' and '%': a filename cannot truncate
        # the path or drop `mode=ro` from the connection string.
        try:
            con = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
        except sqlite3.Error as exc:
            sys.exit(f"sql.py: cannot open {path}: {exc}")
    else:
        try:
            frame = load_frame(path, kind, strings=args.strings)
        except Exception as exc:
            sys.exit(f"sql.py: cannot load {kind} file: {type(exc).__name__}: {exc}")
        con = sqlite3.connect(":memory:")
        # sqlite3 cannot bind dict/list cells; JSON logs and Parquet structs are
        # common, so stringify them instead of dying in to_sql.
        frame = frame.map(lambda v: json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list, tuple)) else v)
        frame.to_sql("data", con, index=False)
    con.set_authorizer(read_only_guard)
    try:
        columns, rows = run(con, query)
    except sqlite3.Error as exc:
        sys.exit(f"sql.py: query failed: {exc}")
    finally:
        con.close()
    render(columns, rows, args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
