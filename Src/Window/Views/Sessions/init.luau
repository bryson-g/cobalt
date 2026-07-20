--!nonstrict
-- rh-farm fork — Sessions view: record and browse capture sessions.
-- Left  = the record button plus the sessions (name, event count, duration; the live one is marked).
-- Right = the selected session's feed, newest first, with Play / Stop / Save / Export / Delete.
--
-- Play re-fires the recorded OUTGOING calls with their original spacing — that hits the real server,
-- so it only ever runs from an explicit click.

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")
local ViewSwitcher = require("@src/Window/Components/ViewSwitcher")

local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)
local SELECT_BLUE = Color3.fromRGB(38, 96, 190)
local REC_RED = Color3.fromRGB(200, 70, 70)

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
	Recorder: any,
	OnGoTo: ((any) -> ())?, -- jump to the tab/entry this event came from
})
	local MainFrame = props.MainFrame
	local ContextMenu = props.ContextMenu
	local Recorder = props.Recorder

	local View = { Selected = nil }
	local Buttons = {} -- [session] = row
	local SelectedRow = nil

	--// Left: session list //-----------------------------------------------------------------------
	local LeftList = Interface.New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.yAxis,
		Size = UDim2.new(0, 240, 1, -36),
		Position = UDim2.fromScale(0, 1),
		Parent = MainFrame,

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
		},
	})

	local Header = Interface.New("Frame", {
		BackgroundColor3 = BG,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		["UIPadding"] = { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) },
	})

	Interface.New("TextLabel", {
		Text = "Sessions",
		TextSize = 15,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = Header,
	})

	local HeaderCount = Interface.New("TextLabel", {
		Text = "0",
		TextSize = 15,
		TextTransparency = 0.4,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = Header,
	})

	-- Record control lives here in the tab rather than the topbar: it belongs with the thing it
	-- produces, and the topbar is for window-level chrome.
	local RecordButton = Interface.New("TextButton", {
		BackgroundColor3 = Color3.fromRGB(60, 40, 40),
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.new(1, 0, 0, 26),
		Text = "● Record",
		TextSize = 14,
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local ListWrapper = Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -68), -- header (30) + record button (26) + gaps
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local EmptyHint = Interface.New("TextLabel", {
		Text = "No recordings yet.\nHit ● Record, do the thing by hand, then hit it again.",
		TextSize = 13,
		TextWrapped = true,
		TextTransparency = 0.45,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 60),
		Parent = ListWrapper,
	})

	local SessionList = Interface.New("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		Parent = ListWrapper,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 6),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
		},
	})

	--// Divider //---------------------------------------------------------------------------------
	Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.new(0, 240, 1, 0),
		Size = UDim2.new(0, 2, 1, -36),
		Parent = MainFrame,
	})

	--// Right: detail //----------------------------------------------------------------------------
	local RightWrap = Interface.New("Frame", {
		AnchorPoint = Vector2.one,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(1, -242, 1, -36),
		Parent = MainFrame,

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
		},
	})

	-- Name row. Editing it IS the rename — no dialog needed, and it keeps the title off the button row
	-- (they shared one row before, which is what pushed the actions out of the window).
	local NameBox = Interface.New("TextBox", {
		BackgroundColor3 = BG_INNER,
		Size = UDim2.new(1, 0, 0, 24),
		Position = UDim2.fromOffset(0, 0),
		Text = "",
		PlaceholderText = "Select a session",
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextEditable = false,
		ClearTextOnFocus = false,
		Parent = RightWrap,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		["UIPadding"] = { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) },
	})

	local Toolbar = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = RightWrap,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		},
	})

	-- sized from the label so the row fits inside the default window instead of running off it
	local function ToolbarButton(text: string, order: number, color: Color3?)
		return Interface.New("TextButton", {
			BackgroundColor3 = color or Color3.fromRGB(45, 45, 45),
			Size = UDim2.fromOffset(#text * 7 + 16, 22),
			LayoutOrder = order,
			Text = text,
			TextSize = 13,
			Visible = false,
			Parent = Toolbar,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		})
	end

	local PlayButton = ToolbarButton("Play", 1, Color3.fromRGB(40, 90, 60))
	local StopButton = ToolbarButton("Stop", 2, Color3.fromRGB(90, 45, 45))
	local SaveButton = ToolbarButton("Save", 3, Color3.fromRGB(45, 70, 110))
	local ExportButton = ToolbarButton("Export", 4)
	local DeleteButton = ToolbarButton("Delete", 5)

	local MetaLabel = Interface.New("TextLabel", {
		Text = "",
		TextSize = 12,
		TextTransparency = 0.45,
		Size = UDim2.new(0, 110, 1, 0),
		LayoutOrder = 6,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = Toolbar,
	})

	-- Direction filter for the feed. All is the default so nothing is hidden until asked.
	local FilterRow = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = RightWrap,
	})

	-- Suppressed traffic is recorded but hidden by default — it's the noise you already chose to
	-- filter out; this reveals it without it drowning the real events.
	local IgnoredToggle = Interface.New("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(40, 40, 40),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(104, 22),
		Text = "⊘ ignored: off",
		TextSize = 12,
		Parent = FilterRow,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local Events = Interface.New("ScrollingFrame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -84),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		Parent = RightWrap,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 4),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
		},
	})

	--// Rendering //--------------------------------------------------------------------------------
	local MAX_EVENT_ROWS = 300

	local Filter = "All" -- "All" | "Outgoing" | "Incoming"
	local ShowIgnored = false

	-- Prompts and seats have no remote direction, but they ARE client-originated actions — the things
	-- you actually did — so they group with Outgoing rather than being dropped. That keeps the
	-- Outgoing view a usable "what I performed" list, which is the view worth turning into automation.
	local function PassesFilter(event): boolean
		if event.ignored and not ShowIgnored then
			return false
		end
		if Filter == "All" then
			return true
		end
		local kind = event.kind or "remote"
		if kind == "remote" then
			return event.type == Filter
		end
		return Filter == "Outgoing"
	end

	local function ClearEvents()
		for _, child in ipairs(Events:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
	end

	-- marker + tint per stream, so a mixed timeline is scannable at a glance
	local KIND_STYLE = {
		remote = { colour = Color3.fromRGB(150, 190, 255) },
		prompt = { marker = "⊙", colour = Color3.fromRGB(190, 165, 255) },
		seat = { marker = "▭", colour = Color3.fromRGB(160, 210, 170) },
	}

	-- Right-click actions on a feed row. Remotes can be ignored (which also purges them from the
	-- session); anything can just be removed. Events are held by reference, so a row keeps working
	-- after earlier events are removed and the indices shift.
	local function EventContextOptions(event)
		local options = {}

		table.insert(options, {
			Text = "Go to",
			Icon = "arrow-right",
			Callback = function()
				if props.OnGoTo then
					props.OnGoTo(event)
				end
			end,
		})

		if (event.kind or "remote") == "remote" then
			table.insert(options, {
				Text = "Ignore remote",
				Icon = "eye-off",
				Callback = function()
					local ok, removed = Recorder.IgnoreAndPurge(View.Selected, event)
					if wax.shared.Sonner then
						if ok then
							wax.shared.Sonner.success(
								("Ignoring %s — removed %d event(s)"):format(tostring(event.name), removed)
							)
						else
							wax.shared.Sonner.error("Could not ignore that remote")
						end
					end
				end,
			})
		end

		table.insert(options, {
			Text = "Remove from session",
			Icon = "trash",
			Callback = function()
				Recorder.RemoveEvent(View.Selected, event)
			end,
		})

		return options
	end

	local IGNORED_RED = Color3.fromRGB(230, 110, 110)

	local function MakeEventRow(event, index: number)
		local kind = event.kind or "remote"
		local style = KIND_STYLE[kind] or KIND_STYLE.remote
		local marker = style.marker or (event.type == "Outgoing" and "→" or "←")
		local isIgnored = event.ignored == true
		if isIgnored then
			marker = "⊘" -- distinct from the direction arrows, so it reads as "suppressed" at a glance
		end

		-- a TextButton (not a Frame) so the row can receive right-clicks
		local Row = Interface.New("TextButton", {
			BackgroundColor3 = BG,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			-- negative order = newest on top, matching the prompt/seat lists
			LayoutOrder = -index,
			Text = "",
			Parent = Events,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
			},
		})

		local Menu = ContextMenu:Create(Row, EventContextOptions(event), true)
		Row.MouseButton2Click:Connect(Menu.Toggle)
		Menu:BindLongPress(Row)

		Interface.New("TextLabel", {
			Text = ("%6.2fs  %s  %s"):format(event.t or 0, marker, tostring(event.name)),
			TextSize = 14,
			TextColor3 = isIgnored and IGNORED_RED or style.colour,
			Size = UDim2.new(1, -70, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Row,
		})

		Interface.New("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 66, 0, 18),
			Text = isIgnored and "ignored" or (kind == "remote" and (event.class or "") or kind),
			TextColor3 = isIgnored and IGNORED_RED or Color3.new(1, 1, 1),
			TextSize = 12,
			TextTransparency = isIgnored and 0.15 or 0.5,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = Row,
		})

		return Row
	end

	-- Newest rows arrive at the top, so "follow the feed" means staying pinned at scroll 0. Only do it
	-- when the user is already near the top, so reading back through a live recording isn't yanked.
	local function StickToTop()
		if Events.CanvasPosition.Y > 48 then
			return
		end
		task.defer(function()
			pcall(function()
				wax.shared.RunService.Heartbeat:Wait()
			end)
			if Events.CanvasPosition.Y <= 48 then
				Events.CanvasPosition = Vector2.zero
			end
		end)
	end

	local function RenderEvents(session)
		ClearEvents()
		if not session then
			return
		end
		-- walk newest -> oldest so the row cap keeps the most RECENT matches, not the oldest ones
		local shown = 0
		for i = #session.Events, 1, -1 do
			local event = session.Events[i]
			if PassesFilter(event) then
				MakeEventRow(event, i)
				shown += 1
				if shown >= MAX_EVENT_ROWS then
					break
				end
			end
		end
		StickToTop()
	end

	-- append just the newest event (live feed while recording) instead of rebuilding the list
	local function AppendLatestEvent(session)
		local total = #session.Events
		local event = session.Events[total]
		if not event or not PassesFilter(event) then
			return -- still recorded, just not shown under the current filter
		end
		MakeEventRow(event, total)

		local rows = 0
		for _, child in ipairs(Events:GetChildren()) do
			if child:IsA("TextButton") then
				rows += 1
			end
		end
		if rows > MAX_EVENT_ROWS then
			-- order is -index, so the OLDEST row is the one with the largest LayoutOrder
			local oldest
			for _, child in ipairs(Events:GetChildren()) do
				if child:IsA("TextButton") and (not oldest or child.LayoutOrder > oldest.LayoutOrder) then
					oldest = child
				end
			end
			if oldest then
				oldest:Destroy()
			end
		end
		StickToTop()
	end

	local function RefreshToolbar()
		local session = View.Selected
		local has = session ~= nil
		PlayButton.Visible = has
		StopButton.Visible = has and Recorder.Playing ~= nil
		SaveButton.Visible = has
		ExportButton.Visible = has
		DeleteButton.Visible = has
		NameBox.TextEditable = has
		if has then
			SaveButton.Text = session.Saved and "Re-save" or "Save"
			SaveButton.BackgroundColor3 = session.Saved and Color3.fromRGB(40, 70, 55) or Color3.fromRGB(45, 70, 110)
			MetaLabel.Text = ("%d events%s"):format(#session.Events, session.Restored and " · restored" or "")
			if not NameBox:IsFocused() then
				NameBox.Text = session.Name
			end
		else
			MetaLabel.Text = ""
			NameBox.Text = ""
		end
	end

	local function RefreshRow(session)
		local row = Buttons[session]
		if not row then
			return
		end
		local live = session.EndedAt == nil
		local duration = (session.EndedAt or os.time()) - session.StartedAt
		row.Title.Text = session.Name
		local ignored = 0
		for _, event in ipairs(session.Events) do
			if event.ignored then
				ignored += 1
			end
		end
		row.Sub.Text = ("%d events%s · %ds%s%s"):format(
			#session.Events,
			ignored > 0 and (" (" .. ignored .. " ignored)") or "",
			duration,
			session.Saved and "  ·  saved" or "",
			live and "  ● recording" or ""
		)
		row.Sub.TextColor3 = live and REC_RED or Color3.new(1, 1, 1)
	end

	local function SelectSession(session)
		if SelectedRow then
			SelectedRow.BackgroundTransparency = 1
			SelectedRow.BackgroundColor3 = BG
		end
		View.Selected = session
		local row = Buttons[session]
		if row then
			row.Root.BackgroundColor3 = SELECT_BLUE
			row.Root.BackgroundTransparency = 0
			SelectedRow = row.Root
		end
		RefreshToolbar()
		RenderEvents(session)
	end

	local function EnsureRow(session)
		if Buttons[session] then
			RefreshRow(session)
			return
		end
		EmptyHint.Visible = false

		local Root = Interface.New("TextButton", {
			BackgroundColor3 = BG,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = -tonumber(session.StartedAt or 0), -- newest first
			Text = "",
			Parent = SessionList,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			["UIListLayout"] = { Padding = UDim.new(0, 2) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		local Title = Interface.New("TextLabel", {
			Text = session.Name,
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Root,
		})

		local Sub = Interface.New("TextLabel", {
			Text = "",
			TextSize = 12,
			TextTransparency = 0.35,
			Size = UDim2.new(1, 0, 0, 16),
			LayoutOrder = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Root,
		})

		local record = { Root = Root, Title = Title, Sub = Sub }
		Buttons[session] = record
		Root.MouseButton1Click:Connect(function()
			SelectSession(session)
		end)

		local Menu = ContextMenu:Create(Root, {
			{
				Text = "Rename",
				Icon = "pencil",
				Callback = function()
					SelectSession(session)
					NameBox:CaptureFocus() -- the name field IS the rename control
				end,
			},
			{
				Text = function()
					return session.Saved and "Re-save" or "Save"
				end,
				Icon = "save",
				Callback = function()
					SelectSession(session)
					if Recorder.Save(session) then
						wax.shared.Sonner.success("Saved " .. session.Name)
					else
						wax.shared.Sonner.error("Failed to save session")
					end
					RefreshRow(session)
					RefreshToolbar()
				end,
			},
			{
				Text = "Play",
				Icon = "play",
				Callback = function()
					SelectSession(session)
					if not Recorder.Playing then
						Recorder.Play(session)
						RefreshToolbar()
					end
				end,
			},
			{
				Text = "Delete",
				Icon = "trash",
				Callback = function()
					Recorder.Delete(session.Id)
				end,
			},
		}, true)
		Root.MouseButton2Click:Connect(Menu.Toggle)
		Menu:BindLongPress(Root)

		RefreshRow(session)
		HeaderCount.Text = tostring(#wax.shared.RecordedSessions)
	end

	local function RefreshAll()
		for _, session in ipairs(wax.shared.RecordedSessions or {}) do
			EnsureRow(session)
		end
		-- drop rows whose session was deleted
		for session, row in pairs(Buttons) do
			local stillThere = false
			for _, live in ipairs(wax.shared.RecordedSessions or {}) do
				if live == session then
					stillThere = true
					break
				end
			end
			if not stillThere then
				row.Root:Destroy()
				Buttons[session] = nil
				if View.Selected == session then
					View.Selected = nil
					SelectedRow = nil
					ClearEvents()
					RefreshToolbar()
				end
			end
		end
		HeaderCount.Text = tostring(#(wax.shared.RecordedSessions or {}))
		EmptyHint.Visible = #(wax.shared.RecordedSessions or {}) == 0
	end

	--// Actions //---------------------------------------------------------------------------------
	PlayButton.MouseButton1Click:Connect(function()
		local session = View.Selected
		if not session then
			return
		end
		if Recorder.Playing then
			wax.shared.Sonner.warning("Already playing a session")
			return
		end
		Recorder.Play(session)
		RefreshToolbar()
	end)

	StopButton.MouseButton1Click:Connect(function()
		Recorder.StopPlayback()
		RefreshToolbar()
	end)

	local FeedTabs = ViewSwitcher({
		Parent = FilterRow,
		Tabs = { "All", "Outgoing", "Incoming" },
		OnSelected = function(Name)
			Filter = Name
			RenderEvents(View.Selected)
		end,
	})
	FeedTabs:Select("All", true)

	IgnoredToggle.MouseButton1Click:Connect(function()
		ShowIgnored = not ShowIgnored
		IgnoredToggle.Text = ShowIgnored and "⊘ ignored: on" or "⊘ ignored: off"
		IgnoredToggle.BackgroundColor3 = ShowIgnored and Color3.fromRGB(90, 45, 45) or Color3.fromRGB(40, 40, 40)
		RenderEvents(View.Selected)
	end)

	local function RefreshRecordButton()
		local recording = Recorder.IsRecording()
		RecordButton.Text = recording and "■ Stop recording" or "● Record"
		RecordButton.BackgroundColor3 = recording and REC_RED or Color3.fromRGB(60, 40, 40)
	end

	RecordButton.MouseButton1Click:Connect(function()
		Recorder.Toggle()
		RefreshRecordButton()
	end)

	SaveButton.MouseButton1Click:Connect(function()
		local session = View.Selected
		if not session then
			return
		end
		if Recorder.Save(session) then
			wax.shared.Sonner.success("Written to Cobalt/Sessions")
		else
			wax.shared.Sonner.error("Failed to save session")
		end
		RefreshRow(session)
		RefreshToolbar()
	end)

	-- committing the name field renames the session (and re-writes its file if already saved)
	NameBox.FocusLost:Connect(function(enterPressed)
		local session = View.Selected
		if not session then
			return
		end
		local text = NameBox.Text
		if enterPressed and text ~= "" and text ~= session.Name then
			Recorder.Rename(session, text)
			RefreshRow(session)
		end
		RefreshToolbar()
	end)

	ExportButton.MouseButton1Click:Connect(function()
		local session = View.Selected
		if not session then
			return
		end
		local ok = pcall(function()
			local FileHelper = require("@src/Utils/FileHelper")
			local json = wax.shared.HttpService:JSONEncode(Recorder.SessionToTable(session))
			FileHelper.new("Cobalt/Sessions"):WriteFile(session.Id .. ".json", json)
		end)
		if wax.shared.Sonner then
			if ok then
				wax.shared.Sonner.success("Exported to Cobalt/Sessions/" .. session.Id .. ".json")
			else
				wax.shared.Sonner.error("Export failed")
			end
		end
	end)

	DeleteButton.MouseButton1Click:Connect(function()
		local session = View.Selected
		if not session then
			return
		end
		Recorder.Delete(session.Id)
		RefreshAll()
	end)

	--// Live //-----------------------------------------------------------------------------------
	Recorder.Subscribe(function(kind, session)
		-- keep the button in step even when recording is toggled elsewhere (e.g. the agent)
		if kind == "started" or kind == "stopped" then
			RefreshRecordButton()
		end

		if kind == "started" then
			RefreshAll()
			if session then
				SelectSession(session)
			end
		elseif kind == "event" then
			if session then
				RefreshRow(session)
				if View.Selected == session then
					RefreshToolbar()
					AppendLatestEvent(session) -- live feed: don't wait for the recording to stop
				end
			end
		elseif kind == "stopped" then
			RefreshAll()
			if View.Selected == session then
				RenderEvents(session)
				RefreshToolbar()
			end
		elseif kind == "deleted" or kind == "loaded" then
			RefreshAll()
		elseif kind == "mutated" then
			-- an event was removed/purged: indices shifted, so redraw the feed
			if session then
				RefreshRow(session)
			end
			if View.Selected == session then
				RenderEvents(session)
				RefreshToolbar()
			end
		elseif kind == "saved" or kind == "renamed" then
			if session then
				RefreshRow(session)
			end
			if View.Selected == session then
				RefreshToolbar()
			end
		elseif kind == "play" or kind == "playstopped" then
			RefreshToolbar()
		end
	end)

	RefreshAll()
	RefreshRecordButton()

	return View
end
