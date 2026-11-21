#!/usr/bin/env bash
# Structural timeline: scene cuts, black intervals, audio silence intervals.
#   scene.sh clip.mp4                     # human timeline
#   scene.sh clip.mp4 --threshold 0.3 --json
#   scene.sh clip.mp4 --min-black 0.1 --silence-db -45 --min-silence 0.5
#
# Three independent ffmpeg passes on purpose: `select` (scene cuts) drops frames,
# so chaining blackdetect after it would measure only the surviving cuts. Video
# passes read the first video stream, the silence pass the first audio stream.
#
# Scene scores are ffmpeg's `lavfi.scene_score`, a 0..1 luma-change score from
# the select filter (measured 0.65 red->black, 0.25 black->blue on an RGB
# fixture). It is not a semantic "scene change" probability: flat color cuts
# score low, camera motion scores high.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scene.sh <file> [--threshold <0..1>] [--min-black <s>] [--pix-th <0..1>]
                [--silence-db <db>] [--min-silence <s>] [--json]

  --threshold 0.2   scene score above which a frame is reported as a cut
  --min-black 0.2   shortest black interval to report (blackdetect d=)
  --pix-th 0.10     black pixel threshold (blackdetect pix_th=)
  --silence-db -40  silence level (silencedetect n=)
  --min-silence 0.3 shortest silence to report (silencedetect d=)
  --json            machine-readable intervals
EOF
}

die() {
  echo "scene.sh: $*" >&2
  exit 1
}

file=""
as_json=0
threshold=0.2
min_black=0.2
pix_th=0.10
silence_db=-40
min_silence=0.3
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      threshold=${2:-}
      shift || die "--threshold needs a value"
      ;;
    --min-black)
      min_black=${2:-}
      shift || die "--min-black needs a value"
      ;;
    --pix-th)
      pix_th=${2:-}
      shift || die "--pix-th needs a value"
      ;;
    --silence-db)
      silence_db=${2:-}
      shift || die "--silence-db needs a value"
      ;;
    --min-silence)
      min_silence=${2:-}
      shift || die "--min-silence needs a value"
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

numeric() { case "$1" in '' | *[!0-9.eE+-]*) return 1 ;; esac }
for pair in "threshold=$threshold" "min-black=$min_black" "pix-th=$pix_th" \
  "silence-db=$silence_db" "min-silence=$min_silence"; do
  name=${pair%%=*}
  value=${pair#*=}
  numeric "$value" || die "--$name must be numeric (got: $value)"
done
awk -v v="$min_silence" 'BEGIN{exit !(v > 0)}' || die "--min-silence must be > 0"
awk -v v="$min_black" 'BEGIN{exit !(v >= 0)}' || die "--min-black must be >= 0"

probe_path=$file
case "$probe_path" in -*) probe_path="./$probe_path" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/scene.XXXXXX")
trap 'rm -r "$tmp"' EXIT

duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 -- "$probe_path" 2>/dev/null || true)
case "$duration" in '' | *[!0-9.]*) duration="" ;; esac
video_n=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 -- "$probe_path" 2>/dev/null | wc -l | tr -d ' ')
audio_n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$probe_path" 2>/dev/null | wc -l | tr -d ' ')

: >"$tmp/cuts.tsv"
: >"$tmp/black.tsv"
: >"$tmp/silence.tsv"
notes=""

if [ "$video_n" -gt 0 ]; then
  # Pass 1: scene cuts. metadata=print writes "frame:/pts_time:" + score to stdout.
  ffmpeg -nostats -i "$probe_path" -map 0:v:0 -an \
    -vf "select='gt(scene,$threshold)',showinfo,metadata=print:file=-" \
    -f null - >"$tmp/scene.meta" 2>"$tmp/scene.log" || die "ffmpeg failed (scene pass)"
  awk '
    /^frame:/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^pts_time:/) { split($i, a, ":"); t = a[2] }
    }
    /^lavfi\.scene_score=/ { split($0, b, "="); printf "%.6f\t%s\n", t, b[2] }
  ' "$tmp/scene.meta" >"$tmp/cuts.tsv"

  # Pass 2: black intervals. Separate pass so blackdetect sees every frame.
  ffmpeg -nostats -i "$probe_path" -map 0:v:0 -an \
    -vf "blackdetect=d=$min_black:pix_th=$pix_th" -f null - >/dev/null 2>"$tmp/black.log" ||
    die "ffmpeg failed (blackdetect pass)"
  awk -v total="$duration" '
    function grab(line, key,   m) {
      if (match(line, key ": *[0-9.]+")) { m = substr(line, RSTART, RLENGTH); sub(key ": *", "", m); return m }
      return ""
    }
    /black_start:/ { s = grab($0, "black_start") }
    /black_end:/ { e = grab($0, "black_end") }
    /black_duration:/ {
      d = grab($0, "black_duration")
      if (s != "") {
        if (e == "") { if (total == "") next; e = total; if (d == "") d = e - s }
        if (d == "") d = e - s
        printf "%.3f\t%.3f\t%.3f\n", s, e, d
        s = ""; e = ""; d = ""
      }
    }
    END { if (s != "" && total != "") { printf "%.3f\t%.3f\t%.3f\n", s, total, total - s } }
  ' "$tmp/black.log" >"$tmp/black.tsv"
else
  notes="${notes}no video stream: scene cuts and black intervals not measured; "
fi

if [ "$audio_n" -gt 0 ]; then
  ffmpeg -nostats -i "$probe_path" -map 0:a:0 -vn \
    -af "silencedetect=n=${silence_db}dB:d=${min_silence}" -f null - >/dev/null 2>"$tmp/silence.log" ||
    die "ffmpeg failed (silencedetect pass)"
  awk -v total="$duration" '
    function grab(line, key,   m) {
      if (match(line, key ": *[0-9.]+")) { m = substr(line, RSTART, RLENGTH); sub(key ": *", "", m); return m }
      return ""
    }
    /silence_start:/ { s = grab($0, "silence_start") }
    /silence_end:/ {
      e = grab($0, "silence_end")
      d = grab($0, "silence_duration")
      if (s != "") {
        if (d == "") d = e - s
        printf "%.3f\t%.3f\t%.3f\n", s, e, d
        s = ""; e = ""; d = ""
      }
    }
    END { if (s != "" && total != "") { printf "%.3f\t%.3f\t%.3f\n", s, total, total - s } }
  ' "$tmp/silence.log" >"$tmp/silence.tsv"
else
  notes="${notes}no audio stream: silence not measured; "
fi

python3 - "$tmp" "$file" "$duration" "$threshold" "$min_black" "$pix_th" \
  "$silence_db" "$min_silence" "$as_json" "$notes" <<'PY'
import json
import os
import sys

tmp, src, duration, threshold, min_black, pix_th, silence_db, min_silence, json_flag, notes = sys.argv[1:11]
as_json = json_flag == "1"


def rows(name):
    path = os.path.join(tmp, name)
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            yield line.split("\t")


cuts = [{"t_s": round(float(t), 3), "score": round(float(s), 3)} for t, s in rows("cuts.tsv")]
black = [
    {"start_s": round(float(s), 3), "end_s": round(float(e), 3), "duration_s": round(float(d), 3)}
    for s, e, d in rows("black.tsv")
]
silence = [
    {"start_s": round(float(s), 3), "end_s": round(float(e), 3), "duration_s": round(float(d), 3)}
    for s, e, d in rows("silence.tsv")
]

note_list = [n.strip().rstrip(";") for n in notes.split(";") if n.strip()]
if cuts:
    note_list.append(
        "scene scores are luma-change scores from select (0..1), not semantic scene boundaries"
    )
if black:
    note_list.append("blackdetect uses pixel-level luma threshold, not letterbox detection")

payload = {
    "file": src,
    "duration_s": round(float(duration), 3) if duration else None,
    "settings": {
        "scene_threshold": float(threshold),
        "min_black_s": float(min_black),
        "black_pix_th": float(pix_th),
        "silence_db": float(silence_db),
        "min_silence_s": float(min_silence),
    },
    "cuts": cuts,
    "black": black,
    "silence": silence,
    "notes": note_list,
}

if as_json:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)

print("file: %s" % src)
print("duration: %s s" % ("?" if not duration else "%.3f" % float(duration)))
print("scene cuts (> %s): %d" % (threshold, len(cuts)))
for c in cuts:
    print("  t=%.3fs  score=%.3f" % (c["t_s"], c["score"]))
print("black intervals (min %ss, pix_th %s): %d" % (min_black, pix_th, len(black)))
for b in black:
    print("  %.3fs - %.3fs  (%.3fs)" % (b["start_s"], b["end_s"], b["duration_s"]))
print("silence intervals (<= %s dB, min %ss): %d" % (silence_db, min_silence, len(silence)))
for s in silence:
    print("  %.3fs - %.3fs  (%.3fs)" % (s["start_s"], s["end_s"], s["duration_s"]))
for note in note_list:
    print("note: %s" % note)
PY
