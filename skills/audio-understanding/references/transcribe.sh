#!/usr/bin/env bash
# Speech to timed text with whisper.cpp, plus the model provenance that decides
# how much the text can be trusted.
#   transcribe.sh FILE                 # human summary
#   transcribe.sh FILE --json          # machine-readable
#   transcribe.sh FILE --lang zh       # force a language ('auto' detects)
#   transcribe.sh FILE --model PATH
#
# Model resolution: --model, then $WHISPER_MODEL, then ~/.cache/whisper.cpp,
# then /opt/homebrew/share/whisper-cpp, then ./models. for-tests-* fixtures are
# refused by name (they have no weights and transcribe to nothing) and anything
# under 1 MB is refused by size.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

download_hint() {
  cat >&2 <<'HINT'
Download a real model (74 MB tiny, 142 MB base):
  mkdir -p ~/.cache/whisper.cpp
  curl -L -o ~/.cache/whisper.cpp/ggml-tiny.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
  curl -L -o ~/.cache/whisper.cpp/ggml-base.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
Or point at an existing one: --model /path/to/ggml-small.bin (or WHISPER_MODEL=...).
HINT
}

file=""
as_json=0
lang=auto
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    --lang)
      lang=${2:?--lang needs a value}
      shift
      ;;
    --model)
      model=${2:?--model needs a path}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "transcribe.sh: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$file" ]; then
        echo "transcribe.sh: one file at a time" >&2
        exit 1
      fi
      file=$1
      ;;
  esac
  shift
done
[ -n "$file" ] || {
  usage >&2
  exit 1
}
[ -r "$file" ] || {
  echo "transcribe.sh: cannot read: $file" >&2
  exit 2
}
for tool in ffmpeg ffprobe whisper-cli python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "transcribe.sh: $tool not found (brew install ffmpeg whisper-cpp)" >&2
    exit 3
  }
done

# Quality ladder, not a glob: an .en model would be picked first alphabetically
# and then produce English guesses for Chinese audio.
pick_in_dir() {
  for name in ggml-small.bin ggml-base.bin ggml-tiny.bin ggml-medium.bin \
    ggml-large-v3-turbo.bin ggml-large-v3.bin ggml-large-v2.bin ggml-large-v1.bin; do
    if [ -f "$1/$name" ]; then
      printf '%s\n' "$1/$name"
      return 0
    fi
  done
  for candidate in "$1"/ggml-*.bin; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

if [ -z "$model" ] && [ -n "${WHISPER_MODEL:-}" ]; then
  model=$WHISPER_MODEL
fi
if [ -z "$model" ]; then
  for dir in "$HOME/.cache/whisper.cpp" /opt/homebrew/share/whisper-cpp ./models; do
    if model=$(pick_in_dir "$dir"); then break; fi
    model=""
  done
fi
if [ -z "$model" ] || [ ! -f "$model" ]; then
  [ -n "$model" ] && echo "transcribe.sh: model not found: $model" >&2
  download_hint
  exit 2
fi

base=$(basename "$model")
case "$base" in
  for-tests-*)
    cat >&2 <<MSG
transcribe.sh: refusing model $model
  It is a for-tests fixture: real whisper.cpp metadata, no weights. It loads,
  exits 0 and returns an empty transcript (measured on this host), so using it
  would turn "no speech" into a silent lie. Download a real model instead:
MSG
    download_hint
    exit 2
    ;;
esac
model_bytes=$(wc -c <"$model" | tr -d ' ')
if [ "$model_bytes" -lt 1048576 ]; then
  echo "transcribe.sh: refusing model $model (${model_bytes} bytes, <1 MB): too small to hold weights." >&2
  download_hint
  exit 2
fi
case "$base" in
  *.en.bin | *.en-*.bin | *-en.bin | *-en-*.bin)
    if [ "$lang" = auto ]; then
      echo "transcribe.sh: $base is English-only; auto language may transcribe other languages as English" >&2
    elif [ "$lang" != en ]; then
      echo "transcribe.sh: $base is English-only but --lang $lang was requested" >&2
      echo "  use a multilingual model (ggml-base.bin, ggml-small.bin) for other languages" >&2
      exit 2
    fi
    ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/audio-transcribe.XXXXXX")
trap 'rm -r "$tmp"' EXIT

if ! ffmpeg -nostdin -v error -i "$file" -ar 16000 -ac 1 -c:a pcm_s16le "$tmp/in.wav" 2>"$tmp/ffmpeg.err"; then
  echo "transcribe.sh: ffmpeg could not decode: $file" >&2
  tail -3 "$tmp/ffmpeg.err" >&2
  exit 4
fi
audio_seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/in.wav")

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
start_ms=$(now_ms)
if ! whisper-cli -m "$model" -f "$tmp/in.wav" -l "$lang" -oj -of "$tmp/asr" -np \
  >"$tmp/whisper.out" 2>"$tmp/whisper.err"; then
  echo "transcribe.sh: whisper-cli failed (model: $model)" >&2
  grep -v 'load_backend\|^ggml_' "$tmp/whisper.err" | tail -3 >&2
  exit 5
fi
end_ms=$(now_ms)
wall_ms=$((end_ms - start_ms))

[ -f "$tmp/asr.json" ] || {
  echo "transcribe.sh: whisper-cli wrote no JSON (-oj failed)" >&2
  tail -3 "$tmp/whisper.err" >&2
  exit 5
}

FILE="$file" MODEL="$model" MODEL_BYTES="$model_bytes" LANG_REQ="$lang" \
  WALL_MS="$wall_ms" AUDIO_S="$audio_seconds" AS_JSON="$as_json" \
  python3 - "$tmp/asr.json" <<'PY'
import json, os, sys

data = json.load(open(sys.argv[1]))
model_info = data.get("model") or {}
params = data.get("params") or {}
result = data.get("result") or {}
segments = []
for seg in data.get("transcription") or []:
    offsets = seg.get("offsets") or {}
    segments.append({
        "start_s": round(float(offsets.get("from", 0)) / 1000.0, 3),
        "end_s": round(float(offsets.get("to", 0)) / 1000.0, 3),
        "text": (seg.get("text") or "").strip(),
    })
text = "".join(seg["text"] for seg in segments).strip()
wall_ms = int(os.environ["WALL_MS"])
audio_s = float(os.environ["AUDIO_S"])
report = {
    "file": os.environ["FILE"],
    "model": {
        "path": os.environ["MODEL"],
        "name": os.path.basename(os.environ["MODEL"]),
        "bytes": int(os.environ["MODEL_BYTES"]),
        "type": model_info.get("type"),
        "multilingual": model_info.get("multilingual"),
    },
    "language_requested": os.environ["LANG_REQ"],
    "language": result.get("language"),
    "translate": params.get("translate"),
    "audio_seconds": round(audio_s, 3),
    "wall_ms": wall_ms,
    "realtime_factor": round(audio_s / (wall_ms / 1000.0), 1) if wall_ms > 0 and audio_s else None,
    "empty": not segments,
    "text": text,
    "segments": segments,
}
if not segments:
    print("transcribe.sh: no speech segments (silence, wrong language, or a test model)",
          file=sys.stderr)
if os.environ["AS_JSON"] == "1":
    print(json.dumps(report, indent=2, ensure_ascii=False))
    sys.exit(0)

mb = report["model"]["bytes"] / 1048576.0
print(f"file      {report['file']}")
print(f"model     {report['model']['type']} "
      f"({'multilingual' if report['model']['multilingual'] else 'English-only'}, {mb:.1f} MB) "
      f"{report['model']['path']}")
lang = report["language"] or "unknown"
echoed = " (echoes --lang, not a detection)" if report["language_requested"] != "auto" else " (auto-detected)"
print(f"language  {lang}{echoed}")
print(f"audio     {audio_s:.3f}s in, 16000 Hz mono")
print(f"wall      {wall_ms / 1000.0:.2f}s"
      + (f" ({report['realtime_factor']}x realtime)" if report["realtime_factor"] else ""))
if not segments:
    print("text      (no speech segments — silence, wrong language, or a test model)")
else:
    print(f"text      {text}")
    print(f"segments  {len(segments)}")
    for seg in segments:
        print(f"  [{seg['start_s']:7.3f}-{seg['end_s']:7.3f}] {seg['text']}")
PY
