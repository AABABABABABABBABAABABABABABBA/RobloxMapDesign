# Roblox Studio via MCP

## Connecting
The official Roblox Studio MCP server (github.com/Roblox/studio-rust-mcp-server, also
built into recent Studio versions under Assistant/MCP settings) exposes tools such
as `run_code` (execute Luau in Studio's edit context and return printed output),
`insert_model` (insert a Creator Store asset), `get_console_output`,
`start_stop_play`. Exact names vary — list the server's tools before starting.

Tips:
- `run_code` returns what you `print`. Print compact summaries, not thousands of lines.
- Wrap edits in a ChangeHistoryService recording so the user can undo in one step:
  ```lua
  local CHS = game:GetService("ChangeHistoryService")
  local rec = CHS:TryBeginRecording("MapDesign: dock dressing")
  -- ... edits ...
  if rec then CHS:FinishRecording(rec, Enum.FinishRecordingOperation.Commit) end
  ```
- Scripts in `scripts/` are self-contained: read the file, adjust the CONFIG block
  at the top, send the whole text through `run_code`.
- Large builds: split into several `run_code` calls (one per zone) so one error
  doesn't lose everything, and so output stays readable.

## Inspecting a place
```lua
local function count(root)
  local parts, meshes, models = 0, 0, 0
  for _, d in root:GetDescendants() do
    if d:IsA("MeshPart") then meshes += 1 elseif d:IsA("BasePart") then parts += 1
    elseif d:IsA("Model") then models += 1 end
  end
  return parts, meshes, models
end
for _, c in workspace:GetChildren() do
  local p, m, mo = count(c)
  print(c.ClassName, c.Name, "parts", p, "meshes", m, "models", mo)
end
local L = game.Lighting
print("Lighting", L.Technology, L.ClockTime, L.Brightness, L.Ambient, L.OutdoorAmbient)
for _, e in L:GetChildren() do print(" ", e.ClassName, e.Name) end
```

## Lighting recipes (starting points — tune by screenshot, not by numbers)
Always: `Lighting.Technology = Enum.Technology.Future`, add an `Atmosphere`, replace
the default `Sky`, keep `Ambient` dark (shadows need contrast), use
`OutdoorAmbient` for fill.

**Warm golden hour**
```lua
local L = game.Lighting
L.Technology = Enum.Technology.Future
L.ClockTime = 17.4; L.GeographicLatitude = 35
L.Brightness = 3; L.ExposureCompensation = 0.1
L.Ambient = Color3.fromRGB(40, 35, 45)
L.OutdoorAmbient = Color3.fromRGB(120, 105, 110)
L.EnvironmentDiffuseScale = 0.5; L.EnvironmentSpecularScale = 0.6
L.ShadowSoftness = 0.15
local atm = L:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere", L)
atm.Density = 0.32; atm.Offset = 0.2; atm.Haze = 1.6; atm.Glare = 0.6
atm.Color = Color3.fromRGB(255, 214, 170); atm.Decay = Color3.fromRGB(120, 90, 110)
local cc = L:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect", L)
cc.Contrast = 0.08; cc.Saturation = 0.05; cc.TintColor = Color3.fromRGB(255, 246, 235)
local bloom = L:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect", L)
bloom.Intensity = 0.4; bloom.Size = 24; bloom.Threshold = 1.6
local rays = L:FindFirstChildOfClass("SunRaysEffect") or Instance.new("SunRaysEffect", L)
rays.Intensity = 0.04; rays.Spread = 0.6
```

**Overcast / moody**: ClockTime 14, Brightness 1.5, Atmosphere Density 0.45,
Haze 2.5, Color (190,200,210), ColorCorrection Saturation −0.15, no SunRays.

**Night**: ClockTime 0.5, Brightness 0.4, Ambient (15,18,30), OutdoorAmbient
(40,50,80), Atmosphere Density 0.35 Color (60,70,110). Lighting comes from motivated
local lights (lamps, windows, fires) with warm `PointLight`/`SpotLight`
(Range 12–24, Brightness 1–2, Shadows on for the hero lights only).

**Stylised / bright simulator**: ClockTime 13, Brightness 2.5, saturated but not
neon palette, ColorCorrection Saturation 0.15, Bloom low.

Rules: max one strong `Neon` accent per view; local lights must have a visible
source; no more than ~6 shadow-casting local lights visible at once.

## Materials
- Prefer `Slate`, `Rock`, `Cobblestone`, `WoodPlanks`, `Wood`, `Concrete`,
  `Brick`, `Plaster`, `Sand`, `Grass`, `LeafyGrass`, `Ground`, `Metal`,
  `CorrodedMetal`, `DiamondPlate`, `Fabric`, `Pebble`, `Limestone`, `Basalt`.
- `SmoothPlastic` is fine for a stylised look *if* used consistently with a palette.
- For a custom look, create `MaterialVariant`s in `MaterialService` from PBR maps
  (Poly Haven via Blender MCP is a good source — see blender-pipeline.md).
- Rotate texture direction on adjacent parts (or vary part orientation) so material
  tiling doesn't line up across seams.

## Terrain
Use Terrain for ground, cliffs and water when the style allows — it blends and
avoids part seams entirely.
```lua
local T = workspace.Terrain
T:FillBlock(CFrame.new(0, -6, 0), Vector3.new(512, 12, 512), Enum.Material.Grass)
T:FillBall(Vector3.new(40, 2, -30), 18, Enum.Material.Rock)
T:FillBlock(CFrame.new(0, -9, 120), Vector3.new(200, 6, 80), Enum.Material.Water)
```
Vary ground with several FillBall/FillWedge calls of different radii and materials;
blend material transitions (Grass → Ground → Rock) rather than hard edges.

## Organisation & performance
```
Workspace
└─ Map
   ├─ Zones/<ZoneName>/{Structures, Props, Lights}
   ├─ Landmarks
   ├─ Scatter          (output of scatter.luau)
   └─ _Blockout        (delete when done)
```
- Static: `Anchored = true`.
- Decoration: `CanCollide = false`, `CanTouch = false`, `CanQuery = false`.
- Tiny props: `CastShadow = false`.
- MeshParts: `CollisionFidelity = Box` for decor, `Hull` for walkable rocks,
  `RenderFidelity = Automatic`.
- Large maps: `workspace.StreamingEnabled = true`; hero landmarks
  `ModelStreamingMode = Persistent`.

## Uploading images, meshes and textures
Studio MCP code cannot upload files from disk itself. Use
`scripts/upload_to_roblox.py` (Open Cloud, needs `ROBLOX_API_KEY` +
`ROBLOX_CREATOR_ID` env vars) and run the generated insert script — see
blender-pipeline.md → Auto-import. For a single user-owned image (sign, poster,
logo) bake it onto a mesh in Blender or drop it in a textures folder and upload it
as a Decal the same way; `insert_assets.luau` resolves decal ids to image ids.
Without an API key, ask the user to import via Asset Manager → Bulk Import and
give you the `rbxassetid://`.
