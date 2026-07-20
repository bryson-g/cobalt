--!nonstrict
-- rh-farm fork — Sessions view: browse recordings made with the topbar record button.
-- Left  = the sessions (name, event count, duration; the live one is marked).
-- Right = the selected session's remote calls in order, with Play / Stop / Export / Delete.
--
-- Play re-fires the recorded OUTGOING calls with their original spacing — that hits the real server,
-- so it only ever runs from an explicit click.

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")

local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)
local SELECT_BLUE = Color3.fromRGB(38, 96, 190)
local REC_RED = Color3.fromRGB(200, 70, 70)

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
	Recorder: any,
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

	local ListWrapper = Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -36),
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local EmptyHint = Interface.New("TextLabel", {
		Text = "No recordings yet.\nHit the ● record button in the topbar, do the thing by hand, hit it again.",
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

	local Events = Interface.New("ScrollingFrame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -58),
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

	local function ClearEvents()
		for _, child in ipairs(Events:GetChildren()) do
			if child:IsA("Frame") then
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

	local function MakeEventRow(event, index: number)
		local kind = event.kind or "remote"
		local style = KIND_STYLE[kind] or KIND_STYLE.remote
		local marker = style.marker or (event.type == "Outgoing" and "→" or "←")

		local Row = Interface.New("Frame", {
			BackgroundColor3 = BG,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = index,
			Parent = Events,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
			},
		})

		Interface.New("TextLabel", {
			Text = ("%6.2fs  %s  %s"):format(event.t or 0, marker, tostring(event.name)),
			TextSize = 14,
			TextColor3 = style.colour,
			Size = UDim2.new(1, -70, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Row,
		})

		Interface.New("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 66, 0, 18),
			Text = kind == "remote" and (event.class or "") or kind,
			TextSize = 12,
			TextTransparency = 0.5,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = Row,
		})

		return Row
	end

	-- Keep the feed pinned to the newest entry, but only while the user is already at the bottom, so
	-- scrolling back through a live recording isn't yanked away. Deferred a frame because
	-- AutomaticCanvasSize hasn't measured the new row yet.
	local function StickToBottom()
		local canvas = Events.AbsoluteCanvasSize.Y
		local viewport = Events.AbsoluteSize.Y
		local atBottom = (canvas - viewport - Events.CanvasPosition.Y) < 48
		if not atBottom then
			return
		end
		task.defer(function()
			pcall(function()
				wax.shared.RunService.Heartbeat:Wait()
			end)
			Events.CanvasPosition = Vector2.new(0, math.max(0, Events.AbsoluteCanvasSize.Y - Events.AbsoluteSize.Y))
		end)
	end

	local function RenderEvents(session)
		ClearEvents()
		if not session then
			return
		end
		local total = #session.Events
		local startIndex = math.max(1, total - MAX_EVENT_ROWS + 1)
		for i = startIndex, total do
			MakeEventRow(session.Events[i], i)
		end
		StickToBottom()
	end

	-- append just the newest event (live feed while recording) instead of rebuilding the list
	local function AppendLatestEvent(session)
		local total = #session.Events
		local event = session.Events[total]
		if not event then
			return
		end
		MakeEventRow(event, total)

		local rows = 0
		for _, child in ipairs(Events:GetChildren()) do
			if child:IsA("Frame") then
				rows += 1
			end
		end
		if rows > MAX_EVENT_ROWS then
			local oldest
			for _, child in ipairs(Events:GetChildren()) do
				if child:IsA("Frame") and (not oldest or child.LayoutOrder < oldest.LayoutOrder) then
					oldest = child
				end
			end
			if oldest then
				oldest:Destroy()
			end
		end
		StickToBottom()
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
			SaveButton.Text = session.Saved and "Saved" or "Save"
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
		row.Sub.Text = ("%d events · %ds%s%s"):format(
			#session.Events,
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

	SaveButton.MouseButton1Click:Connect(function()
		local session = View.Selected
		if not session then
			return
		end
		if Recorder.Save(session) then
			wax.shared.Sonner.success("Saved — persists across injections")
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

	return View
end
