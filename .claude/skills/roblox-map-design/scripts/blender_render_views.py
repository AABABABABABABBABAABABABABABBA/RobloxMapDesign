"""blender_render_views.py — background "render view" of the Blender scene.

Renders PNGs to disk instead of grabbing the screen, so it works while Blender is
minimised or headless and never needs desktop/computer-use screenshots.
Run through Blender MCP `execute_blender_code` (or `blender -b f.blend --python ...`),
then open the printed PNG paths with the Read tool to look at them.

Views (auto-framed on all visible meshes not starting with "_", or on TARGETS):
  hero     3/4 view from eye-ish height, the "money shot"
  front / side / top   orthographic, for silhouettes and layout
  turn     4-angle turntable merged into one contact sheet (needs no extra deps)
Lighting: if the scene has no lights, a temporary sun + sky-ish world is added and
removed afterwards, so the user's scene is left untouched.
"""
import math
import os

import bpy
from mathutils import Vector

OUT_DIR = os.environ.get("RENDER_OUT") or (bpy.path.abspath("//renders/") if bpy.data.filepath else "/tmp/roblox_renders/")
VIEWS = ["hero", "front", "side", "top", "turn"]
TARGETS = []  # object names; empty = everything visible
RES = int(os.environ.get("RENDER_RES", "768"))
ENGINE = os.environ.get("RENDER_ENGINE", "AUTO")  # AUTO tries EEVEE then falls back to CYCLES


def targets():
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH" and o.visible_get() and not o.name.startswith("_")]
    if TARGETS:
        objs = [o for o in objs if o.name in TARGETS]
    return objs


def bounds(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def set_engine(scene):
    # EEVEE needs a GPU context: fine in the GUI Blender the MCP talks to, but it can
    # hard-crash `blender -b` on GPU-less machines, so AUTO uses Cycles there.
    if ENGINE == "EEVEE" or (ENGINE == "AUTO" and not bpy.app.background):
        for name in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
            try:
                scene.render.engine = name
                return name
            except TypeError:
                continue
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.cycles.device = "CPU"
    return "CYCLES"


def render_to(scene, cam, path):
    scene.camera = cam
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def main():
    scene = bpy.context.scene
    objs = targets()
    if not objs:
        print("RENDER: nothing to render")
        return []
    mn, mx = bounds(objs)
    centre = (mn + mx) / 2
    size = mx - mn
    radius = max(size.length / 2, 0.5)
    os.makedirs(OUT_DIR, exist_ok=True)

    old = {
        "engine": scene.render.engine, "x": scene.render.resolution_x, "y": scene.render.resolution_y,
        "pct": scene.render.resolution_percentage, "cam": scene.camera, "path": scene.render.filepath,
        "world": scene.world, "fmt": scene.render.image_settings.file_format,
    }
    temp = []
    set_engine(scene)
    scene.render.resolution_x = RES
    scene.render.resolution_y = int(RES * 0.66)
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"

    if not any(o.type == "LIGHT" for o in scene.objects):
        sun_data = bpy.data.lights.new("_tmp_sun", "SUN")
        sun_data.energy = 3.5
        sun_data.angle = math.radians(8)
        sun = bpy.data.objects.new("_tmp_sun", sun_data)
        sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(35))
        scene.collection.objects.link(sun)
        temp.append(sun)
    if scene.world is None or not scene.world.use_nodes:
        w = bpy.data.worlds.new("_tmp_world")
        w.use_nodes = True
        bg = w.node_tree.nodes.get("Background")
        bg.inputs[0].default_value = (0.55, 0.62, 0.72, 1)
        bg.inputs[1].default_value = 0.6
        scene.world = w

    cam_data = bpy.data.cameras.new("_tmp_cam")
    cam = bpy.data.objects.new("_tmp_cam", cam_data)
    scene.collection.objects.link(cam)
    temp.append(cam)

    def aim(loc):
        cam.location = loc
        cam.rotation_euler = (centre - Vector(loc)).to_track_quat("-Z", "Y").to_euler()

    outputs = {}
    for view in VIEWS:
        if view == "hero":
            cam_data.type = "PERSP"
            cam_data.lens = 35
            d = radius * 1.9
            aim(centre + Vector((d * 0.75, -d * 0.75, max(size.z * 0.35, radius * 0.45))))
            outputs[view] = render_to(scene, cam, os.path.join(OUT_DIR, "hero.png"))
        elif view in ("front", "side", "top"):
            cam_data.type = "ORTHO"
            cam_data.ortho_scale = max(size.x, size.y, size.z) * 1.25
            off = {"front": Vector((0, -radius * 4, 0)), "side": Vector((radius * 4, 0, 0)), "top": Vector((0, 0, radius * 4))}[view]
            aim(centre + off)
            if view == "top":
                cam.rotation_euler = (0, 0, 0)
            outputs[view] = render_to(scene, cam, os.path.join(OUT_DIR, f"{view}.png"))
        elif view == "turn":
            cam_data.type = "PERSP"
            cam_data.lens = 50
            frames = []
            for i in range(4):
                a = math.radians(45 + 90 * i)
                d = radius * 3.2
                aim(centre + Vector((math.cos(a) * d, math.sin(a) * d, radius * 0.8)))
                frames.append(render_to(scene, cam, os.path.join(OUT_DIR, f"turn_{i}.png")))
            outputs[view] = contact_sheet(frames, os.path.join(OUT_DIR, "turntable.png"))

    for o in temp:
        bpy.data.objects.remove(o, do_unlink=True)
    scene.render.engine = old["engine"]
    scene.render.resolution_x, scene.render.resolution_y = old["x"], old["y"]
    scene.render.resolution_percentage = old["pct"]
    scene.camera = old["cam"]
    scene.render.filepath = old["path"]
    scene.render.image_settings.file_format = old["fmt"]
    if old["world"] is not None:
        scene.world = old["world"]

    for k, v in outputs.items():
        print(f"RENDER {k}: {v}")
    return outputs


def contact_sheet(paths, out):
    """2x2 sheet using Blender's own image API (no PIL needed inside Blender)."""
    imgs = [bpy.data.images.load(p) for p in paths]
    w, h = imgs[0].size
    sheet = bpy.data.images.new("_sheet", w * 2, h * 2, alpha=False)
    px = [0.0] * (w * 2 * h * 2 * 4)
    for idx, im in enumerate(imgs):
        src = list(im.pixels)
        ox, oy = (idx % 2) * w, (1 - idx // 2) * h
        for y in range(h):
            row = src[y * w * 4:(y + 1) * w * 4]
            start = ((oy + y) * w * 2 + ox) * 4
            px[start:start + w * 4] = row
    sheet.pixels = px
    sheet.filepath_raw = out
    sheet.file_format = "PNG"
    sheet.save()
    for im in imgs + [sheet]:
        bpy.data.images.remove(im)
    for p in paths:
        os.remove(p)
    return out


main()
