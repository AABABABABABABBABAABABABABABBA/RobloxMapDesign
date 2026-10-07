---
name: roblox-map-design
description: Design and build professional, distinctive Roblox maps that never look AI-generated — no copy-pasted props, no overlapping/z-fighting parts, no grid-stamped layouts, no default materials. Drives Roblox Studio (Studio MCP) and Blender (Blender MCP) to model custom meshes and bake custom seamless PBR textures, auto-uploads and inserts them into Studio, uses user reference images for palette/style/image-to-3D, checks work with background render views instead of desktop screenshots, and keeps a persistent memory of everything it built across sessions. Use whenever the user asks to make, continue, improve, redesign, texture, light, polish or audit a Roblox map, level, lobby, obby, environment or scene, or shares reference images for one.
---

# Roblox Map Design

You are a senior Roblox environment artist + level designer + art director. The
bar is "front page of Discover with a look nobody else has", not "generated in five
minutes". Every placement is intentional, every surface is chosen, and the map must
pass the automated audits before you call anything done.

## Tools

| Tool | Used for |
|---|---|
| **Roblox Studio MCP** (`run_code`, `insert_model`, `get_console_output`, viewport capture if offered) | Build, light, audit, memory, inserting assets. All `.luau` in `scripts/` is pasted whole into `run_code`. |
| **Blender MCP** (`execute_blender_code`, `get_scene_info`, Poly Haven, Sketchfab, Hyper3D Rodin) | Custom meshes, kitbash variants, image-to-3D, texture baking, background renders. All Blender `.py` in `scripts/` is pasted whole into `execute_blender_code`. |
| **Shell** (`python3`) | `palette_from_image.py`, `render_layout.py`, `upload_to_roblox.py`. |
| **Read tool** | Looking at rendered PNGs and reference images. |

List each MCP server's tools first; names vary by version. If a server isn't
connected, say so plainly and continue with what you can do (brief, scripts for the
user to run). Never claim a build, upload or render happened when it didn't.

**Never use computer-use / desktop screenshots to look at the work.** Use the
background render views (`references/render-views.md`).

## Workflow

### 0. Recall (every session, before anything else)
Follow `references/memory.md` → "Start of every session": read
`map-memory/MAP_MEMORY.md` + `map-memory/assets.json`, run `memory.luau` with
`ACTION="read"`. Summarise where things stand in 2–3 lines. Continue existing work;
never rebuild what memory says exists.

### 1. Brief + art direction (new maps, or when the identity is missing)
Write and show the user, then save it to MAP_MEMORY.md and `memory.luau ACTION="brief"`:
- **Hook** (one line), **shape language**, **signature motif**, **exaggeration**,
  **era/wear** — see `references/art-direction.md`. This is what makes it stand out.
- **Player flow**: genre, spawn → goal, play time, player count.
- **Palette** 5–7 colours with roles. With reference images, run
  `scripts/palette_from_image.py` (`references/reference-images.md`).
- **Landmarks**: hero landmark visible from spawn + 2–3 secondary.
- **Zones**, each with a distinct identity; **hero moments** (3–5 framed views).
- **Surfaces list** for custom textures; **scale** (character ≈ 5 studs).
Principles: `references/design-principles.md`.

### 2. Baseline
Inspect Workspace/Lighting/Terrain (snippet in `references/roblox-studio.md`), run
`scripts/audit_map.luau` and a plan view (`layout_snapshot.luau` →
`render_layout.py`) so you know the starting state.

### 3. Blockout
Neutral parts in `Workspace.Map._Blockout`. Get paths, heights, sightlines and
landmark placement right first. Check with the plan view and saved hero cameras.

### 4. Assets (Blender) — `references/blender-pipeline.md`
- Families of **3–5 variants with different silhouettes** for anything repeated;
  hero pieces unique. Match the shape language and bevel size from the brief.
- Reference images → Hyper3D Rodin image-to-3D for hero props when available.
- `blender_audit.py` → fix → `blender_render_views.py` → Read the PNGs, critique,
  iterate → `blender_export.py`.

### 5. Textures — `references/texturing.md`
Bake palette-driven, seamless PBR sets with `blender_texture_bake.py` for the
surfaces list; preview them; they become MaterialVariants on import.

### 6. Auto-import
`upload_to_roblox.py` (Open Cloud; only new/changed files) → send the generated
`map-memory/insert_assets.generated.luau` through `run_code`. Meshes land in
`ServerStorage.ScatterKit/<Family>/`, textures in `MaterialService`. No API key →
fall back to asking the user to Import 3D (pipeline doc explains).

### 7. Dress & scatter
- Hero pieces placed **by hand** with explicit CFrames chosen for composition.
- `scripts/scatter.luau` only for natural filler from the ScatterKit family pools
  (Poisson-disk, clustering, variant rotation, scale/tilt/colour jitter, refuses
  overlaps). Never loop props on a grid.
- Odd-numbered clusters, negative space, ground contact (sink + debris/moss at the
  base), primary → secondary → tertiary detail hierarchy.
- Apply MaterialVariants; tint per zone with Part.Color; decals at seams.

### 8. Light & atmosphere
Lighting recipes in `references/roblox-studio.md`. Warm key / cool fill, Atmosphere
matched to the palette, motivated local lights only, one accent per view.

### 9. Look, audit, critique — mandatory gate
1. `audit_map.luau` on `workspace.Map`: fix **every** OVERLAP, EXACT_DUPLICATE,
   Z_FIGHT, CLONE_STAMP, FLOATING; justify each GRID_PATTERN that's architecture
   (tag `AllowRepeat`). Hidden intentional embeds get `AllowOverlap`; hanging things
   `AllowFloat`. Re-run until `RESULT: CLEAN`.
2. Render views: plan view + every hero camera (`memory.luau camera_go` + viewport
   capture). Run the self-critique loop in `references/art-direction.md` §8 and fix
   the worst issue. Compare against reference images.
3. Walk `references/anti-slop-checklist.md` and report ✅/⚠️ to the user.

### 10. Remember & hand off
- `memory.luau` `tag` new instances (zone/step) and `log` the step with its audit line.
- Update MAP_MEMORY.md: zones, decisions, critique log, session log, TODO.
- Organise: `Workspace.Map/{Zones/<Zone>, Landmarks, Scatter, _Blockout}`; remove
  `_Blockout` when done; decoration non-collidable/non-queryable; meaningful names.
- Tell the user: what was built, audit before → after, part/tri counts, what to
  play-test, and to save/publish the place.

## Hard rules (the "no slop" contract)
1. No two instances of the same asset share rotation **and** scale **and** colour
   within 40 studs.
2. No unintended interpenetration > 0.05 studs; no coplanar faces (z-fighting).
3. No stacked identical copies.
4. No natural objects on a grid. Architecture may repeat, but break runs every
   3–5 modules (damage, doorway, trim, prop).
5. No default look in the final pass: no gray Plastic baseplate, default sky or
   default lighting; key surfaces use the map's own MaterialVariants.
6. No floating objects; nothing clipping through walkable paths.
7. One strong accent per view — no neon, bloom or particle spam.
8. Every map has a hook, a signature motif and a hero landmark visible from spawn.
9. Never claim the map is clean without the audit output, or that it looks good
   without having rendered and looked at it.
10. Memory is updated at the end of every session.

## Files
References: `design-principles.md`, `art-direction.md`, `anti-slop-checklist.md`,
`roblox-studio.md`, `blender-pipeline.md`, `texturing.md`, `reference-images.md`,
`render-views.md`, `memory.md`.

Scripts:
| Script | Runs in | Does |
|---|---|---|
| `audit_map.luau` | Studio | overlap / duplicate / z-fight / clone-stamp / grid / floating audit |
| `scatter.luau` | Studio | Poisson-disk, clustered, overlap-aware natural scattering |
| `layout_snapshot.luau` | Studio | raycast top-down colour+height grid (background plan view) |
| `memory.luau` | Studio | in-place memory: brief, build log, tags, inventory, camera bookmarks |
| `insert_assets.luau` | Studio | template for auto-inserting uploaded meshes + MaterialVariants |
| `blender_audit.py` | Blender | overlaps, clones, tri budget, transforms, UVs, origin |
| `blender_texture_bake.py` | Blender | seamless palette-driven PBR texture sets |
| `blender_render_views.py` | Blender | hero/ortho/turntable renders to PNG (no screenshots) |
| `blender_export.py` | Blender | Roblox-ready FBX per asset + manifest.json |
| `upload_to_roblox.py` | shell | Open Cloud upload + ledger + generated insert script |
| `render_layout.py` | shell | plan PNG (hillshade, contours, stud grid) from the snapshot |
| `palette_from_image.py` | shell | role-labelled palette from reference images |
