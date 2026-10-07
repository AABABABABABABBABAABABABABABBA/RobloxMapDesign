# Using Reference Images

Users can attach images in chat or drop them in the repo's `reference-images/`
folder. Treat them as the source of truth for style — the map should look like it
belongs in the same world as the references.

## 1. Read the images (before the brief)
For each image, write down:
- **Mood & time of day**: light direction, warm/cool, contrast, fog.
- **Palette**: run the extractor (below), then name each colour's role.
- **Shapes & silhouettes**: chunky vs. thin, rounded vs. angular, tall vs. wide.
- **Materials**: what surfaces exist and how worn they are.
- **Detail density**: where detail clusters and where it's calm.
- **Layout ideas**: paths, landmarks, framing, level changes.
- **Signature props**: 3–6 objects that make this place recognisable.

If several images disagree, ask the user which one wins for style vs. layout.

## 2. Palette extraction
```bash
python3 .claude/skills/roblox-map-design/scripts/palette_from_image.py reference-images/*.png --colors 7
```
Outputs hex, `Color3.fromRGB(...)` and a suggested role per colour (dominant,
secondary, accent, shadow, highlight), plus a Luau `PALETTE` table you can paste
into build scripts. Needs Pillow (`pip install pillow`). For images attached in
chat that aren't on disk, estimate the palette by eye and say so.

## 3. Turning references into the map
| Reference shows | Do this |
|---|---|
| A specific prop/building | Blender: `generate_hyper3d_model_via_images` with the image (Hyper3D Rodin image-to-3D), clean up, make 2–3 variants, export. Or model it by hand matching the silhouette. |
| A texture or surface | Blender: find a matching Poly Haven texture, or crop the reference into a tileable texture and bake; in Studio build a `MaterialVariant`. |
| A sign, poster, logo the user owns | Upload as a Decal (see roblox-studio.md → Uploading) and place it. |
| A layout / top-down sketch | Trace it into the blockout: estimate scale from doors/people, build `_Blockout` parts matching the plan. |
| A mood / lighting shot | Match ClockTime/sun direction, Atmosphere colour & density, ColorCorrection tint. Compare a Studio screenshot side by side. |

## 4. Check against the references
After lighting and dressing, take a screenshot from a comparable camera angle and
compare: palette, contrast, density, silhouette. List the differences and fix the
biggest one. Repeat once or twice.

## Rights
Only upload or recreate images the user has the rights to use. For third-party
art (other games, films, artists), use it for mood/palette/shape language and
build original assets — don't trace or upload it directly. Say so briefly if the
user asks to upload something that looks like someone else's IP.
