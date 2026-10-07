# Roblox Map Design — Claude Code skill

A Claude Code skill (`.claude/skills/roblox-map-design/`) that turns Claude into a
Roblox environment artist and level designer. It builds maps that don't look
AI-generated, and keeps working on them across sessions.

- **No slop**: an audit script catches overlapping parts, stacked duplicates,
  z-fighting, copy-pasted props (same rotation, scale and colour), grid-stamped
  placement and floating objects. The skill doesn't call the map done until the
  audit comes back clean.
- **Art direction**: each map gets a hook, a shape language, a signature motif,
  hero landmarks, framed hero shots and a palette, so it has its own look.
- **Blender**: custom mesh families through the Blender MCP, image-to-3D from your
  reference images, and pre-export audits.
- **Custom textures**: seamless PBR sets (color, normal, roughness, metalness) baked
  in Blender from the map palette. They become MaterialVariants in Studio.
- **Auto-import**: exports go to Roblox through Open Cloud and are inserted into
  Studio automatically. Unchanged files are never uploaded twice.
- **Render views**: the skill checks its work with background renders (Blender
  renders and a raycast plan view of the Studio map), not desktop screenshots.
- **Memory**: `map-memory/` in the repo, plus a log, instance tags and camera
  bookmarks saved inside the place file.
- **Repair**: `fix_map.luau` finds and fixes broken maps and camera glitches.
  It handles flickering surfaces (z-fighting), sparkling seams, the camera snapping
  in on bushes or leaves, walls you can see through, LOD and streaming pop-in,
  clipping or floating props, and parts that fall when you press Play. It runs as
  a dry run first, then applies everything as one undo step.
- **Reference images**: drop them in `reference-images/` or attach them in chat.
  They drive the palette, style, layout and image-to-3D assets.

## Install in Claude Code
In Claude Code, run:
```
/plugin marketplace add AABABABABABABBABAABABABABABBA/RobloxMapDesign
/plugin install roblox-map-design@roblox-map-design
```
or from a terminal:
```bash
claude plugin marketplace add AABABABABABABBABAABABABABABBA/RobloxMapDesign
claude plugin install roblox-map-design@roblox-map-design
```
Until this branch is merged into the default branch, pin it:
`AABABABABABABBABAABABABABABBA/RobloxMapDesign#claude/gracious-noether-jgu4no`.
If the repo is private, your git/GitHub login on that machine must have access.
Update later with `claude plugin marketplace update roblox-map-design`.

The plugin also registers the Blender MCP server (`uvx blender-mcp`) from `.mcp.json`.

Without plugins: copy `.claude/skills/roblox-map-design/` into `~/.claude/skills/`
(all projects) or into your project's `.claude/skills/`.

## Setup
1. **Roblox Studio MCP**: install the official server
   (github.com/Roblox/studio-rust-mcp-server), or turn on the MCP server built into
   Studio, and add it to Claude Code. Follow its README; the installer can register
   it for you.
2. **Blender MCP**: install the add-on from github.com/ahujasid/blender-mcp, open
   the BlenderMCP panel in Blender and click *Connect*. This repo's `.mcp.json`
   already registers the server (`uvx blender-mcp`, which needs `uv`). For more
   features, turn on Poly Haven, Sketchfab and Hyper3D in the panel.
3. **Auto-import (optional, recommended)**: create an Open Cloud API key at
   create.roblox.com → Credentials with **Assets** read+write, then set these
   environment variables where Claude Code runs:
   ```
   ROBLOX_API_KEY=...        # never commit this
   ROBLOX_CREATOR_ID=...     # your user id (or group id, then pass --group)
   ```
   Without a key, Claude asks you to run *Import 3D* on the exported FBX files.
4. Python 3 with Pillow for the palette and plan-view tools: `pip install pillow`.

## Use
Ask Claude Code something like:
- "Make a cozy fishing village lobby map, here are 3 reference images"
- "Continue the map" (it picks up from memory)
- "Audit my map for overlaps and copy-paste"
- "My map glitches when I move the camera, fix it"
- "Retexture the cliffs with custom stone that matches the palette"

You can also invoke the skill directly with `/roblox-map-design`.

## Layout
```
.claude/skills/roblox-map-design/
  SKILL.md            workflow + hard rules
  references/         design principles, art direction, texturing, Blender
                      pipeline, Studio/lighting, render views, memory, checklists
  scripts/            Luau (Studio), Python (Blender), and CLI tools
map-memory/           persistent design memory + asset ledger
reference-images/     put your reference images here
```
