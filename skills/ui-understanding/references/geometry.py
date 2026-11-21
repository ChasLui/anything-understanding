#!/usr/bin/env python3
"""Box geometry checks for UI screenshots and DOM dumps.

    python3 geometry.py boxes.json                    # boxes: [{name,x,y,w,h},...]
    python3 geometry.py boxes.json --platform ios     # 44pt target minimum
    python3 geometry.py boxes.json --viewport 1440x900 --json

Reports, from measured rectangles only:
  - invalid boxes (non-positive w/h)
  - target-size failures (WCAG 2.2 AA 24 CSS px, iOS 44 pt, Android 48 dp)
  - pairwise overlaps with the overlapping area in px^2
  - boxes that extend outside the viewport, when a viewport is given

Coordinates are whatever the source gave you (CSS px from getBoundingClientRect,
points from an accessibility frame, or device px from an image). Mixing sources
in one file makes every number wrong: boxes.json must say which unit it is via
`"unit": "css-px" | "pt" | "dp" | "px"`.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

MIN_TARGET = {"wcag": 24.0, "ios": 44.0, "android": 48.0}


def load(path: Path) -> tuple[str, list[dict]]:
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        if "boxes" not in data:
            raise SystemExit('geometry.py: expected {"unit","boxes"} or a list of boxes')
        unit = data.get("unit", "css-px")
        boxes = data["boxes"] or []
    else:
        unit = "css-px"
        boxes = data
    if not isinstance(boxes, list):
        raise SystemExit('geometry.py: expected a list of boxes or {"unit","boxes"}')
    return unit, boxes


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("boxes", type=Path)
    parser.add_argument("--platform", choices=sorted(MIN_TARGET), default="wcag")
    parser.add_argument("--viewport", help="WxH, e.g. 1440x900")
    parser.add_argument(
        "--dpr",
        type=float,
        default=1.0,
        help="device-pixel ratio for unit=px boxes (thresholds scale by it)",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    unit, boxes = load(args.boxes)
    problems: list[dict] = []
    parsed: list[dict] = []
    for index, box in enumerate(boxes):
        if not isinstance(box, dict):
            problems.append({"kind": "malformed", "box": f"box#{index + 1}"})
            continue
        name = str(box.get("name") or f"box#{index + 1}")
        try:
            x, y, w, h = (float(box[k]) for k in ("x", "y", "w", "h"))
        except (KeyError, TypeError, ValueError):
            problems.append({"kind": "malformed", "box": name})
            continue
        if not all(math.isfinite(v) for v in (x, y, w, h)):
            problems.append({"kind": "malformed", "box": name})
            continue
        parsed.append({"name": name, "x": x, "y": y, "w": w, "h": h})
        if w <= 0 or h <= 0:
            problems.append({"kind": "non_positive", "box": name, "w": w, "h": h})

    minimum = MIN_TARGET[args.platform]
    if unit == "px":
        # unit=px means device pixels (e.g. from a screenshot); the minimums are
        # logical units, so a 2x capture must compare against 2x the threshold.
        minimum *= args.dpr
    small = [b for b in parsed if b["w"] > 0 and b["h"] > 0 and (b["w"] < minimum or b["h"] < minimum)]
    for box in small:
        problems.append(
            {
                "kind": "target_too_small",
                "box": box["name"],
                "size": [box["w"], box["h"]],
                "minimum": minimum,
                "unit": unit,
            }
        )

    overlaps = []
    for i, a in enumerate(parsed):
        for b in parsed[i + 1 :]:
            ix = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
            iy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
            if ix > 0 and iy > 0:
                overlaps.append(
                    {
                        "a": a["name"],
                        "b": b["name"],
                        "area": round(ix * iy, 1),
                        "overlap_px": [round(ix, 1), round(iy, 1)],
                    }
                )

    outside = []
    if args.viewport:
        try:
            vw, vh = (float(v) for v in args.viewport.lower().split("x"))
        except ValueError:
            sys.exit("geometry.py: --viewport expects WxH")
        for box in parsed:
            if box["x"] < 0 or box["y"] < 0 or box["x"] + box["w"] > vw or box["y"] + box["h"] > vh:
                outside.append({"box": box["name"], "rect": [box["x"], box["y"], box["w"], box["h"]]})

    result = {
        "unit": unit,
        "platform": args.platform,
        "dpr": args.dpr,
        "minimum": minimum,
        "boxes": parsed,
        "too_small": [b["name"] for b in small],
        "overlaps": overlaps,
        "outside_viewport": outside,
        "problems": problems,
    }
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{len(parsed)} box(es), unit={unit}, target minimum={minimum} ({args.platform})")
        if small:
            print("  too small: " + ", ".join(f"{b['name']} {b['w']:.0f}x{b['h']:.0f}" for b in small))
        for item in overlaps:
            print(f"  overlap: {item['a']} / {item['b']}  {item['area']} {unit}^2")
        for item in outside:
            print(f"  outside viewport: {item['box']} {item['rect']}")
        if not (small or overlaps or outside or problems):
            print("  no size/overlap/viewport problems found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
