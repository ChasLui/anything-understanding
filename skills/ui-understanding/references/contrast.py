#!/usr/bin/env python3
"""WCAG contrast ratio between two colors, with the thresholds that matter.

    python3 contrast.py "#777777" "#ffffff"
    python3 contrast.py "#767676" "#ffffff" --font-size 16
    python3 contrast.py "rgba(0,0,0,0.54)" "#ffffff" --json   # alpha composited
    python3 contrast.py "#0b57d0" "#ffffff" --font-size 16 --bold

Ratio formula is WCAG 2.x: relative luminance from linearised sRGB, then
(L1+0.05)/(L2+0.05). Thresholds used:
  AA  normal 4.5 · large 3.0 · UI component/graphic 3.0
  AAA normal 7.0 · large 4.5
Large text = >= 24 px, or >= 18.66 px when bold (WCAG 1.4.3).

The number is exact for the two colors you pass. It says nothing about how the
colors were sampled: anti-aliased pixels, gradients and overlays make sampled
screenshots unreliable — take colors from computed styles when you can.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

HEX_RE = re.compile(r"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
RGB_RE = re.compile(r"^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+%?)\s*)?\)$")


def parse_color(text: str) -> tuple[float, float, float, float]:
    """Return (r, g, b, a) with channels 0..255 and alpha 0..1."""
    s = text.strip()
    m = HEX_RE.match(s)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
        return r, g, b, a
    m = RGB_RE.match(s)
    if m:
        r, g, b = (float(m.group(i)) for i in (1, 2, 3))
        alpha = m.group(4)
        if alpha is None:
            a = 1.0
        elif alpha.endswith("%"):
            a = float(alpha[:-1]) / 100
        else:
            a = float(alpha)
        return r, g, b, a
    raise ValueError(f"unsupported color {text!r} (use #rgb, #rrggbb, #rrggbbaa, rgb()/rgba())")


def composite(
    fg: tuple[float, float, float, float], bg: tuple[float, float, float, float]
) -> tuple[float, float, float]:
    """Alpha-composite fg over an opaque bg; returns 0..255 channels."""
    br, bg_, bb, _ = bg
    r, g, b, a = fg
    return (r * a + br * (1 - a), g * a + bg_ * (1 - a), b * a + bb * (1 - a))


def luminance(rgb: tuple[float, float, float]) -> float:
    def channel(c: float) -> float:
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(l1: float, l2: float) -> float:
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def is_large(font_px: float | None, bold: bool) -> bool:
    if font_px is None:
        return False
    return font_px >= 24 or (bold and font_px >= 18.66)


def judge(contrast: float, large: bool) -> dict:
    aa = 3.0 if large else 4.5
    aaa = 4.5 if large else 7.0
    return {
        "aa_text": {"threshold": aa, "pass": contrast >= aa},
        "aaa_text": {"threshold": aaa, "pass": contrast >= aaa},
        "aa_ui": {"threshold": 3.0, "pass": contrast >= 3.0},
    }


def hex_of(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{round(c):02x}" for c in rgb)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("fg")
    parser.add_argument("bg")
    parser.add_argument("--font-size", type=float, help="CSS px; >=24 (or >=18.66 bold) counts as large text")
    parser.add_argument("--bold", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        fg = parse_color(args.fg)
        bg = parse_color(args.bg)
    except ValueError as exc:
        sys.exit(f"contrast.py: {exc}")
    for label, color in (("foreground", fg), ("background", bg)):
        if any(c < 0 or c > 255 for c in color[:3]):
            sys.exit(f"contrast.py: {label} channels must be 0..255: {color[:3]}")
        if not 0 <= color[3] <= 1:
            sys.exit(f"contrast.py: {label} alpha must be 0..1: {color[3]}")
    if bg[3] != 1.0:
        sys.exit(
            "contrast.py: background must be opaque; composite it over the real "
            "backdrop first (a translucent/gradient background has no single ratio)"
        )
    flat = composite(fg, bg)
    c = ratio(luminance(flat), luminance(bg[:3]))
    large = is_large(args.font_size, args.bold)
    verdict = judge(c, large)
    result = {
        "foreground": args.fg,
        "background": args.bg,
        "composited_foreground": hex_of(flat),
        "ratio": round(c, 2),
        "large_text": large,
        **verdict,
    }
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        level = "large" if large else "normal"
        print(f"{args.fg} on {args.bg}  ->  {c:.2f}:1  ({level} text)")
        if flat != fg[:3]:
            print(f"  composited foreground: {hex_of(flat)}")
        for key, label in (("aa_text", "AA text"), ("aaa_text", "AAA text"), ("aa_ui", "AA UI/graphic")):
            v = result[key]
            print(f"  {label:15s} >= {v['threshold']:.1f}  {'pass' if v['pass'] else 'FAIL'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
