#!/usr/bin/env python3
"""Inspect a glTF/GLB without any dependency: structure, budgets, bounds.

Use it as the evidence step before an agent claims anything about a game
asset, or before/after a Godot import. It reads the container and the JSON
chunk only; it never decodes pixels and never needs Blender.

    python3 glb-inspect.py model.glb           # human summary
    python3 glb-inspect.py model.glb --json    # machine-readable

Reported: scene/node hierarchy, meshes and primitives, triangle and vertex
counts, materials, textures and their encoded bytes, animations and duration,
skins, morph targets, extensions, world-space bounding box, and a short list of
issues that usually break an import or a budget.

Limits: geometry stats come from accessors, not from vertices; bounds use each
primitive's POSITION min/max transformed by its node matrix (conservative, not
tight); external .bin/.png URIs are not fetched.
"""

import json
import math
import os
import struct
import sys

MODE_TRIANGLES = 4
MODE_STRIP = 5
MODE_FAN = 6


def load(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data.lstrip()[:1] == b"{":
        try:
            gltf = json.loads(data.decode("utf-8"))
        except (ValueError, RecursionError) as exc:
            raise SystemExit("%s is not parseable glTF JSON: %s" % (path, exc)) from None
        external = [
            buf.get("uri") for buf in gltf.get("buffers", []) if buf.get("uri") and not buf["uri"].startswith("data:")
        ]
        meta = {
            "container": "gltf",
            "version": gltf.get("asset", {}).get("version", "?"),
            "bytes": len(data),
            "json_chunk_bytes": len(data),
            "bin_chunk_bytes": 0,
            "external_buffers": external,
        }
        return gltf, meta
    if data[:4] != b"glTF":
        raise SystemExit("%s is neither GLB nor glTF JSON" % path)
    version, total = struct.unpack_from("<II", data, 4)
    offset = 12
    chunks = []
    while offset + 8 <= len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        body = data[offset + 8 : offset + 8 + length]
        chunks.append((kind, body))
        offset += 8 + length
    if not chunks or chunks[0][0] != 0x4E4F534A:
        raise SystemExit("GLB has no JSON chunk")
    try:
        gltf = json.loads(chunks[0][1].decode("utf-8"))
    except (ValueError, RecursionError) as exc:
        raise SystemExit("GLB JSON chunk is not parseable: %s" % exc) from None
    bin_bytes = sum(len(b) for k, b in chunks[1:] if k == 0x004E4942)
    meta = {
        "container": "glb",
        "version": version,
        "bytes": len(data),
        "header_total_bytes": total,
        "json_chunk_bytes": len(chunks[0][1]),
        "bin_chunk_bytes": bin_bytes,
        "external_buffers": [],
    }
    return gltf, meta


def mat_mul(a, b):
    """Row-major 4x4 multiply: applies b first, then a."""
    out = [0.0] * 16
    for row in range(4):
        for col in range(4):
            out[row * 4 + col] = sum(a[row * 4 + k] * b[k * 4 + col] for k in range(4))
    return out


def node_matrix(node):
    if "matrix" in node:
        try:
            col_major = [float(v) for v in node["matrix"]]
        except (TypeError, ValueError):
            col_major = []
        if len(col_major) != 16:
            return [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
        return [
            col_major[0],
            col_major[4],
            col_major[8],
            col_major[12],
            col_major[1],
            col_major[5],
            col_major[9],
            col_major[13],
            col_major[2],
            col_major[6],
            col_major[10],
            col_major[14],
            col_major[3],
            col_major[7],
            col_major[11],
            col_major[15],
        ]
    t = node.get("translation", [0.0, 0.0, 0.0])
    r = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    s = node.get("scale", [1.0, 1.0, 1.0])
    try:
        x, y, z, w = (float(v) for v in r)
        t = [float(v) for v in t]
        s = [float(v) for v in s]
    except (TypeError, ValueError):
        return [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
    rot = [
        1 - 2 * (y * y + z * z),
        2 * (x * y - z * w),
        2 * (x * z + y * w),
        0.0,
        2 * (x * y + z * w),
        1 - 2 * (x * x + z * z),
        2 * (y * z - x * w),
        0.0,
        2 * (x * z - y * w),
        2 * (y * z + x * w),
        1 - 2 * (x * x + y * y),
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
    ]
    scale = [s[0], 0.0, 0.0, 0.0, 0.0, s[1], 0.0, 0.0, 0.0, 0.0, s[2], 0.0, 0.0, 0.0, 0.0, 1.0]
    trans = [1.0, 0.0, 0.0, t[0], 0.0, 1.0, 0.0, t[1], 0.0, 0.0, 1.0, t[2], 0.0, 0.0, 0.0, 1.0]
    return mat_mul(trans, mat_mul(rot, scale))


def transform_point(m, p):
    x, y, z = p
    return (
        m[0] * x + m[1] * y + m[2] * z + m[3],
        m[4] * x + m[5] * y + m[6] * z + m[7],
        m[8] * x + m[9] * y + m[10] * z + m[11],
    )


def accessor_count(gltf, index):
    if not isinstance(index, int) or index < 0:
        return 0
    accessors = gltf.get("accessors", [])
    if index >= len(accessors):
        return 0
    acc = accessors[index]
    try:
        return int(acc.get("count", 0))
    except (TypeError, ValueError):
        return 0


def primitive_triangles(gltf, prim):
    mode = prim.get("mode", MODE_TRIANGLES)
    count = accessor_count(gltf, prim.get("indices"))
    if not count:
        count = accessor_count(gltf, prim.get("attributes", {}).get("POSITION"))
    if mode == MODE_TRIANGLES:
        return count // 3
    if mode in (MODE_STRIP, MODE_FAN) and count >= 3:
        return count - 2
    return 0


def walk(nodes, roots):
    """Yield (node_index, depth, world_matrix)."""
    stack = [(idx, 0, [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]) for idx in roots]
    seen: dict[int, int] = {}
    while stack:
        idx, depth, parent = stack.pop()
        if not isinstance(idx, int) or idx < 0 or idx >= len(nodes):
            continue
        # glTF instancing reuses a node under several parents; cap repeats so a
        # cycle terminates but shared geometry is counted and bounded per use.
        if seen.get(idx, 0) >= 8 or depth > 64:
            continue
        seen[idx] = seen.get(idx, 0) + 1
        node = nodes[idx]
        world = mat_mul(parent, node_matrix(node))
        yield idx, depth, world
        for child in node.get("children", []):
            stack.append((child, depth + 1, world))


def inspect(path, label=None):
    gltf, meta = load(path)
    scenes = gltf.get("scenes", [])
    nodes = gltf.get("nodes", [])
    meshes = gltf.get("meshes", [])
    materials = gltf.get("materials", [])
    textures = gltf.get("textures", [])
    images = gltf.get("images", [])
    issues: list[str] = []

    scene_index = gltf.get("scene", 0)
    if not isinstance(scene_index, int) or not 0 <= scene_index < len(scenes):
        scene_index = 0 if scenes else None
    roots = scenes[scene_index].get("nodes", []) if scene_index is not None else []

    node_rows = []
    triangles = 0
    vertices = 0
    primitives = 0
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for idx, depth, world in walk(nodes, roots):
        node = nodes[idx]
        node_rows.append(
            {
                "index": idx,
                "name": node.get("name", ""),
                "depth": depth,
                "mesh": node.get("mesh"),
                "children": len(node.get("children", [])),
                "has_matrix": "matrix" in node,
            }
        )
        mesh_index = node.get("mesh")
        if not isinstance(mesh_index, int) or not 0 <= mesh_index < len(meshes):
            continue
        for prim in meshes[mesh_index].get("primitives", []):
            primitives += 1
            triangles += primitive_triangles(gltf, prim)
            attrs = prim.get("attributes", {})
            pos_index = attrs.get("POSITION")
            vertices += accessor_count(gltf, pos_index)
            if pos_index is None:
                continue
            accessors = gltf.get("accessors", [])
            pos = accessors[pos_index] if pos_index < len(accessors) else None
            if not pos or "min" not in pos or "max" not in pos:
                continue
            mn, mx = pos["min"], pos["max"]
            try:
                finite = all(math.isfinite(float(v)) for v in list(mn)[:3] + list(mx)[:3])
            except (TypeError, ValueError):
                finite = False
            if len(mn) < 3 or len(mx) < 3 or not finite:
                issues.append("accessor %s has invalid min/max; world bounds incomplete" % pos_index)
                continue
            for corner in range(8):
                p = (
                    mn[0] if corner & 1 else mx[0],
                    mn[1] if corner & 2 else mx[1],
                    mn[2] if corner & 4 else mx[2],
                )
                q = transform_point(world, p)
                for axis in range(3):
                    lo[axis] = min(lo[axis], q[axis])
                    hi[axis] = max(hi[axis], q[axis])

    animations = gltf.get("animations", [])
    duration = 0.0
    for anim in animations:
        for sampler in anim.get("samplers", []):
            acc = gltf.get("accessors", [])
            inp = sampler.get("input")
            if isinstance(inp, int) and 0 <= inp < len(acc) and "max" in acc[inp]:
                duration = max(duration, float(acc[inp]["max"][0]))

    image_bytes = 0
    external = []
    views = gltf.get("bufferViews", [])
    for image in images:
        if "bufferView" in image:
            view_index = image["bufferView"]
            if not isinstance(view_index, int) or not 0 <= view_index < len(views):
                issues.append("image bufferView %r is out of range" % (view_index,))
                continue
            image_bytes += int(views[view_index].get("byteLength", 0) or 0)
        elif image.get("uri"):
            external.append(image["uri"])

    header_total = meta.get("header_total_bytes")
    if header_total is not None and header_total != meta["bytes"]:
        issues.append(
            "GLB header says %d bytes but the file is %d: truncated or padded" % (header_total, meta["bytes"])
        )
    if meta.get("container") == "glb":
        need = sum(int(buf.get("byteLength", 0) or 0) for buf in gltf.get("buffers", []) if not buf.get("uri"))
        if need > meta.get("bin_chunk_bytes", 0):
            issues.append(
                "embedded buffer declares %d bytes but BIN chunk holds %d: truncated"
                % (need, meta.get("bin_chunk_bytes", 0))
            )
    if not scenes:
        issues.append("no scene: importers may load nothing")
    if not triangles:
        issues.append("0 triangles: no drawable geometry in the scene")
    used = gltf.get("extensionsUsed", [])
    required = gltf.get("extensionsRequired", [])
    for ext in required:
        if ext in ("KHR_draco_mesh_compression", "EXT_meshopt_compression"):
            issues.append("%s is required: plain importers cannot decode" % ext)
    joints = {j for skin in gltf.get("skins", []) for j in skin.get("joints", [])}
    animated = {
        channel.get("target", {}).get("node")
        for anim in gltf.get("animations", [])
        for channel in anim.get("channels", [])
    }
    animated.discard(None)
    cameras = {idx for idx, n in enumerate(nodes) if "camera" in n}
    # Skeleton/animation-only assets legitimately end in leaf bones; the
    # missing-geometry signal is "0 triangles", not a list of empty leaves.
    if meshes:
        for node in node_rows:
            if node["mesh"] is None and node["children"] == 0:
                if node["index"] in joints or node["index"] in cameras:
                    continue  # leaf bones and cameras are legitimate
                if node["index"] in animated:
                    continue  # animated leaf bone, skeleton-only export
                issues.append("node %s (%s) has neither mesh nor children" % (node["index"], node["name"] or "unnamed"))
    for mesh in meshes:
        for prim in mesh.get("primitives", []):
            attrs = prim.get("attributes", {})
            if "NORMAL" not in attrs:
                issues.append("mesh %s primitive lacks NORMAL" % mesh.get("name", "?"))
                break
    if textures and not any("TEXCOORD_0" in p.get("attributes", {}) for m in meshes for p in m.get("primitives", [])):
        issues.append("textures exist but no primitive has TEXCOORD_0")
    if external:
        issues.append("%d image(s) reference external files, not embedded" % len(external))
    if meta["external_buffers"]:
        issues.append(
            "%d buffer(s) live in external files (%s); move the whole set together"
            % (len(meta["external_buffers"]), ", ".join(meta["external_buffers"][:3]))
        )

    bounds = None
    if lo[0] < math.inf:
        bounds = {
            "min": [round(v, 3) for v in lo],
            "max": [round(v, 3) for v in hi],
            "size": [round(hi[i] - lo[i], 3) for i in range(3)],
        }

    return {
        "file": label or os.path.abspath(path),
        "container": meta["container"],
        "version": meta["version"],
        "bytes": meta["bytes"],
        "json_chunk_bytes": meta["json_chunk_bytes"],
        "bin_chunk_bytes": meta["bin_chunk_bytes"],
        "asset": gltf.get("asset", {}),
        "extensions_used": used,
        "extensions_required": required,
        "counts": {
            "scenes": len(scenes),
            "nodes": len(nodes),
            "meshes": len(meshes),
            "primitives": primitives,
            "triangles": triangles,
            "vertices": vertices,
            "materials": len(materials),
            "textures": len(textures),
            "images": len(images),
            "image_bytes": image_bytes,
            "animations": len(animations),
            "skins": len(gltf.get("skins", [])),
            "morph_targets": sum(len(p.get("targets", [])) for m in meshes for p in m.get("primitives", [])),
        },
        "animation_seconds": round(duration, 3),
        "bounds": bounds,
        "nodes": node_rows[:80],
        "nodes_truncated": max(0, len(node_rows) - 80),
        "issues": issues,
    }


def summary(report):
    c = report["counts"]
    b = report["bounds"]
    lines = [
        "%s" % report["file"],
        "%s | %d bytes (json %d, bin %d)"
        % (
            report["asset"].get("generator", "unknown"),
            report["bytes"],
            report["json_chunk_bytes"],
            report["bin_chunk_bytes"],
        ),
        "scenes %(scenes)d | nodes %(nodes)d | meshes %(meshes)d | primitives %(primitives)d" % c,
        "triangles %(triangles)d | vertices %(vertices)d" % c,
        "materials %d | textures %d (%d B) | animations %d (%ss)"
        % (
            c["materials"],
            c["textures"],
            c["image_bytes"],
            c["animations"],
            report["animation_seconds"],
        ),
        "skins %(skins)d | morph targets %(morph_targets)d" % c,
    ]
    if b:
        lines.append("bounds min %s max %s size %s" % (b["min"], b["max"], b["size"]))
    if report["extensions_required"]:
        lines.append("required extensions: %s" % ", ".join(report["extensions_required"]))
    if report["issues"]:
        lines.append("issues:")
        lines.extend("  - %s" % item for item in report["issues"][:12])
    else:
        lines.append("issues: none")
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if a]
    as_json = "--json" in args
    label = None
    if "--source" in args:
        idx = args.index("--source")
        if idx + 1 >= len(args):
            raise SystemExit("--source needs a path")
        label = args[idx + 1]
        del args[idx : idx + 2]
    args = [a for a in args if not a.startswith("--")]
    if len(args) != 1:
        raise SystemExit("usage: glb-inspect.py model.glb [--json] [--source label]")
    try:
        report = inspect(args[0], label)
    except FileNotFoundError:
        raise SystemExit("no such file: %s" % args[0]) from None
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise SystemExit("%s is not valid glTF JSON: %s" % (args[0], exc)) from exc
    except struct.error as exc:
        raise SystemExit("%s has a truncated GLB header: %s" % (args[0], exc)) from exc
    if as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(summary(report))


if __name__ == "__main__":
    main()
