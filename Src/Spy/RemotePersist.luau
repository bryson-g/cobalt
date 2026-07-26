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

local function ReadFile()
	local helper = FileHelper.new(DIR)
	if not helper:DoesExist(FILE) then
		return nil
	end
	local ok, data = pcall(function()
		return wax.shared.HttpService:JSONDecode(helper:ReadFile(FILE))
	end)
	if ok and type(data) == "table" and type(data.remotes) == "table" then
		return data.remotes
	end
	return nil
end

-- Snapshot the current capture (non-ignored) to disk, MERGED with what's already saved. Merge, not
-- replace, is the whole point: a fresh session that hasn't re-seen a saved remote yet must not wipe
-- its history from the file — a plain overwrite would clobber the saved log with a sparse one, which
-- is exactly the "rejoined and it was empty" failure. Remotes not live this session are preserved;
-- live ones are updated. Capped per remote and in total.
function RemotePersist.Snapshot()
	local byPath, order = {}, {}
	for _, remote in ipairs(ReadFile() or {}) do
		if remote.path and not byPath[remote.path] then
			byPath[remote.path] = remote
			order[#order + 1] = remote.path
		end
	end

	for direction, category in pairs(wax.shared.Logs or {}) do
		for instance, log in pairs(category) do
			if typeof(instance) ~= "Instance" or log.Ignored or #log.Calls == 0 then
				continue
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
			local path = PathOf(instance)
			if not byPath[path] then
				order[#order + 1] = path
			end
			byPath[path] = {
				path = path,
				name = instance.Name,
				class = instance.ClassName,
				direction = direction,
				calls = calls,
			}
		end
	end

	local remotes = {}
	for _, path in ipairs(order) do
		remotes[#remotes + 1] = byPath[path]
		if #remotes >= MAX_REMOTES then
			break
		end
	end

	pcall(function()
		local json = wax.shared.HttpService:JSONEncode({ savedAt = os.time(), remotes = remotes })
		FileHelper.new(DIR):WriteFile(FILE, json)
	end)
end

-- Has this log already been restored (idempotency, so a retry can't double-append)?
local function AlreadyRestored(log): boolean
	for _, call in ipairs(log.Calls) do
		if call.WasPersisted then
			return true
		end
	end
	return false
end

-- Restore persisted remotes into the live log store, keyed back onto the live instance at each path.
-- Idempotent: a remote whose log already holds persisted calls is skipped, so calling this again (the
-- retry below) only fills in remotes that have since resolved. When fireUI is true (the retry, after
-- the window exists), newly-attached logs are pushed to the Remotes list via the Communicator.
-- Returns (restored, calls, resolvedButPending-count is folded into skipped).
function RemotePersist.Restore(fireUI: boolean?): (number, number, number)
	local remotes = ReadFile()
	if not remotes then
		return 0, 0, 0
	end

	local restored, calls, skipped = 0, 0, 0
	local batch = {}
	for _, remote in ipairs(remotes) do
		local instance = ResolvePath(remote.path)
		local category = instance and wax.shared.Logs[remote.direction]
		if not (instance and category) then
			skipped += 1 -- path not present yet; the retry will pick it up once it replicates
			continue
		end

		local log = category[instance] or wax.shared.NewLog(instance, remote.direction)
		if AlreadyRestored(log) then
			continue -- restored on an earlier pass
		end

		local lastIndex
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
			lastIndex = idx
			calls += 1
		end
		restored += 1

		if fireUI and lastIndex then
			batch[#batch + 1] =
				{ Instance = instance, Type = remote.direction, LogIndex = log.Index, CallIndex = lastIndex }
		end
	end

	-- Push newly-attached logs to the live Remotes list (the initial pass renders via ShowTab; a
	-- retry happens after the window exists, so it has to notify the list itself).
	if fireUI and #batch > 0 and wax.shared.Communicator then
		pcall(function()
			wax.shared.Communicator:Fire(batch)
		end)
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
		RemotePersist.ClearSaved()
		if wax.shared.Sonner then
			wax.shared.Sonner.info("Stopped persisting — cleared the saved log")
		end
	end
end

-- Delete the saved capture. Used by the "off" toggle and the topbar clear ("reset everything").
function RemotePersist.ClearSaved()
	pcall(function()
		FileHelper.new(DIR):DeleteFile(FILE)
	end)
end

-- Called once at load: restore a prior capture and resume the writer if persist was left on. Remotes
-- whose path hasn't replicated yet are retried a couple of times, since a fresh join may not have the
-- full ReplicatedStorage tree the instant Cobalt loads.
function RemotePersist.Init()
	if not RemotePersist.IsOn() then
		return
	end
	local restored, calls, skipped = RemotePersist.Restore(false)
	RemotePersist.StartWriter()
	if restored > 0 and wax.shared.Sonner then
		wax.shared.Sonner.success(("Restored %d persisted remote%s (%d calls)"):format(
			restored,
			restored == 1 and "" or "s",
			calls
		))
	end

	if skipped > 0 then
		for _, delay in ipairs({ 5, 12 }) do
			task.delay(delay, function()
				if RemotePersist.IsOn() and not wax.shared.Unloaded then
					RemotePersist.Restore(true) -- idempotent; fills in late-replicating remotes + UI
				end
			end)
		end
	end
end

return RemotePersist
