--!nonstrict
-- rh-farm fork — Playground: take a captured OUTGOING remote call, edit its arguments, and fire it.
--
-- Left  = the bench (remotes you've sent here from the Remotes call list).
-- Right = the selected call's arguments, each with a type-appropriate editor, plus Fire and a looper.
--
-- Outgoing only, deliberately: firing an incoming signal just runs local handlers and teaches you
-- nothing about the server. Everything here hits the real server, so nothing fires without a click.

local Interface = require("@src/Utils/UI/Interface")
local ValueEditor = require("@src/Window/Components/ValueEditor")

local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)
local SELECT_BLUE = Color3.fromRGB(38, 96, 190)
local FIRE_GREEN = Color3.fromRGB(40, 90, 60)
local STOP_RED = Color3.fromRGB(90, 45, 45)

local MIN_INTERVAL = 0.05 -- a loop tighter than this is a good way to get the account flagged

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
})
	local MainFrame = props.MainFrame
	local ContextMenu = props.ContextMenu

	local View = { Selected = nil }
	local Entries = {} -- bench entries: { Instance, Type, Args, Original, Name, Path }
	local Rows = {} -- [entry] = row button
	local SelectedRow = nil
	local LoopHandle = nil

	--// Left: the bench //--------------------------------------------------------------------------
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
		Text = "Bench",
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
		Text = "Nothing on the bench.\nRight-click an outgoing call in Remotes → \"Send to Playground\".",
		TextSize = 13,
		TextWrapped = true,
		TextTransparency = 0.45,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 60),
		Parent = ListWrapper,
	})

	local BenchList = Interface.New("ScrollingFrame", {
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

	--// Right: the editor //------------------------------------------------------------------------
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

	local TitleLabel = Interface.New("TextLabel", {
		Text = "Select something on the bench",
		TextSize = 14,
		TextTransparency = 0.3,
		Size = UDim2.new(1, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = RightWrap,
	})

	-- Controls panel. Two labelled rows: nothing here is a bare number you have to guess at — the
	-- interval says what unit it is, the repeat button says what it does, and the floor is stated.
	local Controls = Interface.New("Frame", {
		BackgroundColor3 = BG,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 62),
		Visible = false,
		Parent = RightWrap,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 7),
			PaddingBottom = UDim.new(0, 7),
		},
	})

	local function Caption(parent, text: string, order: number, dim: number?)
		return Interface.New("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			LayoutOrder = order,
			Text = text,
			TextSize = 13,
			TextTransparency = dim or 0.35,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})
	end

	local function ToolButton(parent, text: string, order: number, colour: Color3?)
		return Interface.New("TextButton", {
			BackgroundColor3 = colour or Color3.fromRGB(45, 45, 45),
			Size = UDim2.fromOffset(#text * 7 + 18, 22),
			LayoutOrder = order,
			Text = text,
			TextSize = 13,
			Parent = parent,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		})
	end

	--// Row 1: one-shot actions \\--
	local ActionRow = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = Controls,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		},
	})

	local FireButton = ToolButton(ActionRow, "▶ Fire", 1, FIRE_GREEN)
	local ResetButton = ToolButton(ActionRow, "Reset args", 2)
	local RemoveButton = ToolButton(ActionRow, "Remove", 3)

	local StatusLabel = Interface.New("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		-- scales with the pane so it can never grow into the buttons on a narrow window
		Size = UDim2.new(0.34, 0, 0, 22),
		Text = "",
		TextSize = 12,
		TextTransparency = 0.35,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = Controls,
	})

	--// Row 2: the looper, spelled out \\--
	local RepeatRow = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = Controls,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		},
	})

	Caption(RepeatRow, "Repeat every", 1)

	local IntervalBox = Interface.New("TextBox", {
		BackgroundColor3 = BG_INNER,
		Size = UDim2.fromOffset(46, 22),
		LayoutOrder = 2,
		Text = "1.0",
		PlaceholderText = "1.0",
		TextSize = 13,
		ClearTextOnFocus = false,
		Parent = RepeatRow,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	Caption(RepeatRow, "seconds", 3)
	local LoopButton = ToolButton(RepeatRow, "▶ Start", 4)
	Caption(RepeatRow, ("min %ss"):format(MIN_INTERVAL), 5, 0.55)

	local ArgsHeader = Interface.New("TextLabel", {
		Position = UDim2.fromOffset(2, 90),
		Size = UDim2.new(1, 0, 0, 16),
		Text = "Arguments",
		TextSize = 13,
		TextTransparency = 0.45,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		Parent = RightWrap,
	})

	local ArgsList = Interface.New("ScrollingFrame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -110),
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

	--// Firing //----------------------------------------------------------------------------------
	local function StopLoop()
		if LoopHandle then
			LoopHandle.Stopped = true
			LoopHandle = nil
		end
		LoopButton.Text = "▶ Start"
		LoopButton.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	end

	local function FireOnce(entry): (boolean, string?)
		if not entry or typeof(entry.Instance) ~= "Instance" then
			return false, "remote is gone"
		end
		local method = entry.Instance.ClassName == "RemoteFunction" and "InvokeServer" or "FireServer"
		local ok, err = pcall(function()
			entry.Instance[method](entry.Instance, table.unpack(entry.Args, 1, entry.Args.n or #entry.Args))
		end)
		if ok then
			entry.Fired = (entry.Fired or 0) + 1
		end
		-- NOT `ok and nil or tostring(err)` — nil is falsy, so that always falls through and reports
		-- the string "nil" as the error on every success.
		if ok then
			return true, nil
		end
		return false, tostring(err)
	end

	local RenderArgs -- forward declaration; the editors re-render after each commit

	local function UpdateStatus(entry)
		if not entry then
			StatusLabel.Text = ""
			return
		end
		local fired = entry.Fired or 0
		StatusLabel.Text = entry.LastError and ("failed: " .. entry.LastError)
			or (fired == 0 and "not fired yet" or ("fired %d time%s"):format(fired, fired == 1 and "" or "s"))
		StatusLabel.TextColor3 = entry.LastError and Color3.fromRGB(230, 110, 110) or Color3.new(1, 1, 1)
	end

	--// Bench //-----------------------------------------------------------------------------------
	local function RefreshToolbar()
		local has = View.Selected ~= nil
		Controls.Visible = has
		ArgsHeader.Visible = has
		TitleLabel.Text = has and ("%s  ·  %s"):format(View.Selected.Name, View.Selected.Path)
			or "Select something on the bench"
		UpdateStatus(View.Selected)
	end

	local function SelectEntry(entry)
		if SelectedRow then
			SelectedRow.BackgroundTransparency = 1
			SelectedRow.BackgroundColor3 = BG
		end
		StopLoop() -- a loop belongs to the entry it was started on
		View.Selected = entry
		local row = Rows[entry]
		if row then
			row.BackgroundColor3 = SELECT_BLUE
			row.BackgroundTransparency = 0
			SelectedRow = row
		end
		RefreshToolbar()
		RenderArgs(entry)
	end

	local function RemoveEntry(entry)
		if View.Selected == entry then
			StopLoop()
			View.Selected = nil
			SelectedRow = nil
		end
		local row = Rows[entry]
		if row then
			row:Destroy()
		end
		Rows[entry] = nil
		for index, existing in ipairs(Entries) do
			if existing == entry then
				table.remove(Entries, index)
				break
			end
		end
		HeaderCount.Text = tostring(#Entries)
		EmptyHint.Visible = #Entries == 0
		RefreshToolbar()
		RenderArgs(View.Selected)
	end

	local function AddRow(entry)
		EmptyHint.Visible = false
		local Row = Interface.New("TextButton", {
			BackgroundColor3 = BG,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = -#Entries, -- newest on top
			Text = "",
			Parent = BenchList,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			["UIListLayout"] = { Padding = UDim.new(0, 2) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		Interface.New("TextLabel", {
			Text = entry.Name,
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Row,
		})

		Interface.New("TextLabel", {
			Text = ("%s · %d arg%s"):format(
				entry.Instance.ClassName,
				entry.Args.n or #entry.Args,
				(entry.Args.n or #entry.Args) == 1 and "" or "s"
			),
			TextSize = 12,
			TextTransparency = 0.4,
			Size = UDim2.new(1, 0, 0, 16),
			LayoutOrder = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Row,
		})

		Rows[entry] = Row
		Row.MouseButton1Click:Connect(function()
			SelectEntry(entry)
		end)

		local Menu = ContextMenu:Create(Row, {
			{ Text = "Fire once", Icon = "play", Callback = function()
				SelectEntry(entry)
				local ok, err = FireOnce(entry)
				entry.LastError = err
				UpdateStatus(entry)
				if wax.shared.Sonner then
					if ok then
						wax.shared.Sonner.success("Fired " .. entry.Name)
					else
						wax.shared.Sonner.error("Fire failed — " .. tostring(err))
					end
				end
			end },
			{ Text = "Remove from bench", Icon = "trash", Callback = function()
				RemoveEntry(entry)
			end },
		}, true)
		Row.MouseButton2Click:Connect(Menu.Toggle)
		Menu:BindLongPress(Row)
	end

	--// Argument editors //-------------------------------------------------------------------------
	local function ClearArgs()
		ValueEditor.ClosePicker()
		for _, child in ipairs(ArgsList:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
	end

	RenderArgs = function(entry)
		ClearArgs()
		if not entry then
			return
		end

		local count = entry.Args.n or #entry.Args
		if count == 0 then
			Interface.New("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 20),
				Parent = ArgsList,
				["TextLabel"] = {
					Text = "(no arguments — Fire sends an empty call)",
					TextSize = 13,
					TextTransparency = 0.45,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Left,
				},
			})
			return
		end

		for index = 1, count do
			local value = entry.Args[index]
			local Row = Interface.New("Frame", {
				BackgroundColor3 = BG,
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = index,
				Parent = ArgsList,

				["UICorner"] = { CornerRadius = UDim.new(0, 4) },
				["UIPadding"] = { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) },
			})

			Interface.New("TextLabel", {
				Text = ("%d  %s"):format(index, typeof(value)),
				TextSize = 13,
				TextTransparency = 0.45,
				Position = UDim2.fromOffset(0, 4),
				Size = UDim2.new(0.32, -4, 0, 18),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = Row,
			})

			local Holder = Interface.New("Frame", {
				BackgroundColor3 = Color3.fromRGB(34, 34, 34),
				Position = UDim2.new(0.32, 0, 0, 3),
				Size = UDim2.new(0.68, 0, 0, 20),
				Parent = Row,
				["UICorner"] = { CornerRadius = UDim.new(0, 3) },
			})

			local editable = ValueEditor.Build(Holder, value, { ContextMenu = ContextMenu }, function(newValue)
				entry.Args[index] = newValue
				RenderArgs(entry) -- re-render so the type label and control follow the new value
			end)

			if not editable then
				-- tables/instances keep their captured value; editing them inline would be guesswork
				Interface.New("TextLabel", {
					Text = ValueEditor.Format(value) .. "  (sent as captured)",
					TextSize = 13,
					TextTransparency = 0.3,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = Holder,
					["UIPadding"] = { PaddingLeft = UDim.new(0, 6) },
				})
			end
		end
	end

	--// Actions //---------------------------------------------------------------------------------
	FireButton.MouseButton1Click:Connect(function()
		local entry = View.Selected
		if not entry then
			return
		end
		local ok, err = FireOnce(entry)
		entry.LastError = err
		UpdateStatus(entry)
		if not ok and wax.shared.Sonner then
			wax.shared.Sonner.error("Fire failed — " .. tostring(err))
		end
	end)

	LoopButton.MouseButton1Click:Connect(function()
		local entry = View.Selected
		if not entry then
			return
		end
		if LoopHandle then
			StopLoop()
			return
		end

		local interval = tonumber(IntervalBox.Text) or 1
		if interval < MIN_INTERVAL then
			interval = MIN_INTERVAL
			IntervalBox.Text = tostring(MIN_INTERVAL)
			if wax.shared.Sonner then
				wax.shared.Sonner.warning("Interval clamped to " .. MIN_INTERVAL .. "s")
			end
		end

		local handle = { Stopped = false }
		LoopHandle = handle
		LoopButton.Text = "■ Stop"
		LoopButton.BackgroundColor3 = STOP_RED

		task.spawn(function()
			while not handle.Stopped do
				local ok, err = FireOnce(entry)
				entry.LastError = err
				if View.Selected == entry then
					UpdateStatus(entry)
				end
				if not ok then
					-- stop on the first failure rather than hammering a call that can't work
					if wax.shared.Sonner then
						wax.shared.Sonner.error("Loop stopped — " .. tostring(err))
					end
					break
				end
				task.wait(interval)
			end
			if LoopHandle == handle then
				StopLoop()
			end
		end)
	end)

	ResetButton.MouseButton1Click:Connect(function()
		local entry = View.Selected
		if not entry then
			return
		end
		entry.Args = table.clone(entry.Original)
		RenderArgs(entry)
		if wax.shared.Sonner then
			wax.shared.Sonner.info("Arguments reset to the captured values")
		end
	end)

	RemoveButton.MouseButton1Click:Connect(function()
		if View.Selected then
			RemoveEntry(View.Selected)
		end
	end)

	--// Public //----------------------------------------------------------------------------------
	--- Put a captured call on the bench. `info` is a CallInfo from the Remotes call list.
	function View.Load(info): boolean
		if not info or typeof(info.Instance) ~= "Instance" then
			return false
		end
		if info.Type ~= "Outgoing" then
			if wax.shared.Sonner then
				wax.shared.Sonner.warning("Playground is for outgoing calls — firing an incoming signal only runs local handlers")
			end
			return false
		end

		local args = { n = 0 }
		local raw = info.Arguments
		if type(raw) == "table" then
			local count = raw.n or #raw
			for index = 1, count do
				args[index] = raw[index]
			end
			args.n = count
		end

		local path = info.Instance.Name
		pcall(function()
			path = info.Instance:GetFullName()
		end)

		local entry = {
			Instance = info.Instance,
			Type = info.Type,
			Name = info.Instance.Name,
			Path = path,
			Args = args,
			Original = table.clone(args),
			Fired = 0,
		}
		Entries[#Entries + 1] = entry
		AddRow(entry)
		HeaderCount.Text = tostring(#Entries)
		SelectEntry(entry)
		return true
	end

	function View.StopLoop()
		StopLoop()
	end

	RefreshToolbar()
	return View
end
