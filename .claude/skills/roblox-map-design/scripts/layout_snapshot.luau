--[[
	layout_snapshot.luau — background "render view" of a Roblox map as a top-down plan.

	Runs through Studio MCP `run_code`; casts a grid of rays straight down (no
	camera, no window focus, no desktop screenshot) and prints a compact
	colour + height grid. Save the printed block to a file and turn it into a PNG:

	    python3 scripts/render_layout.py snapshot.txt -o renders/plan.png

	then open the PNG with the Read tool. Good for checking layout, path widths,
	spacing/clumping of scatter, negative space, and repeated patterns from above.

	Decoration with CanQuery=false is temporarily made queryable so it shows up,
	then restored. Nothing else is changed.
]]

local CONFIG = {
	ROOT = workspace:FindFirstChild("Map") or workspace,
	CELLS = 64, -- grid resolution (64 -> ~20 KB of output; 96 max recommended)
	REGION = nil :: { center: Vector3, size: Vector2 }?, -- nil = bounds of ROOT
	INCLUDE_TERRAIN = true,
}

local parts: { BasePart } = {}
for _, d in CONFIG.ROOT:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") then
		table.insert(parts, d)
	end
end

local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
local minY, maxY = math.huge, -math.huge
if CONFIG.REGION then
	local c, s = CONFIG.REGION.center, CONFIG.REGION.size
	minX, maxX, minZ, maxZ = c.X - s.X / 2, c.X + s.X / 2, c.Z - s.Y / 2, c.Z + s.Y / 2
	minY, maxY = c.Y - 500, c.Y + 500
else
	for _, p in parts do
		local h = p.Size / 2
		local cf = p.CFrame
		local ex = math.abs(cf.RightVector.X) * h.X + math.abs(cf.UpVector.X) * h.Y + math.abs(cf.LookVector.X) * h.Z
		local ey = math.abs(cf.RightVector.Y) * h.X + math.abs(cf.UpVector.Y) * h.Y + math.abs(cf.LookVector.Y) * h.Z
		local ez = math.abs(cf.RightVector.Z) * h.X + math.abs(cf.UpVector.Z) * h.Y + math.abs(cf.LookVector.Z) * h.Z
		minX, maxX = math.min(minX, cf.X - ex), math.max(maxX, cf.X + ex)
		minZ, maxZ = math.min(minZ, cf.Z - ez), math.max(maxZ, cf.Z + ez)
		minY, maxY = math.min(minY, cf.Y - ey), math.max(maxY, cf.Y + ey)
	end
	if minX == math.huge then
		minX, maxX, minZ, maxZ, minY, maxY = -256, 256, -256, 256, -50, 150
	end
end

-- square cells
local span = math.max(maxX - minX, maxZ - minZ)
local cell = span / CONFIG.CELLS

-- temporarily make everything under ROOT queryable, skip invisible parts
local restore: { [BasePart]: boolean } = {}
local exclude: { Instance } = {}
for _, p in parts do
	if p.Transparency >= 0.95 then
		table.insert(exclude, p)
	elseif not p.CanQuery then
		restore[p] = true
		p.CanQuery = true
	end
end

local rp = RaycastParams.new()
if CONFIG.ROOT == workspace then
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = exclude
else
	rp.FilterType = Enum.RaycastFilterType.Include
	local inc: { Instance } = { CONFIG.ROOT }
	if CONFIG.INCLUDE_TERRAIN then
		table.insert(inc, workspace.Terrain)
	end
	rp.FilterDescendantsInstances = inc
end

local topY = maxY + 50
local hits = table.create(CONFIG.CELLS * CONFIG.CELLS)
local hMin, hMax = math.huge, -math.huge
for row = 0, CONFIG.CELLS - 1 do
	for col = 0, CONFIG.CELLS - 1 do
		local x = minX + (col + 0.5) * cell
		local z = minZ + (row + 0.5) * cell
		local origin = Vector3.new(x, topY, z)
		local dir = Vector3.new(0, -(topY - minY + 200), 0)
		local res = workspace:Raycast(origin, dir, rp)
		-- step through fully transparent parts when ROOT == workspace (Include mode already skips others)
		local guard = 0
		while res and res.Instance:IsA("BasePart") and res.Instance.Transparency >= 0.95 and guard < 8 do
			guard += 1
			origin = res.Position - Vector3.new(0, 0.05, 0)
			res = workspace:Raycast(origin, dir, rp)
		end
		if res then
			local color: Color3
			if res.Instance:IsA("Terrain") then
				color = workspace.Terrain:GetMaterialColor(res.Material)
			else
				color = (res.Instance :: BasePart).Color
			end
			hits[row * CONFIG.CELLS + col + 1] = { color, res.Position.Y }
			hMin, hMax = math.min(hMin, res.Position.Y), math.max(hMax, res.Position.Y)
		else
			hits[row * CONFIG.CELLS + col + 1] = false
		end
	end
end

for p in restore do
	p.CanQuery = false
end

if hMin == math.huge then
	hMin, hMax = 0, 1
end
local hRange = math.max(hMax - hMin, 1e-3)

print(string.format(
	'LAYOUT {"cells":%d,"minX":%.2f,"minZ":%.2f,"cell":%.3f,"hMin":%.2f,"hMax":%.2f,"root":"%s"}',
	CONFIG.CELLS, minX, minZ, cell, hMin, hMax, CONFIG.ROOT:GetFullName()
))
for row = 0, CONFIG.CELLS - 1 do
	local buf = table.create(CONFIG.CELLS)
	for col = 0, CONFIG.CELLS - 1 do
		local h = hits[row * CONFIG.CELLS + col + 1]
		if h then
			local c: Color3 = h[1]
			buf[col + 1] = string.format(
				"%x%x%x%02x",
				math.floor(c.R * 15 + 0.5), math.floor(c.G * 15 + 0.5), math.floor(c.B * 15 + 0.5),
				math.floor((h[2] - hMin) / hRange * 255 + 0.5)
			)
		else
			buf[col + 1] = "....."
		end
	end
	print(table.concat(buf))
end
print("END_LAYOUT")
