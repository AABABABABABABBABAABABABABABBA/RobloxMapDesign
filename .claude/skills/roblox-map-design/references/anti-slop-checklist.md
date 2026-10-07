# Anti-Slop Checklist

Run this after `audit_map.luau` comes back clean. Report each item to the user as
✅ / ⚠️ (with what you did about it). Don't mark ✅ without checking.

## Automated (from `audit_map.luau`)
- [ ] 0 `OVERLAP` (unintended interpenetration)
- [ ] 0 `EXACT_DUPLICATE` (stacked identical copies)
- [ ] 0 `Z_FIGHT` (coplanar overlapping faces)
- [ ] 0 `CLONE_STAMP` (same asset, same rotation+scale+colour, nearby)
- [ ] `GRID_PATTERN` only on intentional architecture, each justified
- [ ] 0 `FLOATING` objects
- [ ] `AllowOverlap` tag used < ~5% of parts, only where the overlap is hidden

## Visual tells of generated maps — look for each
- [ ] **Uniform spacing**: trees/lamps/rocks at equal intervals → re-scatter.
- [ ] **Same yaw**: props all facing the same direction → rotate meaningfully.
- [ ] **Same size**: a whole forest of identical-height trees → vary 0.75–1.3×.
- [ ] **Floating / hovering**: gaps under props → ground them, sink slightly.
- [ ] **Clipping**: props through walls, paths, each other → move or tag if hidden.
- [ ] **Default look**: gray Plastic, default Baseplate, default sky, default lighting.
- [ ] **Symmetry everywhere**: perfect mirror layouts outside formal architecture.
- [ ] **Flat terrain**: one ground height across the whole map.
- [ ] **Even detail density**: no calm areas, no focal points.
- [ ] **Neon/particle spam**: more than one strong accent per view.
- [ ] **Inconsistent scale**: doors a character can't fit through; giant chairs.
- [ ] **Floating text/signs with no supports**; lights with no fixture.
- [ ] **Unmotivated lights**: PointLights not attached to a lamp, window, fire, etc.
- [ ] **Seams**: visible gaps between modular wall pieces or terrain edges.
- [ ] **Unnamed hierarchy**: hundreds of `Part`/`Model` at the root.

## Design quality
- [ ] Hero landmark visible from spawn.
- [ ] Clear critical path; player never wonders where to go.
- [ ] At least one reveal moment and one optional side area.
- [ ] Height variation in every zone.
- [ ] Each zone recognisable from a screenshot alone.
- [ ] Palette adhered to; accents used only on important things.
- [ ] Every zone has at least one story vignette.
- [ ] Skyline broken up from spawn and from the highest point.

## Technical
- [ ] All static parts anchored.
- [ ] Decoration: `CanCollide/CanTouch/CanQuery = false`.
- [ ] Small props: `CastShadow = false`.
- [ ] Mesh collision fidelity: `Box` or `Hull` for decor, `PreciseConvexDecomposition`
      only where players actually collide with complex shapes.
- [ ] No mesh > 20k tris; repeated meshes far lower.
- [ ] `_Blockout` removed or hidden.
- [ ] Play-tested: walk the critical path with a character, check jumps and doorways.
