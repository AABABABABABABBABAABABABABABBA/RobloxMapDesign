# Repair — fixing broken designs and camera glitches

Use this when the user says the map is broken, glitchy, flickering, "blocks glitch
when I move the camera", the camera jerks, things pop in, props float or clip, or
when you take over a map someone else built.

## Repair loop
1. **Recall** memory (memory.md) so you know which parts are yours and which are
   the user's.
2. **Diagnose**: `audit_map.luau`, then `fix_map.luau` with `APPLY = false`. Read
   the plan. Show the user a short summary: counts per category + the `[ask]` items.
3. **Protect intent**: tag things that are meant to be that way before applying —
   `AllowOverlap` (hidden embeds), `AllowFloat` (hanging/flying), `AllowRepeat`
   (architectural rhythm), `NoAutoFix` (anything the user hand-tuned).
4. **Apply**: `fix_map.luau` with `APPLY = true`. It's one undo step (`fix_map`), and
   every fixed instance gets an `MD_Fixed` attribute.
5. **Repeat** audit + fix (dry run) until there are no `[fix]` items left (usually
   2–3 rounds; fixes can expose new contacts).
6. **Decide `[ask]` items** with the user or by judgement (MANUAL, TRANSPARENT_SORT,
   LOOSE_ASSEMBLY, FAR_FROM_ORIGIN, BELOW_KILL_PLANE), fix them by hand via
   `run_code`.
7. **Verify** with render views: plan view + hero cameras; play-test the path if the
   Studio MCP can start play mode (`start_stop_play`) and read console errors.
8. **Log** in memory: what was broken, counts before → after.

## Glitch → cause → fix
| What the player sees | Cause | fix_map category |
|---|---|---|
| Surfaces flicker / stripe when the camera moves | Two faces in the same plane (z-fighting) | `Z_FIGHT` (offsets the smaller part 0.02 studs) |
| Sparkling white/black lines along joints | Hair-line gaps between parts let the sky/background through | `SEAM` (closes gaps < 0.05) |
| Decals flicker on a wall | Several decals on one face with the same ZIndex | `DECAL_FIGHT` |
| Glass/water/ghost parts swap or vanish at some angles | Overlapping semi-transparent parts are depth-sorted per part | `TRANSPARENT_SORT` (report: make one opaque, separate them, or merge) |
| Big rocks/buildings change shape as you walk | Mesh LOD switching on large MeshParts | `LOD_POP` (RenderFidelity Precise, budgeted) |
| Tiny shadows crawl/shimmer | Shadow-map resolution vs tiny casters | `TINY_SHADOW` |
| Landmarks disappear and pop back | StreamingEnabled unloading them | `STREAM_POP` (Persistent + radius advice) |
| Everything jitters far from spawn | Floating-point precision > ~10k studs from origin | `FAR_FROM_ORIGIN` (report; move the map) |
| Camera zooms in / snaps when passing bushes, leaves, lamps | Roblox Poppercam treats any opaque CanCollide part as a wall | `CAMERA_SNAP` (decor → CanCollide false; camera sweep finds the culprits) |
| You can see through walls when backed against them | Walls thinner than the camera near-plane | `THIN_WALL` (thicken to 0.6) |
| Props sink into each other / walls | Overlapping placement | `OVERLAP` (remove scatter item or push small prop out) |
| Doubled, darker, or "thick" looking parts | Stacked identical copies | `EXACT_DUPLICATE` |
| Parts that do nothing but cost performance and z-fight | Parts buried inside other parts | `HIDDEN_INSIDE` |
| Props hovering | Not grounded | `FLOATING` (drops them onto the surface) |
| Map falls apart when you press Play | Unanchored static parts | `UNANCHORED`, `LOOSE_ASSEMBLY` |
| Things vanish at Play | Below FallenPartsDestroyHeight | `BELOW_KILL_PLANE` |
| "Looks copy-pasted" | Same prop, rotation, scale, colour | `CLONE_STAMP` (re-rotate, rescale, tint) |

## Camera sweep
`fix_map` simulates the default third-person camera: from points along
`Map._Waypoints` (parts named `01`, `02`, … along the critical path; create them if
missing) and every SpawnLocation, it casts 8 camera rays (14 studs back, slightly
up) and counts which opaque, collidable parts block them. Decor gets fixed
automatically; structural blockers come back as `[ask]` with a suggestion (widen the
path, raise the ceiling, move the object). Add waypoints through tight spaces —
that's where camera snapping is worst.

## Glitches that aren't geometry
- **Lighting flicker**: too many shadow-casting local lights overlapping → keep ≤ 6
  shadowed lights visible; set `Shadows = false` on fill lights.
- **Bloom pulsing**: Neon parts + high Bloom intensity → lower `BloomEffect.Intensity`
  or raise `Threshold`.
- **Texture shimmer/moire in the distance**: very high-frequency textures on large
  surfaces → increase `StudsPerTile`, use a calmer MaterialVariant.
- **Water edge flicker**: water parts coplanar with terrain water → remove one.
- **Script-driven glitches** (tweens fighting, parts teleporting): out of scope for
  geometry fixes; read the console via the Studio MCP and report the script.

## Rules
- Diagnose before applying, and never apply to a map without recalling memory first.
- Don't "fix" a user's intentional design: when unsure, tag `NoAutoFix` and ask.
- Report before → after counts; don't say "fixed" without a clean re-run.
