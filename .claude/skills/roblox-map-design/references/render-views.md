# Render Views — looking at the work without desktop screenshots

Never use computer-use / desktop screenshots to inspect the map: they need the
window in front, break when Studio or Blender is minimised, and capture whatever
else is on screen. Use these background renders instead and open the PNGs with
the Read tool.

| Need | Use | Works in background? |
|---|---|---|
| Asset check (silhouette, variants, bevels) | `blender_render_views.py` → hero / front / side / top / turntable PNGs | Yes — renders to file |
| Texture check | `blender_render_views.py` on a tiled plane, or tile the PNGs 2×2 with Pillow | Yes |
| Map layout / spacing / clumping / paths | `layout_snapshot.luau` → `render_layout.py` → plan PNG | Yes — raycasts, no camera |
| Composition of a hero shot in Studio | `memory.luau camera_go` + the Studio MCP's own viewport capture tool (if the server has one) | Studio renders its viewport itself; no desktop capture |
| Whole-map beauty shot | Rebuild the snapshot in Blender (optional) or Studio viewport capture | — |

## Blender renders
```
execute_blender_code(<contents of scripts/blender_render_views.py>)
```
- Set `TARGETS` to limit to the assets you're judging; `VIEWS` to choose shots.
- Output: `//renders/` next to the .blend (or `/tmp/roblox_renders/`). Printed paths
  like `RENDER hero: …/hero.png` — Read them.
- In the GUI Blender the MCP talks to it uses EEVEE (fast); in `blender -b` it
  uses Cycles CPU automatically.
- If the files are on another machine than Claude (remote Blender), use the MCP's
  `get_viewport_screenshot` instead — that's still Blender's own render of its
  viewport, not a desktop screenshot.

## Studio plan view
1. `run_code(<layout_snapshot.luau>)` (set `CELLS` 64–96, optional `REGION`).
2. Save the printed block (from `LAYOUT {` to `END_LAYOUT`) to
   `renders/snapshot.txt` (the Write tool is fine).
3. `python3 .claude/skills/roblox-map-design/scripts/render_layout.py renders/snapshot.txt -o renders/plan.png`
4. Read `renders/plan.png`.

What to look for: path continuity and width, landmark placement vs. spawn,
clumps vs. clearings, rows or grids of props, empty dead zones, contour
(height) variety per zone.

## Camera bookmarks
Save hero cameras once (`memory.luau`, `ACTION="camera_save"`, `CAMERA="Spawn_Hero"`),
then every pass: `camera_go` → viewport capture tool → compare against the previous
pass and against the reference images. Bookmarks are stored in the place
(ServerStorage.MapDesignMemory.Cameras), so they survive between sessions.

## Critique checklist per render
First read of the eye, greyscale read, signature motif visible, visible repetition,
floating/clipping, default-looking surfaces. Write findings into MAP_MEMORY.md.
