--!nonstrict
--[[
	rh-farm fork — persist remote network activity across re-injection (like DevTools "Preserve log").

	A re-injection (teleport / realm hop / manual reload) starts with an empty wax.shared.Logs, so the
	captured remote history is normally lost. With Persist on, the current capture is snapshotted to
	Cobalt/Persisted/remotes.json on a cadence and restored on the next load, so the log survives the
	navigation. It's "temp": turning it off deletes the file, so nothing lingers once you're done.

	Fidelity is the same tradeoff sessions have — arguments are serialised (instances -> path) and
	revived on restore, so a restored call shows what fired with readable args, but not the original
	live userdata. Restored calls are keyed back onto the LIVE instance at each path (RH remotes keep
	their path across teleports), so new live calls merge into the same log naturally.
]]

local FileHelper = require("@src/Utils/FileHelper")

local RemotePersist = {}

local KEY = "PersistRemotes" -- SaveManager boolean
local FILE = "remotes.json"
local DIR = "Cobalt/Persisted"
local WRITE_INTERVAL = 5 -- seconds between snapshots while on
local CALLS_PER_REMOTE = 100 -- keep the newest N calls of each remote
local MAX_REMOTES = 800

local writerRunning = false

local function SaveManager()
	return wax.shared.SaveManager
end

function RemotePersist.IsOn(): boolean
	return SaveManager():GetState(KEY, false) == true
end

--// Serialise / revive //--------------------------------------------------------------------------

local function PathOf(instance): string
	local ok, full = pcall(function()
		return instance:GetFullName()
	end)
	return (ok and full) or instance.Name
end

local function SafeValue(value, depth: number)
	local t = typeof(value)
	if t == "Instance" then
		return { __instance = PathOf(value), class = value.ClassName }
	elseif t == "table" then
		if depth > 4 then
			return "<table:deep>"
		end
		local out, count = {}, 0
		for key, inner in pairs(value) do
			if key ~= "n" and (type(key) == "string" or type(key) == "number") then
				out[tostring(key)] = SafeValue(inner, depth + 1)
				count += 1
				if count > 48 then
					out.__truncated = true
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

local function SerialiseArgs(call)
	local args = {}
	local raw = call and call.Arguments
	if type(raw) == "table" then
		local n = raw.n or #raw
		for i = 1, n do
			args[i] = SafeValue(raw[i], 0)
		end
	end
	return args
end

local function ResolvePath(path: string): Instance?
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local node: any = game
	for segment in path:gmatch("[^%.]+") do
		node = node:FindFirstChild(segment)
		if not node then
			return nil
		end
	end
	return node
end

local function ReviveValue(value)
	if type(value) ~= "table" then
		return value
	end
	if value.__instance then
		return ResolvePath(value.__instance) or value -- keep the marker if the path is gone
	end
	local out = {}
	for key, inner in pairs(value) do
		if key ~= "__truncated" then
			out[key] = ReviveValue(inner)
		end
	end
	return out
end

--// Snapshot / restore //--------------------------------------------------------------------------

-- Serialise the current capture (non-ignored) to disk. Cheap enough for a 5s cadence: capped per
-- remote and in total.
function RemotePersist.Snapshot()
	local remotes = {}
	for direction, category in pairs(wax.shared.Logs or {}) do
		for instance, log in pairs(category) do
			if typeof(instance) ~= "Instance" or log.Ignored or #log.Calls == 0 then
				continue
			end
			if #remotes >= MAX_REMOTES then
				break
			end
			local calls = {}
			local total = #log.Calls
			local startIndex = math.max(1, total - CALLS_PER_REMOTE + 1)
			for i = startIndex, total do
				local call = log.Calls[i]
				calls[#calls + 1] = {
					time = call.CreationTime,
					isExecutor = call.IsExecutor or false,
					args = SerialiseArgs(call),
				}
			end
			remotes[#remotes + 1] = {
				path = PathOf(instance),
				name = instance.Name,
				class = instance.ClassName,
				direction = direction,
				calls = calls,
			}
		end
	end

	pcall(function()
		local json = wax.shared.HttpService:JSONEncode({ savedAt = os.time(), remotes = remotes })
		FileHelper.new(DIR):WriteFile(FILE, json)
	end)
end

-- Restore persisted remotes into the live log store, keyed back onto the live instance at each path.
-- Returns (restoredRemotes, restoredCalls, skipped).
function RemotePersist.Restore(): (number, number, number)
	local helper = FileHelper.new(DIR)
	if not helper:DoesExist(FILE) then
		return 0, 0, 0
	end
	local ok, data = pcall(function()
		return wax.shared.HttpService:JSONDecode(helper:ReadFile(FILE))
	end)
	if not ok or type(data) ~= "table" or type(data.remotes) ~= "table" then
		return 0, 0, 0
	end

	local restored, calls, skipped = 0, 0, 0
	for _, remote in ipairs(data.remotes) do
		local instance = ResolvePath(remote.path)
		local category = instance and wax.shared.Logs[remote.direction]
		if not (instance and category) then
			skipped += 1
			continue
		end

		local log = category[instance] or wax.shared.NewLog(instance, remote.direction)
		for _, call in ipairs(remote.calls or {}) do
			local args = { n = 0 }
			for index, value in ipairs(call.args or {}) do
				args[index] = ReviveValue(value)
				args.n = index
			end
			local info = {
				Arguments = args,
				CreationTime = call.time or os.time(),
				IsExecutor = call.isExecutor or false,
				Blocked = false,
				WasPersisted = true, -- render marker; also bypasses the show-executor-logs gate
			}
			local idx = #log.Calls + 1
			log.Calls[idx] = info
			if not info.IsExecutor then
				table.insert(log.GameCalls, idx)
			end
			calls += 1
		end
		restored += 1
	end
	return restored, calls, skipped
end

--// Toggle + writer //-----------------------------------------------------------------------------

function RemotePersist.StartWriter()
	if writerRunning then
		return
	end
	writerRunning = true
	task.spawn(function()
		while RemotePersist.IsOn() and not wax.shared.Unloaded do
			task.wait(WRITE_INTERVAL)
			if RemotePersist.IsOn() then
				RemotePersist.Snapshot()
			end
		end
		writerRunning = false
	end)
end

function RemotePersist.SetOn(on: boolean)
	SaveManager():SetState(KEY, on == true)
	if on then
		RemotePersist.Snapshot() -- capture what's already here, don't wait for the first tick
		RemotePersist.StartWriter()
		if wax.shared.Sonner then
			wax.shared.Sonner.info("Persisting remote activity across re-injection")
		end
	else
		pcall(function()
			FileHelper.new(DIR):DeleteFile(FILE)
		end)
		if wax.shared.Sonner then
			wax.shared.Sonner.info("Stopped persisting — cleared the saved log")
		end
	end
end

-- Called once at load: restore a prior capture and resume the writer if persist was left on.
function RemotePersist.Init()
	if not RemotePersist.IsOn() then
		return
	end
	local restored, calls = RemotePersist.Restore()
	RemotePersist.StartWriter()
	if restored > 0 and wax.shared.Sonner then
		wax.shared.Sonner.success(("Restored %d persisted remote%s (%d calls)"):format(
			restored,
			restored == 1 and "" or "s",
			calls
		))
	end
end

return RemotePersist
