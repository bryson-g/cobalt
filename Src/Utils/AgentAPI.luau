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

-- Query the live capture as a plain table — the agent-facing "query remotes instead of grepping"
-- interface (call it over the bridge). All opts optional:
--   name              substring match on the remote name OR full path (case-insensitive)
--   direction         "Incoming" | "Outgoing"
--   class             match ClassName (e.g. "RemoteEvent")
--   minCalls          only remotes with >= this many calls
--   includeIgnored    default true; set false to hide ignored remotes
--   includeArgs       default true; set false for a lightweight name/count-only listing
--   maxCallsPerRemote cap calls returned per remote (newest first), default 40
--   limit             cap number of remotes returned (after sorting by call count desc)
function AgentAPI.GetLogs(opts): { any }
	opts = opts or {}
	local maxCalls = opts.maxCallsPerRemote or 40
	local nameFilter = opts.name and string.lower(opts.name) or nil
	local out = {}
	for direction, category in pairs(wax.shared.Logs or {}) do
		if opts.direction and direction ~= opts.direction then
			continue
		end
		for instance, log in pairs(category) do
			if typeof(instance) ~= "Instance" then
				continue
			end
			if opts.class and instance.ClassName ~= opts.class then
				continue
			end
			if opts.includeIgnored == false and log.Ignored then
				continue
			end
			local total = #log.Calls
			if opts.minCalls and total < opts.minCalls then
				continue
			end
			local key = RemoteKey(instance)
			if nameFilter and not (string.find(string.lower(instance.Name), nameFilter, 1, true) or string.find(string.lower(key), nameFilter, 1, true)) then
				continue
			end

			local calls = {}
			if opts.includeArgs ~= false then
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
			end

			out[#out + 1] = {
				remote = key,
				name = instance.Name,
				class = instance.ClassName,
				direction = direction,
				ignored = log.Ignored or false,
				callCount = total,
				calls = calls,
			}
		end
	end

	-- busiest remotes first, then optional limit
	table.sort(out, function(a, b)
		return a.callCount > b.callCount
	end)
	if opts.limit and #out > opts.limit then
		local trimmed = {}
		for i = 1, opts.limit do
			trimmed[i] = out[i]
		end
		return trimmed
	end
	return out
end

-- Alias: reads as a query at the call site.
AgentAPI.Query = AgentAPI.GetLogs

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

--// Proximity-prompt capture (separate stream) ////////////////////////////////////////////////////
-- Prompts are captured by Spy/PromptSpy into wax.shared.PromptLogs (keyed by prompt instance). Ignore
-- persists under its own key so it's independent of the remote ignore set. Query/export mirror the
-- remote GetLogs/ExportLogs so the agent can pull prompt activity as JSON too.

local PROMPT_IGNORE_KEY = "PromptIgnores"

local function LoadPromptIgnores(): { [string]: boolean }
	local set = SaveManager():GetState(PROMPT_IGNORE_KEY)
	if type(set) ~= "table" then
		return {}
	end
	return set
end

local function StorePromptIgnores(set: { [string]: boolean })
	pcall(function()
		SaveManager():SetState(PROMPT_IGNORE_KEY, set)
	end)
end

function AgentAPI.IsPromptIgnored(instance): boolean
	return LoadPromptIgnores()[RemoteKey(instance)] == true
end

function AgentAPI.SetPromptIgnored(instance, ignored: boolean)
	local set = LoadPromptIgnores()
	local key = RemoteKey(instance)
	if ignored then
		set[key] = true
	else
		set[key] = nil
	end
	StorePromptIgnores(set)
end

-- Best-effort display name for a prompt (ActionText, else instance name).
local function PromptName(instance): string
	local name
	pcall(function()
		name = instance.ActionText
	end)
	if not name or name == "" then
		name = instance.Name
	end
	return name
end

-- Live PromptLogs whose prompt matches a name (ActionText/Name) or full path substring.
local function MatchingPromptLogs(nameOrPath: string)
	local out = {}
	for instance, log in pairs(wax.shared.PromptLogs or {}) do
		if typeof(instance) == "Instance" then
			local key = RemoteKey(instance)
			if
				PromptName(instance) == nameOrPath
				or instance.Name == nameOrPath
				or key == nameOrPath
				or string.find(key, nameOrPath, 1, true)
			then
				out[#out + 1] = log
			end
		end
	end
	return out
end

-- Ignore a prompt by name or full path. Persists + applies to live PromptLogs. Returns matches.
function AgentAPI.IgnorePrompt(nameOrPath: string): number
	local set = LoadPromptIgnores()
	local matched = 0
	for _, log in ipairs(MatchingPromptLogs(nameOrPath)) do
		log.Ignored = true
		set[RemoteKey(log.Instance)] = true
		matched += 1
	end
	if matched == 0 then
		set[nameOrPath] = true
	end
	StorePromptIgnores(set)
	return matched
end

-- Un-ignore (show) a prompt by name or path. Persists the removal.
function AgentAPI.ShowPrompt(nameOrPath: string): number
	local set = LoadPromptIgnores()
	local matched = 0
	for _, log in ipairs(MatchingPromptLogs(nameOrPath)) do
		log.Ignored = false
		set[RemoteKey(log.Instance)] = nil
		matched += 1
	end
	set[nameOrPath] = nil
	StorePromptIgnores(set)
	return matched
end

-- The full persisted prompt-ignore list (keys), sorted.
function AgentAPI.ListIgnoredPrompts(): { string }
	local out = {}
	for key in pairs(LoadPromptIgnores()) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

-- Query captured prompt activity as a plain table (the agent-facing "query prompts" interface). Opts:
--   name                    substring match on the prompt name (ActionText/Name) OR full path
--   minActivations          only prompts with >= this many activations
--   includeIgnored          default true; set false to hide ignored prompts
--   includeActivations      default true; set false for a name/count-only listing
--   maxActivationsPerPrompt cap activations returned per prompt (newest first), default 40
--   limit                   cap prompts returned (after sorting by activation count desc)
function AgentAPI.GetPrompts(opts): { any }
	opts = opts or {}
	local maxActs = opts.maxActivationsPerPrompt or 40
	local nameFilter = opts.name and string.lower(opts.name) or nil
	local out = {}
	for instance, log in pairs(wax.shared.PromptLogs or {}) do
		if typeof(instance) ~= "Instance" then
			continue
		end
		if opts.includeIgnored == false and log.Ignored then
			continue
		end
		local total = #log.Activations
		if opts.minActivations and total < opts.minActivations then
			continue
		end
		local key = RemoteKey(instance)
		local latest = log.Activations[total]
		-- Label from the LAST FIRING, not the live instance: a reused prompt may already have been
		-- re-purposed since it last fired, which would mislabel the whole history.
		local name = (latest and latest.actionText ~= nil and latest.actionText ~= "" and latest.actionText)
			or PromptName(instance)

		if nameFilter then
			local hit = string.find(string.lower(name), nameFilter, 1, true)
				or string.find(string.lower(key), nameFilter, 1, true)
			-- also match labels it fired with previously, so searching an older action text still
			-- finds a prompt that has since been re-purposed
			if not hit then
				for _, variant in ipairs(log.Variants or {}) do
					if variant.actionText and string.find(string.lower(variant.actionText), nameFilter, 1, true) then
						hit = true
						break
					end
				end
			end
			if not hit then
				continue
			end
		end

		local activations = {}
		if opts.includeActivations ~= false then
			local startIndex = math.max(1, total - maxActs + 1)
			for i = startIndex, total do
				local a = log.Activations[i]
				activations[#activations + 1] = {
					index = i,
					time = a.time,
					actionText = a.actionText,
					objectText = a.objectText,
					holdDuration = a.holdDuration,
					maxDistance = a.maxDistance,
					keyCode = a.keyCode,
					enabled = a.enabled,
					style = a.style,
					attributes = a.attributes,
					tags = a.tags,
					variantIndex = a.variantIndex,
					changed = a.changed or nil, -- true = meant something different than the firing before it
					previousActionText = a.previousActionText,
					path = a.path,
				}
			end
		end

		-- Distinct states this prompt has fired with. reused/variantCount > 1 means the SAME instance
		-- was re-purposed for different actions over time — in that case read the per-activation
		-- actionText, never just `name`, or you'll attribute every firing to the latest label.
		local variants = {}
		for _, variant in ipairs(log.Variants or {}) do
			variants[#variants + 1] = {
				actionText = variant.actionText,
				objectText = variant.objectText,
				count = variant.count,
				first = variant.first,
				last = variant.last,
			}
		end

		-- Prefer the path captured at TRIGGER time: games reparent prompts to nil once used, and a
		-- detached instance's GetFullName() collapses to a bare "ProximityPrompt" with no ancestry.
		local path = (latest and latest.path) or key

		out[#out + 1] = {
			prompt = path,
			name = name,
			path = path,
			group = log.GroupName,
			groupKey = log.GroupKey,
			ignored = log.Ignored or false,
			activationCount = total,
			reused = #variants > 1, -- same instance fired with different meanings; see `variants`
			variantCount = #variants,
			variants = variants,
			activations = activations,
		}
	end

	table.sort(out, function(a, b)
		return a.activationCount > b.activationCount
	end)
	if opts.limit and #out > opts.limit then
		local trimmed = {}
		for i = 1, opts.limit do
			trimmed[i] = out[i]
		end
		return trimmed
	end
	return out
end

-- Write a prompt-activity snapshot to Cobalt/Export/*.json. Returns (path, promptCount).
function AgentAPI.ExportPrompts(fileName: string?, opts): (string?, number)
	local snapshot = AgentAPI.GetPrompts(opts)
	local ok, json = pcall(function()
		return wax.shared.HttpService:JSONEncode({
			exportedAt = os.time(),
			executor = wax.shared.ExecutorName,
			promptCount = #snapshot,
			prompts = snapshot,
		})
	end)
	if not ok then
		return nil, 0
	end
	local name = fileName or ("cobalt-prompts-" .. os.time() .. ".json")
	local helper = FileHelper.new("Cobalt/Export")
	local written = pcall(function()
		helper:WriteFile(name, json)
	end)
	if not written then
		return nil, #snapshot
	end
	return "Cobalt/Export/" .. name, #snapshot
end

-- Clear captured prompt activity (all, or a specific prompt by name/path).
function AgentAPI.ClearPrompts(nameOrPath: string?)
	local PromptSpy = wax.shared.PromptSpy
	if not PromptSpy then
		return false
	end
	if nameOrPath then
		for _, log in ipairs(MatchingPromptLogs(nameOrPath)) do
			pcall(PromptSpy.Clear, log)
		end
	else
		pcall(PromptSpy.Clear, nil)
	end
	return true
end

--// Seats ////////////////////////////////////////////////////////////////////////////////////////
-- Every seat the character has sat on, newest last. Snapshots are taken at SIT time (seats get
-- destroyed/reparented — vehicles despawn, furniture unloads — and the ancestry would be gone).
--   name   substring match on seat name or path
--   limit  cap results (newest kept)
function AgentAPI.GetSeats(opts): { any }
	opts = opts or {}
	local nameFilter = opts.name and string.lower(opts.name) or nil
	local out = {}
	for _, event in ipairs(wax.shared.SeatLogs or {}) do
		local name = tostring(event.name or "")
		local path = tostring(event.path or "")
		if
			not nameFilter
			or string.find(string.lower(name), nameFilter, 1, true)
			or string.find(string.lower(path), nameFilter, 1, true)
		then
			out[#out + 1] = {
				index = event.index,
				time = event.time,
				name = event.name,
				class = event.class,
				path = event.path,
				parentName = event.parentName,
				parentClass = event.parentClass,
				position = event.position,
				disabled = event.disabled,
				attributes = event.attributes,
				stillExists = typeof(event.seat) == "Instance" and event.seat.Parent ~= nil,
			}
		end
	end
	if opts.limit and #out > opts.limit then
		local trimmed = {}
		for i = #out - opts.limit + 1, #out do
			trimmed[#trimmed + 1] = out[i]
		end
		return trimmed
	end
	return out
end

function AgentAPI.ExportSeats(fileName: string?, opts): (string?, number)
	local snapshot = AgentAPI.GetSeats(opts)
	local ok, json = pcall(function()
		return wax.shared.HttpService:JSONEncode({
			exportedAt = os.time(),
			seatCount = #snapshot,
			seats = snapshot,
		})
	end)
	if not ok then
		return nil, 0
	end
	local name = fileName or ("cobalt-seats-" .. os.time() .. ".json")
	local written = pcall(function()
		FileHelper.new("Cobalt/Export"):WriteFile(name, json)
	end)
	return written and ("Cobalt/Export/" .. name) or nil, #snapshot
end

function AgentAPI.ClearSeats(): boolean
	if wax.shared.SeatSpy then
		pcall(wax.shared.SeatSpy.Clear)
		return true
	end
	return false
end

--// Recording sessions ////////////////////////////////////////////////////////////////////////////
-- Record every captured remote call between Start and Stop, so a process performed by hand can be
-- read back as data and turned into automation. Sessions also persist to Cobalt/Sessions/<id>.json.
-- NOTE: recording inherits the capture filters — an ignored/blocked remote produces no call, so it
-- never enters a session.

local function Recorder()
	return wax.shared.Recorder
end

function AgentAPI.StartRecording(name: string?)
	local rec = Recorder()
	if not rec then
		return nil
	end
	local session = rec.Start(name)
	return session and session.Id or nil
end

function AgentAPI.StopRecording()
	local rec = Recorder()
	if not rec then
		return nil
	end
	local session = rec.Stop()
	return session and rec.SessionToTable(session, { includeEvents = false }) or nil
end

function AgentAPI.IsRecording(): boolean
	local rec = Recorder()
	return rec ~= nil and rec.IsRecording()
end

-- All sessions, newest last. Pass includeEvents=false for a lightweight listing.
function AgentAPI.GetSessions(opts): { any }
	local rec = Recorder()
	if not rec then
		return {}
	end
	opts = opts or { includeEvents = false }
	local out = {}
	for _, session in ipairs(wax.shared.RecordedSessions or {}) do
		out[#out + 1] = rec.SessionToTable(session, opts)
	end
	return out
end

-- One session with its full event list (this is the one to read when turning a recording into code).
function AgentAPI.GetSession(id: string, opts)
	local rec = Recorder()
	if not rec then
		return nil
	end
	local session = rec.Get(id)
	return session and rec.SessionToTable(session, opts or {}) or nil
end

function AgentAPI.ExportSession(id: string, fileName: string?): (string?, number)
	local rec = Recorder()
	local session = rec and rec.Get(id)
	if not session then
		return nil, 0
	end
	local data = rec.SessionToTable(session)
	local ok, json = pcall(function()
		return wax.shared.HttpService:JSONEncode(data)
	end)
	if not ok then
		return nil, 0
	end
	local name = fileName or (session.Id .. ".json")
	local written = pcall(function()
		FileHelper.new("Cobalt/Sessions"):WriteFile(name, json)
	end)
	return written and ("Cobalt/Sessions/" .. name) or nil, data.eventCount
end

-- Replay a session's outgoing calls. This FIRES REMOTES for real — server-side effects apply.
function AgentAPI.PlaySession(id: string, opts): boolean
	local rec = Recorder()
	local session = rec and rec.Get(id)
	if not session then
		return false
	end
	return rec.Play(session, opts) ~= nil
end

function AgentAPI.StopPlayback(): boolean
	local rec = Recorder()
	return rec ~= nil and rec.StopPlayback()
end

function AgentAPI.DeleteSession(id: string): boolean
	local rec = Recorder()
	return rec ~= nil and rec.Delete(id)
end

-- Persist a session to Cobalt/Sessions/<id>.json so it comes back on the next injection. Recordings
-- stay in memory until saved — this is the explicit step.
function AgentAPI.SaveSession(id: string): boolean
	local rec = Recorder()
	local session = rec and rec.Get(id)
	return session ~= nil and rec.Save(session)
end

function AgentAPI.RenameSession(id: string, name: string): boolean
	local rec = Recorder()
	local session = rec and rec.Get(id)
	return session ~= nil and rec.Rename(session, name)
end

-- Re-read saved sessions off disk (also runs automatically at load).
function AgentAPI.LoadSavedSessions(): number
	local rec = Recorder()
	return rec and rec.LoadSaved() or 0
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
