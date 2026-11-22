#!/usr/bin/env python3
"""SVG inspector: structure, external dependencies, and renderability.

    python3 svg-inspect.py icon.svg
    python3 svg-inspect.py logo.svg --json
    python3 svg-inspect.py logo.svg --no-render

Parses the XML and counts what is actually in it (shapes, paths, text, fonts,
embedded rasters, external references), then optionally proves the file renders
by running rsvg-convert. "It parses" is not "it renders": unresolved external
hrefs, missing fonts and filters show up only in a render.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SHAPES = {
    "rect",
    "circle",
    "ellipse",
    "line",
    "polyline",
    "polygon",
    "path",
}
STRUCTURAL = {
    "svg",
    "g",
    "defs",
    "symbol",
    "use",
    "clipPath",
    "mask",
    "marker",
    "pattern",
    "linearGradient",
    "radialGradient",
    "stop",
    "filter",
}
RASTER = {"image"}
TEXT = {"text", "tspan", "textPath"}


def _tag(elem: ET.Element) -> str:
    return elem.tag.rsplit("}", 1)[-1]


def _strip_ns(tree: ET.ElementTree) -> ET.ElementTree:
    for elem in tree.iter():
        if "}" in elem.tag:
            elem.tag = elem.tag.rsplit("}", 1)[-1]
    return tree


MAX_SVG_BYTES = 20_000_000


def inspect(path: Path, render: bool = True) -> dict:
    issues: list[str] = []
    size = path.stat().st_size
    report: dict = {
        "file": str(path.resolve()),
        "bytes": size,
        "viewBox": None,
        "width": None,
        "height": None,
        "counts": {},
        "text": None,
        "fonts": [],
        "external_refs": [],
        "embedded_rasters": 0,
        "path_segments": 0,
        "render": None,
        "issues": issues,
    }
    if size > MAX_SVG_BYTES:
        issues.append(f"SVG is {size} bytes: over the {MAX_SVG_BYTES}-byte inspection limit")
        return report
    raw = path.read_text(encoding="utf-8", errors="replace")

    try:
        _strip_ns(ET.parse(path))
        tree = _strip_ns(ET.parse(path))
    except ET.ParseError as exc:
        issues.append(f"XML parse error: {exc}")
        return report

    root = tree.getroot()
    report["viewBox"] = root.get("viewBox")
    report["width"] = root.get("width")
    report["height"] = root.get("height")
    if not report["viewBox"]:
        issues.append("no viewBox: scaling and fitting break")
    elif not (report["width"] or report["height"]):
        issues.append("viewBox but no width/height: intrinsic size undefined")

    counts: dict[str, int] = {}
    texts: list[str] = []
    fonts: set[str] = set()
    segments = 0
    data_uris = 0

    for elem in tree.iter():
        tag = _tag(elem)
        counts[tag] = counts.get(tag, 0) + 1
        if tag in SHAPES or tag in STRUCTURAL or tag in RASTER or tag in TEXT:
            pass
        elif counts[tag] == 1:
            issues.append(f"non-standard element <{tag}>")
        if tag == "path":
            d = elem.get("d") or ""
            segments += len(re.findall(r"[MmLlHhVvCcSsQqTtAaZz]", d))
        if tag in TEXT:
            texts.append("".join(elem.itertext()).strip())
        family = elem.get("font-family")
        if family:
            fonts.add(family.strip())
        style = elem.get("style") or ""
        for m in re.finditer(r"font-family\s*:\s*['\"]?([^;'\"]+)", style):
            fonts.add(m.group(1).strip())
        for attr, href in elem.attrib.items():
            # xlink:href keeps its {namespace} prefix through parsing; match the
            # local name so both href and xlink:href are seen.
            if attr.rsplit("}", 1)[-1] != "href" or not href:
                continue
            if href.startswith("data:"):
                data_uris += 1
                if tag == "image":
                    report["embedded_rasters"] += 1
            elif href.startswith("#"):
                continue
            else:
                report["external_refs"].append({"tag": tag, "href": href})

    # CSS can pull resources without an href attribute; treat those as external
    # refs too so the render guard below covers them.
    seen = {(ref["tag"], ref["href"]) for ref in report["external_refs"]}
    for href in re.findall(r"url\(\s*['\"]?([^'\")\s]+)", raw):
        if href.startswith(("#", "data:")) or ("css", href) in seen:
            continue
        report["external_refs"].append({"tag": "css", "href": href})
        seen.add(("css", href))
    for href in re.findall(r"@import\s+(?:url\()?\s*['\"]([^'\"]+)", raw):
        if href.startswith(("#", "data:")) or ("import", href) in seen:
            continue
        report["external_refs"].append({"tag": "import", "href": href})
        seen.add(("import", href))

    report["path_segments"] = segments
    report["counts"] = dict(sorted(counts.items(), key=lambda kv: -kv[1]))
    report["fonts"] = sorted(fonts)
    if texts:
        joined = " | ".join(t for t in texts if t)
        report["text"] = joined[:2000]

    if report["external_refs"]:
        issues.append(f"{len(report['external_refs'])} external refs: file is not self-contained")
    if data_uris and count_embedded_bytes(raw) > 2_000_000:
        issues.append("embedded data URIs > 2 MB: consider external assets")
    if report["fonts"] and not shutil.which("rsvg-convert"):
        pass
    if any(_tag(e) == "image" for e in tree.iter()) and not report["embedded_rasters"]:
        issues.append("<image> without data URI: raster depends on external file")
    if counts.get("use") and not counts.get("symbol") and not counts.get("g"):
        issues.append("<use> present but no <symbol>/<g> target seen")

    # An external href can make librsvg read local files (tested: an <image>
    # href pointing at a local PNG is embedded in the rendered bitmap). Report
    # the refs, but never render a document that has them.
    if render and report["external_refs"]:
        issues.append(
            f"render skipped: {len(report['external_refs'])} external ref(s) would read local or network resources"
        )
    elif render and shutil.which("rsvg-convert"):
        report["render"] = _render(path, issues)
    elif render:
        issues.append("rsvg-convert missing: renderability unverified")
    return report


def count_embedded_bytes(raw: str) -> int:
    return sum(len(m) for m in re.findall(r"data:[^\"')]{1000,}", raw))


def _render(path: Path, issues: list[str]) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.png"
        # Bound the render: an untrusted width/height must not drive a
        # multi-hundred-MB bitmap (or trip PIL's decompression bomb).
        proc = subprocess.run(
            [
                "rsvg-convert",
                "--format=png",
                "--width",
                "2000",
                "--height",
                "2000",
                "--keep-aspect-ratio",
                "--output",
                str(out),
                str(path),
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            issues.append(f"rsvg-convert failed: {proc.stderr.strip()[:300]}")
            return {"ok": False}
        from PIL import Image

        try:
            with Image.open(out) as im:
                im.load()
                return {
                    "ok": True,
                    "size": [im.width, im.height],
                    "png_bytes": out.stat().st_size,
                    "max_dimension": 2000,
                }
        except (Image.DecompressionBombError, OSError) as exc:
            issues.append(f"rendered bitmap not readable: {type(exc).__name__}: {exc}")
            return {"ok": False}


def human(report: dict) -> str:
    lines = [
        f"{report['file']} ({report['bytes']} bytes)",
        f"  viewBox {report['viewBox']} width {report['width']} height {report['height']}",
        f"  elements {report['counts']}",
        f"  path segments {report['path_segments']}",
    ]
    if report["text"]:
        lines.append(f"  text {report['text']!r}")
    if report["fonts"]:
        lines.append(f"  fonts {', '.join(report['fonts'])}")
    if report["embedded_rasters"]:
        lines.append(f"  embedded rasters {report['embedded_rasters']}")
    if report["external_refs"]:
        for ref in report["external_refs"]:
            lines.append(f"  external <{ref['tag']}> {ref['href']}")
    if report["render"]:
        r = report["render"]
        lines.append(f"  render {'ok ' + str(r['size']) if r['ok'] else 'FAILED'}")
    for issue in report["issues"]:
        lines.append(f"  ! {issue}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-render", action="store_true")
    args = parser.parse_args(argv)
    reports = [inspect(p, not args.no_render) for p in args.paths]
    if args.json:
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2))
    else:
        print("\n".join(human(r) for r in reports))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
