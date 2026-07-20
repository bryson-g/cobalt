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

	local Toolbar = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		Parent = RightWrap,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		},
	})

	local DetailTitle = Interface.New("TextLabel", {
		Text = "Select a session",
		TextSize = 14,
		TextTransparency = 0.3,
		Size = UDim2.new(0, 210, 1, 0),
		LayoutOrder = 0,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = Toolbar,
	})

	local function ToolbarButton(text: string, order: number, color: Color3?)
		return Interface.New("TextButton", {
			BackgroundColor3 = color or Color3.fromRGB(45, 45, 45),
			Size = UDim2.fromOffset(#text * 8 + 18, 22),
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
	local ExportButton = ToolbarButton("Export", 3)
	local DeleteButton = ToolbarButton("Delete", 4)

	local Events = Interface.New("ScrollingFrame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -32),
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

	local function RenderEvents(session)
		ClearEvents()
		if not session then
			return
		end
		local total = #session.Events
		local startIndex = math.max(1, total - MAX_EVENT_ROWS + 1)
		for i = startIndex, total do
			local event = session.Events[i]
			local Row = Interface.New("Frame", {
				BackgroundColor3 = BG,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = i,
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
				Text = ("%6.2fs  %s  %s"):format(event.t or 0, event.type == "Outgoing" and "→" or "←", event.name),
				TextSize = 14,
				Size = UDim2.new(1, -70, 0, 18),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = Row,
			})

			Interface.New("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, 66, 0, 18),
				Text = event.class or "",
				TextSize = 12,
				TextTransparency = 0.5,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = Row,
			})
		end
	end

	local function RefreshToolbar()
		local session = View.Selected
		local has = session ~= nil
		PlayButton.Visible = has
		StopButton.Visible = has and Recorder.Playing ~= nil
		ExportButton.Visible = has
		DeleteButton.Visible = has
		if has then
			DetailTitle.Text = ("%s  ·  %d events"):format(session.Name, #session.Events)
		else
			DetailTitle.Text = "Select a session"
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
		row.Sub.Text = ("%d events · %ds%s"):format(#session.Events, duration, live and "  ● recording" or "")
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
					DetailTitle.Text = ("%s  ·  %d events"):format(session.Name, #session.Events)
				end
			end
		elseif kind == "stopped" then
			RefreshAll()
			if View.Selected == session then
				RenderEvents(session)
				RefreshToolbar()
			end
		elseif kind == "deleted" then
			RefreshAll()
		elseif kind == "play" or kind == "playstopped" then
			RefreshToolbar()
		end
	end)

	RefreshAll()

	return View
end
