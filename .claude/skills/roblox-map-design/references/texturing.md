# Professional Texturing

Default Roblox materials are recognisable at a glance; custom, palette-matched
textures are one of the biggest jumps in perceived quality.

## Tools
- `scripts/blender_texture_bake.py` — procedural, **seamless** PBR sets baked in
  Blender (color / normal / roughness / metalness), driven by the map palette.
  Presets: `stone, cobble, plaster, ground, wood, bark, rust_metal, brick`.
- Poly Haven (via Blender MCP) — CC0 scanned textures when realism is wanted.
  Recolour toward the palette in Blender before baking/exporting.
- `scripts/upload_to_roblox.py --textures` + `insert_assets.luau` — upload and turn
  each set into a `MaterialVariant` automatically.

## Workflow
1. From the brief, list the 4–8 surfaces the map actually needs (e.g. cliff stone,
   path cobble, dock wood, plaster walls, roof tiles, ground). Fewer, better.
2. For each, pick 3 palette colours (dark, mid, light) — take them from
   `palette_from_image.py`, shifted for the zone.
3. Edit `JOBS` in `blender_texture_bake.py`, run it via `execute_blender_code`.
   Use `RES = 1024` for finals (512 is fine for previews: env var `TEX_RES`).
4. **Look at them**: render a 2×2 tiled preview (see render-views.md) and check:
   - seams (there should be none — noise is sampled on a 4D torus),
   - visible repetition (one big blotch repeating = reduce low-frequency contrast),
   - value contrast (textures should be quieter than silhouettes; keep the
     albedo range narrow, ±15% value),
   - normal strength (subtle; Roblox lighting exaggerates normals at grazing angles).
5. Upload + insert (blender-pipeline.md → Auto-import).
6. Apply: `part.Material = Enum.Material.<Base>; part.MaterialVariant = "<Name>"`.
   Set `StudsPerTile` so features are the right real size (cobbles ≈ 1–1.5 studs →
   StudsPerTile ≈ 8–10 for the cobble preset).
7. Break tiling at large scale: vary part colours slightly (MaterialVariant colour
   multiplies with `Part.Color`), add decals (cracks, puddles, moss) and props at
   seams, rotate adjacent parts 90°/180°.

## Rules
- Albedo has **no baked lighting** (no strong AO/shadows) — Roblox lights it.
- Normal maps are OpenGL (Y+), which the baker outputs.
- Max 1024×1024 per map. Re-use variants across zones; tint per zone with Part.Color.
- Metals: metalness 1 only for bare metal; painted metal = 0.
- Keep a consistent texel density: similar StudsPerTile for similar surface scale.
- Hero meshes: use `SurfaceAppearance` with a baked, unique texture for the hero
  landmark only — everything else shares tiling MaterialVariants.
- Record every texture (name, base material, studs/tile, where used) in memory.
