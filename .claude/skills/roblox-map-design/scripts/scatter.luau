--[[
	scatter.luau — natural, non-repeating, non-overlapping prop scattering.

	Paste into the Studio MCP `run_code` tool after editing CONFIG.
	Use ONLY for natural filler (rocks, bushes, trees, grass clumps, debris).
	Hero pieces and architecture are placed by hand.

	What it does
	  * Poisson-disk sampling (Bridson) -> organic spacing, never a grid
	  * optional noise-based clustering -> clumps + clearings instead of even fill
	  * picks variants with a shuffle bag and never puts the same variant next to itself
	  * random yaw, scale range, slight tilt, partial alignment to the ground normal
	  * colour jitter per instance (HSV), sinks into the ground so nothing floats
	  * rejects: steep slopes, wrong ground material, AVOID zones (paths), anything
	    overlapping existing geometry or other scatter layers
	  * one undo step (ChangeHistoryService)

	Region: an anchored Part (any rotation) whose X/Z footprint is the area to fill.
	Variants: Models or BaseParts. Models should have their pivot at the base centre
	(origin at base in Blender); if not, the script measures the bottom itself.
]]

local CONFIG = {
	NAME = "Rocks", -- output folder name under SCATTER_ROOT
	VARIANTS_FOLDER = game:GetService("ServerStorage"):FindFirstChild("ScatterKit") and game:GetService("ServerStorage").ScatterKit:FindFirstChild("Rocks"),
	REGION_PART = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("_ScatterRegions") and workspace.Map._ScatterRegions:FindFirstChild("Rocks"),
	SCATTER_ROOT_PARENT = workspace:FindFirstChild("Map") or workspace,

	MIN_DIST = 10, -- Poisson radius (studs) between samples
	MAX_COUNT = 120,
	CLUSTERING = 0.45, -- 0 = even fill, 1 = strong clumps with big clearings
	CLUSTER_SCALE = 60, -- studs; size of clumps/clearings
	SCALE = { 0.8, 1.3 },
	TILT_DEG = 6, -- random lean (rocks/trees); 0 for upright things like lamps
	ALIGN_TO_NORMAL = 0.35, -- 0 = world-up, 1 = fully follow the ground slope
	SINK = { 0.15, 0.5 }, -- studs pushed into the ground
	COLOR_JITTER = 0.05, -- HSV jitter amount
	MAX_SLOPE_DEG = 35,
	GROUND_MATERIALS = nil :: { Enum.Material }?, -- e.g. { Enum.Material.Grass, Enum.Material.Ground }; nil = any
	AVOID = {} :: { Instance }, -- folders/parts to keep clear (paths, buildings, spawn)
	AVOID_PADDING = 4,
	COLLIDE = false, -- true for rocks players should bump into
	CAST_SHADOW_MIN_SIZE = 4, -- smaller than this -> CastShadow = false
	SEED = 1337,
	DRY_RUN = false, -- true = only report what would be placed
}

local CHS = game:GetService("ChangeHistoryService")
local rng = Random.new(CONFIG.SEED)

assert(CONFIG.VARIANTS_FOLDER, "VARIANTS_FOLDER not found — put variant models in ServerStorage.ScatterKit.<Name>")
assert(CONFIG.REGION_PART and CONFIG.REGION_PART:IsA("BasePart"), "REGION_PART not found — add an anchored Part defining the area")

local variants: { Instance } = {}
for _, v in CONFIG.VARIANTS_FOLDER:GetChildren() do
	if v:IsA("Model") or v:IsA("BasePart") then
		table.insert(variants, v)
	end
end
assert(#variants >= 1, "no variants found")
if #variants < 3 then
	warn(string.format("only %d variant(s) for %s — make at least 3 in Blender for a natural look", #variants, CONFIG.NAME))
end

------------------------------------------------------------------ helpers
local function bounds(inst: Instance): (CFrame, Vector3)
	if inst:IsA("Model") then
		return inst:GetBoundingBox()
	end
	local p = inst :: BasePart
	return p.CFrame, p.Size
end

local function aabbMinY(cf: CFrame, size: Vector3): number
	local h = size / 2
	local ey = math.abs(cf.RightVector.Y) * h.X + math.abs(cf.UpVector.Y) * h.Y + math.abs(cf.LookVector.Y) * h.Z
	return cf.Y - ey
end

local function forEachPart(inst: Instance, fn: (BasePart) -> ())
	if inst:IsA("BasePart") then
		fn(inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			fn(d)
		end
	end
end

local function scaleInstance(inst: Instance, s: number)
	if inst:IsA("Model") then
		inst:ScaleTo(inst:GetScale() * s)
	else
		(inst :: BasePart).Size *= s
	end
end

local function jitterColor(c: Color3, j: number, dh: number, ds: number, dv: number): Color3
	local h, s, v = c:ToHSV()
	h = (h + dh * j * 0.3) % 1
	s = math.clamp(s + ds * j * 0.6, 0, 1)
	v = math.clamp(v + dv * j, 0, 1)
	return Color3.fromHSV(h, s, v)
end

local function rotateUpTo(up: Vector3): CFrame
	local axis = Vector3.yAxis:Cross(up)
	if axis.Magnitude < 1e-5 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(Vector3.yAxis:Dot(up), -1, 1)))
end

------------------------------------------------------------------ Poisson disk (Bridson)
local function poisson(w: number, h: number, r: number, k: number): { Vector2 }
	local cell = r / math.sqrt(2)
	local gw, gh = math.ceil(w / cell), math.ceil(h / cell)
	local grid: { [number]: Vector2 } = {}
	local pts: { Vector2 } = {}
	local active: { Vector2 } = {}
	local function gi(p: Vector2): (number, number)
		return math.floor(p.X / cell), math.floor(p.Y / cell)
	end
	local function ok(p: Vector2): boolean
		if p.X < 0 or p.Y < 0 or p.X >= w or p.Y >= h then
			return false
		end
		local cx, cy = gi(p)
		for x = math.max(cx - 2, 0), math.min(cx + 2, gw - 1) do
			for y = math.max(cy - 2, 0), math.min(cy + 2, gh - 1) do
				local q = grid[y * gw + x]
				if q and (q - p).Magnitude < r then
					return false
				end
			end
		end
		return true
	end
	local function add(p: Vector2)
		table.insert(pts, p)
		table.insert(active, p)
		local cx, cy = gi(p)
		grid[cy * gw + cx] = p
	end
	add(Vector2.new(rng:NextNumber() * w, rng:NextNumber() * h))
	while #active > 0 do
		local idx = rng:NextInteger(1, #active)
		local base = active[idx]
		local found = false
		for _ = 1, k do
			local a = rng:NextNumber() * math.pi * 2
			local d = r * (1 + rng:NextNumber())
			local p = base + Vector2.new(math.cos(a), math.sin(a)) * d
			if ok(p) then
				add(p)
				found = true
				break
			end
		end
		if not found then
			active[idx] = active[#active]
			active[#active] = nil
		end
	end
	return pts
end

------------------------------------------------------------------ main
local region = CONFIG.REGION_PART :: BasePart
local scatterRoot = CONFIG.SCATTER_ROOT_PARENT:FindFirstChild("Scatter")
if not scatterRoot then
	scatterRoot = Instance.new("Folder")
	scatterRoot.Name = "Scatter"
	scatterRoot.Parent = CONFIG.SCATTER_ROOT_PARENT
end
local out = scatterRoot:FindFirstChild(CONFIG.NAME)

-- footprints of everything already scattered (other layers) to avoid cross-layer overlap
type Spot = { pos: Vector3, r: number, variant: string }
local spots: { Spot } = {}
for _, layer in scatterRoot:GetChildren() do
	if layer ~= out then
		for _, obj in layer:GetChildren() do
			local cf, size = bounds(obj)
			table.insert(spots, { pos = cf.Position, r = math.max(size.X, size.Z) / 2, variant = obj:GetAttribute("ScatterVariant") or "" })
		end
	end
end

local rec = (not CONFIG.DRY_RUN) and CHS:TryBeginRecording("Scatter " .. CONFIG.NAME) or nil
if out and not CONFIG.DRY_RUN then
	out:Destroy() -- re-running replaces this layer
end
if not CONFIG.DRY_RUN then
	out = Instance.new("Folder")
	out.Name = CONFIG.NAME
	out.Parent = scatterRoot
end

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.FilterDescendantsInstances = { region, scatterRoot }

local avoidParams = OverlapParams.new()
avoidParams.FilterType = Enum.RaycastFilterType.Include
avoidParams.FilterDescendantsInstances = CONFIG.AVOID

local bag: { Instance } = {}
local function nextVariant(avoidName: string): Instance
	for _ = 1, 4 do
		if #bag == 0 then
			for _, v in variants do
				table.insert(bag, v)
			end
			for i = #bag, 2, -1 do
				local j = rng:NextInteger(1, i)
				bag[i], bag[j] = bag[j], bag[i]
			end
		end
		local v = table.remove(bag) :: Instance
		if v.Name ~= avoidName or #variants == 1 then
			return v
		end
		table.insert(bag, 1, v)
	end
	return table.remove(bag) :: Instance
end

local reasons: { [string]: number } = {}
local used: { [string]: number } = {}
local placed = 0
local function reject(why: string)
	reasons[why] = (reasons[why] or 0) + 1
end

local samples = poisson(region.Size.X, region.Size.Z, CONFIG.MIN_DIST, 30)
-- shuffle so MAX_COUNT doesn't fill one corner first
for i = #samples, 2, -1 do
	local j = rng:NextInteger(1, i)
	samples[i], samples[j] = samples[j], samples[i]
end
local noiseSeed = rng:NextNumber() * 1000

for _, s in samples do
	if placed >= CONFIG.MAX_COUNT then
		break
	end
	local local2 = Vector3.new(s.X - region.Size.X / 2, 0, s.Y - region.Size.Z / 2)
	local world = region.CFrame:PointToWorldSpace(local2)

	-- clustering: thin out samples where low-frequency noise is low
	if CONFIG.CLUSTERING > 0 then
		local n = math.noise(world.X / CONFIG.CLUSTER_SCALE, world.Z / CONFIG.CLUSTER_SCALE, noiseSeed) * 0.5 + 0.5
		if rng:NextNumber() > math.clamp(1 - CONFIG.CLUSTERING + (n - 0.5) * 2 * CONFIG.CLUSTERING, 0, 1) then
			reject("clustering")
			continue
		end
	end

	local hit = workspace:Raycast(Vector3.new(world.X, region.Position.Y + 500, world.Z), Vector3.new(0, -2000, 0), rp)
	if not hit then
		reject("no ground")
		continue
	end
	local blocked = false
	for _, a in CONFIG.AVOID do
		if hit.Instance:IsDescendantOf(a) or hit.Instance == a then
			blocked = true
		end
	end
	if blocked or (#CONFIG.AVOID > 0 and #workspace:GetPartBoundsInRadius(hit.Position, CONFIG.AVOID_PADDING, avoidParams) > 0) then
		reject("avoid zone")
		continue
	end
	local slope = math.deg(math.acos(math.clamp(hit.Normal.Y, -1, 1)))
	if slope > CONFIG.MAX_SLOPE_DEG then
		reject("too steep")
		continue
	end
	if CONFIG.GROUND_MATERIALS and not table.find(CONFIG.GROUND_MATERIALS, hit.Material) then
		reject("ground material")
		continue
	end

	-- neighbour check (other layers + this layer)
	local nearestName, nearestD = "", math.huge
	local tooClose = false
	local variant = nextVariant("")
	local scale = rng:NextNumber(CONFIG.SCALE[1], CONFIG.SCALE[2])
	local _, vsize = bounds(variant)
	local radius = math.max(vsize.X, vsize.Z) / 2 * scale
	for _, sp in spots do
		local d = Vector2.new(sp.pos.X - hit.Position.X, sp.pos.Z - hit.Position.Z).Magnitude
		if d < sp.r + radius * 0.9 then
			tooClose = true
			break
		end
		if d < nearestD then
			nearestD, nearestName = d, sp.variant
		end
	end
	if tooClose then
		reject("too close to other scatter")
		continue
	end
	if nearestName == variant.Name and #variants > 1 and nearestD < CONFIG.MIN_DIST * 2.5 then
		variant = nextVariant(nearestName)
		_, vsize = bounds(variant)
		radius = math.max(vsize.X, vsize.Z) / 2 * scale
	end

	if CONFIG.DRY_RUN then
		placed += 1
		used[variant.Name] = (used[variant.Name] or 0) + 1
		table.insert(spots, { pos = hit.Position, r = radius, variant = variant.Name })
		continue
	end

	local obj = variant:Clone()
	scaleInstance(obj, scale)
	-- measure pivot-to-bottom distance in an upright pose
	obj:PivotTo(CFrame.identity)
	local bcf, bsize = bounds(obj)
	local pivotAboveBottom = -aabbMinY(bcf, bsize)

	local up = Vector3.yAxis:Lerp(hit.Normal, CONFIG.ALIGN_TO_NORMAL).Unit
	local tilt = math.rad(CONFIG.TILT_DEG)
	local cf = CFrame.new(hit.Position)
		* rotateUpTo(up)
		* CFrame.Angles(rng:NextNumber(-tilt, tilt), rng:NextNumber() * math.pi * 2, rng:NextNumber(-tilt, tilt))
		* CFrame.new(0, pivotAboveBottom - rng:NextNumber(CONFIG.SINK[1], CONFIG.SINK[2]), 0)
	obj:PivotTo(cf)

	-- overlap with non-ground map geometry
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = { obj, hit.Instance, region, workspace.Terrain }
	local ocf, osize = bounds(obj)
	local shrink = Vector3.new(0.5, 0.5, 0.5)
	if #workspace:GetPartBoundsInBox(ocf * CFrame.new(0, CONFIG.SINK[2], 0), (osize - shrink):Max(Vector3.one * 0.1), op) > 0 then
		obj:Destroy()
		reject("overlaps geometry")
		continue
	end

	local dh, ds, dv = rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)
	local maxDim = math.max(osize.X, osize.Y, osize.Z)
	forEachPart(obj, function(p)
		p.Anchored = true
		p.CanCollide = CONFIG.COLLIDE
		p.CanTouch = false
		p.CanQuery = CONFIG.COLLIDE
		p.CastShadow = maxDim >= CONFIG.CAST_SHADOW_MIN_SIZE
		p.Color = jitterColor(p.Color, CONFIG.COLOR_JITTER, dh, ds, dv)
	end)
	obj:SetAttribute("ScatterVariant", variant.Name)
	obj.Name = string.format("%s_%s_%03d", CONFIG.NAME, variant.Name, placed + 1)
	obj.Parent = out

	table.insert(spots, { pos = hit.Position, r = radius, variant = variant.Name })
	placed += 1
	used[variant.Name] = (used[variant.Name] or 0) + 1
end

if rec then
	CHS:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
end

print(string.format("=== SCATTER %s: placed %d / %d samples%s ===", CONFIG.NAME, placed, #samples, CONFIG.DRY_RUN and " (dry run)" or ""))
for name, n in used do
	print(string.format("  variant %-24s %d", name, n))
end
for why, n in reasons do
	print(string.format("  rejected: %-26s %d", why, n))
end
print("Next: run audit_map.luau to confirm 0 OVERLAP / CLONE_STAMP / FLOATING.")
