#!/usr/bin/env bash
# Self-test for the video tools. Builds lavfi fixtures, asserts measured fields.
#   bash selftest.sh
# Needs only ffmpeg/ffprobe + python3; no network, no real footage.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/video-selftest.XXXXXX")
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
check_near() { # check_near <label> <actual> <expected> <tolerance>
  local verdict
  verdict=$(python3 -c 'import sys; a,e,t=map(float,sys.argv[1:4]); print(abs(a-e) <= t)' \
    "$2" "$3" "$4")
  if [ "$verdict" = "True" ]; then
    echo "ok   $1 = $2 (±$4)"
  else
    echo "FAIL $1 = $2 (expected $3 ±$4)" >&2
    fail=1
  fi
}
jqpy() { python3 -c "import json,sys; print(eval(sys.argv[1], {'d': json.load(sys.stdin)}))" "$1"; }
round3() { python3 -c 'import sys; print(round(float(sys.argv[1]), 3))' "$1"; }

command -v ffmpeg >/dev/null || {
  echo "selftest needs ffmpeg" >&2
  exit 1
}

# --- fixtures -------------------------------------------------------------
# red | black | blue, 1 s each at 25 fps; sine 2 s then silence 1 s, so the
# timeline has cuts at 1 s and 2 s, black 1-2 s, silence 2-3 s.
ffmpeg -v error -y \
  -f lavfi -i "color=c=red:s=320x240:d=1:r=25" \
  -f lavfi -i "color=c=black:s=320x240:d=1:r=25" \
  -f lavfi -i "color=c=blue:s=320x240:d=1:r=25" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
  -f lavfi -i "anullsrc=r=44100:cl=mono:d=1" \
  -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v];[3:a][4:a]concat=n=2:v=0:a=1[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$work/cuts.mp4"

# Same frames, rotated through the display matrix only (no re-encode).
ffmpeg -v error -y -display_rotation 90 -i "$work/cuts.mp4" -c copy "$work/rot.mp4"

# Variable frame rate: drop every third frame and keep the remaining pts.
ffmpeg -v error -y -i "$work/cuts.mp4" -vf "select='not(eq(mod(n\,3),0))'" \
  -fps_mode vfr -an "$work/vfr.mp4"

# HDR tags only survive via setparams (see SKILL.md: -color_trc alone is dropped
# by libx264 on this build).
ffmpeg -v error -y -t 1 -i "$work/cuts.mp4" \
  -vf "setparams=color_trc=smpte2084:color_primaries=bt2020:colorspace=bt2020nc" \
  -c:v libx264 -an "$work/pq.mp4"

# Subtitle + attachment container.
printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' >"$work/s.srt"
printf 'note\n' >"$work/att.txt"
ffmpeg -v error -y -i "$work/cuts.mp4" -i "$work/s.srt" -attach "$work/att.txt" \
  -metadata:s:t:0 mimetype=text/plain -map 0 -map 1 -c copy -c:s srt \
  -metadata:s:s:0 language=eng "$work/both.mkv"

# --- probe: container + streams + rotation + vfr + hdr --------------------
out=$(bash "$here/probe.sh" "$work/cuts.mp4" --json)
check "cut fixture duration" "$(jqpy 'd["duration_s"]' <<<"$out")" "3.0"
check "cut fixture container" "$(jqpy '"mp4" in d["container"]["name"]' <<<"$out")" "True"
check "cut fixture bytes" "$(jqpy 'd["bytes"] > 0' <<<"$out")" "True"
check "cut fixture stream counts" \
  "$(jqpy '[d["counts"]["video"], d["counts"]["audio"], d["counts"]["subtitle"], d["counts"]["attachment"]]' <<<"$out")" \
  "[1, 1, 0, 0]"
check "cut fixture codec" "$(jqpy 'd["video"][0]["codec"]' <<<"$out")" "h264"
check "cut fixture stored size" "$(jqpy 'd["video"][0]["stored_size"]' <<<"$out")" "[320, 240]"
check "cut fixture displayed size" "$(jqpy 'd["video"][0]["displayed_size"]' <<<"$out")" "[320, 240]"
check "cut fixture rotation" "$(jqpy 'd["video"][0]["rotation_deg"]' <<<"$out")" "0"
check "cut fixture fps" "$(jqpy 'd["video"][0]["fps"]' <<<"$out")" "25.0"
check "cut fixture not vfr" "$(jqpy 'd["video"][0]["vfr"]' <<<"$out")" "False"
check "cut fixture pix_fmt" "$(jqpy 'd["video"][0]["pix_fmt"]' <<<"$out")" "yuv420p"
check "cut fixture audio channels" "$(jqpy 'd["audio"][0]["channels"]' <<<"$out")" "1"
check "cut fixture sample rate" "$(jqpy 'd["audio"][0]["sample_rate"]' <<<"$out")" "44100"
check "cut fixture audio language" "$(jqpy 'd["audio"][0]["language"]' <<<"$out")" "und"
check "cut fixture no hdr tag" "$(jqpy 'd["video"][0]["hdr"]' <<<"$out")" "None"

out=$(bash "$here/probe.sh" "$work/rot.mp4" --json)
check "rotated rotation" "$(jqpy 'd["video"][0]["rotation_deg"]' <<<"$out")" "90"
check "rotated stored size" "$(jqpy 'd["video"][0]["stored_size"]' <<<"$out")" "[320, 240]"
check "rotated displayed size swapped" "$(jqpy 'd["video"][0]["displayed_size"]' <<<"$out")" "[240, 320]"
check "rotated reported in notes" \
  "$(jqpy 'any("rotation" in n for n in d["notes"])' <<<"$out")" "True"

out=$(bash "$here/probe.sh" "$work/vfr.mp4" --json)
check "vfr flag" "$(jqpy 'd["video"][0]["vfr"]' <<<"$out")" "True"
check "vfr avg below r" \
  "$(jqpy 'd["video"][0]["fps_avg"] < d["video"][0]["fps"]' <<<"$out")" "True"
check "vfr raw rates differ" \
  "$(jqpy 'd["video"][0]["fps_r"] != d["video"][0]["fps_avg_raw"]' <<<"$out")" "True"

out=$(bash "$here/probe.sh" "$work/pq.mp4" --json)
check "hdr transfer" "$(jqpy 'd["video"][0]["color"]["transfer"]' <<<"$out")" "smpte2084"
check "hdr verdict" "$(jqpy 'd["video"][0]["hdr"]' <<<"$out")" "pq"

out=$(bash "$here/probe.sh" "$work/both.mkv" --json)
check "mkv subtitle count" "$(jqpy 'd["counts"]["subtitle"]' <<<"$out")" "1"
check "mkv attachment count" "$(jqpy 'd["counts"]["attachment"]' <<<"$out")" "1"
check "mkv per-stream bitrate unknown" "$(jqpy 'd["video"][0]["bit_rate_bps"]' <<<"$out")" "None"

bash "$here/probe.sh" "$work/cuts.mp4" | grep -q "streams: 1 video / 1 audio" &&
  echo "ok   probe human summary lists stream counts"

# --- scene: cuts, black, silence ------------------------------------------
out=$(bash "$here/scene.sh" "$work/cuts.mp4" --json)
check "scene duration" "$(jqpy 'd["duration_s"]' <<<"$out")" "3.0"
check "scene cut count" "$(jqpy 'len(d["cuts"])' <<<"$out")" "2"
check_near "first cut" "$(jqpy 'd["cuts"][0]["t_s"]' <<<"$out")" "1.0" "0.05"
check_near "second cut" "$(jqpy 'd["cuts"][1]["t_s"]' <<<"$out")" "2.0" "0.05"
check "cut scores above threshold" \
  "$(jqpy 'all(c["score"] > 0.2 for c in d["cuts"])' <<<"$out")" "True"
check "black interval count" "$(jqpy 'len(d["black"])' <<<"$out")" "1"
check_near "black start" "$(jqpy 'd["black"][0]["start_s"]' <<<"$out")" "1.0" "0.05"
check_near "black end" "$(jqpy 'd["black"][0]["end_s"]' <<<"$out")" "2.0" "0.05"
check "silence interval count" "$(jqpy 'len(d["silence"])' <<<"$out")" "1"
check_near "silence start" "$(jqpy 'd["silence"][0]["start_s"]' <<<"$out")" "2.0" "0.06"
check_near "silence end" "$(jqpy 'd["silence"][0]["end_s"]' <<<"$out")" "3.0" "0.06"

out=$(bash "$here/scene.sh" "$work/cuts.mp4" --threshold 0.4 --json)
check "higher threshold keeps one cut" "$(jqpy 'len(d["cuts"])' <<<"$out")" "1"

out=$(bash "$here/scene.sh" "$work/vfr.mp4" --json)
check "video-only file: silence skipped" "$(jqpy 'len(d["silence"])' <<<"$out")" "0"
check "video-only file: note explains" \
  "$(jqpy 'any("no audio stream" in n for n in d["notes"])' <<<"$out")" "True"

# --- frames: interval, timestamps, contact sheet --------------------------
out=$(bash "$here/frames.sh" "$work/cuts.mp4" --interval 0.5 --out "$work/f_interval" --json)
check "interval frame count" "$(jqpy 'len(d["frames"])' <<<"$out")" "6"
check "interval first t" "$(jqpy 'd["frames"][0]["t_s"]' <<<"$out")" "0.0"
check "interval last t" "$(jqpy 'd["frames"][-1]["t_s"]' <<<"$out")" "2.5"
check "interval frame files exist" \
  "$(jqpy 'all(__import__("os").path.getsize(f["path"]) > 0 for f in d["frames"])' <<<"$out")" \
  "True"

out=$(bash "$here/frames.sh" "$work/cuts.mp4" --at 1.0,2.5 --out "$work/f_at" --json)
check "at-mode frame count" "$(jqpy 'len(d["frames"])' <<<"$out")" "2"
check "at-mode exact timestamp" "$(jqpy 'd["frames"][0]["t_s"]' <<<"$out")" "1.0"
check_near "at-mode snaps to next frame" "$(jqpy 'd["frames"][1]["t_s"]' <<<"$out")" "2.5" "0.05"
check "at-mode records request" "$(jqpy 'd["frames"][1]["requested_t_s"]' <<<"$out")" "2.5"

out=$(bash "$here/frames.sh" "$work/cuts.mp4" --tile 4 --out "$work/f_tile" --json)
check "tile cells" "$(jqpy 'd["sheet"]["cells"]' <<<"$out")" "4"
check "tile grid" "$(jqpy 'd["sheet"]["grid"]' <<<"$out")" "4x1"
check "tile step" "$(jqpy 'd["sheet"]["step_s"]' <<<"$out")" "0.75"
check "tile sheet geometry" "$(jqpy 'd["sheet"]["size"]' <<<"$out")" "640x120"
check "tile sheet exists" \
  "$(jqpy '__import__("os").path.getsize(d["sheet"]["path"]) > 0' <<<"$out")" "True"

# --- human output is readable, not just JSON ------------------------------
bash "$here/frames.sh" "$work/cuts.mp4" --tile 4 --out "$work/f_tile" | grep -q "4x1 grid" &&
  echo "ok   frames human sheet summary"
bash "$here/scene.sh" "$work/cuts.mp4" | grep -q "scene cuts (> 0.2): 2" &&
  echo "ok   scene human summary"

# One measured number worth keeping visible: where fps=1/S sampling lands.
out=$(bash "$here/frames.sh" "$work/cuts.mp4" --interval 0.5 --out "$work/f_note" --json)
echo "note: sampling grid for --interval 0.5 on the 3 s fixture = $(jqpy '[f["t_s"] for f in d["frames"]]' <<<"$out")"

# --- seek verification on a non-zero-start container; numeric validation ---
ffmpeg -v error -i "$work/cuts.mp4" -c copy "$work/cuts.ts" -y 2>/dev/null || true
if [ -s "$work/cuts.ts" ]; then
  err=$work/ts.err
  out=$(bash "$here/frames.sh" "$work/cuts.ts" --at 2.2 --out "$work/ts_frames" --json 2>"$err" || true)
  if [ -z "$out" ]; then
    echo "TS seek produced no JSON; frames.sh stderr:"
    sed 's/^/  /' "$err"
  fi
  check "TS seek lands within a quarter second" \
    "$(jqpy 'bool(d["frames"]) and abs(d["frames"][0]["t_s"] - 2.2) <= 0.25' <<<"$out")" "True"
  set +e
  bash "$here/frames.sh" "$work/cuts.ts" --at 0.2 --out "$work/ts_early" >/dev/null 2>"$work/ts_early.err"
  rc_early=$?
  set -e
  if [ "$rc_early" != 3 ]; then
    echo "early TS seek rc=$rc_early; frames.sh stderr:"
    sed 's/^/  /' "$work/ts_early.err"
  fi
  check "TS seek before first frame reports no frame" "$rc_early" "3"
fi
set +e
bash "$here/frames.sh" "$work/cuts.mp4" --width 100.5 --out "$work/bad_w" >/dev/null 2>&1
rc_width=$?
set -e
check "float --width rejected" "$rc_width" "1"

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
