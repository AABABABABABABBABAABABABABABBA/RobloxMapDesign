"""blender_texture_bake.py — bake seamless, palette-driven PBR textures for Roblox.

Run inside Blender (Blender MCP `execute_blender_code`, or headless:
`blender -b --python blender_texture_bake.py`). Edit JOBS below first.

For each job it builds a procedural material whose noise is sampled on a 4D torus,
so the result tiles perfectly in both directions, then bakes with Cycles to:
    <out>/<name>_color.png      sRGB albedo
    <out>/<name>_normal.png     tangent-space normal, OpenGL (Y+) as Roblox expects
    <out>/<name>_roughness.png
    <out>/<name>_metalness.png
Those map 1:1 onto a Roblox MaterialVariant / SurfaceAppearance
(ColorMap, NormalMap, RoughnessMap, MetalnessMap). Max useful size is 1024.

Presets: stone, cobble, plaster, ground, wood, bark, rust_metal, brick.
Each takes 3 palette colours (dark, mid, light) so textures match the map palette —
pass the colours from palette_from_image.py.
"""
import math
import os

import bpy

OUT_DIR = os.environ.get("TEX_OUT") or (bpy.path.abspath("//textures/") if bpy.data.filepath else "/tmp/roblox_textures/")
RES = int(os.environ.get("TEX_RES", "1024"))
SEED = 7

JOBS = [
    # name, preset, (dark, mid, light) as 0-255 RGB, extra options
    {"name": "Cliff_Stone", "preset": "stone", "colors": [(58, 56, 60), (112, 106, 100), (168, 160, 148)]},
    {"name": "Path_Cobble", "preset": "cobble", "colors": [(52, 46, 42), (120, 108, 96), (176, 164, 146)]},
    {"name": "Dock_Wood", "preset": "wood", "colors": [(62, 40, 26), (118, 82, 52), (166, 124, 84)]},
]


# --------------------------------------------------------------------------- helpers
def srgb_to_linear(c):
    c = c / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgba(c):
    return (srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), 1.0)


class G:
    """Tiny node-graph builder."""

    def __init__(self, mat):
        self.nt = mat.node_tree
        self.nt.nodes.clear()
        self.x = 0

    def n(self, kind, **props):
        node = self.nt.nodes.new(kind)
        node.location = (self.x, 0)
        self.x += 200
        for k, v in props.items():
            setattr(node, k, v)
        return node

    def link(self, a, b):
        self.nt.links.new(a, b)

    def math(self, op, a, b=None, clamp=False):
        m = self.n("ShaderNodeMath", operation=op, use_clamp=clamp)
        self._in(m.inputs[0], a)
        if b is not None:
            self._in(m.inputs[1], b)
        return m.outputs[0]

    def _in(self, sock, v):
        if isinstance(v, (int, float)):
            sock.default_value = v
        else:
            self.link(v, sock)

    def ramp(self, fac, stops):
        r = self.n("ShaderNodeValToRGB")
        els = r.color_ramp.elements
        while len(els) > len(stops):
            els.remove(els[-1])
        while len(els) < len(stops):
            els.new(0.5)
        for e, (pos, col) in zip(els, stops):
            e.position = pos
            e.color = col if len(col) == 4 else (*col, 1)
        self.link(fac, r.inputs["Fac"])
        return r.outputs["Color"]

    def mix_color(self, fac, a, b, blend="MIX"):
        m = self.n("ShaderNodeMix", data_type="RGBA", blend_type=blend)
        self._in(m.inputs[0], fac)
        for sock, v in ((m.inputs[6], a), (m.inputs[7], b)):
            if isinstance(v, tuple):
                sock.default_value = v
            else:
                self.link(v, sock)
        return m.outputs[2]

    def mix_float(self, fac, a, b):
        m = self.n("ShaderNodeMix", data_type="FLOAT")
        self._in(m.inputs[0], fac)
        self._in(m.inputs[2], a)
        self._in(m.inputs[3], b)
        return m.outputs[0]


def torus(g, sx=1.0, sy=1.0, offset=0.0):
    """Map UV (0..1) onto a 4D torus -> (vector, w) sockets. Noise sampled there tiles."""
    tc = g.n("ShaderNodeTexCoord")
    sep = g.n("ShaderNodeSeparateXYZ")
    g.link(tc.outputs["UV"], sep.inputs[0])
    tau = 2 * math.pi
    th = g.math("MULTIPLY", sep.outputs[0], tau)
    ph = g.math("MULTIPLY", sep.outputs[1], tau)
    rx, ry = sx / tau, sy / tau  # radius so 'scale 1' ~ one feature per tile
    comb = g.n("ShaderNodeCombineXYZ")
    g.link(g.math("ADD", g.math("MULTIPLY", g.math("COSINE", th), rx), offset), comb.inputs[0])
    g.link(g.math("MULTIPLY", g.math("SINE", th), rx), comb.inputs[1])
    g.link(g.math("MULTIPLY", g.math("COSINE", ph), ry), comb.inputs[2])
    w = g.math("MULTIPLY", g.math("SINE", ph), ry)
    return comb.outputs[0], w


def noise(g, scale, detail=6, rough=0.55, sx=1, sy=1, offset=0.0, distortion=0.0):
    v, w = torus(g, sx * scale, sy * scale, offset)
    t = g.n("ShaderNodeTexNoise", noise_dimensions="4D")
    g.link(v, t.inputs["Vector"])
    g.link(w, t.inputs["W"])
    t.inputs["Scale"].default_value = 1.0
    t.inputs["Detail"].default_value = detail
    t.inputs["Roughness"].default_value = rough
    t.inputs["Distortion"].default_value = distortion
    return t.outputs["Fac"]


def voronoi(g, scale, feature="F1", offset=0.0, randomness=1.0, out="Distance"):
    v, w = torus(g, scale, scale, offset)
    t = g.n("ShaderNodeTexVoronoi", voronoi_dimensions="4D", feature=feature)
    g.link(v, t.inputs["Vector"])
    g.link(w, t.inputs["W"])
    t.inputs["Scale"].default_value = 1.0
    t.inputs["Randomness"].default_value = randomness
    return t.outputs[out]


# --------------------------------------------------------------------------- presets
# each returns (color_socket, height_socket, roughness_socket, metal_value)
def p_stone(g, d, m, l):
    big = noise(g, 3, 4, 0.5, offset=SEED)
    det = noise(g, 18, 8, 0.6, offset=SEED + 3)
    cells = voronoi(g, 5, "DISTANCE_TO_EDGE", offset=SEED + 5)
    cracks = g.math("POWER", g.math("SUBTRACT", 1.0, g.math("MULTIPLY", cells, 14.0, clamp=True)), 3.0)
    tone = g.math("ADD", g.math("MULTIPLY", big, 0.6), g.math("MULTIPLY", det, 0.4))
    col = g.ramp(tone, [(0.3, rgba(d)), (0.5, rgba(m)), (0.72, rgba(l))])
    col = g.mix_color(g.math("MULTIPLY", cracks, 0.7), col, rgba(d))
    height = g.math("SUBTRACT", g.math("ADD", g.math("MULTIPLY", big, 0.5), g.math("MULTIPLY", det, 0.5)), g.math("MULTIPLY", cracks, 0.6))
    rough = g.mix_float(det, 0.75, 0.95)
    return col, height, rough, 0.0


def p_cobble(g, d, m, l):
    stones = voronoi(g, 7, "DISTANCE_TO_EDGE", offset=SEED, randomness=0.85)
    rid = voronoi(g, 7, "F1", offset=SEED, randomness=0.85, out="Color")
    shape = g.math("MULTIPLY", stones, 6.0, clamp=True)
    det = noise(g, 30, 6, 0.6, offset=SEED + 1)
    bw = g.n("ShaderNodeRGBToBW")
    g.link(rid, bw.inputs[0])
    tone = g.math("ADD", g.math("MULTIPLY", bw.outputs[0], 0.7), g.math("MULTIPLY", det, 0.3))
    col = g.ramp(tone, [(0.25, rgba(m)), (0.75, rgba(l))])
    col = g.mix_color(g.math("SUBTRACT", 1.0, shape), col, rgba(d))
    height = g.math("ADD", g.math("POWER", shape, 0.5), g.math("MULTIPLY", det, 0.15))
    rough = g.mix_float(shape, 0.95, 0.7)
    return col, height, rough, 0.0


def p_plaster(g, d, m, l):
    big = noise(g, 2, 3, 0.4, offset=SEED)
    det = noise(g, 40, 8, 0.65, offset=SEED + 2)
    stain = g.math("POWER", noise(g, 4, 5, 0.6, offset=SEED + 4), 3.0)
    col = g.ramp(g.math("ADD", g.math("MULTIPLY", big, 0.7), g.math("MULTIPLY", det, 0.3)), [(0.4, rgba(m)), (0.62, rgba(l))])
    col = g.mix_color(g.math("MULTIPLY", stain, 1.5, clamp=True), col, rgba(d))
    return col, g.math("MULTIPLY", det, 0.4), g.mix_float(det, 0.8, 0.95), 0.0


def p_ground(g, d, m, l):
    big = noise(g, 3, 5, 0.55, offset=SEED)
    det = noise(g, 25, 8, 0.7, offset=SEED + 2)
    pebbles = g.math("GREATER_THAN", voronoi(g, 22, "F1", offset=SEED + 6), 0.35)
    tone = g.math("ADD", g.math("MULTIPLY", big, 0.55), g.math("MULTIPLY", det, 0.45))
    col = g.ramp(tone, [(0.3, rgba(d)), (0.55, rgba(m)), (0.75, rgba(l))])
    col = g.mix_color(g.math("MULTIPLY", g.math("SUBTRACT", 1.0, pebbles), 0.5), col, rgba(l))
    height = g.math("ADD", g.math("MULTIPLY", det, 0.6), g.math("MULTIPLY", g.math("SUBTRACT", 1.0, pebbles), 0.4))
    return col, height, g.mix_float(det, 0.85, 1.0), 0.0


def p_wood(g, d, m, l):
    # stretched noise along U = grain; integer plank count along V keeps tiling
    grain = noise(g, 1, 8, 0.6, sx=2, sy=40, offset=SEED, distortion=0.4)
    fine = noise(g, 1, 4, 0.5, sx=6, sy=160, offset=SEED + 1)
    tc = g.n("ShaderNodeTexCoord")
    sep = g.n("ShaderNodeSeparateXYZ")
    g.link(tc.outputs["UV"], sep.inputs[0])
    planks = 5.0
    vv = g.math("FRACT", g.math("MULTIPLY", sep.outputs[1], planks))
    gap = g.math("MULTIPLY", g.math("LESS_THAN", vv, 0.03), 1.0)
    tone = g.math("ADD", g.math("MULTIPLY", grain, 0.75), g.math("MULTIPLY", fine, 0.25))
    col = g.ramp(tone, [(0.35, rgba(d)), (0.5, rgba(m)), (0.65, rgba(l))])
    col = g.mix_color(gap, col, rgba((d[0] // 2, d[1] // 2, d[2] // 2)))
    height = g.math("SUBTRACT", g.math("MULTIPLY", fine, 0.3), g.math("MULTIPLY", gap, 0.8))
    return col, height, g.mix_float(fine, 0.6, 0.85), 0.0


def p_bark(g, d, m, l):
    ridges = noise(g, 1, 6, 0.6, sx=10, sy=1.5, offset=SEED, distortion=1.5)
    det = noise(g, 30, 6, 0.6, offset=SEED + 2)
    col = g.ramp(ridges, [(0.35, rgba(d)), (0.55, rgba(m)), (0.7, rgba(l))])
    height = g.math("ADD", g.math("MULTIPLY", ridges, 0.8), g.math("MULTIPLY", det, 0.2))
    return col, height, g.mix_float(det, 0.85, 1.0), 0.0


def p_rust_metal(g, d, m, l):
    rust = g.math("MULTIPLY", g.math("SUBTRACT", noise(g, 4, 8, 0.65, offset=SEED), 0.45), 4.0, clamp=True)
    det = noise(g, 50, 6, 0.6, offset=SEED + 1)
    col = g.mix_color(rust, rgba(m), g.ramp(det, [(0.3, rgba(d)), (0.7, rgba(l))]))
    rough = g.mix_float(rust, 0.35, 0.95)
    return col, g.math("MULTIPLY", g.math("MULTIPLY", rust, det), 0.6), rough, "rust"


def p_brick(g, d, m, l):
    tc = g.n("ShaderNodeTexCoord")
    b = g.n("ShaderNodeTexBrick")
    g.link(tc.outputs["UV"], b.inputs["Vector"])
    b.inputs["Scale"].default_value = 1.0  # 4 bricks wide x 8 rows per tile (keeps tiling)
    b.inputs["Brick Width"].default_value = 0.25
    b.inputs["Row Height"].default_value = 0.125
    b.inputs["Mortar Size"].default_value = 0.012
    b.inputs["Color1"].default_value = rgba(m)
    b.inputs["Color2"].default_value = rgba(l)
    b.inputs["Mortar"].default_value = rgba(d)
    det = noise(g, 30, 6, 0.6, offset=SEED)
    col = g.mix_color(g.math("MULTIPLY", det, 0.3), b.outputs["Color"], rgba(d), "MULTIPLY")
    height = g.math("SUBTRACT", g.math("MULTIPLY", det, 0.3), g.math("MULTIPLY", b.outputs["Fac"], 1.0))
    return col, height, g.mix_float(b.outputs["Fac"], 0.85, 1.0), 0.0


PRESETS = {
    "stone": p_stone, "cobble": p_cobble, "plaster": p_plaster, "ground": p_ground,
    "wood": p_wood, "bark": p_bark, "rust_metal": p_rust_metal, "brick": p_brick,
}


# --------------------------------------------------------------------------- bake
def bake_job(job):
    name = job["name"]
    d, m, l = job["colors"]
    mat = bpy.data.materials.new("TEX_" + name)
    mat.use_nodes = True
    g = G(mat)
    col, height, rough, metal = PRESETS[job["preset"]](g, d, m, l)

    bump = g.n("ShaderNodeBump")
    bump.inputs["Strength"].default_value = job.get("bump", 1.0)
    bump.inputs["Distance"].default_value = job.get("bump_distance", 0.12)
    g.link(height, bump.inputs["Height"])
    bsdf = g.n("ShaderNodeBsdfPrincipled")
    g.link(col, bsdf.inputs["Base Color"])
    g.link(rough, bsdf.inputs["Roughness"])
    g.link(bump.outputs["Normal"], bsdf.inputs["Normal"])
    emit = g.n("ShaderNodeEmission")
    out = g.n("ShaderNodeOutputMaterial")
    g.link(bsdf.outputs[0], out.inputs["Surface"])

    bpy.ops.mesh.primitive_plane_add(size=2)
    plane = bpy.context.object
    plane.data.materials.append(mat)

    img_node = g.n("ShaderNodeTexImage")
    g.nt.nodes.active = img_node
    os.makedirs(OUT_DIR, exist_ok=True)

    def new_img(suffix, colorspace):
        img = bpy.data.images.new(f"{name}_{suffix}", RES, RES, alpha=False, float_buffer=False)
        img.colorspace_settings.name = colorspace
        img_node.image = img
        return img

    def save(img, suffix):
        path = os.path.join(OUT_DIR, f"{name}_{suffix}.png")
        img.filepath_raw = path
        img.file_format = "PNG"
        img.save()
        return path

    scene = bpy.context.scene
    files = {}

    # colour + roughness via emission (exact values, no lighting)
    for suffix, sock, cs in (("color", col, "sRGB"), ("roughness", rough, "Non-Color")):
        img = new_img(suffix, cs)
        g.link(sock, emit.inputs["Color"])
        g.link(emit.outputs[0], out.inputs["Surface"])
        scene.cycles.samples = 1
        bpy.ops.object.bake(type="EMIT", margin=0)
        files[suffix] = save(img, suffix)

    # normal (tangent, OpenGL Y+)
    g.link(bsdf.outputs[0], out.inputs["Surface"])
    img = new_img("normal", "Non-Color")
    scene.cycles.samples = 4
    scene.render.bake.normal_space = "TANGENT"
    scene.render.bake.normal_g = "POS_Y"
    bpy.ops.object.bake(type="NORMAL", margin=0)
    files["normal"] = save(img, "normal")

    # metalness
    img = new_img("metalness", "Non-Color")
    if metal == "rust":
        # metal where not rusty == inverse of roughness-ish mask
        inv = g.math("SUBTRACT", 1.0, g.math("MULTIPLY", g.math("SUBTRACT", rough, 0.35), 1.7, clamp=True))
        g.link(inv, emit.inputs["Color"])
    else:
        emit.inputs["Color"].default_value = (metal, metal, metal, 1)
        for lk in list(emit.inputs["Color"].links):
            g.nt.links.remove(lk)
    g.link(emit.outputs[0], out.inputs["Surface"])
    scene.cycles.samples = 1
    bpy.ops.object.bake(type="EMIT", margin=0)
    files["metalness"] = save(img, "metalness")

    bpy.data.objects.remove(plane, do_unlink=True)
    return files


def main():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    results = {}
    for job in JOBS:
        results[job["name"]] = bake_job(job)
        print("baked", job["name"])
    print("TEXTURES:", results)
    return results


main()
