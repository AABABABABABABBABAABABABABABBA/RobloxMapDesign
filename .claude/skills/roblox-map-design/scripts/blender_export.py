"""blender_export.py — export Blender assets as Roblox-ready FBX + a manifest.

Run inside Blender (MCP `execute_blender_code`) after blender_audit.py is clean.
For every visible mesh object not starting with "_" (or only EXPORT_ONLY):
  * origin moved to the bottom-centre of its bounds (so it sits on the ground)
  * rotation & scale applied
  * exported alone to <EXPORT_DIR>/<name>.fbx (1 Blender unit = 1 stud)
  * entry written to <EXPORT_DIR>/manifest.json:
      {name, family, file, sha1, tris, size:[x,y,z] in studs (Roblox Y-up), textures}
Family = custom property "family" if set, else the name without its last _suffix
("Rock_A" -> "Rock"). upload_to_roblox.py reads this manifest.

Objects are restored to their original world position after export; only the
origin and applied transforms change (which is what Roblox needs anyway).
"""
import hashlib
import json
import os

import bpy
import bmesh
from mathutils import Matrix, Vector

EXPORT_DIR = os.environ.get("EXPORT_DIR") or (bpy.path.abspath("//export/") if bpy.data.filepath else "/tmp/roblox_export/")
EXPORT_ONLY = []  # names; empty = all eligible meshes


def family_of(o):
    if "family" in o:
        return str(o["family"])
    return o.name.rsplit("_", 1)[0] if "_" in o.name else o.name


def tri_count(o):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    n = sum(len(p.vertices) - 2 for p in me.polygons)
    ev.to_mesh_clear()
    return n


def origin_to_base(o):
    me = o.data
    pts = [o.matrix_world @ v.co for v in me.vertices]
    if not pts:
        return
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    base = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    local = o.matrix_world.inverted() @ base
    me.transform(Matrix.Translation(-local))
    o.matrix_world = o.matrix_world @ Matrix.Translation(local)


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def textures_of(o):
    out = []
    for slot in o.material_slots:
        if slot.material and slot.material.use_nodes:
            for n in slot.material.node_tree.nodes:
                if n.type == "TEX_IMAGE" and n.image:
                    out.append(bpy.path.abspath(n.image.filepath) or n.image.name)
    return out


def main():
    os.makedirs(EXPORT_DIR, exist_ok=True)
    objs = [
        o for o in bpy.context.scene.objects
        if o.type == "MESH" and o.visible_get() and not o.name.startswith("_")
        and (not EXPORT_ONLY or o.name in EXPORT_ONLY)
    ]
    manifest_path = os.path.join(EXPORT_DIR, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            manifest = {e["name"]: e for e in json.load(f)}

    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    for o in objs:
        if o.data.users > 1:
            o.data = o.data.copy()  # don't edit shared meshes of other variants
        # apply rotation+scale into the mesh, keep location
        loc = o.matrix_world.to_translation()
        o.data.transform(o.matrix_world.to_3x3().to_4x4())
        o.matrix_world = Matrix.Translation(loc)
        origin_to_base(o)

        world = o.matrix_world.copy()
        o.matrix_world = Matrix.Identity(4)  # export at origin so pivot == base centre
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        path = os.path.join(EXPORT_DIR, o.name + ".fbx")
        bpy.ops.export_scene.fbx(
            filepath=path, use_selection=True, object_types={"MESH"},
            apply_unit_scale=True, apply_scale_options="FBX_SCALE_UNITS",
            axis_forward="-Z", axis_up="Y", mesh_smooth_type="FACE",
            use_mesh_modifiers=True, path_mode="COPY", embed_textures=True,
        )
        o.matrix_world = world

        dims = o.dimensions
        manifest[o.name] = {
            "name": o.name,
            "family": family_of(o),
            "file": path,
            "sha1": sha1(path),
            "tris": tri_count(o),
            "size": [round(dims.x, 3), round(dims.z, 3), round(dims.y, 3)],  # Roblox X, Y(up), Z
            "textures": textures_of(o),
        }
        print("exported", o.name, "->", path)

    with open(manifest_path, "w") as f:
        json.dump(list(manifest.values()), f, indent=1)
    print("MANIFEST:", manifest_path, f"({len(manifest)} assets)")


main()
