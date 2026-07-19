--!nonstrict
--[[
	rh-farm fork — ProximityPrompt activity capture (a SEPARATE stream from the remote spy).

	Why this exists: ProximityPrompt activations do NOT travel over a script RemoteEvent, so Cobalt's
	__namecall / FireServer hooks never see them. The client -> server hop is engine-internal (the
	prompt's `Triggered` is a *replicating* signal — see Volt's replicatesignal / cansignalreplicate).
	The one clean, global observation point is `ProximityPromptService.PromptTriggered`, which fires on
	the client for every prompt the LocalPlayer activates (this includes executor fireproximityprompt).

	We snapshot each activation (the prompt's properties + full path + time) into a per-prompt PromptLog,
	mirroring the remote LogStore shape, and notify subscribers (the Prompts view). Ignore decisions
	persist to Cobalt/Settings.json via AgentAPI (PromptIgnores) exactly like the remote ignore set.

	There is no arbitrary argument payload to inspect (unlike a RemoteEvent) — the replicated message is
	just "this prompt was triggered by this player". So the analyzable data is the prompt's identity and
	properties, captured at trigger time.
]]

local PromptSpy = {}

local Subscribers = {}
local MAX_ACTIVATIONS = 500 -- per-prompt rolling cap (prompt triggers are low-volume/human-paced)

local function Store()
	return wax.shared.PromptLogs
end

--- Subscribe to capture events. fn(kind, promptLog, activation?) where kind is one of:
---   "ensure"     a prompt was seen for the first time (promptLog just created; no activation yet)
---   "activation" a new activation was appended (activation = the snapshot)
---   "ignore"     a prompt's ignore state changed
---   "clear"      activations cleared (promptLog = the prompt, or nil for "all")
function PromptSpy.Subscribe(fn)
	table.insert(Subscribers, fn)
	return fn
end

local function Notify(kind, promptLog, activation)
	for _, fn in ipairs(Subscribers) do
		local ok, err = pcall(fn, kind, promptLog, activation)
		if not ok then
			warn("[Cobalt·rh PromptSpy] subscriber error: " .. tostring(err))
		end
	end
end

local NextIndex = 0

-- Container Models whose name carries no meaning — skip them when picking a group so we label the
-- group with the actual object (Dryer / WashingMachine / Photocopier), not a generic wrapper.
local GENERIC_MODEL_NAMES = { Model = true, Models = true, Parts = true, Meshes = true }

-- Pick the node a prompt should be GROUPED under, so sibling prompts on the same object (a washer's
-- Open/Close/Turn On/…) collapse into one row. Resolved AT TRIGGER TIME on purpose: games reparent
-- prompts to nil once used, and once detached the ancestry is gone entirely (GetFullName then returns
-- a bare "ProximityPrompt"), so resolving this lazily at render time would lose every group.
--   1) nearest ancestor Model with a meaningful name  -> "Dryer", "Photocopier", "Mini Fridge"
--   2) else the outermost container under the service -> "Office", "MorningBathroom"
local function ResolveGroup(prompt): Instance?
	local chain = {}
	local node = prompt.Parent
	while node and node ~= game do
		chain[#chain + 1] = node
		node = node.Parent
	end
	for _, ancestor in ipairs(chain) do
		if ancestor.ClassName == "Model" and not GENERIC_MODEL_NAMES[ancestor.Name] then
			return ancestor
		end
	end
	-- chain ends at the service (Workspace); the entry before it is the top-level container
	return chain[#chain - 1] or chain[#chain]
end

-- Stamp the group onto the log. Only resolves while the prompt is still parented, so retry on later
-- activations if the first attempt came up empty.
local function EnsureGroup(log, prompt)
	if log.GroupKey then
		return
	end
	local ok, node = pcall(ResolveGroup, prompt)
	if not ok or not node then
		return
	end
	local key
	pcall(function()
		key = node:GetFullName()
	end)
	log.GroupKey = key or node.Name
	log.GroupName = node.Name
	log.GroupClass = node.ClassName
end

--- Find or create the PromptLog for a ProximityPrompt instance. Applies any persisted ignore.
function PromptSpy.EnsureLog(prompt)
	local store = Store()
	local log = store[prompt]
	if log then
		return log
	end

	NextIndex += 1
	log = {
		Instance = prompt,
		Index = NextIndex,
		Activations = {},
		Ignored = false,
		Button = nil,
	}

	-- rh fork: restore a persisted ignore decision so it survives re-injection.
	local AgentAPI = wax.shared.AgentAPI
	if AgentAPI and AgentAPI.IsPromptIgnored then
		local ok, ignored = pcall(AgentAPI.IsPromptIgnored, prompt)
		if ok and ignored then
			log.Ignored = true
		end
	end

	EnsureGroup(log, prompt)
	store[prompt] = log
	Notify("ensure", log, nil)
	return log
end

-- Snapshot the prompt's state at trigger time (properties can change or the prompt can be destroyed
-- later, so we copy what we care about now). Every read is pcall-guarded against a nil-parented ref.
local function Snapshot(prompt, player)
	local snap = { time = os.time(), clock = tick() }
	pcall(function() snap.actionText = prompt.ActionText end)
	pcall(function() snap.objectText = prompt.ObjectText end)
	pcall(function() snap.holdDuration = prompt.HoldDuration end)
	pcall(function() snap.maxDistance = prompt.MaxActivationDistance end)
	pcall(function() snap.requiresLineOfSight = prompt.RequiresLineOfSight end)
	pcall(function() snap.enabled = prompt.Enabled end)
	pcall(function() snap.exclusivity = prompt.Exclusivity and prompt.Exclusivity.Name end)
	pcall(function() snap.keyCode = prompt.KeyboardKeyCode and prompt.KeyboardKeyCode.Name end)
	pcall(function() snap.gamepadKeyCode = prompt.GamepadKeyCode and prompt.GamepadKeyCode.Name end)
	pcall(function() snap.path = prompt:GetFullName() end)
	pcall(function()
		local parent = prompt.Parent
		if parent then
			snap.parentName = parent.Name
			snap.parentClass = parent.ClassName
		end
	end)
	if player then
		pcall(function() snap.player = player.Name end)
	end
	return snap
end

local function OnTriggered(prompt, player)
	if typeof(prompt) ~= "Instance" then
		return
	end
	-- Only the local player's activations. (On the client PromptTriggered fires for the LocalPlayer;
	-- guard anyway in case a game re-fires the service signal with another player.)
	local lp = wax.shared.LocalPlayer
	if player ~= nil and lp ~= nil and player ~= lp then
		return
	end

	local log = PromptSpy.EnsureLog(prompt)
	EnsureGroup(log, prompt) -- retry if the first resolve came up empty (prompt still parented now)
	if log.Ignored then
		return -- ignored: keep the (greyed) list entry for un-ignoring, but drop the activation
	end

	local snap = Snapshot(prompt, player)
	local activations = log.Activations
	activations[#activations + 1] = snap
	if #activations > MAX_ACTIVATIONS then
		table.remove(activations, 1)
	end

	Notify("activation", log, snap)
end

--- Toggle a prompt's ignore state (persists via AgentAPI, like the remote ignore set).
function PromptSpy.SetIgnored(log, ignored)
	if not log then
		return
	end
	log.Ignored = ignored and true or false

	local AgentAPI = wax.shared.AgentAPI
	if AgentAPI and AgentAPI.SetPromptIgnored then
		pcall(AgentAPI.SetPromptIgnored, log.Instance, log.Ignored)
	end
	Notify("ignore", log, nil)
end

--- Clear activations: one prompt (keeps the entry) or all (empties the store).
function PromptSpy.Clear(log)
	if log then
		table.clear(log.Activations)
	else
		local store = Store()
		for _, l in pairs(store) do
			table.clear(l.Activations)
		end
		table.clear(store)
		NextIndex = 0
	end
	Notify("clear", log, nil)
end

--- Begin listening. Idempotent. The connection registers with wax.shared.Connect so Unload cleans it.
function PromptSpy.Start()
	if PromptSpy.Started then
		return
	end
	PromptSpy.Started = true

	local ok, service = pcall(function()
		return cloneref(game:GetService("ProximityPromptService"))
	end)
	if not ok or not service then
		warn("[Cobalt·rh PromptSpy] ProximityPromptService unavailable — prompt capture disabled")
		return
	end
	PromptSpy.Service = service

	wax.shared.Connect(service.PromptTriggered:Connect(OnTriggered))
	-- (Hold/visibility lifecycle is available if we want it later: PromptButtonHoldBegan/Ended,
	--  PromptShown/Hidden — the Triggered signal is the client -> server action we care about.)
end

return PromptSpy
