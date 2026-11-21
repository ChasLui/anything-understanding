#!/usr/bin/env bash
# Loudness, true peak, silence and clipping in one ffmpeg pass.
#   loudness.sh FILE                     # human summary
#   loudness.sh FILE --json              # machine-readable
#   loudness.sh FILE --silence-db -35 --silence-min 0.5
#
# One decode, four analysis filters on the same samples:
#   ebur128=peak=true   integrated LUFS, LRA, true peak
#   silencedetect       silence intervals
#   volumedetect        mean/max sample volume
#   astats              flat factor, peak count, sample count
# ffmpeg has no "clipped samples" counter; clipping is inferred from the sample
# peak, the true peak and the flat factor, and the raw values are kept.
set -euo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

file=""
as_json=0
silence_db=-40
silence_min=0.3
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    --silence-db)
      silence_db=${2:?--silence-db needs a value}
      shift
      ;;
    --silence-min)
      silence_min=${2:?--silence-min needs a value}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "loudness.sh: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$file" ]; then
        echo "loudness.sh: one file at a time" >&2
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
  echo "loudness.sh: cannot read: $file" >&2
  exit 2
}
command -v ffmpeg >/dev/null 2>&1 || {
  echo "loudness.sh: ffmpeg not found (brew install ffmpeg)" >&2
  exit 3
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/audio-loudness.XXXXXX")
trap 'rm -r "$tmp"' EXIT

case "$silence_db" in
  '' | *[!0-9.+-]*)
    echo "loudness.sh: --silence-db needs a numeric dB value: $silence_db" >&2
    exit 1
    ;;
esac
case "$silence_min" in
  '' | *[!0-9.]*)
    echo "loudness.sh: --silence-min needs a numeric seconds value: $silence_min" >&2
    exit 1
    ;;
esac

chain="ebur128=peak=true,silencedetect=n=${silence_db}dB:d=${silence_min},volumedetect,astats=metadata=0"
if ! ffmpeg -nostats -nostdin -hide_banner -i "$file" -af "$chain" -f null - >/dev/null 2>"$tmp/log"; then
  echo "loudness.sh: ffmpeg failed on: $file" >&2
  grep -v '^\[.*load_backend\|^ggml_' "$tmp/log" | tail -5 >&2
  exit 4
fi

# The audio stream can be shorter than the container (video with a short track):
# silence ratio must use the stream duration, container only as a fallback.
duration=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 "$file" 2>/dev/null || true)
[ -n "$duration" ] || duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || true)
[ -n "$duration" ] || duration=""

FILE="$file" DURATION="$duration" SILENCE_DB="$silence_db" SILENCE_MIN="$silence_min" \
  AS_JSON="$as_json" python3 - "$tmp/log" <<'PY'
import json, os, re, sys

lines = open(sys.argv[1], errors="replace").read().splitlines()
as_json = os.environ["AS_JSON"] == "1"
silence_db = float(os.environ["SILENCE_DB"])
silence_min = float(os.environ["SILENCE_MIN"])


def val(x):
    if x in (None, "", "-inf", "inf", "nan", "-nan"):
        return None
    try:
        return float(x)
    except ValueError:
        return None


def last(pat):
    """Last match wins: the ebur128/astats summary blocks print after the
    per-second and per-channel ones."""
    out = None
    for ln in lines:
        m = re.search(pat, ln)
        if m:
            out = m.group(1)
    return out


# Anchored on leading whitespace: per-second ebur128 lines start with
# "[Parsed_ebur128_0 @ 0x...] t: ...", the summary block is indented only.
integrated = val(last(r"^\s+I:\s+(\S+)\s+LUFS"))
lra = val(last(r"^\s+LRA:\s+(\S+)\s+LU"))
true_peak = val(last(r"^\s+Peak:\s+(\S+)\s+dBFS"))
mean_db = val(last(r"mean_volume:\s+(-?[\d.]+)\s+dB"))
max_db = val(last(r"max_volume:\s+(-?[\d.]+)\s+dB"))
peak_level = val(last(r"Peak level dB:\s+(-?[\d.]+)"))
rms_level = val(last(r"RMS level dB:\s+(-?[\d.]+)"))
flat_raw = last(r"Flat factor:\s+(\S+)")
flat_factor = val(flat_raw)  # "-inf" for a constant-level (digital silence) signal
peak_count = val(last(r"Abs Peak count:\s+(\d+)"))
samples = val(last(r"Number of samples:\s+(\d+)"))
bit_depth = last(r"Bit depth:\s+(\S+)")

intervals = []
open_start = None
for ln in lines:
    m = re.search(r"silence_start:\s+(-?[\d.]+)", ln)
    if m:
        open_start = max(0.0, float(m.group(1)))
        continue
    m = re.search(r"silence_end:\s+(-?[\d.]+)\s*\|\s*silence_duration:\s+([\d.]+)", ln)
    if m and open_start is not None:
        end = float(m.group(1))
        intervals.append({"start_s": round(open_start, 3), "end_s": round(end, 3),
                          "duration_s": round(float(m.group(2)), 3), "open_ended": False})
        open_start = None
if open_start is not None:  # stream stopped inside silence without an end marker
    intervals.append({"start_s": round(open_start, 3), "end_s": None,
                      "duration_s": None, "open_ended": True})

duration = val(os.environ["DURATION"])
silence_total = round(sum(i["duration_s"] or 0.0 for i in intervals), 3)
suspect = (max_db is not None and max_db >= -0.05) or (true_peak is not None and true_peak >= 0.0)

if samples is None and integrated is None:
    print(f"loudness.sh: no audio stream measured in: {os.environ['FILE']}", file=sys.stderr)
    sys.exit(4)

report = {
    "file": os.environ["FILE"],
    "duration_s": duration,
    "loudness": {
        "integrated_lufs": integrated,
        "integrated_floor": integrated is not None and integrated <= -70.0,
        "lra_lu": lra,
        "true_peak_dbfs": true_peak,
    },
    "volume": {"mean_db": mean_db, "max_db": max_db,
               "astats_peak_db": peak_level, "astats_rms_db": rms_level,
               "astats_bit_depth": bit_depth},
    "clipping": {
        "true_peak_dbfs": true_peak,
        "max_volume_db": max_db,
        "flat_factor": flat_factor,
        "abs_peak_count": int(peak_count) if peak_count is not None else None,
        "samples": int(samples) if samples is not None else None,
        "suspect": suspect,
    },
    "silence": {
        "threshold_db": silence_db,
        "min_duration_s": silence_min,
        "count": len(intervals),
        "total_s": silence_total,
        "ratio": round(silence_total / duration, 4) if duration else None,
        "intervals": intervals,
    },
}

if as_json:
    print(json.dumps(report, indent=2, ensure_ascii=False))
    sys.exit(0)


def f(x, digits=1, unit=""):
    return "n/a" if x is None else f"{x:.{digits}f}{unit}"


def inf_aware(x, digits=1, unit=""):
    return "-inf" + unit if x is None else f"{x:.{digits}f}{unit}"


lines_out = [f"file      {report['file']}"]
lines_out.append(f"duration  {f(duration, 3, 's')}")
lines_out.append(
    f"loudness  {f(integrated, 1, ' LUFS')} integrated"
    + (" (floor, at or below -70)" if report["loudness"]["integrated_floor"] else "")
    + f" | LRA {f(lra, 1, ' LU')} | true peak {inf_aware(true_peak, 1, ' dBFS')}")
lines_out.append(f"volume    mean {f(mean_db, 1, ' dB')} | max {f(max_db, 1, ' dB')}")
lines_out.append(
    f"clipping  {'SUSPECT' if suspect else 'no'}"
    f" | flat factor {f(flat_factor, 3) if flat_factor is not None else flat_raw}"
    f" | abs peak count {int(peak_count) if peak_count is not None else 0}"
    f" | {int(samples) if samples is not None else 0} samples")
ratio = report["silence"]["ratio"]
lines_out.append(
    f"silence   {len(intervals)} interval(s) at <= {f(silence_db, 0, ' dB')}"
    f" / >= {f(silence_min, 3)}s: {f(silence_total, 3)}s total"
    + (f" ({ratio * 100:.1f}%)" if ratio is not None else ""))
for iv in intervals:
    end = "open" if iv["end_s"] is None else f"{iv['end_s']:.3f}"
    dur = "?" if iv["duration_s"] is None else f"{iv['duration_s']:.3f}"
    lines_out.append(f"  {iv['start_s']:.3f} - {end}s ({dur}s)")
print("\n".join(lines_out))
PY
