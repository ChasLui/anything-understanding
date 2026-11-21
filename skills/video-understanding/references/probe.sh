#!/usr/bin/env bash
# Normalized container + stream probe. One ffprobe pass, one shape of output.
#   probe.sh clip.mp4            # human summary
#   probe.sh clip.mp4 --json     # machine-readable (stable keys, unknown = null)
#
# Why this exists: raw `ffprobe -show_streams` answers nothing without a decoder
# of its own output. Here rotation is folded into displayed_size, r_frame_rate
# vs avg_frame_rate into a `vfr` flag, and color tags into an `hdr` verdict.
#
# Everything below is read from ffprobe except `bytes` (file size, stat). When a
# field is absent from the container (mkv has no per-stream bit_rate, most
# encodes carry no color tags) the value is null, never a guess.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: probe.sh <file> [--json]

  container: format name, duration, file bytes, container bitrate
  video:     codec/profile, stored size, fps (r and avg) + vfr flag, pix_fmt,
             color tags + hdr verdict, rotation + displayed size, bitrate, frames
  audio:     codec/profile, channels, sample rate, bitrate, language
  counts:    video / audio / subtitle / attachment streams
EOF
}

file=""
as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "probe.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$file" ]; then
        echo "probe.sh: one file at a time" >&2
        exit 1
      fi
      file=$1
      ;;
  esac
  shift
done
[ -n "$file" ] || {
  usage
  exit 1
}
[ -f "$file" ] || {
  echo "probe.sh: no such file: $file" >&2
  exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
  echo "probe.sh: needs ffprobe (ffmpeg build)" >&2
  exit 1
}

# A path starting with '-' would be read as an option by ffprobe.
probe_path=$file
case "$probe_path" in -*) probe_path="./$probe_path" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
trap 'rm -r "$tmp"' EXIT
bytes=$(wc -c <"$file" | tr -d ' ')

ffprobe -v error -of json \
  -show_entries stream=index,codec_type,codec_name,profile,width,height,r_frame_rate,avg_frame_rate,nb_frames,pix_fmt,color_range,color_space,color_transfer,color_primaries,bit_rate,channels,channel_layout,sample_rate \
  -show_entries stream_side_data=rotation \
  -show_entries stream_tags=language \
  -show_entries format=format_name,format_long_name,duration,bit_rate \
  -- "$probe_path" >"$tmp/ffprobe.json" 2>"$tmp/ffprobe.err" || {
  echo "probe.sh: ffprobe could not read $file" >&2
  sed -n '1,5p' "$tmp/ffprobe.err" >&2
  exit 1
}

python3 - "$tmp/ffprobe.json" "$file" "$bytes" "$as_json" <<'PY'
import json
import sys

raw_path, display_path, bytes_s, json_flag = sys.argv[1:5]
raw = json.load(open(raw_path, encoding="utf-8"))
fmt = raw.get("format") or {}
bytes_total = int(bytes_s)
as_json = json_flag == "1"

HDR_TRANSFER = {"smpte2084": "pq", "arib-std-b67": "hlg"}


def rational(text):
    """'30000/1001' -> 29.97, '0/0' -> None (audio streams report this)."""
    if not text or text in ("0/0", "N/A"):
        return None
    try:
        num, den = text.split("/")
        den_f = float(den)
    except ValueError:
        return None
    if den_f == 0:
        return None
    return float(num) / den_f


def rotation_of(stream):
    for item in stream.get("side_data_list") or []:
        rot = item.get("rotation")
        if isinstance(rot, (int, float)):
            return int(rot)
    return 0


def num(value, cast=int):
    if value in (None, "", "N/A"):
        return None
    try:
        return cast(value)
    except (TypeError, ValueError):
        return None


duration = num(fmt.get("duration"), float)
container_bitrate = num(fmt.get("bit_rate"))
bitrate_source = "container" if container_bitrate is not None else None
if container_bitrate is None and duration:
    container_bitrate = round(bytes_total * 8 / duration)
    bitrate_source = "derived (file bytes / duration)"

video, audio = [], []
subtitle_n = attachment_n = 0
for stream in raw.get("streams") or []:
    kind = stream.get("codec_type")
    if kind == "subtitle":
        subtitle_n += 1
        continue
    if kind == "attachment":
        attachment_n += 1
        continue
    index = stream.get("index")
    if kind == "video":
        w = num(stream.get("width"))
        h = num(stream.get("height"))
        rot = rotation_of(stream)
        swap = w is not None and h is not None and abs(rot) % 180 == 90
        fps_r = rational(stream.get("r_frame_rate"))
        fps_avg = rational(stream.get("avg_frame_rate"))
        vfr = (
            fps_r is not None
            and fps_avg is not None
            and fps_avg > 0
            and abs(fps_r - fps_avg) / fps_avg > 0.005
        )
        transfer = stream.get("color_transfer")
        video.append(
            {
                "index": index,
                "codec": stream.get("codec_name"),
                "profile": stream.get("profile"),
                "stored_size": [w, h],
                "rotation_deg": rot,
                "displayed_size": [h, w] if swap else [w, h],
                "fps": round(fps_r, 3) if fps_r is not None else None,
                "fps_r": stream.get("r_frame_rate"),
                "fps_avg": round(fps_avg, 3) if fps_avg is not None else None,
                "fps_avg_raw": stream.get("avg_frame_rate"),
                "vfr": vfr,
                "pix_fmt": stream.get("pix_fmt"),
                "color": {
                    "range": stream.get("color_range"),
                    "space": stream.get("color_space"),
                    "transfer": transfer,
                    "primaries": stream.get("color_primaries"),
                },
                "hdr": HDR_TRANSFER.get(transfer or ""),
                "bit_rate_bps": num(stream.get("bit_rate")),
                "frames": num(stream.get("nb_frames")),
            }
        )
    elif kind == "audio":
        audio.append(
            {
                "index": index,
                "codec": stream.get("codec_name"),
                "profile": stream.get("profile"),
                "channels": num(stream.get("channels")),
                "channel_layout": stream.get("channel_layout"),
                "sample_rate": num(stream.get("sample_rate")),
                "bit_rate_bps": num(stream.get("bit_rate")),
                "language": (stream.get("tags") or {}).get("language"),
            }
        )

counts = {
    "video": len(video),
    "audio": len(audio),
    "subtitle": subtitle_n,
    "attachment": attachment_n,
}
notes = []
for v in video:
    if v["rotation_deg"]:
        notes.append(
            "rotation %d deg stored as display matrix; decoders rotate by default, "
            "so decoded frames are %dx%d" % (v["rotation_deg"], *v["displayed_size"])
        )
    if v["vfr"]:
        notes.append(
            "variable frame rate: r_frame_rate %s vs avg_frame_rate %s"
            % (v["fps_r"], v["fps_avg_raw"])
        )
    if v["color"]["transfer"] is None:
        notes.append("no color_transfer tag: HDR cannot be confirmed from tags alone")
if not video:
    notes.append("no video stream")

payload = {
    "file": display_path,
    "bytes": bytes_total,
    "container": {
        "name": fmt.get("format_name"),
        "long_name": fmt.get("format_long_name"),
    },
    "duration_s": round(duration, 3) if duration is not None else None,
    "bitrate_bps": container_bitrate,
    "bitrate_source": bitrate_source,
    "counts": counts,
    "video": video,
    "audio": audio,
    "notes": notes,
}

if as_json:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)


def kbit(bps):
    return "?" if bps is None else "%.1f kbit/s" % (bps / 1000)


def show(value):
    return "-" if value is None else str(value)


out = [
    "file: %s" % display_path,
    "size: %d B | container bitrate: %s%s"
    % (
        bytes_total,
        kbit(container_bitrate),
        "" if bitrate_source in (None, "container") else " (%s)" % bitrate_source,
    ),
    "container: %s [%s]" % (show(fmt.get("format_name")), show(fmt.get("format_long_name"))),
    "duration: %s s" % ("?" if duration is None else "%.3f" % duration),
    "streams: %d video / %d audio / %d subtitle / %d attachment"
    % (
        counts["video"],
        counts["audio"],
        counts["subtitle"],
        counts["attachment"],
    ),
]
for v in video:
    out.append(
        "video[%s]: %s %s | stored %sx%s | %s fps | pix_fmt=%s | bitrate=%s"
        % (
            v["index"],
            show(v["codec"]),
            show(v["profile"]),
            show(v["stored_size"][0]),
            show(v["stored_size"][1]),
            "?" if v["fps"] is None else "%.3f" % v["fps"],
            show(v["pix_fmt"]),
            kbit(v["bit_rate_bps"]),
        )
    )
    out.append(
        "  fps: r=%s avg=%s vfr=%s frames=%s"
        % (show(v["fps_r"]), show(v["fps_avg_raw"]), str(v["vfr"]).lower(), show(v["frames"]))
    )
    c = v["color"]
    out.append(
        "  color: space=%s transfer=%s primaries=%s range=%s | hdr=%s"
        % (show(c["space"]), show(c["transfer"]), show(c["primaries"]), show(c["range"]), show(v["hdr"]))
    )
    out.append(
        "  rotation: %d deg | displayed: %dx%d"
        % (v["rotation_deg"], v["displayed_size"][0], v["displayed_size"][1])
    )
for a in audio:
    out.append(
        "audio[%s]: %s %s | %s ch | %s Hz | bitrate=%s | language=%s"
        % (
            a["index"],
            show(a["codec"]),
            show(a["profile"]),
            show(a["channels"]),
            show(a["sample_rate"]),
            kbit(a["bit_rate_bps"]),
            show(a["language"]),
        )
    )
for note in notes:
    out.append("note: %s" % note)
print("\n".join(out))
PY
