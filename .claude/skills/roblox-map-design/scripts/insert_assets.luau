--[[
	insert_assets.luau — pull uploaded Blender assets into Studio automatically.

	Normally you don't edit this file: upload_to_roblox.py writes
	map-memory/insert_assets.generated.luau with ASSETS filled in. Send that file
	through Studio MCP `run_code`.

	model    -> InsertService:LoadAsset(id), rescaled to the Blender size if the
	            importer changed units, pivot set to base centre, decor-friendly
	            physics flags, stored in ServerStorage.ScatterKit/<Family>/<Name>
	            (which is exactly where scatter.luau looks for variants).
	material -> each Decal id resolved to its image id, then a MaterialVariant in
	            MaterialService (ColorMap/NormalMap/RoughnessMap/MetalnessMap).
	Already-inserted assets (same assetId) are skipped, so re-running is safe.
]]

local ASSETS = {} -- @@ASSETS@@ filled in by upload_to_roblox.py

local KIT_PARENT = game:GetService("ServerStorage")
local KIT_NAME = "ScatterKit"

local InsertService = game:GetService("InsertService")
local MaterialService = game:GetService("MaterialService")
local CHS = game:GetService("ChangeHistoryService")

local kit = KIT_PARENT:FindFirstChild(KIT_NAME)
if not kit then
	kit = Instance.new("Folder")
	kit.Name = KIT_NAME
	kit.Parent = KIT_PARENT
end

local function folder(parent: Instance, name: string): Instance
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

local function load(id: number): Instance?
	local ok, res = pcall(InsertService.LoadAsset, InsertService, id)
	if not ok then
		warn(string.format("LoadAsset(%d) failed: %s (still in moderation, or not owned by this account/group?)", id, tostring(res)))
		return nil
	end
	return res
end

local rec = CHS:TryBeginRecording("Insert map assets")
local added, skipped, failed = 0, 0, 0

for _, a in ASSETS do
	if a.kind == "model" then
		local famFolder = folder(kit, a.family)
		local existing = famFolder:FindFirstChild(a.name)
		if existing and existing:GetAttribute("MD_AssetId") == a.assetId then
			skipped += 1
			continue
		end
		local container = load(a.assetId)
		if not container then
			failed += 1
			continue
		end
		-- normalise to a Model named after the asset
		local model = Instance.new("Model")
		model.Name = a.name
		for _, c in container:GetChildren() do
			if c:IsA("Model") then
				for _, cc in c:GetChildren() do
					cc.Parent = model
				end
			else
				c.Parent = model
			end
		end
		container:Destroy()

		-- fix units: match the size Blender reported
		local cf, size = model:GetBoundingBox()
		if a.size and a.size.Y > 0 and size.Y > 0 then
			local factor = a.size.Y / size.Y
			if math.abs(factor - 1) > 0.02 then
				model:ScaleTo(factor)
				cf, size = model:GetBoundingBox()
			end
		end
		-- pivot at the base centre, sitting on y = 0
		model.WorldPivot = cf * CFrame.new(0, -size.Y / 2, 0)
		model:PivotTo(CFrame.new())

		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanTouch = false
				if p:IsA("MeshPart") then
					p.CollisionFidelity = Enum.CollisionFidelity.Hull
				end
			end
		end
		model:SetAttribute("MD_AssetId", a.assetId)
		model:SetAttribute("MD_SourceSha1", a.sha1)
		model:SetAttribute("MD_By", "claude")
		if existing then
			existing:Destroy() -- older version of the same asset
		end
		model.Parent = famFolder
		added += 1
		print(string.format("+ %s/%s  (%d)  size %.1f x %.1f x %.1f", a.family, a.name, a.assetId, size.X, size.Y, size.Z))
	elseif a.kind == "material" then
		local mv = MaterialService:FindFirstChild(a.name)
		if not mv then
			mv = Instance.new("MaterialVariant")
			mv.Name = a.name
		end
		local okBase, base = pcall(function()
			return Enum.Material[a.base]
		end)
		mv.BaseMaterial = okBase and base or Enum.Material.Slate
		mv.StudsPerTile = a.studsPerTile or 8
		local props = { color = "ColorMap", normal = "NormalMap", roughness = "RoughnessMap", metalness = "MetalnessMap" }
		for kind, decalId in a.maps do
			local container = load(decalId)
			local decal = container and container:FindFirstChildWhichIsA("Decal", true)
			if decal then
				(mv :: any)[props[kind]] = decal.Texture -- the underlying image id
			else
				failed += 1
				warn("could not resolve decal " .. tostring(decalId) .. " for " .. a.name .. "_" .. kind)
			end
			if container then
				container:Destroy()
			end
		end
		mv:SetAttribute("MD_By", "claude")
		mv.Parent = MaterialService
		added += 1
		print(string.format("+ MaterialVariant %s (base %s, %d studs/tile)", a.name, mv.BaseMaterial.Name, mv.StudsPerTile))
	end
end

if rec then
	CHS:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
end
print(string.format("INSERT: %d added, %d unchanged, %d failed. Variants live in %s", added, skipped, failed, kit:GetFullName()))
print("Use a MaterialVariant by setting part.Material = its BaseMaterial and part.MaterialVariant = its Name.")
