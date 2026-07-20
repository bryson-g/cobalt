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
			local kind = event.kind or "remote"
			local entry = {
				index = i,
				t = event.t,
				kind = kind,
				name = event.name,
				class = event.class,
				remote = event.path,
				path = event.path,
			}
			if kind == "remote" then
				entry.direction = event.type
				entry.isExecutor = event.isExecutor or false
				entry.args = SerialiseArgs(event.call)
			elseif kind == "prompt" then
				local snapshot = event.snapshot
				entry.actionText = snapshot and snapshot.actionText
				entry.objectText = snapshot and snapshot.objectText
				entry.attributes = snapshot and snapshot.attributes
			end
			events[#events + 1] = entry
		end
	end
	return {
		id = session.Id,
		name = session.Name,
		startedAt = session.StartedAt,
		endedAt = session.EndedAt,
		duration = (session.EndedAt or os.time()) - session.StartedAt,
		recording = session.EndedAt == nil,
		saved = session.Saved == true,
		-- restored = loaded from disk, so its events hold serialised args revived at playback rather
		-- than the original call tables; fidelity is lower than a session recorded this injection.
		restored = session.Restored == true,
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

	if wax.shared.Sonner then
		wax.shared.Sonner.success(("Recorded %d events — %s (unsaved)"):format(#session.Events, session.Name))
	end
	Notify("stopped", session)
	return session
end

--// Naming + persistence //------------------------------------------------------------------------
-- Saving is explicit: a recording lives in memory until you Save it, and only saved sessions come
-- back on the next injection. Renaming a saved session re-writes its file so the name sticks too.

local SESSION_DIR = "Cobalt/Sessions"

function Recorder.Save(session): boolean
	if not session then
		return false
	end
	local ok = pcall(function()
		local json = wax.shared.HttpService:JSONEncode(Recorder.SessionToTable(session))
		FileHelper.new(SESSION_DIR):WriteFile(session.Id .. ".json", json)
	end)
	if ok then
		session.Saved = true
		Notify("saved", session)
	end
	return ok
end

function Recorder.Rename(session, name: string): boolean
	if not session or type(name) ~= "string" or name == "" then
		return false
	end
	session.Name = name
	if session.Saved then
		Recorder.Save(session) -- keep the file in step with the rename
	end
	Notify("renamed", session)
	return true
end

-- Restore previously saved sessions from disk. Their events carry serialised arguments rather than
-- live call tables, so they're flagged Restored and playback revives them (see BuildRestoredInfo).
function Recorder.LoadSaved(): number
	local helper = FileHelper.new(SESSION_DIR)
	local ok, files = pcall(function()
		return helper:ListFiles()
	end)
	if not ok or type(files) ~= "table" then
		return 0
	end

	local loaded = 0
	for _, file in ipairs(files) do
		local name = tostring(file)
		if name:sub(-5) == ".json" then
			pcall(function()
				-- ListFiles yields paths RELATIVE to the helper's base, so read them through
				-- ReadFile (which re-prepends it), not ReadRawFile (which expects a full path).
				local raw = helper:ReadFile(name)
				local data = wax.shared.HttpService:JSONDecode(raw)
				if type(data) ~= "table" or not data.id then
					return
				end
				for _, existing in ipairs(Sessions()) do
					if existing.Id == data.id then
						return -- already in memory
					end
				end
				local session = {
					Id = data.id,
					Name = data.name or "Restored session",
					StartedAt = data.startedAt or os.time(),
					StartClock = tick(),
					EndedAt = data.endedAt or data.startedAt or os.time(),
					Saved = true,
					Restored = true,
					Events = {},
				}
				for _, event in ipairs(data.events or {}) do
					session.Events[#session.Events + 1] = {
						t = event.t or 0,
						kind = event.kind or "remote",
						type = event.direction,
						name = event.name,
						class = event.class,
						path = event.remote or event.path,
						isExecutor = event.isExecutor,
						args = event.args, -- serialised; revived at playback
					}
				end
				local list = Sessions()
				list[#list + 1] = session
				loaded += 1
			end)
		end
	end
	if loaded > 0 then
		Notify("loaded", nil)
	end
	return loaded
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
			if session.Saved then
				pcall(function()
					FileHelper.new(SESSION_DIR):DeleteFile(session.Id .. ".json")
				end)
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

-- Single entry point for every captured stream, so a session is one ordered timeline of
-- remotes + prompt activations + seats rather than remotes only.
local function AppendEvent(event)
	local session = Recorder.Recording
	if not session or #session.Events >= MAX_EVENTS_PER_SESSION then
		return
	end
	event.t = tick() - session.StartClock
	session.Events[#session.Events + 1] = event
	Notify("event", session)
end

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
			if call then
				local path
				pcall(function()
					path = log.Instance:GetFullName()
				end)
				AppendEvent({
					kind = "remote",
					instance = log.Instance,
					type = direction,
					call = call, -- original values, needed for faithful playback
					name = log.Instance.Name,
					class = log.Instance.ClassName,
					path = path or log.Instance.Name,
					isExecutor = call.IsExecutor or false,
				})
			end
		end
	end
end

--// Playback //------------------------------------------------------------------------------------

--// Playback helpers //----------------------------------------------------------------------------

-- Walk a GetFullName()-style path back to a live instance ("Workspace.Foo.Bar").
local function ResolveInstancePath(path: string?): Instance?
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

-- Turn a serialised argument back into a real value; instance markers resolve to live instances.
local function ReviveValue(value)
	if type(value) ~= "table" then
		return value
	end
	if value.__instance then
		return ResolveInstancePath(value.__instance)
	end
	local out = {}
	for key, inner in pairs(value) do
		if key ~= "__truncated" then
			out[key] = ReviveValue(inner)
		end
	end
	return out
end

-- Build a CallInfo the Classifier/ReplayCallInfo understand, for an event restored from disk (which
-- has serialised args instead of the original call table). Returns nil if the remote is gone.
local function BuildRestoredInfo(event)
	local instance = ResolveInstancePath(event.path)
	if not instance then
		return nil
	end
	local args = { n = 0 }
	for index, value in ipairs(event.args or {}) do
		args[index] = ReviveValue(value)
		args.n = index
	end
	return { Instance = instance, Type = event.type, Arguments = args }
end

-- Is this event's remote currently on the ignore list? Recording already skips ignored remotes, but a
-- session captured BEFORE a remote was ignored (or restored from disk) can still contain it — so the
-- player re-checks, and the ignore list stays the single source of truth for what may fire.
local function BuildIgnoreMatcher()
	local keys = {}
	local AgentAPI = wax.shared.AgentAPI
	if AgentAPI and AgentAPI.ListIgnored then
		local ok, list = pcall(AgentAPI.ListIgnored)
		if ok and type(list) == "table" then
			for _, key in ipairs(list) do
				keys[#keys + 1] = key
			end
		end
	end

	-- prompts have their own persisted ignore set
	local promptKeys = {}
	if AgentAPI and AgentAPI.ListIgnoredPrompts then
		local ok, list = pcall(AgentAPI.ListIgnoredPrompts)
		if ok and type(list) == "table" then
			promptKeys = list
		end
	end

	return function(event): boolean
		local kind = event.kind or "remote"
		if kind == "prompt" then
			local path, name = event.path or "", event.name or ""
			for _, key in ipairs(promptKeys) do
				if key == path or key == name or (key ~= "" and string.find(path, key, 1, true)) then
					return true
				end
			end
			return false
		end

		-- live Log wins when we still have the instance
		if typeof(event.instance) == "Instance" then
			local category = wax.shared.Logs[event.type]
			local log = category and category[event.instance]
			if log and log.Ignored then
				return true
			end
		end
		local path, name = event.path or "", event.name or ""
		for _, key in ipairs(keys) do
			if key == path or key == name or (key ~= "" and string.find(path, key, 1, true)) then
				return true
			end
		end
		return false
	end
end

--- Replay a session's OUTGOING calls in order.
--- opts.speed      time multiplier (default 1; 2 = twice as fast)
--- opts.maxGap     clamp long idle gaps, seconds (default 2)
--- opts.includeIncoming  also re-fire incoming signals locally (default false)
--- opts.respectIgnores   skip remotes on the ignore list (default true)
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
	-- prompt activations are usually the manual actions worth reproducing, so they replay by default
	local includePrompts = opts.includePrompts ~= false

	local CodeGen = require("@src/Utils/CodeGen/Generator")
	local handle = { Stopped = false, Session = session, Fired = 0, Failed = 0, Skipped = 0 }
	local isIgnored = (opts.respectIgnores ~= false) and BuildIgnoreMatcher() or nil

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

			local kind = event.kind or "remote"

			if kind == "seat" then
				-- observational: sitting marks where in the run it happened, nothing to re-fire
				handle.Skipped += 1
			elseif kind == "prompt" then
				if not includePrompts then
					handle.Skipped += 1
				elseif isIgnored and isIgnored(event) then
					handle.Skipped += 1
				else
					local prompt = event.instance
					if typeof(prompt) ~= "Instance" or prompt.Parent == nil then
						prompt = ResolveInstancePath(event.path) -- restored session, or prompt was replaced
					end
					local ok = prompt ~= nil
						and pcall(function()
							fireproximityprompt(prompt)
						end)
					if ok then
						handle.Fired += 1
					else
						handle.Failed += 1
					end
				end
			elseif event.type == "Outgoing" or (includeIncoming and event.type == "Incoming") then
				if isIgnored and isIgnored(event) then
					handle.Skipped += 1
				else
					-- live capture keeps the original call (real instance/userdata args); a session
					-- restored from disk only has serialised args, so revive those instead
					local info
					if event.call then
						info = setmetatable({ Instance = event.instance, Type = event.type }, { __index = event.call })
					else
						info = BuildRestoredInfo(event)
					end

					if not info then
						handle.Failed += 1
					else
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
			end
		end

		Recorder.Playing = nil
		if wax.shared.Sonner then
			wax.shared.Sonner.success(
				("Playback finished — %d fired, %d skipped (ignored), %d failed"):format(
					handle.Fired,
					handle.Skipped,
					handle.Failed
				)
			)
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

	-- remotes (via the existing capture pipeline)
	wax.shared.Connect(wax.shared.Communicator.Event:Connect(OnBatch))

	-- prompt activations — a manual process is usually driven by these, so they belong on the
	-- timeline (and are re-fireable on playback), not just the remotes they happen to trigger
	if wax.shared.PromptSpy then
		wax.shared.PromptSpy.Subscribe(function(kind, log, snapshot)
			if kind ~= "activation" then
				return
			end
			AppendEvent({
				kind = "prompt",
				instance = log.Instance,
				name = (snapshot and snapshot.actionText ~= "" and snapshot.actionText) or "prompt",
				class = "ProximityPrompt",
				path = (snapshot and snapshot.path) or "",
				snapshot = snapshot,
			})
		end)
	end

	-- seats — contextual only (sitting isn't replayed), but it marks where in the run it happened
	if wax.shared.SeatSpy then
		wax.shared.SeatSpy.Subscribe(function(kind, event)
			if kind ~= "sat" or not event then
				return
			end
			AppendEvent({
				kind = "seat",
				instance = event.seat,
				name = event.name,
				class = event.class,
				path = event.path,
			})
		end)
	end
end

return Recorder
