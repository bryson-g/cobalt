--!nonstrict
--[[
	rh-farm fork — session recording + playback.

	Records every remote call that happens between Start() and Stop() into a named session, so a
	process you performed BY HAND can be captured once, read back as data, and replayed/automated.

	It deliberately adds NO new hooks: Log:Call already queues every captured call onto
	wax.shared.Communicator, so the recorder just subscribes to that batch and resolves each
	notification back to its Log. Consequence worth knowing: recording inherits the capture filters —
	an ignored/blocked remote never produces a call, so it never lands in a session. That's usually
	what you want (the noise filter applies), but it means a session is "what Cobalt captured", not
	"every packet on the wire".

	Each event keeps BOTH:
	  * `call` — the original in-memory call info, so playback can re-fire with real argument values
	    (instances, userdata) that a JSON round-trip would destroy.
	  * enough scalars to serialise for the agent/export.

	Playback reuses CodeGen:ReplayCallInfo — the same path as the per-call "Replay" context action —
	so it fires remotes exactly the way Cobalt already does, instead of reimplementing it.
]]

local FileHelper = require("@src/Utils/FileHelper")

local Recorder = {
	Recording = nil, -- the in-progress session, or nil
	Playing = nil, -- the in-progress playback handle, or nil
}

local Subscribers = {}
local MAX_EVENTS_PER_SESSION = 5000

local function Sessions()
	return wax.shared.RecordedSessions
end

--- Subscribe to recorder state changes. fn(kind) where kind is
--- "started" | "stopped" | "event" | "play" | "playstopped" | "deleted".
function Recorder.Subscribe(fn)
	table.insert(Subscribers, fn)
	return fn
end

local function Notify(kind, session)
	for _, fn in ipairs(Subscribers) do
		local ok, err = pcall(fn, kind, session)
		if not ok then
			warn("[Cobalt·rh Recorder] subscriber error: " .. tostring(err))
		end
	end
end

function Recorder.IsRecording(): boolean
	return Recorder.Recording ~= nil
end

--// Serialisation //-------------------------------------------------------------------------------

-- Compact, JSON-safe rendering of a captured argument (instances -> path, cycles/depth capped).
local function SafeValue(value, depth: number)
	local t = typeof(value)
	if t == "Instance" then
		local ok, full = pcall(function()
			return value:GetFullName()
		end)
		return { __instance = (ok and full) or value.Name, class = value.ClassName }
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

--- A session as plain, JSON-safe data (what the agent and the export file see).
function Recorder.SessionToTable(session, opts)
	opts = opts or {}
	local events = {}
	if opts.includeEvents ~= false then
		local limit = opts.maxEvents or 2000
		local total = #session.Events
		local startIndex = math.max(1, total - limit + 1)
		for i = startIndex, total do
			local event = session.Events[i]
			events[#events + 1] = {
				index = i,
				t = event.t,
				remote = event.path,
				name = event.name,
				class = event.class,
				direction = event.type,
				isExecutor = event.isExecutor or false,
				args = SerialiseArgs(event.call),
			}
		end
	end
	return {
		id = session.Id,
		name = session.Name,
		startedAt = session.StartedAt,
		endedAt = session.EndedAt,
		duration = (session.EndedAt or os.time()) - session.StartedAt,
		recording = session.EndedAt == nil,
		eventCount = #session.Events,
		events = events,
	}
end

--// Recording //-----------------------------------------------------------------------------------

function Recorder.Start(name: string?)
	if Recorder.Recording then
		return Recorder.Recording
	end
	local session = {
		Id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
		Name = (name ~= nil and name ~= "") and name or ("Session " .. os.date("%H:%M:%S")),
		StartedAt = os.time(),
		StartClock = tick(),
		EndedAt = nil,
		Events = {},
	}
	Recorder.Recording = session
	local list = Sessions()
	list[#list + 1] = session

	if wax.shared.Sonner then
		wax.shared.Sonner.info("Recording started — " .. session.Name)
	end
	Notify("started", session)
	return session
end

function Recorder.Stop()
	local session = Recorder.Recording
	if not session then
		return nil
	end
	session.EndedAt = os.time()
	Recorder.Recording = nil

	-- persist so a session survives re-injection / can be read off disk
	pcall(function()
		local json = wax.shared.HttpService:JSONEncode(Recorder.SessionToTable(session))
		FileHelper.new("Cobalt/Sessions"):WriteFile(session.Id .. ".json", json)
	end)

	if wax.shared.Sonner then
		wax.shared.Sonner.success(("Recorded %d events — %s"):format(#session.Events, session.Name))
	end
	Notify("stopped", session)
	return session
end

function Recorder.Toggle()
	if Recorder.Recording then
		return Recorder.Stop()
	end
	return Recorder.Start()
end

function Recorder.Delete(id: string): boolean
	local list = Sessions()
	for index, session in ipairs(list) do
		if session.Id == id then
			if Recorder.Recording == session then
				Recorder.Recording = nil
			end
			table.remove(list, index)
			Notify("deleted", session)
			return true
		end
	end
	return false
end

function Recorder.Get(id: string)
	for _, session in ipairs(Sessions()) do
		if session.Id == id then
			return session
		end
	end
	return nil
end

--// Capture //-------------------------------------------------------------------------------------

local function OnBatch(batch)
	local session = Recorder.Recording
	if not session or typeof(batch) ~= "table" then
		return
	end

	for _, notification in batch do
		local direction = notification.Type
		local instance = notification.Instance
		local category = wax.shared.Logs[direction]
		if category then
			local log = category[instance]
			if not log and notification.LogIndex then
				for _, candidate in category do
					if candidate.Index == notification.LogIndex then
						log = candidate
						break
					end
				end
			end
			local call = log and log.Calls[notification.CallIndex]
			if call and #session.Events < MAX_EVENTS_PER_SESSION then
				local path
				pcall(function()
					path = log.Instance:GetFullName()
				end)
				session.Events[#session.Events + 1] = {
					t = tick() - session.StartClock,
					instance = log.Instance,
					type = direction,
					call = call, -- original values, needed for faithful playback
					name = log.Instance.Name,
					class = log.Instance.ClassName,
					path = path or log.Instance.Name,
					isExecutor = call.IsExecutor or false,
				}
				Notify("event", session)
			end
		end
	end
end

--// Playback //------------------------------------------------------------------------------------

--- Replay a session's OUTGOING calls in order.
--- opts.speed      time multiplier (default 1; 2 = twice as fast)
--- opts.maxGap     clamp long idle gaps, seconds (default 2)
--- opts.includeIncoming  also re-fire incoming signals locally (default false)
--- Returns a handle with :Stop(). Firing remotes has real server-side effects — this only runs when
--- explicitly invoked.
function Recorder.Play(session, opts)
	if not session then
		return nil
	end
	if Recorder.Playing then
		return nil
	end
	opts = opts or {}
	local speed = math.max(0.05, opts.speed or 1)
	local maxGap = opts.maxGap or 2
	local includeIncoming = opts.includeIncoming == true

	local CodeGen = require("@src/Utils/CodeGen/Generator")
	local handle = { Stopped = false, Session = session, Fired = 0, Failed = 0 }

	function handle:Stop()
		self.Stopped = true
	end

	Recorder.Playing = handle
	Notify("play", session)

	task.spawn(function()
		local previous = 0
		for _, event in ipairs(session.Events) do
			if handle.Stopped then
				break
			end
			local gap = math.clamp((event.t or 0) - previous, 0, maxGap) / speed
			previous = event.t or previous
			if gap > 0.001 then
				task.wait(gap)
			end
			if handle.Stopped then
				break
			end

			if event.type == "Outgoing" or (includeIncoming and event.type == "Incoming") then
				local info = setmetatable({
					Instance = event.instance,
					Type = event.type,
				}, { __index = event.call })
				local ok = pcall(function()
					CodeGen:ReplayCallInfo(info)
				end)
				if ok then
					handle.Fired += 1
				else
					handle.Failed += 1
				end
			end
		end

		Recorder.Playing = nil
		if wax.shared.Sonner then
			wax.shared.Sonner.success(("Playback finished — %d fired, %d failed"):format(handle.Fired, handle.Failed))
		end
		Notify("playstopped", session)
	end)

	return handle
end

function Recorder.StopPlayback(): boolean
	local handle = Recorder.Playing
	if not handle then
		return false
	end
	handle:Stop()
	Recorder.Playing = nil
	Notify("playstopped", handle.Session)
	return true
end

--// Init //----------------------------------------------------------------------------------------

function Recorder.Start_Listening()
	if Recorder.Listening then
		return
	end
	Recorder.Listening = true
	wax.shared.Connect(wax.shared.Communicator.Event:Connect(OnBatch))
end

return Recorder
