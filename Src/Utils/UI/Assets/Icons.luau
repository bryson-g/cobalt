--!nonstrict
--[[
	rh-farm fork — lucide icon data loader.

	Upstream fetched this from a single third-party raw URL with no retry and no cache, and
	SetIcon returned silently when it failed — so when that repo was DELETED (2026-07-24, 404),
	every icon in the UI went blank with no error, while text and the logo still rendered.

	Three changes so that can't happen again:
	  1. The data is VENDORED in this fork (Assets/lucide.lua) and listed first, so the primary
	     source is one we control rather than someone else's repo.
	  2. A successful load is cached to Cobalt/Cache/lucide.lua and preferred on later injections —
	     after the first fetch, icons work with no network at all.
	  3. If every source fails we say so ONCE, instead of silently rendering blank buttons.
]]

local FileHelper = require("@src/Utils/FileHelper")

local Icons = {}

type Icon = {
	Url: string,
	Id: number,
	IconName: string,
	ImageRectOffset: Vector2,
	ImageRectSize: Vector2,
}

local CACHE_DIR = "Cobalt/Cache"
local CACHE_FILE = "lucide.lua"

-- Ours first; the rest are mirrors, in case the vendored copy is ever unreachable.
local SOURCES = {
	"https://raw.githubusercontent.com/bryson-g/cobalt/main/Assets/lucide.lua",
	"https://raw.githubusercontent.com/infyiff/backup/main/misc/lucide.lua",
	"https://raw.githubusercontent.com/TexRBLX/Roblox-stuff/main/lucide.lua",
}

-- A module is only usable if it exposes GetAsset; anything else (an error page, a truncated
-- download, a repo that now serves something different) is rejected rather than half-loaded.
local function LoadModule(source: string)
	if type(source) ~= "string" or source == "" then
		return nil
	end
	local ok, module = pcall(function()
		local chunk = loadstring(source)
		return chunk and chunk() or nil
	end)
	if ok and type(module) == "table" and type(module.GetAsset) == "function" then
		return module
	end
	return nil
end

local IconsModule

do
	-- 1) disk cache — no network, and immune to any of the URLs dying later
	local helper = FileHelper.new(CACHE_DIR)
	local cached = helper:DoesExist(CACHE_FILE) and select(2, pcall(function()
		return helper:ReadFile(CACHE_FILE)
	end)) or nil
	IconsModule = LoadModule(cached)

	-- 2) network sources, caching the first one that actually loads
	if not IconsModule then
		for _, url in ipairs(SOURCES) do
			local ok, response = pcall(request, {
				Url = url,
				Method = "GET",
			})
			local body = ok and response and response.Body
			local status = ok and response and response.StatusCode
			if body and status and status >= 200 and status < 300 then
				local module = LoadModule(body)
				if module then
					IconsModule = module
					pcall(function()
						helper:WriteFile(CACHE_FILE, body)
					end)
					break
				end
			end
		end
	end
end

local WarnedUnavailable = false
local function WarnOnce()
	if WarnedUnavailable then
		return
	end
	WarnedUnavailable = true
	warn("[Cobalt·rh] icon data unavailable — every icon source failed; buttons will render without icons")
	task.defer(function()
		if wax.shared.Sonner then
			pcall(wax.shared.Sonner.warning, "Icons unavailable (all sources failed) — buttons still work")
		end
	end)
end

--- Is icon data loaded at all? Useful for diagnosing "why is the UI blank".
function Icons.IsAvailable(): boolean
	return IconsModule ~= nil
end

function Icons.GetIcon(iconName: string): Icon?
	if not IconsModule then
		WarnOnce()
		return nil
	end

	local ok, icon = pcall(IconsModule.GetAsset, iconName)
	if not ok then
		return nil
	end
	return icon
end

function Icons.SetIcon(imageInstance: ImageLabel, iconName: string)
	local Icon: Icon? = Icons.GetIcon(iconName)
	if not Icon then
		return
	end

	imageInstance.Image = Icon.Url
	imageInstance.ImageRectOffset = Icon.ImageRectOffset
	imageInstance.ImageRectSize = Icon.ImageRectSize
end

return Icons
