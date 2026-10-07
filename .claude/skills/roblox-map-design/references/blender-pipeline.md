# Blender MCP → Roblox Pipeline

Uses the Blender MCP (github.com/ahujasid/blender-mcp). Typical tools:
`get_scene_info`, `get_object_info`, `get_viewport_screenshot`,
`execute_blender_code`, Poly Haven (`search_polyhaven_assets`,
`download_polyhaven_asset`, `set_texture`), Sketchfab (`search_sketchfab_models`,
`download_sketchfab_model`), Hyper3D Rodin (`generate_hyper3d_model_via_text`,
`generate_hyper3d_model_via_images`, `poll_rodin_job_status`,
`import_generated_asset`). Check the `get_*_status` tools — Poly Haven, Sketchfab
and Hyper3D must be enabled in the Blender add-on panel.

## When to use Blender vs Studio parts
| Use Blender | Use Studio parts/Terrain |
|---|---|
| Rocks, cliffs, trees, foliage cards | Blockout |
| Organic or bevelled shapes, ruins, arches | Simple architecture with clean edges |
| Hero landmarks | Ground and water (Terrain) |
| Modular kits with trims and wear | Anything gameplay needs to tweak often |
| Anything that would take > ~30 parts | |

## Workflow
1. **Set up the scene for Roblox scale** (once per file):
   ```python
   import bpy
   s = bpy.context.scene
   s.unit_settings.system = 'METRIC'
   s.unit_settings.scale_length = 1.0   # 1 Blender unit == 1 stud (import with Scale Unit = Stud)
   # Reference dummy: a 2x1x5 box = R15 character size, never exported
   bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 2.5))
   ref = bpy.context.object; ref.name = "_REF_Character"; ref.scale = (2, 1, 5)
   ref.hide_render = True
   ```
2. **Model in families.** For each repeated prop make 3–5 variants with distinct
   silhouettes (different proportions, broken edges, lean), named
   `Rock_A`, `Rock_B`, … Shared material, different shapes. Approaches:
   - Procedural base + modifiers (Displace with a noise texture, Decimate, Bevel),
     then apply. Change the noise seed/scale per variant.
   - Kitbash: combine pieces, then join and remesh.
   - Image-to-3D: `generate_hyper3d_model_via_images` with the user's reference
     image(s) → `import_generated_asset` → clean up (decimate, fix origin, scale).
   - Sourcing: Poly Haven models/textures (CC0) or Sketchfab (check licence; only
     use downloadable models whose licence allows it and tell the user the licence).
3. **Bevel** hard edges (Bevel modifier, 1–2 segments, 0.05–0.15 BU) on hero pieces.
4. **Textures**: bake palette-driven seamless PBR sets with
   `scripts/blender_texture_bake.py` (see texturing.md), or Poly Haven PBR at 1k.
   Roblox texture max is 1024×1024.
5. **Audit** with `scripts/blender_audit.py` through `execute_blender_code`
   (paste the file contents). Fix everything flagged.
6. **Look at it** with `scripts/blender_render_views.py` (background renders to PNG,
   then Read them — see render-views.md). Critique silhouette, variation and bevels
   before exporting; show the user the turntable.
7. **Export** with `scripts/blender_export.py` → one FBX per asset + `manifest.json`.
8. **Auto-import** into Studio (below).

## Export rules (blender_export.py does these for you)
- Rotation & scale applied, origin moved to the **base centre**, exported at the
  world origin, 1 Blender unit = 1 stud, FBX `-Z` forward / `Y` up.
- Triangle budget: hard limit 20,000 tris per MeshPart; aim for ≤ 2k for scatter
  props, ≤ 8k for hero props. Decimate (collapse) and re-audit.
- Max size 2048 studs on any axis. UVs required for textured meshes.
- Helper objects named `_…` are never exported.
- Family = custom property `family` or the name minus its last `_X` suffix, so
  `Rock_A`, `Rock_B`, `Rock_C` become the variant pool `ScatterKit/Rock`.
- The .blend should be saved so `//export/` resolves; otherwise set env
  `EXPORT_DIR` or edit the constant.

## Auto-import into Studio
Studio MCP can't drive the 3D Importer UI, so the skill imports through Roblox
Open Cloud instead — no clicking:

1. One-time setup by the user (never paste keys into chat):
   - Create an Open Cloud API key at create.roblox.com → Credentials, with the
     **Assets API** permission (`asset:read`, `asset:write`) for their account
     or group, and an IP allowlist that includes this machine (or `0.0.0.0/0`).
   - Set `ROBLOX_API_KEY` and `ROBLOX_CREATOR_ID` (user id, or group id + `--group`)
     as environment variables where Claude Code runs.
2. Upload (uploads only new/changed files — tracked by sha1 in the ledger):
   ```bash
   python3 $SKILL_DIR/scripts/upload_to_roblox.py \
       --manifest <EXPORT_DIR>/manifest.json \
       --textures <TEX_OUT> --material Cliff_Stone=Slate:10 --material Dock_Wood=WoodPlanks:6 \
       --ledger map-memory/assets.json
   ```
3. Insert: send the generated `map-memory/insert_assets.generated.luau` through the
   Studio MCP `run_code` tool. Models land in `ServerStorage.ScatterKit/<Family>/`
   (auto-rescaled to the Blender size, pivot at base, anchored) and textures become
   `MaterialVariant`s in MaterialService.
4. Place them (by hand for hero pieces, `scatter.luau` for the family pools) and
   run `audit_map.luau`.

If the user has no API key, fall back to: ask them to run *Import 3D* on the FBX
files from `EXPORT_DIR` (multi-select works) into `ServerStorage.ScatterKit/<Family>`
and tell you when done. Uploaded assets may sit in moderation briefly; if
`LoadAsset` fails, wait a minute and re-run the insert (it skips what's done).

## Making variation survive into Roblox
Even with variants, final placement adds variation: random yaw, 0.8–1.25 scale,
slight tilt for rocks, colour jitter if the material allows `Color`. `scatter.luau`
does this automatically. For hand placement, never copy-paste a prop without
rotating and rescaling it.
