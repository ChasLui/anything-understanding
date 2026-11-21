#!/usr/bin/env bash
# Self-test for the data tools. Builds fixtures, asserts measured fields.
#   bash selftest.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/data-selftest.XXXXXX")
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
import json
import sqlite3
import sys

import pyarrow as pa
import pyarrow.parquet as pq

w = sys.argv[1]

# Semicolon CSV: quoted comma, int+float in one column, one null, one duplicate row.
with open(f"{w}/semi.csv", "w") as fh:
    fh.write('id;name;score\n1;"Doe, Jane";9.5\n2;Bob;\n3;Amy;7\n3;Amy;7\n')

# Mixed-type column and a ragged row.
with open(f"{w}/mixed.csv", "w") as fh:
    fh.write("id,val\n1,10\n2,n/a\n3,30\n4,40,extra\n")

# Tabs in a .csv file: kind must come from content, not suffix.
with open(f"{w}/tabs.csv", "w") as fh:
    fh.write("a\tb\n1\t2\n")

# JSON array, JSONL with one malformed line.
with open(f"{w}/arr.json", "w") as fh:
    json.dump([{"id": 1, "name": "a"}, {"id": 2}], fh)
with open(f"{w}/lines.jsonl", "w") as fh:
    fh.write('{"id": 1}\n{"id": 2, "x": true}\nnot json\n')

# Parquet with zstd.
pq.write_table(pa.table({"a": [1, 2, None], "b": ["x", "y", "z"]}), f"{w}/p.parquet", compression="zstd")

# SQLite with two tables and one index.
con = sqlite3.connect(f"{w}/t.db")
con.execute("create table users(id integer primary key, name text)")
con.executemany("insert into users(name) values(?)", [("a",), ("b",)])
con.execute("create index ix_users_name on users(name)")
con.execute("create table orders(id integer, amount real)")
con.execute("insert into orders values(1, 9.5)")
con.commit()
con.close()

# Wide CSV that exceeds the per-column scan bound (PROFILE_ROWS = 50000).
with open(f"{w}/wide.csv", "w") as fh:
    fh.write("id,val\n")
    for i in range(50_010):
        fh.write(f"{i},v\n")

# Excel must be delegated, not half-parsed.
import openpyxl

wb = openpyxl.Workbook()
wb.active["A1"] = "x"
wb.save(f"{w}/s.xlsx")
PY

# --- csv ---
out=$(python3 "$here/probe.py" "$work/semi.csv" --json)
check "csv delimiter" "$(jqpy 'repr(d["details"]["delimiter"])' <<<"$out")" "';'"
check "csv rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "4"
check "csv columns" "$(jqpy 'd["details"]["columns"]' <<<"$out")" "3"
check "csv int+float is float" "$(jqpy '[c["type"] for c in d["details"]["profile"] if c["name"]=="score"][0]' <<<"$out")" "float"
check "csv nulls" "$(jqpy '[c["nulls"] for c in d["details"]["profile"] if c["name"]=="score"][0]' <<<"$out")" "1"
check "csv duplicates" "$(jqpy 'd["details"]["duplicate_rows"]' <<<"$out")" "1"
printf '# exported 2026-11-21\nid,val\n1,a\n2,b\n' >"$work/banner.csv"
out=$(python3 "$here/probe.py" "$work/banner.csv" --json)
check "banner columns" "$(jqpy 'd["details"]["columns"]' <<<"$out")" "2"
check "banner rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "2"
check "banner note" "$(jqpy 'any("skipped before the header" in n for n in d["notes"])' <<<"$out")" "True"
check "banner sql rows" "$(python3 "$here/sql.py" "$work/banner.csv" --query 'select count(*) c from data' | tail -1)" "2"

out=$(python3 "$here/probe.py" "$work/mixed.csv" --json)
check "csv mixed type" "$(jqpy '[c["type"] for c in d["details"]["profile"] if c["name"]=="val"][0]' <<<"$out")" "mixed"
check "ragged row note" "$(jqpy 'any("did not match" in n for n in d["notes"])' <<<"$out")" "True"

out=$(python3 "$here/probe.py" "$work/tabs.csv" --json)
check "tabs csv sniffed as tsv" "$(jqpy 'd["kind"]' <<<"$out")" "tsv"

out=$(python3 "$here/probe.py" "$work/wide.csv" --json)
check "scan bound reported" "$(jqpy 'any("limited to the first 50000 rows" in n for n in d["notes"])' <<<"$out")" "True"

# --- json ---
out=$(python3 "$here/probe.py" "$work/arr.json" --json)
check "json shape" "$(jqpy 'd["details"]["shape"]' <<<"$out")" "array"
check "json rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "2"
check "json keys" "$(jqpy 'd["details"]["keys"]' <<<"$out")" "['id', 'name']"

out=$(python3 "$here/probe.py" "$work/lines.jsonl" --json)
check "jsonl shape" "$(jqpy 'd["details"]["shape"]' <<<"$out")" "jsonl"
check "jsonl rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "2"
check "jsonl bad line note" "$(jqpy 'any("not valid JSON" in n for n in d["notes"])' <<<"$out")" "True"

# --- parquet / sqlite / delegation ---
out=$(python3 "$here/probe.py" "$work/p.parquet" --json)
check "parquet rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "3"
check "parquet columns" "$(jqpy 'd["details"]["columns"]' <<<"$out")" "2"
check "parquet row groups" "$(jqpy 'd["details"]["row_groups"]' <<<"$out")" "1"
check "parquet compression" "$(jqpy 'd["details"]["schema"][0]["compression"]' <<<"$out")" "['ZSTD']"

out=$(python3 "$here/probe.py" "$work/t.db" --json)
check "sqlite tables" "$(jqpy '[t["name"] for t in d["details"]["tables"]]' <<<"$out")" "['orders', 'users']"
check "sqlite users rows" "$(jqpy '[t["rows"] for t in d["details"]["tables"] if t["name"]=="users"][0]' <<<"$out")" "2"
check "sqlite index counted" "$(jqpy '[t["indexes"] for t in d["details"]["tables"] if t["name"]=="users"][0]' <<<"$out")" "1"

out=$(python3 "$here/probe.py" "$work/s.xlsx" --json)
check "xlsx delegated" "$(jqpy 'any("doc-understanding" in n for n in d["notes"])' <<<"$out")" "True"
printf "" >"$work/empty.csv"
out=$(python3 "$here/probe.py" "$work/empty.csv" --json)
check "empty file kind" "$(jqpy 'd["kind"]' <<<"$out")" "empty"
check "empty file note" "$(jqpy 'any("0-byte file" in n for n in d["notes"])' <<<"$out")" "True"
printf "only_one_column\n1\n2\n" >"$work/single.csv"
out=$(python3 "$here/probe.py" "$work/single.csv" --json)
check "single-column csv by suffix" "$(jqpy 'd["kind"]' <<<"$out")" "csv"
check "single-column rows" "$(jqpy 'd["details"]["rows"]' <<<"$out")" "2"
printf 'id,,val\n1,2,3\n' >"$work/unnamed.csv"
out=$(python3 "$here/probe.py" "$work/unnamed.csv" --json)
check "empty header named" "$(jqpy 'd["details"]["profile"][1]["name"]' <<<"$out")" "(unnamed#2)"
check "empty header note" "$(jqpy 'any("empty names" in n for n in d["notes"])' <<<"$out")" "True"

# --- sql ---
check "sql csv aggregate" "$(python3 "$here/sql.py" "$work/semi.csv" \
  --query 'select count(*) n, sum(score) total from data' | tr '\t' ' ' | xargs)" "n total 4 23.5"
check "sql sqlite query" "$(python3 "$here/sql.py" "$work/t.db" --query 'select count(*) from users' | tail -1)" "2"
check "sql joins two tables" "$(python3 "$here/sql.py" "$work/t.db" --query 'select count(*) from users, orders' | tail -1)" "2"
printf 'code,note\n007,x\n010,y\n' >"$work/lead.csv"
check "sql loses leading zeros by default" "$(python3 "$here/sql.py" "$work/lead.csv" --query 'select code from data' | sed -n 2p)" "7"
check "sql strings keeps leading zeros" "$(python3 "$here/sql.py" "$work/lead.csv" --strings --query 'select code from data' | sed -n 2p)" "007"
set +e
msg=$(python3 "$here/sql.py" "$work/semi.csv" --query 'delete from data' 2>&1)
rc=$?
set -e
check "sql write rejected rc" "$rc" "1"
check "sql write rejected message" "$(grep -c 'only SELECT/WITH/EXPLAIN' <<<"$msg")" "1"

# --- encoding, BOM, nested values, pragma reads (review regressions) ---
printf '\xef\xbb\xbfname,score\nalice,1\n' >"$work/bomh.csv"
check "csv BOM header clean" \
  "$(python3 "$here/probe.py" "$work/bomh.csv" --json | jqpy 'd["details"]["header"][0]')" "name"
printf '{"id":1,"meta":{"a":1}}\n{"id":2,"meta":{"a":2}}\n' >"$work/nested.jsonl"
check "nested json stringified" \
  "$(python3 "$here/sql.py" "$work/nested.jsonl" --query 'select meta from data' | sed -n 2p)" '{"a": 1}'
printf '\xef\xbb\xbf{"a":1}\n{"a":2}\n' >"$work/bomj.jsonl"
check "sql reads BOM jsonl" \
  "$(python3 "$here/sql.py" "$work/bomj.jsonl" --query 'select count(*) from data' | tail -1)" "2"
printf 'name,city\nJosé,München\n' >"$work/utf8.csv"
iconv -f UTF-8 -t LATIN1 "$work/utf8.csv" >"$work/latin1.csv" 2>/dev/null || true
if [ -s "$work/latin1.csv" ]; then
  check "sql reads latin-1 csv" \
    "$(python3 "$here/sql.py" "$work/latin1.csv" --query 'select city from data' | sed -n 2p)" "München"
fi
check "pragma table_info select works" \
  "$(python3 "$here/sql.py" "$work/t.db" --query "select count(*) > 0 from pragma_table_info('users')" | tail -1)" "1"

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
