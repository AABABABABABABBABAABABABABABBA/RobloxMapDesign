--[[
	fix_map.luau — repair broken builds and camera glitches automatically.

	Paste into Studio MCP `run_code`. Two passes:
	  1. APPLY = false (default): diagnose only — prints every planned fix, changes nothing.
	  2. APPLY = true: applies the fixes as ONE undo step (Ctrl+Z reverts everything).
	Then run audit_map.luau again; repeat fix_map until it reports nothing to fix
	(fixes can uncover others, e.g. a pushed prop now touching a wall).

	Visual glitches (the stuff that flickers / sparkles / pops when the camera moves)
	  Z_FIGHT            coplanar same-facing faces flicker      -> offset smaller part 0.02 studs
	  SEAM               hair-line gaps sparkle / leak light       -> close the gap (< SEAM_MAX)
	  DECAL_FIGHT        two decals on one face, same ZIndex       -> bump ZIndex
	  TRANSPARENT_SORT   overlapping semi-transparent parts swap   -> report (pick one to be opaque)
	  LOD_POP            big MeshParts change detail as you move   -> RenderFidelity = Precise
	  TINY_SHADOW        tiny parts' shadows shimmer               -> CastShadow = false
	  STREAM_POP         landmarks stream out and pop back         -> ModelStreamingMode = Persistent
	  FAR_FROM_ORIGIN    > 10k studs from origin: jitter           -> report (move the map)
	Camera behaviour
	  CAMERA_SNAP        decor that makes the camera zoom in/jerk  -> CanCollide = false (Poppercam
	                     only reacts to CanCollide + opaque parts); also found by a camera sweep
	                     along _Waypoints / SpawnLocations
	  THIN_WALL          camera near-plane sees through walls      -> thicken to THIN_MIN
	Broken builds
	  EXACT_DUPLICATE    stacked copies                            -> delete the copy
	  HIDDEN_INSIDE      part completely buried in another          -> delete it (wasted + z-fights)
	  OVERLAP            props clipping props/walls                 -> delete scatter item, or push
	                                                                  a small prop out (<= PUSH_MAX)
	  FLOATING           props hovering above the ground            -> drop onto the surface
	  CLONE_STAMP        same prop, same rotation/scale/colour      -> re-rotate, rescale, tint
	  UNANCHORED         static parts that will fall at runtime     -> Anchored = true
	  LOOSE_ASSEMBLY     unanchored welded assemblies               -> report (may be intended physics)
	  BELOW_KILL_PLANE   parts under FallenPartsDestroyHeight      -> report
	  MANUAL             anything not safe to auto-fix              -> report with reason

	Opt-out tags (CollectionService): AllowOverlap, AllowFloat, AllowRepeat, NoAutoFix.
]]

local CONFIG = {
	ROOT = workspace:FindFirstChild("Map") or workspace,
	APPLY = false,
	FIX = {
		EXACT_DUPLICATE = true, HIDDEN_INSIDE = true, OVERLAP = true, Z_FIGHT = true,
		SEAM = true, DECAL_FIGHT = true, FLOATING = true, CLONE_STAMP = true,
		UNANCHORED = true, CAMERA_SNAP = true, THIN_WALL = true, TINY_SHADOW = true,
		LOD_POP = true, STREAM_POP = true,
	},
	OVERLAP_TOL = 0.05,
	ZFIGHT_OFFSET = 0.02,
	SEAM_MAX = 0.05,
	GROUND_SINK_MAX = 0.6, -- props sunk this far into the surface below are intentionally grounded
	PUSH_MAX = 1.0, -- max penetration (studs) that is auto-pushed apart
	FLOAT_TOL = 0.3,
	FLOAT_DROP_MAX = 8, -- only drop props hovering less than this
	SINK = 0.15,
	CLONE_RADIUS = 40,
	PROP_MAX_SIZE = 30,
	THIN_MIN = 0.6, -- walls thinner than this get thickened
	THIN_WALL_MIN_FACE = 8, -- ...if their other two dimensions are at least this
	SHADOW_MIN = 1,
	LOD_MIN_SIZE = 40,
	LOD_MAX_COUNT = 30,
	FAR = 10000,
	WAYPOINTS = nil :: Instance?, -- folder of parts along the player path; default Map._Waypoints
	CAMERA_DIST = 14,
	DECOR_NAME_PATTERN = { "leaf", "leaves", "foliage", "bush", "grass", "canopy", "vine", "flower", "fern", "twig", "branch", "debris", "pebble" },
	SEED = 4242,
	MAX_LINES = 20,
}

local CollectionService = game:GetService("CollectionService")
local CHS = game:GetService("ChangeHistoryService")
local rng = Random.new(CONFIG.SEED)

------------------------------------------------------------------ bookkeeping
type Action = { cat: string, msg: string, fn: (() -> ())? }
local actions: { Action } = {}
local claimed: { [Instance]: string } = {} -- one structural fix per instance per run

local function plan(cat: string, msg: string, fn: (() -> ())?, inst: Instance?)
	if fn and inst then
		if claimed[inst] then
			fn = nil
			msg ..= "  (deferred: already fixed by " .. claimed[inst] .. ", re-run)"
		else
			claimed[inst] = cat
		end
	end
	if fn and CONFIG.FIX[cat] == false then
		fn = nil
	end
	table.insert(actions, { cat = cat, msg = msg, fn = fn })
end

local function hasTagUp(inst: Instance, tag: string): boolean
	local cur: Instance? = inst
	while cur and cur ~= game do
		if CollectionService:HasTag(cur, tag) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function name(inst: Instance): string
	return (inst:GetFullName():gsub("^Workspace%.", ""))
end

local function vol(p: BasePart): number
	return p.Size.X * p.Size.Y * p.Size.Z
end

local function maxDim(v: Vector3): number
	return math.max(v.X, v.Y, v.Z)
end

local function propOwner(p: Instance): Model?
	local best: Model? = nil
	local m = p:FindFirstAncestorWhichIsA("Model")
	while m and m ~= workspace do
		local _, size = m:GetBoundingBox()
		if maxDim(size) > CONFIG.PROP_MAX_SIZE then
			break
		end
		best = m
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return best
end

-- the thing to move/delete when fixing a part: its prop model, or the part itself
local function placeableOf(p: BasePart): Instance
	return propOwner(p) or p
end

local scatterFolder = CONFIG.ROOT:FindFirstChild("Scatter")
local function isScatter(inst: Instance): boolean
	return scatterFolder ~= nil and inst:IsDescendantOf(scatterFolder)
end

local function isDecor(p: BasePart): boolean
	if isScatter(p) then
		return true
	end
	local n = (p.Name .. " " .. (p.Parent and p.Parent.Name or "")):lower()
	for _, pat in CONFIG.DECOR_NAME_PATTERN do
		if n:find(pat, 1, true) then
			return true
		end
	end
	return p.Material == Enum.Material.LeafyGrass or maxDim(p.Size) < 2
end

------------------------------------------------------------------ geometry
local function axes(cf: CFrame): { Vector3 }
	return { cf.RightVector, cf.UpVector, cf.LookVector }
end
local function radiusOn(axis: Vector3, ax: { Vector3 }, half: Vector3): number
	return math.abs(axis:Dot(ax[1])) * half.X + math.abs(axis:Dot(ax[2])) * half.Y + math.abs(axis:Dot(ax[3])) * half.Z
end
-- SAT: returns penetration depth (<= 0 when separated) and the axis of least
-- overlap, oriented from A towards B
local function obbDepth(cfA: CFrame, sA: Vector3, cfB: CFrame, sB: Vector3): (number, Vector3)
	local aA, aB = axes(cfA), axes(cfB)
	local hA, hB = sA / 2, sB / 2
	local d = cfB.Position - cfA.Position
	local best, bestAxis = math.huge, Vector3.yAxis
	local function test(L: Vector3, isFace: boolean)
		local m = L.Magnitude
		if m < 1e-6 then
			return
		end
		L /= m
		local o = radiusOn(L, aA, hA) + radiusOn(L, aB, hB) - math.abs(d:Dot(L))
		-- prefer face axes on ties so pushes/seam closes are along face normals
		if o < best - (isFace and 0 or 1e-4) then
			best = o
			bestAxis = if d:Dot(L) >= 0 then L else -L
		end
	end
	for i = 1, 3 do
		test(aA[i], true)
		test(aB[i], true)
	end
	for i = 1, 3 do
		for j = 1, 3 do
			test(aA[i]:Cross(aB[j]), false)
		end
	end
	return best, bestAxis
end
local function worldAABB(cf: CFrame, size: Vector3): (Vector3, Vector3)
	local h = size / 2
	local ax = axes(cf)
	local e = Vector3.new(
		math.abs(ax[1].X) * h.X + math.abs(ax[2].X) * h.Y + math.abs(ax[3].X) * h.Z,
		math.abs(ax[1].Y) * h.X + math.abs(ax[2].Y) * h.Y + math.abs(ax[3].Y) * h.Z,
		math.abs(ax[1].Z) * h.X + math.abs(ax[2].Z) * h.Y + math.abs(ax[3].Z) * h.Z
	)
	return cf.Position - e, cf.Position + e
end
local function faces(cf: CFrame, size: Vector3)
	local ax = axes(cf)
	local h = { size.X / 2, size.Y / 2, size.Z / 2 }
	local out = {}
	for i = 1, 3 do
		for _, sign in { 1, -1 } do
			local n = ax[i] * sign
			local others = {}
			for j = 1, 3 do
				if j ~= i then
					table.insert(others, { ax[j], h[j] })
				end
			end
			table.insert(out, { n = n, off = n:Dot(cf.Position) + h[i], center = cf.Position + n * h[i], others = others })
		end
	end
	return out
end
local function facesOverlapInPlane(fa, fb): boolean
	local d = fb.center - fa.center
	for _, L in { fa.others[1][1], fa.others[2][1], fb.others[1][1], fb.others[2][1] } do
		local ra = math.abs(L:Dot(fa.others[1][1])) * fa.others[1][2] + math.abs(L:Dot(fa.others[2][1])) * fa.others[2][2]
		local rb = math.abs(L:Dot(fb.others[1][1])) * fb.others[1][2] + math.abs(L:Dot(fb.others[2][1])) * fb.others[2][2]
		if ra + rb - math.abs(d:Dot(L)) <= 0.01 then
			return false
		end
	end
	return true
end
local function contains(outer: BasePart, inner: BasePart): boolean
	local h = outer.Size / 2 + Vector3.one * 0.01
	local ih = inner.Size / 2
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = inner.CFrame:PointToWorldSpace(Vector3.new(sx * ih.X, sy * ih.Y, sz * ih.Z))
				local l = outer.CFrame:PointToObjectSpace(corner)
				if math.abs(l.X) > h.X or math.abs(l.Y) > h.Y or math.abs(l.Z) > h.Z then
					return false
				end
			end
		end
	end
	return true
end
local function isBlock(p: BasePart): boolean
	return p:IsA("Part") and (p :: Part).Shape == Enum.PartType.Block
end
local function sameRotation(a: CFrame, b: CFrame, deg: number): boolean
	local _, angle = a.Rotation:ToObjectSpace(b.Rotation):ToAxisAngle()
	-- 90-degree symmetric boxes: compare axes up to sign/permutation
	if math.deg(angle) <= deg then
		return true
	end
	local ok = 0
	for _, u in axes(a) do
		for _, v in axes(b) do
			if math.abs(u:Dot(v)) > math.cos(math.rad(deg)) then
				ok += 1
				break
			end
		end
	end
	return ok == 3
end

local function moveInst(inst: Instance, delta: Vector3)
	if inst:IsA("Model") then
		inst:PivotTo(inst:GetPivot() + delta)
	elseif inst:IsA("BasePart") then
		inst.CFrame += delta
	end
end

------------------------------------------------------------------ collect
local all: { BasePart } = {}
local parts: { BasePart } = {}
for _, d in CONFIG.ROOT:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") and not hasTagUp(d, "NoAutoFix") then
		table.insert(all, d)
		if d.Transparency < 1 then
			table.insert(parts, d)
		end
	end
end

------------------------------------------------------------------ EXACT_DUPLICATE
local dead: { [Instance]: boolean } = {}
do
	local seen: { [string]: BasePart } = {}
	local function r(x: number, s: number): number
		return math.floor(x / s + 0.5) * s
	end
	for _, p in parts do
		local cf = p.CFrame
		local rx, ry, rz = cf:ToOrientation()
		local key = table.concat({
			p.ClassName, p:IsA("MeshPart") and (p :: MeshPart).MeshId or "",
			r(cf.X, 0.01), r(cf.Y, 0.01), r(cf.Z, 0.01),
			r(math.deg(rx), 0.5), r(math.deg(ry), 0.5), r(math.deg(rz), 0.5),
			r(p.Size.X, 0.01), r(p.Size.Y, 0.01), r(p.Size.Z, 0.01), tostring(p.Color), p.Material.Name,
		}, "|")
		local other = seen[key]
		if other then
			dead[p] = true
			plan("EXACT_DUPLICATE", name(p) .. " is a stacked copy of " .. name(other), function()
				p:Destroy()
			end, p)
		else
			seen[key] = p
		end
	end
end

------------------------------------------------------------------ pair checks
do
	local CELL = 16
	local grid: { [string]: { number } } = {}
	local boxes = {}
	local large: { number } = {}
	local isLarge: { [number]: boolean } = {}
	for i, p in parts do
		local mn, mx = worldAABB(p.CFrame, p.Size)
		boxes[i] = { mn, mx }
		local x0, y0, z0 = math.floor(mn.X / CELL), math.floor(mn.Y / CELL), math.floor(mn.Z / CELL)
		local x1, y1, z1 = math.floor(mx.X / CELL), math.floor(mx.Y / CELL), math.floor(mx.Z / CELL)
		if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 512 then
			table.insert(large, i)
			isLarge[i] = true
		else
			for x = x0, x1 do
				for y = y0, y1 do
					for z = z0, z1 do
						local k = x .. "," .. y .. "," .. z
						grid[k] = grid[k] or {}
						table.insert(grid[k], i)
					end
				end
			end
		end
	end

	local function near(i: number, j: number, pad: number): boolean
		local a, b = boxes[i], boxes[j]
		return a[1].X <= b[2].X + pad and a[2].X >= b[1].X - pad and a[1].Y <= b[2].Y + pad
			and a[2].Y >= b[1].Y - pad and a[1].Z <= b[2].Z + pad and a[2].Z >= b[1].Z - pad
	end

	local function checkPair(i: number, j: number)
		local a, b = parts[i], parts[j]
		if dead[a] or dead[b] or not near(i, j, CONFIG.SEAM_MAX) then
			return
		end
		local depth, axis = obbDepth(a.CFrame, a.Size, b.CFrame, b.Size)
		if depth < -CONFIG.SEAM_MAX then
			return
		end
		local small, big = a, b
		if vol(b) < vol(a) then
			small, big = b, a
		end
		local sameOwner = propOwner(a) ~= nil and propOwner(a) == propOwner(b)

		-- SEAM: hairline gap between aligned blocks
		if depth < -0.001 and isBlock(a) and isBlock(b) and sameRotation(a.CFrame, b.CFrame, 0.5) then
			local gap = -depth
			local dir = if small == a then axis else -axis
			plan("SEAM", string.format("%s <-> %s gap %.3f studs", name(a), name(b), gap), function()
				small.CFrame += dir * gap
			end, small)
			return
		end
		if depth < -0.001 then
			return
		end

		-- Z_FIGHT
		if isBlock(a) and isBlock(b) then
			for _, f1 in faces(a.CFrame, a.Size) do
				local hit = false
				for _, f2 in faces(b.CFrame, b.Size) do
					if f1.n:Dot(f2.n) > 0.999 and math.abs(f1.off - f2.off) < 0.01 and facesOverlapInPlane(f1, f2) then
						local sameLook = a.Material == b.Material and a.Color == b.Color
							and (a.Material == Enum.Material.SmoothPlastic or a.Material == Enum.Material.Plastic)
						if not sameLook then
							local n = if small == a then f1.n else f2.n
							plan("Z_FIGHT", name(a) .. " <> " .. name(b) .. " (coplanar faces flicker)", function()
								small.CFrame += n * CONFIG.ZFIGHT_OFFSET
							end, small)
							hit = true
							break
						end
					end
				end
				if hit then
					break
				end
			end
		end

		-- TRANSPARENT_SORT
		if depth > 0.01 and a.Transparency > 0 and a.Transparency < 1 and b.Transparency > 0 and b.Transparency < 1 then
			plan("TRANSPARENT_SORT", name(a) .. " x " .. name(b) .. " — overlapping see-through parts swap draw order; make one opaque or separate them")
		end

		if depth <= CONFIG.OVERLAP_TOL or sameOwner then
			return
		end
		if math.abs(axis.Y) > 0.7 and depth <= CONFIG.GROUND_SINK_MAX then
			return -- resting on / sunk into the surface below: that's grounding, not clipping
		end
		if hasTagUp(a, "AllowOverlap") or hasTagUp(b, "AllowOverlap") then
			return
		end

		-- HIDDEN_INSIDE
		if big.Transparency < 0.05 and small.Transparency < 0.05 and contains(big, small) then
			if not propOwner(small) and #small:GetChildren() == 0 then
				dead[small] = true
				plan("HIDDEN_INSIDE", name(small) .. " is buried inside " .. name(big), function()
					small:Destroy()
				end, small)
			else
				plan("MANUAL", name(small) .. " is buried inside " .. name(big) .. " (part of a model — check it)")
			end
			return
		end

		local msg = string.format("%s x %s (%.2f studs)", name(a), name(b), depth)
		-- OVERLAP with scatter: remove the scatter item
		if isScatter(a) or isScatter(b) then
			local victim: BasePart = if isScatter(a) and isScatter(b) then small elseif isScatter(a) then a else b
			local inst = victim
			while inst.Parent and inst.Parent.Parent ~= scatterFolder and inst.Parent ~= scatterFolder do
				inst = inst.Parent :: any
			end
			plan("OVERLAP", msg .. " -> remove scatter item " .. inst.Name, function()
				inst:Destroy()
			end, inst)
			return
		end
		-- small prop clipping: push it out horizontally
		local mover = placeableOf(small)
		local movable = mover ~= small or small:IsA("MeshPart") or maxDim(small.Size) <= 6
		if depth <= CONFIG.PUSH_MAX and movable and math.abs(axis.Y) < 0.7 then
			local flat = Vector3.new(axis.X, 0, axis.Z).Unit
			local dir = if small == a then -flat else flat
			plan("OVERLAP", msg .. " -> push " .. mover.Name .. string.format(" %.2f studs", depth + 0.05), function()
				moveInst(mover, dir * (depth + 0.05))
			end, mover)
		else
			plan("MANUAL", msg .. " — too deep or structural to auto-move; reposition, resize or tag AllowOverlap if hidden")
		end
	end

	for i = 1, #parts do
		if not isLarge[i] then
			local mn, mx = boxes[i][1], boxes[i][2]
			local done: { [number]: boolean } = {}
			for x = math.floor((mn.X - CONFIG.SEAM_MAX) / CELL), math.floor((mx.X + CONFIG.SEAM_MAX) / CELL) do
				for y = math.floor((mn.Y - CONFIG.SEAM_MAX) / CELL), math.floor((mx.Y + CONFIG.SEAM_MAX) / CELL) do
					for z = math.floor((mn.Z - CONFIG.SEAM_MAX) / CELL), math.floor((mx.Z + CONFIG.SEAM_MAX) / CELL) do
						local cell = grid[x .. "," .. y .. "," .. z]
						if cell then
							for _, j in cell do
								if j > i and not done[j] then
									done[j] = true
									checkPair(i, j)
								end
							end
						end
					end
				end
			end
		end
	end
	for _, L in large do
		for i = 1, #parts do
			if i ~= L and (not isLarge[i] or i > L) then
				checkPair(math.min(i, L), math.max(i, L))
			end
		end
	end
end

------------------------------------------------------------------ placeables: FLOATING + CLONE_STAMP
type Placeable = { inst: Instance, asset: string, color: Color3 }
local placeables: { Placeable } = {}
local function collect(container: Instance)
	for _, c in container:GetChildren() do
		if hasTagUp(c, "NoAutoFix") then
			continue
		elseif c:IsA("Model") then
			local _, size = c:GetBoundingBox()
			local n, lp, lv = 0, nil, -1
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then
					n += 1
					if vol(d) > lv then
						lp, lv = d, vol(d)
					end
				end
			end
			if n > 0 and maxDim(size) <= CONFIG.PROP_MAX_SIZE then
				table.insert(placeables, { inst = c, asset = c.Name:gsub("_%d+$", "") .. "#" .. n, color = lp and lp.Color or Color3.new() })
			else
				collect(c)
			end
		elseif c:IsA("MeshPart") then
			table.insert(placeables, { inst = c, asset = c.MeshId .. "|" .. c.TextureID, color = c.Color })
		elseif c:IsA("Folder") then
			collect(c)
		end
	end
end
collect(CONFIG.ROOT)

local function bounds(inst: Instance): (CFrame, Vector3)
	if inst:IsA("Model") then
		return inst:GetBoundingBox()
	end
	return (inst :: BasePart).CFrame, (inst :: BasePart).Size
end

for _, pl in placeables do
	local inst = pl.inst
	if dead[inst] or hasTagUp(inst, "AllowFloat") then
		continue
	end
	local cf, size = bounds(inst)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = { inst }
	if #workspace:GetPartBoundsInBox(cf, size + Vector3.one * CONFIG.FLOAT_TOL * 2, op) > 0 then
		continue
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { inst }
	local mn = worldAABB(cf, size)
	local origin = Vector3.new(cf.X, mn.Y + 0.05, cf.Z)
	local hit = workspace:Raycast(origin, Vector3.new(0, -(CONFIG.FLOAT_DROP_MAX + 0.1), 0), rp)
	if hit then
		local drop = (origin.Y - 0.05) - hit.Position.Y + CONFIG.SINK
		plan("FLOATING", string.format("%s hovers %.2f studs -> drop onto %s", name(inst), drop - CONFIG.SINK, hit.Instance.Name), function()
			moveInst(inst, Vector3.new(0, -drop, 0))
		end, inst)
	elseif inst.Parent and not (inst.Parent.Name:lower():find("sky")) then
		plan("MANUAL", name(inst) .. " floats more than " .. CONFIG.FLOAT_DROP_MAX .. " studs up — move it, add a support, or tag AllowFloat")
	end
end

do
	local groups: { [string]: { Placeable } } = {}
	for _, pl in placeables do
		if not dead[pl.inst] and not hasTagUp(pl.inst, "AllowRepeat") then
			groups[pl.asset] = groups[pl.asset] or {}
			table.insert(groups[pl.asset], pl)
		end
	end
	for _, list in groups do
		if #list > 1500 then
			continue
		end
		local touched: { [Instance]: boolean } = {}
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = list[i], list[j]
				if touched[b.inst] then
					continue
				end
				local _, sa = bounds(a.inst)
				local _, sb = bounds(b.inst)
				local pa, pb = (a.inst :: any):GetPivot(), (b.inst :: any):GetPivot()
				if (pa.Position - pb.Position).Magnitude > CONFIG.CLONE_RADIUS then
					continue
				end
				local _, ang = pa.Rotation:ToObjectSpace(pb.Rotation):ToAxisAngle()
				local sameScale = math.abs(sa.Magnitude - sb.Magnitude) / math.max(sa.Magnitude, 1e-3) < 0.03
				local c1, c2 = a.color, b.color
				local sameColor = math.abs(c1.R - c2.R) + math.abs(c1.G - c2.G) + math.abs(c1.B - c2.B) < 0.03
				if math.deg(ang) < 5 and sameScale and sameColor then
					touched[b.inst] = true
					local inst = b.inst
					local yaw = math.rad(rng:NextNumber(40, 320))
					local f = rng:NextNumber(0.85, 1.2)
					local dv = rng:NextNumber(-0.06, 0.06)
					plan("CLONE_STAMP", name(a.inst) .. " ~ " .. name(inst) .. string.format(" -> rotate %.0f°, scale x%.2f, tint", math.deg(yaw), f), function()
						local _, oldSize = bounds(inst)
						if inst:IsA("Model") then
							inst:ScaleTo(inst:GetScale() * f)
						else
							local p = inst :: BasePart
							p.Size *= f
						end
						local piv = (inst :: any):GetPivot()
						local rotated = CFrame.new(piv.Position) * CFrame.Angles(0, yaw, 0) * piv.Rotation
						;(inst :: any):PivotTo(rotated)
						-- keep the base on the ground for parts pivoting at their centre
						if inst:IsA("BasePart") then
							moveInst(inst, Vector3.new(0, (oldSize.Y * f - oldSize.Y) / 2, 0))
						end
						local function tint(p: BasePart)
							local h, s, v = p.Color:ToHSV()
							p.Color = Color3.fromHSV(h, s, math.clamp(v + dv, 0, 1))
						end
						if inst:IsA("BasePart") then
							tint(inst)
						end
						for _, d in inst:GetDescendants() do
							if d:IsA("BasePart") then
								tint(d)
							end
						end
					end, inst)
				end
			end
		end
	end
end

------------------------------------------------------------------ per-part checks
local fallen = workspace.FallenPartsDestroyHeight
local lodCandidates: { MeshPart } = {}
local checkedAssemblies: { [BasePart]: boolean } = {}
for _, p in all do
	if dead[p] then
		continue
	end
	-- UNANCHORED
	if not p.Anchored then
		local joints = p:GetJoints()
		local model = p:FindFirstAncestorWhichIsA("Model")
		local physical = model and (model:FindFirstChildWhichIsA("Humanoid", true) or model:FindFirstChildWhichIsA("VehicleSeat", true)
			or model:FindFirstChildWhichIsA("Script", true) or model:FindFirstChildWhichIsA("LocalScript", true))
		if #joints == 0 and not physical then
			plan("UNANCHORED", name(p) .. " will fall when the game runs -> anchor", function()
				p.Anchored = true
			end, p)
		elseif #joints > 0 and not physical then
			local root = p.AssemblyRootPart
			if root and not root.Anchored and not checkedAssemblies[root] then
				checkedAssemblies[root] = true
				plan("LOOSE_ASSEMBLY", name(root) .. " — welded assembly with nothing anchored; anchor its root if it should be static")
			end
		end
	end
	if p.Position.Y < fallen + 5 then
		plan("BELOW_KILL_PLANE", name(p) .. string.format(" at Y=%.0f is below FallenPartsDestroyHeight (%.0f) — deleted at runtime", p.Position.Y, fallen))
	end
	if p.Position.Magnitude > CONFIG.FAR then
		plan("FAR_FROM_ORIGIN", name(p) .. string.format(" is %.0f studs from origin — float precision jitter; move the map nearer 0,0,0", p.Position.Magnitude))
	end
	if p.Transparency >= 1 then
		continue
	end
	-- CAMERA_SNAP: Poppercam pulls the camera in for any CanCollide part with transparency < 0.25
	if p.CanCollide and p.Transparency < 0.25 and isDecor(p) and not p:IsA("SpawnLocation") then
		local walkable = p.Size.Y < 2 and p.Size.X >= 4 and p.Size.Z >= 4 -- small floor slabs stay solid
		if not walkable then
			plan("CAMERA_SNAP", name(p) .. " is decor the camera bumps into -> CanCollide=false", function()
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			end, p)
		end
	end
	-- THIN_WALL
	if p.CanCollide and p.Transparency < 0.25 and isBlock(p) then
		local s = p.Size
		local dims = { s.X, s.Y, s.Z }
		table.sort(dims)
		if dims[1] < CONFIG.THIN_MIN and dims[2] >= CONFIG.THIN_WALL_MIN_FACE and s.Y ~= dims[1] then
			local newSize = if s.X <= s.Z then Vector3.new(CONFIG.THIN_MIN, s.Y, s.Z) else Vector3.new(s.X, s.Y, CONFIG.THIN_MIN)
			plan("THIN_WALL", name(p) .. string.format(" is %.2f studs thin — camera clips through -> %.1f", dims[1], CONFIG.THIN_MIN), function()
				p.Size = newSize
			end, p)
		end
	end
	-- TINY_SHADOW
	if p.CastShadow and maxDim(p.Size) < CONFIG.SHADOW_MIN then
		plan("TINY_SHADOW", name(p) .. " tiny shadow shimmers -> CastShadow=false", function()
			p.CastShadow = false
		end)
	end
	-- LOD_POP
	if p:IsA("MeshPart") and p.RenderFidelity ~= Enum.RenderFidelity.Precise and maxDim(p.Size) >= CONFIG.LOD_MIN_SIZE then
		table.insert(lodCandidates, p)
	end
	-- DECAL_FIGHT
	local byFace: { [Enum.NormalId]: { Decal } } = {}
	for _, c in p:GetChildren() do
		if c:IsA("Decal") then
			byFace[c.Face] = byFace[c.Face] or {}
			table.insert(byFace[c.Face], c)
		end
	end
	for face, list in byFace do
		local z: { [number]: boolean } = {}
		local clash = false
		for _, dcl in list do
			if z[dcl.ZIndex] then
				clash = true
			end
			z[dcl.ZIndex] = true
		end
		if clash then
			plan("DECAL_FIGHT", name(p) .. " has " .. #list .. " decals on " .. face.Name .. " with the same ZIndex -> spread ZIndex", function()
				for k, dcl in list do
					dcl.ZIndex = k
				end
			end)
		end
	end
end

table.sort(lodCandidates, function(a, b)
	return maxDim(a.Size) > maxDim(b.Size)
end)
for k, mp in lodCandidates do
	if k > CONFIG.LOD_MAX_COUNT then
		plan("LOD_POP", (#lodCandidates - CONFIG.LOD_MAX_COUNT) .. " more large meshes left on automatic LOD (budget)")
		break
	end
	plan("LOD_POP", name(mp) .. string.format(" (%.0f studs) pops detail as the camera moves -> RenderFidelity=Precise", maxDim(mp.Size)), function()
		mp.RenderFidelity = Enum.RenderFidelity.Precise
	end)
end

------------------------------------------------------------------ STREAM_POP
if workspace.StreamingEnabled then
	local landmarks = CONFIG.ROOT:FindFirstChild("Landmarks")
	local list: { Model } = {}
	if landmarks then
		for _, c in landmarks:GetChildren() do
			if c:IsA("Model") then
				table.insert(list, c)
			end
		end
	end
	for _, t in CollectionService:GetTagged("Landmark") do
		if t:IsA("Model") then
			table.insert(list, t)
		end
	end
	for _, m in list do
		if m.ModelStreamingMode ~= Enum.ModelStreamingMode.Persistent then
			plan("STREAM_POP", name(m) .. " landmark can stream out and pop back -> Persistent", function()
				m.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
			end)
		end
	end
	if workspace.StreamingTargetRadius < 512 then
		plan("STREAM_POP", string.format("StreamingTargetRadius %d is short — distant scenery will pop; consider 1024+", workspace.StreamingTargetRadius))
	end
end

------------------------------------------------------------------ camera sweep (simulated third-person camera)
do
	local points: { Vector3 } = {}
	local wp = CONFIG.WAYPOINTS or CONFIG.ROOT:FindFirstChild("_Waypoints")
	if wp then
		local list = wp:GetChildren()
		table.sort(list, function(a, b)
			return a.Name < b.Name
		end)
		local prev: Vector3? = nil
		for _, w in list do
			if w:IsA("BasePart") then
				if prev then
					local steps = math.max(1, math.floor((w.Position - prev).Magnitude / 12))
					for s = 1, steps do
						table.insert(points, prev:Lerp(w.Position, s / steps))
					end
				else
					table.insert(points, w.Position)
				end
				prev = w.Position
			end
		end
	end
	for _, d in workspace:GetDescendants() do
		if d:IsA("SpawnLocation") then
			table.insert(points, d.Position + Vector3.new(0, d.Size.Y / 2, 0))
		end
	end
	local occluders: { [BasePart]: number } = {}
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { CONFIG.ROOT }
	for _, pt in points do
		local head = pt + Vector3.new(0, 4.5, 0)
		for k = 0, 7 do
			local yaw = k * math.pi / 4
			local dir = Vector3.new(math.sin(yaw), 0.35, math.cos(yaw)).Unit * CONFIG.CAMERA_DIST
			local hit = workspace:Raycast(head, dir, rp)
			if hit and hit.Instance:IsA("BasePart") then
				local p = hit.Instance :: BasePart
				if p.CanCollide and p.Transparency < 0.25 then
					occluders[p] = (occluders[p] or 0) + 1
				end
			end
		end
	end
	local nPts = #points
	if nPts == 0 then
		plan("CAMERA_SNAP", "camera sweep skipped: add Map._Waypoints (parts named 01, 02, ... along the player path) or SpawnLocations")
	else
		for p, n in occluders do
			if not claimed[p] and not dead[p] then
				local thin = math.min(p.Size.X, p.Size.Y, p.Size.Z) < 1.5
				if isDecor(p) or (thin and maxDim(p.Size) < 12) then
					plan("CAMERA_SNAP", name(p) .. " blocks the camera in " .. n .. " sweep views -> CanCollide=false", function()
						p.CanCollide = false
						p.CanQuery = false
					end, p)
				elseif n >= 3 then
					plan("MANUAL", name(p) .. " blocks the camera in " .. n .. " sweep views — widen the path, lower/move it, or accept (it's structural)")
				end
			end
		end
	end
end

------------------------------------------------------------------ report / apply
local order = {
	"Z_FIGHT", "SEAM", "DECAL_FIGHT", "TRANSPARENT_SORT", "LOD_POP", "TINY_SHADOW", "STREAM_POP", "FAR_FROM_ORIGIN",
	"CAMERA_SNAP", "THIN_WALL", "EXACT_DUPLICATE", "HIDDEN_INSIDE", "OVERLAP", "FLOATING", "CLONE_STAMP",
	"UNANCHORED", "LOOSE_ASSEMBLY", "BELOW_KILL_PLANE", "MANUAL",
}
local byCat: { [string]: { Action } } = {}
for _, a in actions do
	byCat[a.cat] = byCat[a.cat] or {}
	table.insert(byCat[a.cat], a)
end

local fixable, reportOnly = 0, 0
for _, a in actions do
	if a.fn then
		fixable += 1
	else
		reportOnly += 1
	end
end
print(string.format("=== FIX MAP %s: %d auto-fixable, %d need a decision (%s) ===",
	name(CONFIG.ROOT), fixable, reportOnly, CONFIG.APPLY and "APPLYING" or "dry run"))
for _, cat in order do
	local list = byCat[cat]
	if list then
		print(string.format("--- %s (%d)", cat, #list))
		for k, a in list do
			if k > CONFIG.MAX_LINES then
				print(string.format("  ... %d more", #list - CONFIG.MAX_LINES))
				break
			end
			print((a.fn and "  [fix] " or "  [ask] ") .. a.msg)
		end
	end
end

if CONFIG.APPLY and fixable > 0 then
	local rec = CHS:TryBeginRecording("fix_map")
	local okN, errN = 0, 0
	local stamp = DateTime.now():ToIsoDate()
	for _, a in actions do
		if a.fn then
			local ok, err = pcall(a.fn)
			if ok then
				okN += 1
			else
				errN += 1
				warn("fix failed (" .. a.cat .. "): " .. a.msg .. " :: " .. tostring(err))
			end
		end
	end
	for inst, cat in claimed do
		if inst.Parent then
			inst:SetAttribute("MD_Fixed", cat .. " " .. stamp)
		end
	end
	if rec then
		CHS:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
	end
	print(string.format("APPLIED %d fixes (%d failed). One undo step: 'fix_map'. Now re-run audit_map.luau and fix_map until clean.", okN, errN))
elseif fixable > 0 then
	print("Nothing changed. Set CONFIG.APPLY = true to apply the [fix] items.")
else
	print(reportOnly == 0 and "RESULT: nothing to fix" or "RESULT: only [ask] items left — decide on them with the user")
end
