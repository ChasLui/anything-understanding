#!/usr/bin/env bash
# Audio container and stream facts before you trust a waveform or a transcript.
#   probe.sh FILE           # human summary plus anomaly flags
#   probe.sh FILE --json    # machine-readable
#
# Two independent channels: ffprobe (container + per-stream headers) and
# afinfo (macOS CoreAudio). They disagree often enough that a disagreement is
# reported as its own flag instead of being averaged away.
set -euo pipefail

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }

file=""
as_json=0
for arg in "$@"; do
  case "$arg" in
    --json) as_json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "probe.sh: unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$file" ]; then
        echo "probe.sh: one file at a time" >&2
        exit 1
      fi
      file=$arg
      ;;
  esac
done
[ -n "$file" ] || {
  usage >&2
  exit 1
}
[ -r "$file" ] || {
  echo "probe.sh: cannot read: $file" >&2
  exit 2
}
command -v ffprobe >/dev/null 2>&1 || {
  echo "probe.sh: ffprobe not found (brew install ffmpeg)" >&2
  exit 3
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/audio-probe.XXXXXX")
trap 'rm -r "$tmp"' EXIT

if ! ffprobe -v error -show_format -show_streams -of json "$file" >"$tmp/ffprobe.json" 2>"$tmp/ffprobe.err"; then
  echo "probe.sh: ffprobe could not read: $file" >&2
  sed -n '1,3p' "$tmp/ffprobe.err" >&2
  exit 4
fi

# afinfo reads wav/aiff/caf/mp3/m4a/mov but not flac/ogg/webm/mpegts.
af_present=0
if command -v afinfo >/dev/null 2>&1; then
  af_present=1
  afinfo "$file" >"$tmp/afinfo.txt" 2>&1 || true
fi
size=$(wc -c <"$file" | tr -d ' ')

FILE="$file" FILE_SIZE="$size" AF_PRESENT="$af_present" AS_JSON="$as_json" \
  python3 - "$tmp/ffprobe.json" "$tmp/afinfo.txt" <<'PY'
import json, os, re, sys

probe = json.load(open(sys.argv[1]))
af_path = sys.argv[2]
as_json = os.environ["AS_JSON"] == "1"
af_present = os.environ["AF_PRESENT"] == "1"
fmt = probe.get("format") or {}
streams = probe.get("streams") or []

LOSSY = {
    "mp1", "mp2", "mp3", "mp3adu", "mp3on4", "aac", "ac3", "eac3", "opus",
    "vorbis", "amr_nb", "amr_wb", "speex", "ilbc", "wmav1", "wmav2", "wmav3",
    "hca", "cook", "qdm2", "ra_144", "g723_1", "nellymoser", "atrac3",
}
LOSSLESS = {"flac", "alac", "wavpack", "ape", "tta", "truehd", "mlp"}


def num(x):
    if x in (None, "", "N/A"):
        return None
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def as_int(x):
    v = num(x)
    return int(v) if v is not None else None


def kind(codec):
    if not codec:
        return "unknown"
    if codec.startswith("pcm_"):
        return "pcm"
    if codec in LOSSLESS:
        return "lossless-compressed"
    if codec in LOSSY:
        return "lossy"
    return "unknown"


def fnum(x, digits=3):
    return "n/a" if x is None else f"{x:.{digits}f}"


af = None
if af_present:
    text = open(af_path, errors="replace").read()
    first = next((ln for ln in text.splitlines() if ln.strip()), "")
    if "AudioFileOpenURL failed" in text or not re.search(r"^File type ID:", text, re.M):
        af = {"available": False, "error": first or "unrecognised afinfo output"}
    else:
        def one(pat):
            m = re.search(pat, text, re.M)
            return m.group(1).strip() if m else None

        formats = []
        for m in re.finditer(r"^Data format:\s*(.+)$", text, re.M):
            val = m.group(1).strip()
            if val not in formats:
                formats.append(val)
        af = {
            "available": True,
            "file_type": one(r"^File type ID:\s*(\S+)"),
            "tracks": as_int(one(r"^Num Tracks:\s*(\d+)")),
            "data_formats": formats,
            "duration_s": num(one(r"^estimated duration:\s*([\d.]+) sec")),
            "bit_rate": as_int(one(r"^bit rate:\s*(\d+) bits per second")),
        }

audio, video, others = [], [], []
for s in streams:
    stype = s.get("codec_type")
    index = s.get("index")
    if stype == "audio":
        audio.append({
            "index": index,
            "codec": s.get("codec_name"),
            "kind": kind(s.get("codec_name")),
            "sample_fmt": s.get("sample_fmt"),
            "sample_rate": as_int(s.get("sample_rate")),
            "channels": as_int(s.get("channels")),
            "channel_layout": s.get("channel_layout"),
            "bits_per_sample": as_int(s.get("bits_per_sample")),
            "bits_per_raw_sample": as_int(s.get("bits_per_raw_sample")),
            "bit_rate": as_int(s.get("bit_rate")),
            "duration_s": num(s.get("duration")),
            "start_time_s": num(s.get("start_time")),
        })
    elif stype == "video":
        disp = s.get("disposition") or {}
        video.append({
            "index": index,
            "codec": s.get("codec_name"),
            "attached_pic": int(disp.get("attached_pic") or 0),
            "duration_s": num(s.get("duration")),
        })
    else:
        others.append({"index": index, "type": stype, "codec": s.get("codec_name")})

fmt_dur = num(fmt.get("duration"))
flags = []


def flag(code, detail):
    flags.append({"code": code, "detail": detail})


if not audio:
    flag("no_audio_stream", "no audio stream in this file")

for a in audio:
    tag = f"stream {a['index']}"
    sr, ch, bps = a["sample_rate"], a["channels"], a["bits_per_sample"]
    if sr is None:
        flag("no_sample_rate", f"{tag}: sample rate not declared")
    elif sr < 16000:
        flag("low_sample_rate", f"{tag}: {sr} Hz (<16000) — upsampled for ASR, no content above {sr // 2} Hz")
    elif sr not in {16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000}:
        flag("unusual_sample_rate", f"{tag}: {sr} Hz")
    if ch is not None and ch > 2:
        flag("multichannel", f"{tag}: {ch} channels — downmix before ASR or loudness judgement")
    if a["kind"] == "pcm" and bps not in (8, 16, 24, 32, 64):
        flag("unusual_bit_depth", f"{tag}: PCM with {bps}-bit samples")
    if a["kind"] == "unknown":
        flag("unknown_codec", f"{tag}: {a['codec']} is neither PCM nor a known lossy/lossless codec")
    if fmt_dur is not None and a["duration_s"] is not None and abs(fmt_dur - a["duration_s"]) > 0.05:
        flag("duration_mismatch",
             f"{tag}: {a['duration_s']:.3f}s vs container {fmt_dur:.3f}s "
             f"(delta {a['duration_s'] - fmt_dur:+.3f}s)")
    if a["start_time_s"] is not None and abs(a["start_time_s"]) > 0.001:
        flag("timestamp_offset", f"{tag}: starts at {a['start_time_s']:.3f}s")

if len(audio) > 1:
    flag("multiple_audio_streams", f"{len(audio)} audio streams — name the one you mean")
real_video = [v for v in video if not v["attached_pic"]]
if real_video:
    flag("has_video", f"{len(real_video)} video stream(s) — audio filters ignore them")
if others:
    flag("other_streams", ", ".join(f"{o['type']}:{o['codec']}" for o in others))

if af and af.get("available"):
    tracks = af.get("tracks")
    if tracks is not None and tracks != len(audio):
        flag("afinfo_track_mismatch", f"afinfo sees {tracks} audio track(s), ffprobe {len(audio)}")
    af_dur = af.get("duration_s")
    if af_dur is not None and fmt_dur is not None and abs(af_dur - fmt_dur) > 0.02:
        flag("afinfo_duration_delta", f"afinfo {af_dur:.3f}s vs ffprobe {fmt_dur:.3f}s")
elif af:
    flag("afinfo_unavailable", af.get("error") or "afinfo could not open the file")

report = {
    "file": os.environ["FILE"],
    "size_bytes": int(os.environ["FILE_SIZE"]),
    "format": {
        "name": fmt.get("format_name"),
        "long_name": fmt.get("format_long_name"),
        "duration_s": fmt_dur,
        "bit_rate": as_int(fmt.get("bit_rate")),
        "nb_streams": as_int(fmt.get("nb_streams")),
    },
    "audio_streams": audio,
    "video_streams": video,
    "other_streams": others,
    "afinfo": af,
    "flags": flags,
}

if as_json:
    print(json.dumps(report, indent=2, ensure_ascii=False))
    sys.exit(0)

ch = {1: "mono", 2: "stereo"}
lines = [f"file      {report['file']} ({report['size_bytes']} bytes)"]
lines.append(
    f"format    {fmt.get('format_name')} | duration {fnum(fmt_dur)}s | "
    f"{fmt.get('bit_rate') or 'n/a'} b/s | {fmt.get('nb_streams')} stream(s)")
for a in audio:
    if a["bits_per_sample"]:
        depth = f"{a['bits_per_sample']}-bit"
    elif a["bits_per_raw_sample"]:
        depth = f"{a['bits_per_raw_sample']}-bit (raw)"
    else:
        depth = a["sample_fmt"] or "depth n/a"
    layout = a["channel_layout"] or ch.get(a["channels"] or 0, f"{a['channels']} ch")
    lines.append(
        f"audio#{a['index']}    {a['codec']} ({a['kind']}) | {a['sample_rate']} Hz | "
        f"{a['channels']} ch ({layout}) | {depth} | {fnum(a['duration_s'])}s | "
        f"{a['bit_rate'] or 'n/a'} b/s")
for v in real_video:
    lines.append(f"video#{v['index']}    {v['codec']} (ignored by audio tools)")
for o in others:
    lines.append(f"{o['type']}#{o['index']}    {o['codec']}")
if af is None:
    lines.append("afinfo    not installed (single channel)")
elif af["available"]:
    delta = ""
    if af["duration_s"] is not None and fmt_dur is not None:
        delta = f" (delta {af['duration_s'] - fmt_dur:+.3f}s)"
    lines.append(
        f"afinfo    {af['tracks']} track(s) | {fnum(af['duration_s'])}s{delta} | "
        f"{(af['data_formats'][0] if af['data_formats'] else 'n/a')}")
else:
    lines.append(f"afinfo    unavailable: {af['error']}")
if not flags:
    lines.append("flags     none")
else:
    lines.append(f"flags     {len(flags)}")
    for fl in flags:
        lines.append(f"  {fl['code']}: {fl['detail']}")
print("\n".join(lines))
PY
