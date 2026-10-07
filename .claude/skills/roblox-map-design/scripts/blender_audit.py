"""blender_audit.py — pre-export audit for Roblox assets.

Run inside Blender: paste the file into the Blender MCP `execute_blender_code` tool
(or `blender -b file.blend --python blender_audit.py`). Prints a JSON report.

Checks every visible mesh object whose name doesn't start with "_":
  OVERLAP         triangles of two objects intersect (BVH)
  DUPLICATE       same mesh data/shape at the same transform
  CLONE_STAMP     same mesh data, same rotation+scale (linked copies not varied)
  TRI_BUDGET      > TRI_LIMIT triangles (Roblox hard limit 20k per MeshPart)
  UNAPPLIED_SCALE scale != 1 or negative scale (normals flip in Roblox)
  NO_UV           mesh has no UV map
  ORIGIN          origin not near the bottom-centre of the bounds
  TOO_BIG         any dimension > 2048 (Roblox MeshPart limit)
  NGONS           faces with > 4 verts (triangulate predictably before export)
"""
import json

import bpy
import bmesh
from mathutils import Vector
from mathutils.bvhtree import BVHTree

TRI_LIMIT = 20000
TRI_WARN_SCATTER = 2000
ORIGIN_TOL = 0.15  # fraction of height
CLONE_RADIUS = 40.0

issues = []


def add(kind, msg, *objs):
    issues.append({"type": kind, "msg": msg, "objects": [o.name for o in objs]})


def mesh_objects():
    return [
        o for o in bpy.context.scene.objects
        if o.type == "MESH" and not o.name.startswith("_") and o.visible_get()
    ]


def world_bvh(obj, depsgraph):
    ev = obj.evaluated_get(depsgraph)
    me = ev.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.transform(obj.matrix_world)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    tris = len(bm.faces)
    bvh = BVHTree.FromBMesh(bm)
    bm.free()
    ev.to_mesh_clear()
    return bvh, tris


def world_bounds(obj):
    pts = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def shape_sig(obj):
    """Identifies geometrically identical meshes even when they aren't linked copies."""
    me = obj.data
    dims = [max(c[k] for c in obj.bound_box) - min(c[k] for c in obj.bound_box) for k in range(3)]
    return (len(me.vertices), len(me.polygons), tuple(round(d, 3) for d in dims))


def run():
    dg = bpy.context.evaluated_depsgraph_get()
    objs = mesh_objects()
    bvhs, bounds = {}, {}
    tri_total = 0

    for o in objs:
        bvh, tris = world_bvh(o, dg)
        bvhs[o.name] = bvh
        bounds[o.name] = world_bounds(o)
        tri_total += tris
        if tris > TRI_LIMIT:
            add("TRI_BUDGET", f"{o.name}: {tris} tris > {TRI_LIMIT} (decimate or split)", o)
        elif tris > TRI_WARN_SCATTER and o.get("scatter"):
            add("TRI_BUDGET", f"{o.name}: {tris} tris is heavy for a scattered prop", o)

        s = o.scale
        if any(abs(v - 1) > 1e-4 for v in s) or any(v < 0 for v in s):
            add("UNAPPLIED_SCALE", f"{o.name}: scale {tuple(round(v, 3) for v in s)} (Ctrl+A > Scale)", o)
        if not o.data.uv_layers:
            add("NO_UV", f"{o.name}: no UV map", o)
        ngons = sum(1 for p in o.data.polygons if len(p.vertices) > 4)
        if ngons:
            add("NGONS", f"{o.name}: {ngons} n-gons", o)

        mn, mx = bounds[o.name]
        size = mx - mn
        if max(size) > 2048:
            add("TOO_BIG", f"{o.name}: {tuple(round(v, 1) for v in size)} exceeds 2048", o)
        h = max(size.z, 1e-6)
        org = o.matrix_world.translation
        centre = (mn + mx) / 2
        if abs(org.z - mn.z) > ORIGIN_TOL * h or (Vector((org.x, org.y)) - Vector((centre.x, centre.y))).length > 0.25 * max(size.x, size.y, 1e-6):
            add("ORIGIN", f"{o.name}: origin not at base centre", o)

    # pairwise
    for i, a in enumerate(objs):
        amn, amx = bounds[a.name]
        for b in objs[i + 1:]:
            bmn, bmx = bounds[b.name]
            if a.data == b.data or shape_sig(a) == shape_sig(b):
                same_loc = (a.matrix_world.translation - b.matrix_world.translation).length < 1e-3
                ra, rb = a.matrix_world.to_quaternion(), b.matrix_world.to_quaternion()
                same_rot = ra.rotation_difference(rb).angle < 0.087  # ~5 deg
                sa, sb = a.matrix_world.to_scale(), b.matrix_world.to_scale()
                same_scale = (sa - sb).length / max(sa.length, 1e-6) < 0.03
                if same_loc and same_rot and same_scale:
                    add("DUPLICATE", f"{a.name} == {b.name} (stacked copy)", a, b)
                    continue
                dist = (a.matrix_world.translation - b.matrix_world.translation).length
                if same_rot and same_scale and dist < CLONE_RADIUS:
                    add("CLONE_STAMP", f"{a.name} ~ {b.name}: same mesh, rotation and scale {dist:.1f} apart", a, b)
            if any(amn[k] > bmx[k] or bmn[k] > amx[k] for k in range(3)):
                continue
            hits = bvhs[a.name].overlap(bvhs[b.name])
            if hits:
                add("OVERLAP", f"{a.name} x {b.name}: {len(hits)} intersecting tri pairs", a, b)

    summary = {}
    for it in issues:
        summary[it["type"]] = summary.get(it["type"], 0) + 1
    report = {
        "objects": len(objs),
        "triangles": tri_total,
        "summary": summary,
        "result": "CLEAN" if not issues else f"{len(issues)} issues",
        "issues": issues[:60],
    }
    print(json.dumps(report, indent=1))
    return report


run()
