#!/usr/bin/env bash
# Self-test for probe.sh, loudness.sh and transcribe.sh. Builds throwaway
# fixtures with ffmpeg lavfi, then asserts measured fields, not exit codes
# (except where the exit code is the contract). No network needed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/audio-selftest.XXXXXX")
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
ff() { ffmpeg -nostdin -v error "$@"; }

tone() { ff -f lavfi -i "sine=frequency=440:duration=$1:sample_rate=$2" "${@:3}"; }

# --- fixtures -------------------------------------------------------------
tone 2 44100 -c:a pcm_s16le "$work/sine.wav"
tone 2 44100 -c:a libmp3lame -b:a 128k "$work/sine.mp3"
tone 2 44100 -af "volume=-20dB" -c:a pcm_s16le "$work/quiet.wav"
tone 2 44100 -af "volume=30dB" -c:a pcm_s16le "$work/clip.wav"
ff -f lavfi -i "anullsrc=r=44100:cl=mono:d=1" -c:a pcm_s16le "$work/silent.wav"
# 1.0s tone + 0.5s silence + 0.5s tone
tone 1 44100 -f lavfi -i "anullsrc=r=44100:cl=mono:d=0.5" \
  -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1[o]" -map "[o]" -c:a pcm_s16le "$work/gap.wav"

video_fixtures=1
ff -f lavfi -i "testsrc=size=160x120:rate=5:duration=4" \
  -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac "$work/short.mov" 2>/dev/null ||
  video_fixtures=0
if [ "$video_fixtures" = 1 ]; then
  ff -f lavfi -i "testsrc=size=160x120:rate=5:duration=2" \
    -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
    -f lavfi -i "anullsrc=r=48000:cl=stereo:d=2" \
    -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -c:a aac -shortest \
    "$work/multi.mov" 2>/dev/null || video_fixtures=0
fi

# --- probe ---------------------------------------------------------------
out=$(bash "$here/probe.sh" "$work/sine.wav" --json)
check "probe sample rate" "$(jqpy 'd["audio_streams"][0]["sample_rate"]' <<<"$out")" "44100"
check "probe channels" "$(jqpy 'd["audio_streams"][0]["channels"]' <<<"$out")" "1"
check "probe codec" "$(jqpy 'd["audio_streams"][0]["codec"]' <<<"$out")" "pcm_s16le"
check "probe kind" "$(jqpy 'd["audio_streams"][0]["kind"]' <<<"$out")" "pcm"
check "probe bits" "$(jqpy 'd["audio_streams"][0]["bits_per_sample"]' <<<"$out")" "16"
check "clean wav has no flags" "$(jqpy '[f["code"] for f in d["flags"]]' <<<"$out")" "[]"
check "probe duration" "$(jqpy 'round(d["format"]["duration_s"], 3)' <<<"$out")" "2.0"
if command -v afinfo >/dev/null 2>&1; then
  check "afinfo cross-check tracks" "$(jqpy 'd["afinfo"]["tracks"]' <<<"$out")" "1"
  check "afinfo cross-check duration" "$(jqpy 'round(d["afinfo"]["duration_s"], 3)' <<<"$out")" "2.0"
else
  echo "skip afinfo cross-check (afinfo not installed)"
fi

out=$(bash "$here/probe.sh" "$work/sine.mp3" --json)
check "mp3 classified lossy" "$(jqpy 'd["audio_streams"][0]["kind"]' <<<"$out")" "lossy"
check "lossy has no bit-depth flag" "$(jqpy '"unusual_bit_depth" in [f["code"] for f in d["flags"]]' <<<"$out")" "False"
check "mp3 flagged timestamp offset" "$(jqpy '"timestamp_offset" in [f["code"] for f in d["flags"]]' <<<"$out")" "True"

if [ "$video_fixtures" = 1 ]; then
  out=$(bash "$here/probe.sh" "$work/short.mov" --json)
  check "container duration" "$(jqpy 'round(d["format"]["duration_s"], 3)' <<<"$out")" "4.0"
  check "audio stream duration" "$(jqpy 'round(d["audio_streams"][0]["duration_s"], 3)' <<<"$out")" "2.0"
  check "duration mismatch flagged" \
    "$(jqpy '"duration_mismatch" in [f["code"] for f in d["flags"]]' <<<"$out")" "True"

  out=$(bash "$here/probe.sh" "$work/multi.mov" --json)
  check "two audio streams" "$(jqpy 'len(d["audio_streams"])' <<<"$out")" "2"
  check "multi-track flagged" \
    "$(jqpy '"multiple_audio_streams" in [f["code"] for f in d["flags"]]' <<<"$out")" "True"
  check "video flagged" "$(jqpy '"has_video" in [f["code"] for f in d["flags"]]' <<<"$out")" "True"
else
  echo "skip mov fixtures (libx264 unavailable)"
fi

set +e
err=$(bash "$here/probe.sh" "$work/nope.wav" 2>&1)
rc=$?
set -e
check "probe missing file exit" "$rc" "2"

# --- loudness ------------------------------------------------------------
out=$(bash "$here/loudness.sh" "$work/gap.wav" --json)
check "silence intervals" "$(jqpy 'd["silence"]["count"]' <<<"$out")" "1"
check "silence start" "$(jqpy 'd["silence"]["intervals"][0]["start_s"]' <<<"$out")" "1.0"
check "silence end" "$(jqpy 'd["silence"]["intervals"][0]["end_s"]' <<<"$out")" "1.5"
check "silence duration" "$(jqpy 'd["silence"]["intervals"][0]["duration_s"]' <<<"$out")" "0.5"
check "gap LUFS in band" \
  "$(jqpy '-25 <= d["loudness"]["integrated_lufs"] <= -18' <<<"$out")" "True"
check "gap samples counted" "$(jqpy 'd["clipping"]["samples"]' <<<"$out")" "88200"

out=$(bash "$here/loudness.sh" "$work/quiet.wav" --json)
check "quiet LUFS in band" \
  "$(jqpy '-45 <= d["loudness"]["integrated_lufs"] <= -38' <<<"$out")" "True"
check "quiet not clipped" "$(jqpy 'd["clipping"]["suspect"]' <<<"$out")" "False"

out=$(bash "$here/loudness.sh" "$work/sine.wav" --json)
check "sine LUFS in band" \
  "$(jqpy '-25 <= d["loudness"]["integrated_lufs"] <= -18' <<<"$out")" "True"
check "sine not clipped" "$(jqpy 'd["clipping"]["suspect"]' <<<"$out")" "False"

out=$(bash "$here/loudness.sh" "$work/clip.wav" --json)
check "clipping suspect" "$(jqpy 'd["clipping"]["suspect"]' <<<"$out")" "True"
check "clipped max volume at full scale" "$(jqpy 'd["clipping"]["max_volume_db"] >= -0.1' <<<"$out")" "True"
check "clipped true peak over 0" "$(jqpy 'd["clipping"]["true_peak_dbfs"] >= 0' <<<"$out")" "True"

out=$(bash "$here/loudness.sh" "$work/silent.wav" --json)
check "digital silence hits LUFS floor" "$(jqpy 'd["loudness"]["integrated_floor"]' <<<"$out")" "True"
check "digital silence has null true peak" "$(jqpy 'd["loudness"]["true_peak_dbfs"]' <<<"$out")" "None"

# --- transcribe ----------------------------------------------------------
set +e
err=$(WHISPER_MODEL="$work/nonexistent/ggml-x.bin" bash "$here/transcribe.sh" "$work/sine.wav" 2>&1)
rc=$?
set -e
check "missing model exit" "$rc" "2"
check "missing model names curl" "$(grep -c 'curl --fail' <<<"$err")" "2"
check "missing model names a real file" "$(grep -c 'ggml-base.bin' <<<"$err" >/dev/null && echo yes)" "yes"

tests_model=/opt/homebrew/share/whisper-cpp/for-tests-ggml-tiny.bin
if [ -f "$tests_model" ]; then
  set +e
  err=$(bash "$here/transcribe.sh" "$work/sine.wav" --model "$tests_model" 2>&1)
  rc=$?
  set -e
  check "for-tests model refused" "$rc" "2"
  check "for-tests refusal says why" "$(grep -c 'for-tests fixture' <<<"$err")" "1"
else
  echo "skip for-tests refusal (test model not installed)"
fi

head -c 1000 /dev/zero >"$work/ggml-fake.bin"
set +e
err=$(bash "$here/transcribe.sh" "$work/sine.wav" --model "$work/ggml-fake.bin" 2>&1)
rc=$?
set -e
check "undersized model refused" "$rc" "2"
check "undersized refusal says size" "$(grep -c 'too small' <<<"$err")" "1"

if command -v say >/dev/null 2>&1; then
  say -o "$work/speech.aiff" "The quick brown fox jumps over the lazy dog near the river bank."
  ff -i "$work/speech.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$work/speech.wav"
  set +e
  out=$(bash "$here/transcribe.sh" "$work/speech.wav" --json 2>"$work/transcribe.err")
  rc=$?
  set -e
  if [ "$rc" = 2 ]; then
    echo "skip transcription ($(head -1 "$work/transcribe.err"))"
  else
    check "transcribe exit" "$rc" "0"
    check "transcription has speech" "$(jqpy 'd["empty"]' <<<"$out")" "False"
    check "English keyword survives" "$(jqpy '"quick" in d["text"].lower()' <<<"$out")" "True"
    check "language detected as en" "$(jqpy 'd["language"]' <<<"$out")" "en"
    # Whisper snaps offsets to its 10 ms token grid, so the last end_s can pass
    # the file duration slightly (measured 4.000 vs 3.920).
    check "segment offsets are seconds" \
      "$(jqpy 'all(0 <= s["end_s"] <= d["audio_seconds"] + 0.2 for s in d["segments"])' <<<"$out")" "True"
    check "wall time measured" "$(jqpy 'd["wall_ms"] > 0' <<<"$out")" "True"
    check "model type reported" "$(jqpy 'd["model"]["type"] in ("tiny", "base", "small", "medium", "large")' <<<"$out")" "True"
  fi
else
  echo "skip transcription (say not available)"
fi

# --- stream duration, threshold validation, flat factor, .en guard ---
if [ "$video_fixtures" = 1 ]; then
  audio_dur=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 "$work/short.mov")
  out=$(bash "$here/loudness.sh" "$work/short.mov" --json)
  check "loudness uses audio stream duration" \
    "$(jqpy 'round(d["duration_s"], 1)' <<<"$out")" \
    "$(awk -v v="$audio_dur" 'BEGIN{printf "%.1f", v}')"
fi
set +e
bash "$here/loudness.sh" "$work/sine.wav" --silence-db abc >/dev/null 2>&1
rc_bad_db=$?
set -e
check "non-numeric --silence-db is usage error" "$rc_bad_db" "1"

out=$(bash "$here/loudness.sh" "$work/silent.wav" --json)
check "digital silence flat_factor null" "$(jqpy 'd["clipping"]["flat_factor"] is None' <<<"$out")" "True"

mkdir -p "$work/models"
head -c 2000000 /dev/zero >"$work/models/ggml-tiny.en-q5_1.bin"
set +e
bash "$here/transcribe.sh" "$work/sine.wav" --model "$work/models/ggml-tiny.en-q5_1.bin" --lang zh >/dev/null 2>&1
rc_en_guard=$?
set -e
check "quantized .en model refused for zh" "$rc_en_guard" "2"

[ "$fail" = 0 ] && echo "selftest passed" || {
  echo "selftest FAILED" >&2
  exit 1
}
