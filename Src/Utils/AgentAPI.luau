--!nonstrict
--[[
	rh-farm fork — Agent API + machine-readable capture.

	Adds three things the upstream tool lacks, for driving Cobalt from an AI agent / the bridge:
	  1. PERSISTENT per-remote ignore — the upstream ignore list (right-click -> Ignore) is in-memory
	     only, so you re-ignore every injection. Here the ignore set saves to Cobalt/Settings.json
	     (PersistentIgnores) and is restored onto each Log as it's created. Toggling ignore in the UI
	     or via this API persists automatically.
	  2. MACHINE-READABLE export — dump the live capture (wax.shared.Logs) to compact JSON
	     (Cobalt/Export/*.json) instead of the giant human-oriented .log files, so the agent can query
	     captured remotes programmatically.
	  3. A programmatic API on getgenv().CobaltAgent so the agent/bridge can set farm-tuned filters,
	     ignore/show remotes, snapshot logs, and clear the view — all persisted.

	Everything routes through SaveManager (Cobalt/Settings.json), so decisions survive re-injection
	and are visible/editable in the Settings > Ignored Remotes UI.
]]

local FileHelper = require("@src/Utils/FileHelper")

local AgentAPI = {}

local IGNORE_KEY = "PersistentIgnores" -- SaveManager key: { [remotePath: string]: true }

local function SaveManager()
	return wax.shared.SaveManager
end

-- Stable identity for a remote across sessions: its full instance path (falls back to name for nil
-- or unreachable parents). This is what we persist + match on.
local function RemoteKey(instance): string
	if typeof(instance) ~= "Instance" then
		return tostring(instance)
	end
	local ok, full = pcall(function()
		return instance:GetFullName()
	end)
	if ok and type(full) == "string" and full ~= "" then
		return full
	end
	return instance.Name
end
AgentAPI.RemoteKey = RemoteKey

local function LoadIgnores(): { [string]: boolean }
	local set = SaveManager():GetState(IGNORE_KEY)
	if type(set) ~= "table" then
		return {}
	end
	return set
end

local function StoreIgnores(set: { [string]: boolean })
	pcall(function()
		SaveManager():SetState(IGNORE_KEY, set)
	end)
end

--// Persistence hooks (called from Log.luau + init) ///////////////////////////////////////////////

-- Is this remote in the persisted ignore set?
function AgentAPI.IsIgnored(instance): boolean
	return LoadIgnores()[RemoteKey(instance)] == true
end

-- Persist an ignore decision for a remote (called from Log:Ignore so UI + right-click persist).
function AgentAPI.SetIgnored(instance, ignored: boolean)
	local set = LoadIgnores()
	local key = RemoteKey(instance)
	if ignored then
		set[key] = true
	else
		set[key] = nil
	end
	StoreIgnores(set)
end

-- Apply the persisted ignore state onto a freshly-created Log (called from wax.shared.NewLog). Also
-- surfaces it in the Settings > Ignored Remotes list so the operator can see + toggle it.
function AgentAPI.RestoreLog(log)
	if not log or not log.Instance then
		return
	end
	if LoadIgnores()[RemoteKey(log.Instance)] then
		log.Ignored = true
		local list = wax.shared.Settings and wax.shared.Settings["IgnoredRemotes"]
		if list and list.AddToList then
			pcall(function()
				list:AddToList({ Instance = log.Instance, Type = log.Type })
			end)
		end
	end
end

--// Programmatic API (getgenv().CobaltAgent) //////////////////////////////////////////////////////

-- Live Logs whose remote matches a name or path substring.
local function MatchingLogs(nameOrPath: string)
	local out = {}
	for _, category in pairs(wax.shared.Logs or {}) do
		for instance, log in pairs(category) do
			if typeof(instance) == "Instance" then
				local key = RemoteKey(instance)
				if instance.Name == nameOrPath or key == nameOrPath or string.find(key, nameOrPath, 1, true) then
					out[#out + 1] = log
				end
			end
		end
	end
	return out
end

-- Ignore a remote by name or full path. Persists + applies to any live Logs. Returns how many live
-- Logs matched (0 still persists the key so it takes effect when the remote next appears).
function AgentAPI.IgnoreRemote(nameOrPath: string): number
	local set = LoadIgnores()
	local matched = 0
	for _, log in ipairs(MatchingLogs(nameOrPath)) do
		log.Ignored = true
		set[RemoteKey(log.Instance)] = true
		matched += 1
	end
	if matched == 0 then
		set[nameOrPath] = true
	end
	StoreIgnores(set)
	return matched
end

-- Un-ignore (show) a remote by name or path. Persists the removal.
function AgentAPI.ShowRemote(nameOrPath: string): number
	local set = LoadIgnores()
	local matched = 0
	for _, log in ipairs(MatchingLogs(nameOrPath)) do
		log.Ignored = false
		set[RemoteKey(log.Instance)] = nil
		matched += 1
	end
	set[nameOrPath] = nil
	StoreIgnores(set)
	return matched
end

-- The full persisted ignore list (keys), sorted.
function AgentAPI.ListIgnored(): { string }
	local out = {}
	for key in pairs(LoadIgnores()) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

-- Bulk-set the farm-tuned ignore list (replaces the persisted set with `keys`).
function AgentAPI.SetIgnoreList(keys: { string })
	local set = {}
	for _, key in ipairs(keys) do
		set[key] = true
	end
	StoreIgnores(set)
	-- apply to live logs
	for _, category in pairs(wax.shared.Logs or {}) do
		for instance, log in pairs(category) do
			if typeof(instance) == "Instance" then
				log.Ignored = set[RemoteKey(instance)] == true
			end
		end
	end
	return #keys
end

--// Machine-readable capture ///////////////////////////////////////////////////////////////////////

-- Convert an arbitrary captured value into something JSON-safe (instances -> path, functions ->
-- marker, tables -> recursive with a depth cap). Keeps the agent-facing JSON small + parseable.
local function SafeValue(value, depth: number)
	local t = typeof(value)
	if t == "Instance" then
		return { __instance = RemoteKey(value), class = value.ClassName }
	elseif t == "table" then
		if depth > 5 then
			return "<table:deep>"
		end
		local out = {}
		local count = 0
		for k, v in pairs(value) do
			if k == "n" then
				continue
			end
			if type(k) == "string" or type(k) == "number" then
				out[tostring(k)] = SafeValue(v, depth + 1)
				count += 1
				if count > 64 then
					out["__truncated"] = true
					break
				end
			end
		end
		return out
	elseif t == "string" or t == "number" or t == "boolean" then
		return value
	elseif t == "nil" then
		return nil
	end
	return tostring(value)
end

-- Snapshot the live capture as a plain table. opts.maxCallsPerRemote caps calls per remote (newest).
function AgentAPI.GetLogs(opts): { any }
	opts = opts or {}
	local maxCalls = opts.maxCallsPerRemote or 40
	local out = {}
	for direction, category in pairs(wax.shared.Logs or {}) do
		for instance, log in pairs(category) do
			if typeof(instance) ~= "Instance" then
				continue
			end
			local total = #log.Calls
			if total == 0 and opts.skipEmpty ~= false then
				-- keep remotes with 0 calls only if explicitly asked (default: skip)
			end
			local calls = {}
			local startIndex = math.max(1, total - maxCalls + 1)
			for i = startIndex, total do
				local call = log.Calls[i]
				local args = {}
				local rawArgs = call.Arguments
				if type(rawArgs) == "table" then
					local n = rawArgs.n or #rawArgs
					for j = 1, n do
						args[j] = SafeValue(rawArgs[j], 0)
					end
				end
				calls[#calls + 1] = {
					index = i,
					time = call.CreationTime,
					blocked = call.Blocked or false,
					isExecutor = call.IsExecutor or false,
					args = args,
				}
			end
			out[#out + 1] = {
				remote = RemoteKey(instance),
				name = instance.Name,
				class = instance.ClassName,
				direction = direction,
				ignored = log.Ignored or false,
				callCount = total,
				calls = calls,
			}
		end
	end
	return out
end

-- Write the capture snapshot to Cobalt/Export/*.json. Returns (path, remoteCount).
function AgentAPI.ExportLogs(fileName: string?, opts): (string?, number)
	local snapshot = AgentAPI.GetLogs(opts)
	local ok, json = pcall(function()
		return wax.shared.HttpService:JSONEncode({
			exportedAt = os.time(),
			executor = wax.shared.ExecutorName,
			remoteCount = #snapshot,
			remotes = snapshot,
		})
	end)
	if not ok then
		return nil, 0
	end
	local name = fileName or ("cobalt-" .. os.time() .. ".json")
	local helper = FileHelper.new("Cobalt/Export")
	local written = pcall(function()
		helper:WriteFile(name, json)
	end)
	if not written then
		return nil, #snapshot
	end
	return "Cobalt/Export/" .. name, #snapshot
end

-- Seed the farm-tuned noise filter: ignore the high-frequency UI/needs/animation remotes that bury
-- the signal (schedule/class/reward remotes are deliberately NOT here). Merges into the persisted
-- set, so operator overrides stick. Returns how many patterns were added. Callable from the agent.
local FARM_NOISE = {
	"UpdateHygieneBar", "UpdateEnergy", "UpdateHunger", "UpdateHealthBar",
	"ToggleButterflyVisibility", "StartTrackingButterfly",
	"LocalSoundHelper", "TeleportBubbles", "SlideAnnouncementFrame",
	"SetBottomTabTimer", "SetBottomTabText",
	"DiamondPickupLocalAnimation", "ClientsidedAnimation", "ClientsidedAnimations",
	"TriggerLevelUpAnimation",
}
function AgentAPI.SetFarmDefaults(): number
	local added = 0
	for _, pattern in ipairs(FARM_NOISE) do
		AgentAPI.IgnoreRemote(pattern)
		added += 1
	end
	if wax.shared.Sonner then
		pcall(wax.shared.Sonner.info, `Applied farm noise filter ({added} patterns)`)
	end
	return added
end

-- Clear the captured-call view (all remotes, or a specific instance/direction). Refreshes the UI.
function AgentAPI.ClearLogs(instance, direction)
	if wax.shared.ClearLogs then
		pcall(wax.shared.ClearLogs, instance, direction)
		return true
	end
	-- fallback: clear the store directly
	for _, category in pairs(wax.shared.Logs or {}) do
		for _, log in pairs(category) do
			log:ClearCalls()
		end
	end
	return true
end

return AgentAPI
