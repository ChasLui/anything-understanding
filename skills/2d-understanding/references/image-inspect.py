#!/usr/bin/env python3
"""Raster image inspector: the facts an agent needs before it describes an image.

    python3 image-inspect.py photo.jpg
    python3 image-inspect.py shot.png --json
    python3 image-inspect.py big.png --json --force-pixels

Reports container facts (format, size, mode, DPI, ICC, EXIF orientation,
animation) and pixel facts (alpha usage, blankness, dominant colors, content
bbox). Everything printed is measured; nothing is guessed. A field that could
not be measured is null and named in "issues".

Requires Pillow (pip install pillow). No numpy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageCms, ImageStat
except ImportError:  # pragma: no cover - dependency guard
    sys.exit("image-inspect.py needs Pillow: python3 -m pip install pillow")

# Pillow's own bomb guard would refuse >2x its limit before we can read the
# header; header-only reporting is safe because our MAX_PIXELS check gates decode.
Image.MAX_IMAGE_PIXELS = None
SAMPLE_EDGE = 1024  # pixel stats run on a downscale; geometry is exact
MAX_PIXELS = 40_000_000
ALPHA_OPAQUE = 8


def _exif_orientation(im: Image.Image) -> int | None:
    try:
        exif = im.getexif()
    except Exception:
        return None
    value = exif.get(274) if exif else None
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _icc_name(im: Image.Image) -> str | None:
    icc = im.info.get("icc_profile")
    if not icc:
        return None
    try:
        import io

        profile = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        return (ImageCms.getProfileDescription(profile) or "").strip() or "unparsed"
    except Exception:
        return "present-unparsed"


def _frame_durations(im: Image.Image) -> list[int] | None:
    try:
        n = getattr(im, "n_frames", 1)
    except Exception:
        return None
    if n <= 1:
        return None
    durations = []
    for i in range(n):
        try:
            im.seek(i)
            durations.append(int(im.info.get("duration", 0) or 0))
        except EOFError:
            break
    return durations


def _dominant_rgb(rgb: Image.Image, limit: int = 6) -> list[dict]:
    small = rgb.copy()
    small.thumbnail((256, 256))
    total = small.width * small.height
    if not total:
        return []
    quantized = small.quantize(colors=limit, method=Image.Quantize.MEDIANCUT)
    palette = quantized.getpalette() or []
    counts = sorted(quantized.getcolors(limit * 4) or [], reverse=True)
    out = []
    for count, index in counts[:limit]:
        base = index * 3
        rgb_triplet = palette[base : base + 3]
        if len(rgb_triplet) < 3:
            continue
        out.append(
            {
                "hex": f"#{rgb_triplet[0]:02x}{rgb_triplet[1]:02x}{rgb_triplet[2]:02x}",
                "ratio": round(count / total, 4),
            }
        )
    return out


def _content_bbox(rgb: Image.Image, background: str, tolerance: int = 12):
    small = rgb.copy()
    small.thumbnail((SAMPLE_EDGE, SAMPLE_EDGE))
    flat = Image.new("RGB", small.size, background)
    diff = ImageChops.difference(small, flat).convert("L").point(lambda v: 255 if v > tolerance else 0)
    box = diff.getbbox()
    if not box:
        return None
    sx = rgb.width / small.width
    sy = rgb.height / small.height
    return [
        int(round(box[0] * sx)),
        int(round(box[1] * sy)),
        int(round(box[2] * sx)),
        int(round(box[3] * sy)),
    ]


def inspect(path: Path, force_pixels: bool = False) -> dict:
    issues: list[str] = []
    data = path.read_bytes()
    report: dict = {
        "file": str(path.resolve()),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest()[:16],
        "format": None,
        "size": None,
        "mode": None,
        "dpi": None,
        "icc": None,
        "exif_orientation": None,
        "displayed_size": None,
        "frames": None,
        "durations_ms": None,
        "alpha": None,
        "colors": None,
        "pixels": None,
        "content_bbox": None,
        "issues": issues,
    }

    try:
        opened = Image.open(path)
    except (Image.UnidentifiedImageError, Image.DecompressionBombError, OSError) as exc:
        issues.append(f"cannot open as an image: {type(exc).__name__}: {exc}")
        return report
    with opened as im:
        # Check the header size BEFORE decoding: a 78 KB PNG can be 81 MP.
        total = im.width * im.height
        report["format"] = im.format
        report["size"] = [im.width, im.height]
        report["mode"] = im.mode
        if total > MAX_PIXELS and not force_pixels:
            issues.append(f"{total} px exceeds {MAX_PIXELS} px; pixel stats skipped (use --force-pixels)")
            return report
        try:
            im.load()
        except (OSError, Image.DecompressionBombError) as exc:
            issues.append(f"cannot decode pixels: {type(exc).__name__}: {exc}")
            return report
        dpi = im.info.get("dpi")
        report["dpi"] = [round(float(v), 2) for v in dpi] if dpi else None
        report["icc"] = _icc_name(im)
        orientation = _exif_orientation(im)
        report["exif_orientation"] = orientation
        if orientation and orientation >= 5:
            report["displayed_size"] = [im.height, im.width]
            issues.append(
                f"EXIF orientation {orientation}: viewers show "
                f"{im.height}x{im.width}, stored pixels are {im.width}x{im.height}"
            )
        durations = _frame_durations(im)
        if durations:
            report["frames"] = len(durations)
            report["durations_ms"] = durations
            issues.append(f"animated: {len(durations)} frames; inspect frame 0 only")
            im.seek(0)

        if dpi and dpi[0] and min(dpi) < 12:
            issues.append(f"tiny DPI {dpi[0]}x{dpi[1]}: print size, not screen size")
        if im.mode in {"1", "P", "L", "I;16"}:
            issues.append(f"mode {im.mode}: colors are reduced/quantized")

        # --- alpha ---
        has_alpha = "A" in im.getbands() or "transparency" in im.info
        rgba = im.convert("RGBA")
        alpha = rgba.getchannel("A")
        alpha_bbox = rgba.getbbox()
        hist = alpha.histogram()
        transparent = sum(hist[: ALPHA_OPAQUE + 1])
        report["alpha"] = {
            "has_alpha_channel": has_alpha,
            "transparent_ratio": round(min(transparent, total) / total, 4) if total else 0.0,
            "opaque_bbox": list(alpha_bbox) if alpha_bbox else None,
        }
        if has_alpha and transparent == 0:
            issues.append("alpha channel is fully opaque: transparency unused")
        if not has_alpha and transparent:
            issues.append("palette transparency key present: not a true alpha channel")

        # --- pixels on a downscale ---
        rgb = rgba.convert("RGB")
        sample = rgb.copy()
        sample.thumbnail((SAMPLE_EDGE, SAMPLE_EDGE))
        stat = ImageStat.Stat(sample.convert("L"))
        mean = [round(v, 2) for v in stat.mean]
        std = [round(v, 2) for v in stat.stddev]
        colors = sample.getcolors(SAMPLE_EDGE * SAMPLE_EDGE) or []
        # Blank means visually uniform: a two-color logo is still content.
        blank = std[0] < 1.0
        report["pixels"] = {
            "sampled_size": [sample.width, sample.height],
            "gray_mean": mean[0],
            "gray_std": std[0],
            "blank": bool(blank),
            "unique_sampled": len(colors),
        }
        dominant = _dominant_rgb(rgb)
        report["colors"] = {"dominant": dominant}
        if blank:
            issues.append("visually blank: pixel values are uniform")
        if dominant:
            report["content_bbox"] = _content_bbox(rgb, dominant[0]["hex"])
        if report["content_bbox"] is None and not blank:
            issues.append("content bbox not found: background estimate unreliable")

    return report


def human(report: dict) -> str:
    size = f"{report['size'][0]}x{report['size'][1]}" if report["size"] else "size unreadable"
    lines = [
        f"{report['file']}",
        f"  {report['format'] or 'unreadable'} {size} {report['mode'] or '-'} {report['bytes']} bytes",
    ]
    if report["displayed_size"]:
        lines.append(
            f"  displayed {report['displayed_size'][0]}x{report['displayed_size'][1]} (EXIF orientation applied)"
        )
    if report["dpi"]:
        lines.append(f"  dpi {report['dpi'][0]}x{report['dpi'][1]}")
    if report["icc"]:
        lines.append(f"  icc {report['icc']}")
    if report["frames"]:
        lines.append(f"  animated {report['frames']} frames, total {sum(report['durations_ms']) / 1000:.2f}s")
    if report["alpha"]:
        a = report["alpha"]
        lines.append(
            f"  alpha {'yes' if a['has_alpha_channel'] else 'no'}, "
            f"{a['transparent_ratio'] * 100:.1f}% transparent, "
            f"opaque bbox {a['opaque_bbox']}"
        )
    if report["pixels"]:
        p = report["pixels"]
        lines.append(
            f"  gray mean {p['gray_mean']} std {p['gray_std']} "
            f"blank={str(p['blank']).lower()} "
            f"unique~{p['unique_sampled']}"
        )
    if report["colors"]:
        top = ", ".join(f"{c['hex']} {c['ratio'] * 100:.0f}%" for c in report["colors"]["dominant"])
        lines.append(f"  dominant {top}")
    if report["content_bbox"]:
        b = report["content_bbox"]
        lines.append(f"  content bbox [{b[0]},{b[1]},{b[2]},{b[3]}]")
    for issue in report["issues"]:
        lines.append(f"  ! {issue}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--force-pixels", action="store_true")
    args = parser.parse_args(argv)

    reports = [inspect(p, args.force_pixels) for p in args.paths]
    if args.json:
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2))
    else:
        print("\n".join(human(r) for r in reports))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
