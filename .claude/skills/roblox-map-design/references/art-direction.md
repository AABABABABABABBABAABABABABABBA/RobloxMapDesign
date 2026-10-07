# Art Direction — make it look designed, and make it stand out

"Not AI slop" is the floor. The goal is a map players screenshot. That comes from
a **point of view**: a few strong, specific choices applied everywhere, instead of
many generic ones applied evenly.

## 1. Pick an identity before building
Write these down in the brief (and save them to memory):
- **One-line hook**: "A fishing village built inside the ribcage of a sea giant."
  Generic: "a beach town". The hook decides the hero landmark and the props.
- **Shape language** (choose one dominant):
  - round/soft = friendly, cosy, simulators, kids
  - square/blocky = stable, civic, industrial
  - triangular/spiky = danger, fantasy, villains
  Apply it to rooflines, rocks, foliage, UI-facing signage, even the lamp posts.
- **Signature motif**: one recurring element unique to this map — a colour stripe on
  every roof, lanterns of one specific shape, a carved emblem, a material combo
  (teal copper + cream plaster). Repeat the motif, not the props.
- **Exaggeration**: push one property 20–40% past realistic (taller chimneys, bigger
  mushrooms, thicker outlines/trims, chunkier bevels). Stylisation reads as intent.
- **Era & wear level**: brand new / lived-in / abandoned. Stay consistent.

## 2. Value structure beats colour
Squint test: in a greyscale render the path and the landmark must still read.
- Big shapes in 3 value groups: dark (≈20%), mid (≈60%), light (≈20%).
- Put the highest value contrast where you want the eye: landmark silhouette
  against sky, goal against background.
- Check with a greyscale version of the render view (`render_layout.py` plan, or a
  Blender render with saturation 0) — fix value before colour.

## 3. Colour script
- Shared base palette across the map; each zone shifts temperature/hue (warm
  market → cool harbour → toxic-green caves).
- Complementary accent for interactables only.
- Lighting colour is part of the palette: warm key + cool fill (or the inverse for
  night) is the cheapest way to look "rendered".

## 4. Hero moments (plan 3–5 per map)
A hero moment is a framed view: frame (foreground arch/trees) → leading lines →
landmark with rim light → sky gradient. Design each one deliberately, save its
camera with `memory.luau` (`camera_save`), and render-check it every pass.
Examples: the spawn reveal, the first cliff-top overlook, the boss arena entrance,
the shop interior with god rays.

## 5. Detail hierarchy
- **Primary** (seen from 200 studs): silhouettes, landmarks, terrain masses.
- **Secondary** (50 studs): buildings' trims, roofs, big props, foliage clumps.
- **Tertiary** (10 studs): decals, small props, textures, cracks, grass.
Spend the most care on primary, and only add tertiary detail where players linger.
Slop maps invert this: tons of tertiary noise on a bland primary layout.

## 6. Custom > stock
Every reused free model / default material lowers distinctiveness. Prefer:
custom meshes from Blender with the map's bevel size and shape language; custom
MaterialVariants baked from the palette (`blender_texture_bake.py`); custom decals.
Toolbox/Creator Store models only as blockout stand-ins, replaced before shipping.

## 7. Finishing passes that separate pro from amateur
- Edge treatment: bevels, trims, kick plates, caps on wall tops, rims on roofs.
- Contact: moss/dirt/rubble where objects meet the ground; foundations under houses.
- Gradients: darker at the bottom of walls and cliffs (grime), lighter at the top.
- Lights with sources; light pools on the ground under lamps; windows that glow at night.
- Sky + fog colour matched to the palette; distant layers fade into atmosphere.
- Motion: a little life (flags, water, birds, drifting particles) — subtle and sparse.
- Sound is out of scope here but note ambient sound zones in the brief for the dev.

## 8. Self-critique loop (each pass)
Render the hero cameras + plan view, then answer in writing:
1. What is the first thing the eye lands on? Is it the intended thing?
2. Does the greyscale read?
3. Name the signature motif — is it visible in this shot?
4. What looks default or generic? Replace the worst one.
5. What repeats visibly? Break it.
Record the answers and fixes in memory (`MAP_MEMORY.md` → Critique log).
