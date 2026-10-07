--[[
	memory.luau — the map remembers what was built, inside the place file itself.

	Stored in ServerStorage.MapDesignMemory (saved with the .rbxl / published place):
	  Brief    StringValue  design brief + palette (markdown text)
	  Log      StringValue  JSON array of build entries (last 300 kept)
	  Cameras  Folder       CFrameValues = named camera bookmarks for render views
	Every instance Claude builds gets attributes MD_Zone, MD_Step, MD_Session, MD_By
	so "what did we build where" can be answered from the place itself.

	Paste into Studio MCP `run_code` with CONFIG.ACTION set:
	  "read"       print brief, recent log, cameras, inventory   (start of every session)
	  "log"        append CONFIG.ENTRY to the log
	  "tag"        stamp attributes on CONFIG.TARGETS (and descendants)
	  "inventory"  count tagged instances by zone/step
	  "brief"      replace the brief with CONFIG.BRIEF
	  "camera_save"  save the current Studio camera as CONFIG.CAMERA
	  "camera_go"    move the Studio camera to bookmark CONFIG.CAMERA (for viewport captures)
	The repo-side twin is map-memory/ (MAP_MEMORY.md + assets.json); keep both in sync.
]]

local CONFIG = {
	ACTION = "read",
	ROOT = workspace:FindFirstChild("Map") or workspace,
	SESSION = "", -- e.g. "2026-10-07 dock pass"
	ENTRY = {
		step = "dress", -- brief | blockout | assets | dress | scatter | light | audit | fix
		zone = "Docks",
		summary = "Placed pier, 3 boat variants, crate clusters; audit clean",
		created = {} :: { string }, -- full names of new top-level instances
		audit = "", -- e.g. "OVERLAP 0, CLONE_STAMP 0, FLOATING 0"
	},
	TARGETS = {} :: { Instance },
	BRIEF = "",
	CAMERA = "Spawn_Hero",
	LOG_LINES = 15,
}

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local mem = ServerStorage:FindFirstChild("MapDesignMemory")
if not mem then
	mem = Instance.new("Folder")
	mem.Name = "MapDesignMemory"
	mem.Parent = ServerStorage
end
local function value(name: string): StringValue
	local v = mem:FindFirstChild(name)
	if not v then
		v = Instance.new("StringValue")
		v.Name = name
		v.Parent = mem
	end
	return v :: StringValue
end
local cams = mem:FindFirstChild("Cameras")
if not cams then
	cams = Instance.new("Folder")
	cams.Name = "Cameras"
	cams.Parent = mem
end

local function loadLog(): { any }
	local raw = value("Log").Value
	if raw == "" then
		return {}
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	return ok and data or {}
end

local function saveLog(log: { any })
	while #log > 300 do
		table.remove(log, 1)
	end
	local raw = HttpService:JSONEncode(log)
	while #raw > 190000 and #log > 1 do -- StringValue limit ~200k chars
		table.remove(log, 1)
		raw = HttpService:JSONEncode(log)
	end
	value("Log").Value = raw
end

local function inventory()
	local byZone: { [string]: { [string]: number } } = {}
	local total = 0
	for _, d in CONFIG.ROOT:GetDescendants() do
		local zone = d:GetAttribute("MD_Zone")
		if zone and (d:IsA("Model") or d:IsA("BasePart") or d:IsA("Folder")) then
			local step = d:GetAttribute("MD_Step") or "?"
			byZone[zone] = byZone[zone] or {}
			byZone[zone][step] = (byZone[zone][step] or 0) + 1
			total += 1
		end
	end
	print(string.format("INVENTORY: %d tagged instances under %s", total, CONFIG.ROOT:GetFullName()))
	for zone, steps in byZone do
		local parts = {}
		for step, n in steps do
			table.insert(parts, step .. "=" .. n)
		end
		table.sort(parts)
		print(string.format("  %-20s %s", zone, table.concat(parts, "  ")))
	end
end

local A = CONFIG.ACTION
if A == "read" then
	local brief = value("Brief").Value
	print("=== MAP MEMORY ===")
	print(brief ~= "" and brief or "(no brief stored yet — write one and save it with ACTION='brief')")
	local log = loadLog()
	print(string.format("--- log: %d entries (showing last %d)", #log, math.min(#log, CONFIG.LOG_LINES)))
	for i = math.max(1, #log - CONFIG.LOG_LINES + 1), #log do
		local e = log[i]
		print(string.format("  [%s] %s/%s: %s%s", e.time or "?", e.zone or "-", e.step or "-", e.summary or "",
			(e.audit and e.audit ~= "") and ("  | audit: " .. e.audit) or ""))
	end
	local names = {}
	for _, c in cams:GetChildren() do
		table.insert(names, c.Name)
	end
	print("--- camera bookmarks: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
	inventory()
elseif A == "log" then
	local log = loadLog()
	local e = table.clone(CONFIG.ENTRY)
	e.time = DateTime.now():ToIsoDate()
	e.session = CONFIG.SESSION
	table.insert(log, e)
	saveLog(log)
	print("logged entry #" .. #log)
elseif A == "tag" then
	local n = 0
	local stamp = DateTime.now():ToIsoDate()
	for _, t in CONFIG.TARGETS do
		for _, inst in { t, table.unpack(t:GetDescendants()) } do
			if inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder") then
				inst:SetAttribute("MD_Zone", CONFIG.ENTRY.zone)
				inst:SetAttribute("MD_Step", CONFIG.ENTRY.step)
				inst:SetAttribute("MD_Session", CONFIG.SESSION)
				inst:SetAttribute("MD_By", "claude")
				inst:SetAttribute("MD_Time", stamp)
				n += 1
			end
		end
	end
	print("tagged " .. n .. " instances")
elseif A == "inventory" then
	inventory()
elseif A == "brief" then
	value("Brief").Value = CONFIG.BRIEF
	print("brief saved (" .. #CONFIG.BRIEF .. " chars)")
elseif A == "camera_save" then
	local cam = workspace.CurrentCamera
	local v = cams:FindFirstChild(CONFIG.CAMERA) or Instance.new("CFrameValue")
	v.Name = CONFIG.CAMERA
	v.Value = cam.CFrame
	v:SetAttribute("FieldOfView", cam.FieldOfView)
	v.Parent = cams
	print("saved camera " .. CONFIG.CAMERA)
elseif A == "camera_go" then
	local v = cams:FindFirstChild(CONFIG.CAMERA) :: CFrameValue?
	assert(v, "no camera bookmark " .. CONFIG.CAMERA)
	local cam = workspace.CurrentCamera
	cam.CFrame = v.Value -- edit-mode camera: just move it, leave CameraType alone
	cam.FieldOfView = v:GetAttribute("FieldOfView") or 70
	print("camera at " .. CONFIG.CAMERA)
else
	error("unknown ACTION " .. tostring(A))
end
