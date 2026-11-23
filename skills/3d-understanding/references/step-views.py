#!/usr/bin/env python3
"""Headless STEP -> view sheet (SVG) + mass properties (JSON).

Offline fallback for agents that have no 3D-capable backend: it does NOT
produce PMI, tolerances, assembly semantics or part-instance counts. It gives
geometry-derived evidence only: hidden-line views from 14 directions, per-body
volume / area / bounding box, and mass when a density is supplied.

Run with FreeCAD's console interpreter (no GUI needed):

    FreeCADCmd step-views.py -- model.step outdir [--density 7.85] [--hidden]

Outputs:
    <outdir>/views.svg       14 views on one sheet (6 ortho + 8 isometric)
    <outdir>/metrics.json    bodies, volumes, areas, bbox; mass if --density
    <outdir>/views.png       only when rasterized afterwards by the wrapper

`--density` is g/cm3 (steel 7.85, aluminium 2.70, titanium 4.43). Without it
only volumes are reported: never invent a mass.
"""

import os
import sys
from xml.sax.saxutils import escape

import FreeCAD
import TechDraw

# TechDraw's import evicts `json` and `math` from this module's globals
# (FreeCAD 1.1.4); import them inside the functions that use them.

ORTHO = [
    ("front", (0, -1, 0)),
    ("back", (0, 1, 0)),
    ("left", (-1, 0, 0)),
    ("right", (1, 0, 0)),
    ("top", (0, 0, 1)),
    ("bottom", (0, 0, -1)),
]
ISO = [
    ("iso_front_left_top", (-1, -1, 1)),
    ("iso_front_right_top", (1, -1, 1)),
    ("iso_back_left_top", (-1, 1, 1)),
    ("iso_back_right_top", (1, 1, 1)),
    ("iso_front_left_bottom", (-1, -1, -1)),
    ("iso_front_right_bottom", (1, -1, -1)),
    ("iso_back_left_bottom", (-1, 1, -1)),
    ("iso_back_right_bottom", (1, 1, -1)),
]


def parse_args(argv):
    args = [a for a in argv[1:] if a != "--"]
    if len(args) < 2:
        raise SystemExit("usage: FreeCADCmd step-views.py -- model.step outdir [--density 7.85] [--hidden]")
    step_path, outdir = os.path.abspath(args[0]), os.path.abspath(args[1])
    density = None
    hidden = False
    rest = args[2:]
    i = 0
    while i < len(rest):
        if rest[i] == "--density":
            density = float(rest[i + 1])
            i += 2
        elif rest[i] == "--hidden":
            hidden = True
            i += 1
        else:
            raise SystemExit("unknown option: %s" % rest[i])
    return step_path, outdir, density, hidden


SKIP_TYPES = {
    "App::Origin",
    "App::Line",
    "App::Plane",
    "App::DatumFeature",
    "Part::Datum",
}


def top_level(doc):
    """Bodies worth counting: no datums, no aggregation duplicates."""
    tops = []
    for obj in doc.Objects:
        if obj.TypeId in SKIP_TYPES:
            continue
        shape = getattr(obj, "Shape", None)
        if shape is None or shape.isNull():
            continue
        try:
            if not len(shape.Solids):
                continue
        except Exception:
            continue
        if [p for p in obj.InList if p.TypeId.startswith("App::Part")]:
            continue
        tops.append(obj)
    return tops


def metrics(tops, density):
    bodies = []
    total_volume = 0.0
    total_area = 0.0
    for obj in tops:
        shape = obj.Shape
        volume = abs(shape.Volume)
        area = shape.Area
        bb = shape.BoundBox
        entry = {
            "name": obj.Name,
            "label": obj.Label,
            "type": obj.TypeId,
            "solids": len(shape.Solids),
            "volume_mm3": round(volume, 2),
            "area_mm2": round(area, 2),
            "bbox_mm": [
                round(bb.XLength, 3),
                round(bb.YLength, 3),
                round(bb.ZLength, 3),
            ],
        }
        if density is not None:
            entry["mass_g"] = round(volume / 1000.0 * density, 2)
        children = getattr(obj, "Group", None)
        if children:
            entry["children"] = [c.Label for c in children]
        bodies.append(entry)
        total_volume += volume
        total_area += area
    out = {
        "bodies": bodies,
        "totals": {
            "bodies": len(bodies),
            "solids": sum(b["solids"] for b in bodies),
            "volume_mm3": round(total_volume, 2),
            "area_mm2": round(total_area, 2),
        },
        "density_g_cm3": density,
    }
    if density is not None:
        out["totals"]["mass_g"] = round(total_volume / 1000.0 * density, 2)
    return out


def project(shape, direction, with_hidden):
    # projectEx returns [V, V1, VN, VO, VI, H, H1, HN, HO, HI]:
    # index 0 is the visible outline, index 5 the hidden outline.
    parts = TechDraw.projectEx(shape, FreeCAD.Vector(*direction))
    hidden = parts[5] if with_hidden and len(parts) > 5 else None
    return parts[0], hidden


def polylines(edge_shape, samples=24):
    lines = []
    if edge_shape is None or edge_shape.isNull():
        return lines
    for edge in edge_shape.Edges:
        try:
            pts = edge.discretize(samples)
        except Exception:
            continue
        if len(pts) >= 2:
            lines.append([(p.x, p.y) for p in pts])
    return lines


def view_svg(name, vis, hid, cell_w, cell_h, margin=10.0):
    xs = [x for line in vis for x, _ in line]
    ys = [y for line in vis for _, y in line]
    if not xs:
        return "<g></g>"
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    w = max(maxx - minx, 1e-6)
    h = max(maxy - miny, 1e-6)
    scale = min((cell_w - 2 * margin) / w, (cell_h - 2 * margin) / h)
    ox = margin + ((cell_w - 2 * margin) - w * scale) / 2.0
    oy = margin + ((cell_h - 2 * margin) - h * scale) / 2.0

    def to_xy(x, y):
        return ox + (x - minx) * scale, oy + (maxy - y) * scale

    parts = []
    for line in hid:
        pts = " ".join("%.2f,%.2f" % to_xy(x, y) for x, y in line)
        parts.append(
            '<polyline points="%s" fill="none" stroke="#9aa0a6" stroke-width="0.8" stroke-dasharray="4 3"/>' % pts
        )
    for line in vis:
        pts = " ".join("%.2f,%.2f" % to_xy(x, y) for x, y in line)
        parts.append('<polyline points="%s" fill="none" stroke="#1f2328" stroke-width="1.4"/>' % pts)
    return "<g><title>%s</title>%s</g>" % (escape(name), "".join(parts))


def collect(shapes, direction, with_hidden):
    """Project every body separately: one solid failing must not kill the view."""
    vis, hid, failed = [], [], 0
    for shape in shapes:
        try:
            visible, hidden = project(shape, direction, with_hidden)
        except Exception:
            failed += 1
            continue
        vis.extend(polylines(visible))
        hid.extend(polylines(hidden))
    return vis, hid, failed


def sheet(shapes, with_hidden, outdir, title):
    import math

    views = ORTHO + ISO
    cols = 5
    cell_w, cell_h = 400, 300
    rows = int(math.ceil(len(views) / float(cols)))
    width, height = cols * cell_w, rows * cell_h + 28
    chunks = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d">' % (width, height, width, height),
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<text x="12" y="20" font-family="Helvetica" font-size="14" '
        'fill="#1f2328">%s — %d views</text>' % (escape(title), len(views)),
    ]
    failed_views = []
    for idx, (name, direction) in enumerate(views):
        col, row = idx % cols, idx // cols
        x, y = col * cell_w, row * cell_h + 28
        vis, hid, failed = collect(shapes, direction, with_hidden)
        if failed:
            failed_views.append({"view": name, "bodies_failed": failed})
        tag = (
            '<text x="%d" y="%d" font-family="Helvetica" font-size="11" '
            % (
                x + 10,
                y + 16,
            )
            + 'fill="#57606a">%s</text>' % name
        )
        chunks.append(
            '<g transform="translate(%d,%d)">%s%s</g>' % (x, y, tag, view_svg(name, vis, hid, cell_w, cell_h - 20))
        )
    chunks.append("</svg>")
    path = os.path.join(outdir, "views.svg")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(chunks))
    return path, failed_views


def main():
    import json

    step_path, outdir, density, with_hidden = parse_args(sys.argv)
    if not os.path.isfile(step_path):
        raise SystemExit("no such file: %s" % step_path)
    os.makedirs(outdir, exist_ok=True)

    doc = FreeCAD.newDocument("step_views")
    import Import

    Import.insert(step_path, doc.Name)
    doc.recompute()
    tops = top_level(doc)
    if not tops:
        raise SystemExit("no solid shapes found in %s" % step_path)

    svg_path, failed_views = sheet([o.Shape for o in tops], with_hidden, outdir, os.path.basename(step_path))

    data = metrics(tops, density)
    data["source"] = step_path
    data["views_svg"] = svg_path
    data["views_count"] = len(ORTHO) + len(ISO)
    data["hidden_lines"] = with_hidden
    data["unprojected_views"] = failed_views
    data["limits"] = [
        "no PMI, tolerances or process data",
        "no assembly semantics; solids, not installed instances",
        "mass requires --density; without it only volume is reported",
    ]
    with open(os.path.join(outdir, "metrics.json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    print(json.dumps({k: data[k] for k in ("totals", "views_svg")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
