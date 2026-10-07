# Design Principles for Roblox Maps

What separates a professional map from a generated one is **intent**: every object
answers "why is this here?" Use these principles to make those decisions.

## 1. Player flow
- Draw the critical path first (spawn → objective). Everything else supports or
  frames it.
- **Weenies / landmarks**: a tall, distinctive silhouette the player can see from
  spawn pulls them forward. Put the hero landmark at the end of a sightline, slightly
  off-centre.
- **Breadcrumbs**: lights, colour accents, and lines (fences, rails, rivers, cables)
  lead the eye toward the next goal.
- **Funnel → open → funnel**: alternate tight spaces and reveals. A reveal after a
  narrow passage is the cheapest "wow" moment available.
- Give players choice: at least one optional side path or loop per zone, with a
  small reward (view point, secret, collectible).
- Avoid dead flat. Vary floor height by 2–6 studs between areas; use stairs, ramps,
  terraces.

## 2. Composition
- **Big / medium / small**: every view should contain one large form, a few medium
  forms and many small details. Slop maps are usually all-medium.
- **Odd-numbered clusters** (1, 3, 5) of mixed sizes read as natural; pairs and
  rows read as placed.
- **Negative space**: leave calm areas so detail has contrast. Not every square
  stud needs a prop.
- **Silhouette**: check the skyline. Break flat roof lines and horizons with towers,
  trees, chimneys, cliffs at varied heights.
- **Rule of thirds** for landmark placement in the spawn view.
- **Layering**: foreground framing (arch, tree, rock), midground action, background
  skyline. Use Atmosphere so the background reads lighter and bluer.

## 3. Scale (Roblox R15 ≈ 5 studs tall)
| Element | Size |
|---|---|
| Door | 4–5 wide × 7–8 tall |
| Interior ceiling | 12–16 |
| Corridor | 8–12 wide |
| Main path | 10–16 wide |
| Stair step | 1 rise × 1.5–2 run |
| Railing | 3–3.5 tall |
| Window sill | ~3 |
| Jump gap (obby, no run) | ≤ 10 horizontal, ≤ 7 up |

Roblox maps are usually built ~1.2–1.5× real scale so the third-person camera fits.
Be consistent — inconsistent scale is a top tell of generated maps.

## 4. Colour
- Pick 5–7 colours: dominant (60%), secondary (30%), accent (10%), plus a shadow and
  highlight tone. Accents go on things you want players to notice (interactables,
  path markers, goals).
- Desaturate large surfaces; save saturation for small accents.
- Each zone gets a colour identity, shifting the shared palette rather than
  replacing it.
- **Never** use pure white (255,255,255) or pure black on big surfaces; use
  near-values (e.g. 235,230,220 / 30,28,35).
- Variation: same asset in a cluster should vary ±3–8% in value/hue, not identical.

## 5. Materials & surface detail
- Use Roblox materials (and MaterialVariants) deliberately; one material for a large
  area plus a contrasting trim reads better than many random materials.
- Break up big flat surfaces with: trims along edges, a change of material at the
  base (grime/moss line), decals, small props at wall/floor seams.
- Bevel or chamfer hero geometry (in Blender) — perfectly sharp boxes read "default".
- Wear tells a story: worn paths, rust near water, moss on north faces, cracks near
  impacts. Put wear where it makes sense, not uniformly.

## 6. Storytelling
Every zone should imply something happened there: an abandoned cart, a half-built
wall, a campfire with seats. 1–2 story vignettes per zone is plenty.

## 7. Repetition done right
Architecture can be modular, but:
- Use 3+ variants per module and rotate between them non-sequentially.
- Every 3–5 repeats, break the rhythm: damaged piece, doorway, pillar, vine, sign.
- Natural objects never repeat on a grid. Use `scatter.luau`.

## 8. Performance as design
- Prefer fewer, better meshes over thousands of parts.
- Use `StreamingEnabled` for large maps; keep hero landmarks as
  `ModelStreamingMode = Persistent` so the skyline never pops.
- Keep decoration non-collidable and non-queryable.
- Target: < 20k instances for a mid-size map; triangle budget per mesh ≤ 20k (lower
  for anything repeated).
