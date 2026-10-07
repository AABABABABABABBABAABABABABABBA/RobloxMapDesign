--[[
	audit_map.luau — "no slop" audit for a Roblox map.

	Paste the whole file into the Studio MCP `run_code` tool (or the Studio command bar).
	Edit CONFIG first. Read-only except for Selection (if SELECT_OFFENDERS = true).

	Categories reported:
	  OVERLAP          two parts interpenetrate deeper than OVERLAP_TOL (box/OBB test)
	  EXACT_DUPLICATE  identical copies stacked on the same CFrame & size
	  Z_FIGHT          coplanar, same-facing, overlapping faces with differing looks
	  CLONE_STAMP      same asset, same rotation + scale + colour, within CLONE_RADIUS
	  GRID_PATTERN     same asset placed at suspiciously uniform spacing
	  FLOATING         a prop that touches nothing (not grounded / not attached)
	  INFO_SEAMLESS    overlap between same-colour same-material plain blocks (usually OK)

	Opt-outs (CollectionService tags, on the instance or any ancestor):
	  AllowOverlap  – skip OVERLAP for this object (hidden, intentional embedding)
	  AllowFloat    – skip FLOATING (hanging lamps, birds, floating islands)
	  AllowRepeat   – skip CLONE_STAMP / GRID_PATTERN (intentional architecture rhythm)
]]

local CONFIG = {
	ROOT = workspace:FindFirstChild("Map") or workspace,
	OVERLAP_TOL = 0.05, -- studs of penetration allowed
	GROUND_SINK_MAX = 0.6, -- props sunk this far into the surface below count as grounded
	PROP_MAX_SIZE = 30, -- models smaller than this are "props": internal overlaps ignored
	CLONE_RADIUS = 40,
	CLONE_ANGLE_DEG = 5,
	CLONE_SCALE_PCT = 3,
	GRID_MIN_COUNT = 6,
	GRID_CV_MAX = 0.05, -- coefficient of variation of nearest-neighbour distance
	FLOAT_TOL = 0.3,
	MAX_LINES_PER_CATEGORY = 25,
	SELECT_OFFENDERS = true,
	CELL = 16,
}

local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")

local results: { [string]: { string } } = {}
local counts: { [string]: number } = {}
local offenders: { [Instance]: boolean } = {}

local function report(cat: string, msg: string, ...: Instance)
	counts[cat] = (counts[cat] or 0) + 1
	results[cat] = results[cat] or {}
	if #results[cat] < CONFIG.MAX_LINES_PER_CATEGORY then
		table.insert(results[cat], msg)
	end
	if not cat:match("^INFO") then
		for _, inst in { ... } do
			offenders[inst] = true
		end
	end
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

local function shortName(inst: Instance): string
	local full = inst:GetFullName()
	return (full:gsub("^Workspace%.", ""))
end

local function r(x: number, step: number): number
	return math.floor(x / step + 0.5) * step
end

-- outermost Model ancestor that is still a small "prop", or nil
local function propOwner(p: BasePart): Model?
	local best: Model? = nil
	local m = p:FindFirstAncestorWhichIsA("Model")
	while m and m ~= workspace do
		local _, size = m:GetBoundingBox()
		if math.max(size.X, size.Y, size.Z) > CONFIG.PROP_MAX_SIZE then
			break
		end
		best = m
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return best
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

-- faces of a box: list of {normal, offset, inPlaneAxes, halfExtents}
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
	local candidates = { fa.others[1][1], fa.others[2][1], fb.others[1][1], fb.others[2][1] }
	for _, L in candidates do
		local ra = math.abs(L:Dot(fa.others[1][1])) * fa.others[1][2] + math.abs(L:Dot(fa.others[2][1])) * fa.others[2][2]
		local rb = math.abs(L:Dot(fb.others[1][1])) * fb.others[1][2] + math.abs(L:Dot(fb.others[2][1])) * fb.others[2][2]
		if ra + rb - math.abs(d:Dot(L)) <= 0.01 then
			return false
		end
	end
	return true
end

local function isBlock(p: BasePart): boolean
	return p:IsA("Part") and (p :: Part).Shape == Enum.PartType.Block
end

local function looksSame(a: BasePart, b: BasePart): boolean
	return a.Material == b.Material and a.Color == b.Color and a.Transparency == b.Transparency
end

------------------------------------------------------------------ collect
local parts: { BasePart } = {}
for _, d in CONFIG.ROOT:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") and d.Transparency < 1 then
		table.insert(parts, d)
	end
end

------------------------------------------------------------------ EXACT_DUPLICATE
do
	local seen: { [string]: BasePart } = {}
	for _, p in parts do
		local cf = p.CFrame
		local rx, ry, rz = cf:ToOrientation()
		local key = table.concat({
			p.ClassName,
			p:IsA("MeshPart") and (p :: MeshPart).MeshId or "",
			r(cf.X, 0.01), r(cf.Y, 0.01), r(cf.Z, 0.01),
			r(math.deg(rx), 0.5), r(math.deg(ry), 0.5), r(math.deg(rz), 0.5),
			r(p.Size.X, 0.01), r(p.Size.Y, 0.01), r(p.Size.Z, 0.01),
		}, "|")
		local other = seen[key]
		if other then
			report("EXACT_DUPLICATE", shortName(p) .. "  ==  " .. shortName(other), p)
		else
			seen[key] = p
		end
	end
end

------------------------------------------------------------------ OVERLAP + Z_FIGHT (broadphase grid)
do
	local CELL = CONFIG.CELL
	local grid: { [string]: { number } } = {}
	local large: { number } = {}
	local boxes = {}
	for i, p in parts do
		local mn, mx = worldAABB(p.CFrame, p.Size)
		boxes[i] = { mn, mx }
		local x0, y0, z0 = math.floor(mn.X / CELL), math.floor(mn.Y / CELL), math.floor(mn.Z / CELL)
		local x1, y1, z1 = math.floor(mx.X / CELL), math.floor(mx.Y / CELL), math.floor(mx.Z / CELL)
		if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 512 then
			table.insert(large, i)
		else
			for x = x0, x1 do
				for y = y0, y1 do
					for z = z0, z1 do
						local k = x .. "," .. y .. "," .. z
						local cell = grid[k]
						if not cell then
							cell = {}
							grid[k] = cell
						end
						table.insert(cell, i)
					end
				end
			end
		end
	end

	local owners: { [BasePart]: Model | false } = {}
	local function ownerOf(p: BasePart): Model?
		local o = owners[p]
		if o == nil then
			o = propOwner(p) or false
			owners[p] = o
		end
		return if o then o else nil
	end

	local function aabbTouch(i: number, j: number): boolean
		local a, b = boxes[i], boxes[j]
		return a[1].X <= b[2].X + 0.02 and a[2].X >= b[1].X - 0.02
			and a[1].Y <= b[2].Y + 0.02 and a[2].Y >= b[1].Y - 0.02
			and a[1].Z <= b[2].Z + 0.02 and a[2].Z >= b[1].Z - 0.02
	end

	local function checkPair(i: number, j: number)
		if not aabbTouch(i, j) then
			return
		end
		local a, b = parts[i], parts[j]
		local depth, axis = obbDepth(a.CFrame, a.Size, b.CFrame, b.Size)
		if depth < -0.02 then
			return
		end

		-- Z_FIGHT: same-facing coplanar overlapping faces (blocks only, exact geometry)
		if isBlock(a) and isBlock(b) and not looksSame(a, b) then
			local fa, fb = faces(a.CFrame, a.Size), faces(b.CFrame, b.Size)
			for _, f1 in fa do
				for _, f2 in fb do
					if f1.n:Dot(f2.n) > 0.999 and math.abs(f1.off - f2.off) < 0.01 and facesOverlapInPlane(f1, f2) then
						report("Z_FIGHT", shortName(a) .. "  <>  " .. shortName(b), a, b)
						return
					end
				end
			end
		end

		if depth <= CONFIG.OVERLAP_TOL then
			return
		end
		if math.abs(axis.Y) > 0.7 and depth <= CONFIG.GROUND_SINK_MAX then
			return -- grounded: resting on / sunk into the surface below
		end
		local oa, ob = ownerOf(a), ownerOf(b)
		if oa and oa == ob then
			return -- internal construction of a single small prop
		end
		if hasTagUp(a, "AllowOverlap") or hasTagUp(b, "AllowOverlap") then
			return
		end
		local msg = string.format("%s  x  %s  (%.2f studs)", shortName(a), shortName(b), depth)
		if isBlock(a) and isBlock(b) and looksSame(a, b) and not oa and not ob then
			report("INFO_SEAMLESS", msg)
		else
			report("OVERLAP", msg, a, b)
		end
	end

	local isLarge: { [number]: boolean } = {}
	for _, i in large do
		isLarge[i] = true
	end
	for i = 1, #parts do
		if not isLarge[i] then
			local mn, mx = boxes[i][1], boxes[i][2]
			local done: { [number]: boolean } = {}
			for x = math.floor(mn.X / CELL), math.floor(mx.X / CELL) do
				for y = math.floor(mn.Y / CELL), math.floor(mx.Y / CELL) do
					for z = math.floor(mn.Z / CELL), math.floor(mx.Z / CELL) do
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
	-- huge parts (baseplates, terrain slabs) against everything
	for _, L in large do
		for i = 1, #parts do
			if i ~= L and (not isLarge[i] or i > L) then
				checkPair(math.min(i, L), math.max(i, L))
			end
		end
	end
end

------------------------------------------------------------------ placeables (props)
type Placeable = { inst: Instance, cf: CFrame, size: Vector3, asset: string, color: Color3 }
local placeables: { Placeable } = {}

local function largestPart(m: Model): BasePart?
	local best, bv = nil, -1
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bv then
				best, bv = d, v
			end
		end
	end
	return best
end

local function collectPlaceables(container: Instance)
	for _, c in container:GetChildren() do
		if c:IsA("Model") then
			local nParts = 0
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then
					nParts += 1
				end
			end
			local _, size = c:GetBoundingBox()
			if nParts > 0 and math.max(size.X, size.Y, size.Z) <= CONFIG.PROP_MAX_SIZE then
				local lp = largestPart(c)
				table.insert(placeables, {
					inst = c, cf = c:GetPivot(), size = size,
					asset = "M:" .. c.Name .. "#" .. nParts,
					color = lp and lp.Color or Color3.new(),
				})
			else
				collectPlaceables(c) -- big model (building / zone): look inside
			end
		elseif c:IsA("MeshPart") then
			table.insert(placeables, {
				inst = c, cf = c.CFrame, size = c.Size,
				asset = "MP:" .. c.MeshId .. "|" .. c.TextureID,
				color = c.Color,
			})
		elseif c:IsA("Folder") or c:IsA("WorldModel") then
			collectPlaceables(c)
		end
	end
end
collectPlaceables(CONFIG.ROOT)

------------------------------------------------------------------ CLONE_STAMP + GRID_PATTERN
do
	local groups: { [string]: { Placeable } } = {}
	for _, pl in placeables do
		if not hasTagUp(pl.inst, "AllowRepeat") then
			groups[pl.asset] = groups[pl.asset] or {}
			table.insert(groups[pl.asset], pl)
		end
	end
	local cosTol = math.cos(math.rad(CONFIG.CLONE_ANGLE_DEG))
	for asset, list in groups do
		local n = #list
		if n >= 2 and n <= 3000 then
			local nn = table.create(n, math.huge)
			for i = 1, n do
				local a = list[i]
				for j = i + 1, n do
					local b = list[j]
					local dist = (a.cf.Position - b.cf.Position).Magnitude
					if dist < nn[i] then nn[i] = dist end
					if dist < nn[j] then nn[j] = dist end
					if dist <= CONFIG.CLONE_RADIUS then
						local rel = a.cf.Rotation:ToObjectSpace(b.cf.Rotation)
						local _, angle = rel:ToAxisAngle()
						local sameRot = math.cos(angle) >= cosTol
						local sa, sb = a.size.Magnitude, b.size.Magnitude
						local sameScale = math.abs(sa - sb) / math.max(sa, 1e-3) * 100 <= CONFIG.CLONE_SCALE_PCT
						local ca, cb = a.color, b.color
						local sameColor = math.abs(ca.R - cb.R) + math.abs(ca.G - cb.G) + math.abs(ca.B - cb.B) < 0.03
						if sameRot and sameScale and sameColor then
							report("CLONE_STAMP", string.format("%s  ~  %s  (%.0f studs apart)", shortName(a.inst), shortName(b.inst), dist), a.inst, b.inst)
						end
					end
				end
			end
			if n >= CONFIG.GRID_MIN_COUNT then
				local sum, sq = 0, 0
				for i = 1, n do
					sum += nn[i]
				end
				local mean = sum / n
				for i = 1, n do
					sq += (nn[i] - mean) ^ 2
				end
				local cv = math.sqrt(sq / n) / math.max(mean, 1e-3)
				if cv < CONFIG.GRID_CV_MAX then
					report("GRID_PATTERN", string.format("%d x %s  spacing %.1f studs, CV %.3f  (e.g. %s)", n, asset, mean, cv, shortName(list[1].inst)), list[1].inst)
				end
			end
		end
	end
end

------------------------------------------------------------------ FLOATING
do
	for _, pl in placeables do
		if not hasTagUp(pl.inst, "AllowFloat") then
			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { pl.inst }
			local cf, size
			if pl.inst:IsA("Model") then
				cf, size = (pl.inst :: Model):GetBoundingBox()
			else
				cf, size = pl.cf, pl.size
			end
			local touching = workspace:GetPartBoundsInBox(cf, size + Vector3.one * (CONFIG.FLOAT_TOL * 2), params)
			local supported = #touching > 0
			if not supported then
				local rp = RaycastParams.new()
				rp.FilterType = Enum.RaycastFilterType.Exclude
				rp.FilterDescendantsInstances = { pl.inst }
				local mn = worldAABB(cf, size)
				local origin = Vector3.new(cf.X, mn.Y + 0.5, cf.Z)
				local hit = workspace:Raycast(origin, Vector3.new(0, -(0.5 + CONFIG.FLOAT_TOL * 2), 0), rp)
				supported = hit ~= nil
			end
			if not supported then
				report("FLOATING", shortName(pl.inst), pl.inst)
			end
		end
	end
end

------------------------------------------------------------------ output
local order = { "OVERLAP", "EXACT_DUPLICATE", "Z_FIGHT", "CLONE_STAMP", "GRID_PATTERN", "FLOATING", "INFO_SEAMLESS" }
print(string.format("=== MAP AUDIT: %s | %d parts, %d props ===", shortName(CONFIG.ROOT), #parts, #placeables))
local total = 0
for _, cat in order do
	local c = counts[cat] or 0
	if not cat:match("^INFO") then
		total += c
	end
	print(string.format("%-16s %d", cat, c))
end
for _, cat in order do
	local lines = results[cat]
	if lines then
		print("--- " .. cat .. (counts[cat] > #lines and string.format(" (first %d of %d)", #lines, counts[cat]) or ""))
		for _, l in lines do
			print("  " .. l)
		end
	end
end
print(total == 0 and "RESULT: CLEAN" or ("RESULT: " .. total .. " issues to fix"))

if CONFIG.SELECT_OFFENDERS then
	local sel = {}
	for inst in offenders do
		table.insert(sel, inst)
	end
	Selection:Set(sel)
end
