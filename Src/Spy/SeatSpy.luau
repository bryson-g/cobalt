--!nonstrict
--[[
	rh-farm fork — Seat capture.

	Logs every time the LocalPlayer's character sits, recording WHICH seat. Sitting is a Humanoid
	signal (`Humanoid.Seated(active, seatPart)`), not a remote, so nothing else in Cobalt sees it.

	Everything is snapshotted at SIT time for the same reason prompts are: games reparent/destroy
	seats (vehicles despawn, furniture unloads), and a detached instance's GetFullName() collapses to
	a bare name with no ancestry — resolving the path later would lose it.

	The Instance reference is kept alongside the snapshot so the UI can hand it to the Inspect tab.
]]

local SeatSpy = {}

local Subscribers = {}
local MAX_EVENTS = 300

local function Store()
	return wax.shared.SeatLogs
end

--- Subscribe to sit events. fn(kind, event) where kind is "sat" or "clear".
function SeatSpy.Subscribe(fn)
	table.insert(Subscribers, fn)
	return fn
end

local function Notify(kind, event)
	for _, fn in ipairs(Subscribers) do
		local ok, err = pcall(fn, kind, event)
		if not ok then
			warn("[Cobalt·rh SeatSpy] subscriber error: " .. tostring(err))
		end
	end
end

local function ScalarAttributes(instance)
	local ok, attrs = pcall(function()
		return instance:GetAttributes()
	end)
	if not ok or type(attrs) ~= "table" then
		return nil
	end
	local out, n = {}, 0
	for key, value in pairs(attrs) do
		local t = typeof(value)
		out[key] = (t == "string" or t == "number" or t == "boolean") and value or tostring(value)
		n += 1
		if n >= 16 then
			break
		end
	end
	return n > 0 and out or nil
end

local NextIndex = 0

local function RecordSit(seat)
	if typeof(seat) ~= "Instance" then
		return
	end

	NextIndex += 1
	local event = {
		index = NextIndex,
		time = os.time(),
		clock = tick(),
		seat = seat, -- live reference, for "Inspect in explorer"
	}
	pcall(function() event.name = seat.Name end)
	pcall(function() event.class = seat.ClassName end)
	pcall(function() event.path = seat:GetFullName() end)
	pcall(function()
		local parent = seat.Parent
		if parent then
			event.parentName = parent.Name
			event.parentClass = parent.ClassName
		end
	end)
	pcall(function()
		local p = seat.Position
		event.position = ("%.1f, %.1f, %.1f"):format(p.X, p.Y, p.Z)
	end)
	pcall(function() event.disabled = seat.Disabled end)
	event.attributes = ScalarAttributes(seat)

	local store = Store()
	store[#store + 1] = event
	if #store > MAX_EVENTS then
		table.remove(store, 1)
	end

	Notify("sat", event)
end

--- Clear the captured sit log.
function SeatSpy.Clear()
	table.clear(Store())
	NextIndex = 0
	Notify("clear", nil)
end

-- Humanoid.Seated fires (active, seatPart); we only care about sitting down, not standing up. The
-- connection is per-character, so it's rebuilt on every respawn.
local function WatchCharacter(character)
	if not character then
		return
	end
	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			local ok, found = pcall(function()
				return character:WaitForChild("Humanoid", 15)
			end)
			humanoid = ok and found or nil
		end
		if not humanoid then
			return
		end
		wax.shared.Connect(humanoid.Seated:Connect(function(active, seatPart)
			if active and seatPart then
				RecordSit(seatPart)
			end
		end))
	end)
end

--- Begin watching. Idempotent.
function SeatSpy.Start()
	if SeatSpy.Started then
		return
	end
	SeatSpy.Started = true

	local player = wax.shared.LocalPlayer
	if not player then
		return
	end
	WatchCharacter(player.Character)
	wax.shared.Connect(player.CharacterAdded:Connect(WatchCharacter))
end

return SeatSpy
