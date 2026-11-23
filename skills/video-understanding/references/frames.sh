#!/usr/bin/env bash
# Frame extraction: stills by interval or by timestamp, plus contact sheets.
#   frames.sh clip.mp4 --interval 1 --out frames/
#   frames.sh clip.mp4 --at 0.5,2.0,7.25 --out frames/
#   frames.sh clip.mp4 --tile 8 --out frames/ [--cols 4] [--width 320]
#   frames.sh ... --json            # manifest: path + measured timestamp
#
# Timestamps are NOT arithmetic: each written frame's pts_time is read back from
# ffmpeg's showinfo, so the manifest says where the frame really is. With 25 fps
# a request for 0.5 s yields the frame at 0.52 s — the first frame at or after
# the request — and the manifest records 0.52.
#
# Seeks in --at mode use input seek (`-ss` before `-i`) with `-copyts`, which on
# ffmpeg 9.0.2 was both faster and frame-identical to output seek in every test
# (see SKILL.md). Exit 3 means a requested timestamp had no frame (past EOF).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: frames.sh <file> --out <dir> (--interval <s> | --at <t1,t2,...> | --tile <n>)
                  [--cols <n>] [--width <px>] [--quality <1-31>] [--json]

  --interval S   one frame every S seconds (fps=1/S; first frame at t=0)
  --at LIST      one frame per comma-separated timestamp
  --tile N       one contact sheet of N frames (grid --cols wide, default 4)
  --width PX     contact-sheet cell width (default 160, height keeps aspect)
  --quality Q    JPEG quality for stills, lower is better (default 2)
  --json         print a manifest instead of the human summary
EOF
}

die() {
  echo "frames.sh: $*" >&2
  exit 1
}

file=""
out=""
interval=""
at_list=""
tile_n=""
cols=4
width=160
quality=2
as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      out=${2:-}
      shift || die "--out needs a directory"
      ;;
    --interval)
      interval=${2:-}
      shift || die "--interval needs a number"
      ;;
    --at)
      at_list=${2:-}
      shift || die "--at needs a list"
      ;;
    --tile)
      tile_n=${2:-}
      shift || die "--tile needs a count"
      ;;
    --cols)
      cols=${2:-}
      shift || die "--cols needs a number"
      ;;
    --width)
      width=${2:-}
      shift || die "--width needs a number"
      ;;
    --quality)
      quality=${2:-}
      shift || die "--quality needs a number"
      ;;
    --json) as_json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$file" ] || die "one file at a time"
      file=$1
      ;;
  esac
  shift
done

[ -n "$file" ] || {
  usage
  exit 1
}
[ -f "$file" ] || die "no such file: $file"
command -v ffmpeg >/dev/null 2>&1 || die "needs ffmpeg"
command -v ffprobe >/dev/null 2>&1 || die "needs ffprobe"
[ -n "$out" ] || die "--out <dir> is required"

numeric() { case "$1" in '' | *[!0-9.eE+-]*) return 1 ;; esac }
decimal() { case "$1" in '' | *[!0-9.]* | *.*.*) return 1 ;; esac }
integer() { case "$1" in '' | *[!0-9]*) return 1 ;; esac }
integer "$quality" || die "--quality must be an integer (1-31)"
integer "$width" || die "--width must be an integer"
integer "$cols" || die "--cols must be an integer"
numeric "$quality" || die "--quality must be numeric"

probe_path=$file
case "$probe_path" in -*) probe_path="./$probe_path" ;; esac

# --interval is the sampling step for --tile when both are given; --at never
# combines with anything.
[ -z "$tile_n" ] || [ -z "$at_list" ] || die "--at cannot be combined with --tile"
if [ -z "$interval" ] && [ -z "$at_list" ] && [ -z "$tile_n" ]; then
  die "pick one of --interval, --at, --tile"
fi
if [ -n "$interval" ]; then
  decimal "$interval" || die "--interval must be a decimal number"
  numeric "$interval" || die "--interval must be numeric"
  awk -v v="$interval" 'BEGIN{exit !(v > 0)}' || die "--interval must be > 0"
fi
[ -z "$at_list" ] || numeric "${at_list%%,*}" || die "--at values must be numeric"
if [ -n "$tile_n" ]; then
  case "$tile_n" in *[!0-9]*) die "--tile must be a positive integer" ;; esac
  [ "$tile_n" -gt 0 ] || die "--tile must be a positive integer"
  [ "$cols" -gt 0 ] || die "--cols must be > 0"
fi

# ffprobe may print one line per matching stream; take the first non-empty line.
duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 -- "$probe_path" 2>/dev/null | awk 'NF {print $1; exit}' || true)
case "$duration" in '' | *[!0-9.]*) duration="" ;; esac
fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 -- "$probe_path" 2>/dev/null | awk 'NF {print $1; exit}' || true)
seek_tolerance=$(awk -v f="$fps" 'BEGIN { split(f, a, "/"); r = (a[2] ? a[1] / a[2] : a[1]); t = (r > 0 ? 1.05 / r : 0.25); if (t < 0.25) t = 0.25; if (t > 1.0) t = 1.0; printf "%.3f", t }')

tmp=$(mktemp -d "${TMPDIR:-/tmp}/frames.XXXXXX")
trap 'rm -r "$tmp"' EXIT
mkdir -p "$out"
out=$(cd "$out" && pwd)

# rows for the manifest: n <TAB> path <TAB> measured_t <TAB> requested_t
: >"$tmp/rows.tsv"
missing=""
if [ -n "$tile_n" ]; then
  [ -n "$duration" ] || die "--tile needs a container duration; ffprobe reported none"
  if [ -n "$interval" ]; then
    step=$interval
  else
    step=$(awk -v d="$duration" -v n="$tile_n" 'BEGIN{printf "%.6f", d / n}')
  fi
  rows=$(((tile_n + cols - 1) / cols))
  sheet=$out/sheet_${tile_n}f_${cols}x${rows}.png
  ffmpeg -nostats -y -i "$probe_path" \
    -vf "fps=1/$step,scale=$width:-2,tile=${cols}x${rows}" -frames:v 1 "$sheet" \
    2>"$tmp/tile.log" || die "ffmpeg failed (contact sheet)"
  [ -s "$sheet" ] || die "contact sheet not written"
  dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0 -- "$sheet" 2>/dev/null || true)
  printf '0\t%s\t%s\t%s\n' "$sheet" "$step" "${dims//,/x}" >>"$tmp/rows.tsv"
elif [ -n "$interval" ]; then
  : >"$tmp/log"
  ffmpeg -nostats -y -i "$probe_path" -vf "fps=1/$interval,showinfo" -q:v "$quality" \
    "$out/frame_%03d.jpg" 2>"$tmp/log" || die "ffmpeg failed (interval extraction)"
  grep -oE 'pts_time:[0-9.]+' "$tmp/log" | sed 's/^pts_time://' >"$tmp/pts" || true
  n=0
  while IFS= read -r t; do
    n=$((n + 1))
    src=$(printf '%s/frame_%03d.jpg' "$out" "$n")
    [ -f "$src" ] || continue
    dst=$(printf '%s/frame_%03d_t%.3f.jpg' "$out" "$n" "$t")
    mv "$src" "$dst"
    printf '%d\t%s\t%s\t%s\n' "$n" "$dst" "$t" "$t" >>"$tmp/rows.tsv"
  done <"$tmp/pts"
  [ "$n" -gt 0 ] || die "no frames extracted (interval $interval)"
else
  n=0
  missing=""
  IFS=',' read -r -a stamps <<<"$at_list"
  for stamp in "${stamps[@]}"; do
    stamp=$(echo "$stamp" | tr -d ' ')
    decimal "$stamp" || die "--at value must be a decimal number of seconds: $stamp"
    n=$((n + 1))
    src=$out/frame_$(printf '%03d' "$n").jpg
    log=$tmp/at_$n.log
    seek_ok=0
    # Fast path: input seek keeps container pts with -copyts. On containers with a
    # non-zero start_time (MPEG-TS ~1.8 s) it can land seconds away, so the result
    # is verified and, on a miss, retried as an exact output seek (slow but right).
    for mode in fast loose exact; do
      set +e
      case "$mode" in
        fast)
          ffmpeg -nostats -y -ss "$stamp" -copyts -i "$probe_path" -frames:v 1 \
            -vf showinfo -q:v "$quality" "$src" 2>"$log"
          ;;
        loose)
          # Land on the frame covering the request instead of emitting nothing
          # when the next frame is past the end (low-fps clips).
          ffmpeg -nostats -y -ss "$stamp" -noaccurate_seek -copyts -i "$probe_path" -frames:v 1 \
            -vf showinfo -q:v "$quality" "$src" 2>"$log"
          ;;
        *)
          ffmpeg -nostats -y -i "$probe_path" -ss "$stamp" -copyts -frames:v 1 \
            -vf showinfo -q:v "$quality" "$src" 2>"$log"
          ;;
      esac
      rc=$?
      set -e
      if [ "$mode" = exact ]; then
        measured=$(grep -oE 'pts_time:[0-9.]+' "$log" | sed 's/^pts_time://' | tail -1 || true)
      else
        measured=$(grep -oE 'pts_time:[0-9.]+' "$log" | sed 's/^pts_time://' | sed -n '1p' || true)
      fi
      if [ "$rc" -eq 0 ] && [ -s "$src" ] && [ -n "$measured" ] &&
        awk -v m="$measured" -v s="$stamp" -v tol="$seek_tolerance" 'BEGIN{exit !((m - s) <= tol && (s - m) <= tol)}'; then
        seek_ok=1
        break
      fi
      rm -f "$src"
    done
    if [ "$seek_ok" -ne 1 ]; then
      echo "frames.sh: no frame at ${stamp}s (before start, past EOF, or seek landed elsewhere)" >&2
      missing="${missing}${missing:+,}$stamp"
      continue
    fi
    dst=$(printf '%s/frame_%03d_t%.3f.jpg' "$out" "$n" "$measured")
    mv "$src" "$dst"
    printf '%d\t%s\t%s\t%s\n' "$n" "$dst" "$measured" "$stamp" >>"$tmp/rows.tsv"
  done
fi

python3 - "$tmp/rows.tsv" "$file" "$out" "${interval:-}" "${at_list:-}" "${tile_n:-}" \
  "$cols" "$width" "${duration:-}" "$as_json" <<'PY'
import json
import sys

rows_path, src, out_dir, interval, at_list, tile_n, cols, width, duration, json_flag = sys.argv[1:11]
rows = [line.rstrip("\n").split("\t") for line in open(rows_path, encoding="utf-8") if line.strip()]
as_json = json_flag == "1"

frames, sheet = [], None
if tile_n:
    for row in rows:
        n, path, step, dims = row
        sheet = {
            "path": path,
            "grid": "%sx%s" % (cols, (int(tile_n) + int(cols) - 1) // int(cols)),
            "cells": int(tile_n),
            "cell_width": int(width),
            "step_s": float(step),
            "size": dims if dims != "0" else None,
        }
else:
    for row in rows:
        n, path, measured, requested = row
        frames.append(
            {
                "n": int(n),
                "path": path,
                "t_s": float(measured),
                "requested_t_s": float(requested),
            }
        )

mode = "tile" if tile_n else ("interval" if interval else "at")
notes = []
if frames:
    offsets = [round(f["t_s"] - f["requested_t_s"], 3) for f in frames]
    if any(abs(o) > 1e-6 for o in offsets):
        notes.append("requested timestamps snap forward to the next decoded frame")
if sheet:
    notes.append(
        "contact sheet is tiled from fps=1/%s frames; the sheet is one image, "
        "cell timestamps are not stored in it" % sheet["step_s"]
    )

payload = {
    "file": src,
    "mode": mode,
    "out_dir": out_dir,
    "duration_s": float(duration) if duration else None,
    "timestamp_source": "ffmpeg showinfo pts_time of each written frame",
    "frames": frames,
    "sheet": sheet,
    "notes": notes,
}

if as_json:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)

print("file: %s" % src)
print("mode: %s | out: %s" % (mode, out_dir))
if sheet:
    print(
        "sheet: %s | %s cells in a %s grid | cell %dpx | size %s | step %s s"
        % (
            sheet["path"],
            sheet["cells"],
            sheet["grid"],
            sheet["cell_width"],
            sheet["size"] or "unknown",
            sheet["step_s"],
        )
    )
for f in frames:
    print("  %s  t=%ss" % (f["path"], f["t_s"]))
if not sheet:
    print("%d frame%s" % (len(frames), "" if len(frames) == 1 else "s"))
for note in notes:
    print("note: %s" % note)
PY

[ -z "$missing" ] || exit 3
