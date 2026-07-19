--!nonstrict
-- rh-farm fork — Prompts view: ProximityPrompt activity, kept in its own pane so it never collides with
-- the remote spy. Left = captured prompts (title + activation count, right-click to ignore/clear);
-- right = the selected prompt's activations (a property snapshot + time per trigger). Fed live by
-- Spy/PromptSpy; ignore persists via AgentAPI. Layout mirrors the remote view for visual parity.

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")

-- palette (matches the remote view)
local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)
local SELECTED = Color3.fromRGB(50, 50, 50)

return function(props: {
	MainFrame: GuiObject, -- the PromptsRoot container (full-size, so geometry matches the remote view)
	ContextMenu: any,
	PromptSpy: any,
	GetDPIScale: () -> number,
})
	local MainFrame = props.MainFrame
	local ContextMenu = props.ContextMenu
	local PromptSpy = props.PromptSpy

	local View = {
		CurrentPrompt = nil,
		CurrentButton = nil,
		TopOrder = 0,
	}

	local Buttons = {} -- [promptLog] = { Root, Name, Count, Icon }
	local PromptCount = 0

	--// Helpers //---------------------------------------------------------------------------------
	local function PromptTitle(log): string
		local instance = log.Instance
		local name
		pcall(function()
			name = instance.ActionText
		end)
		if not name or name == "" then
			-- fall back to the newest snapshot, then the instance name
			local acts = log.Activations
			local latest = acts[#acts]
			if latest and latest.actionText and latest.actionText ~= "" then
				name = latest.actionText
			end
		end
		if not name or name == "" then
			pcall(function()
				name = instance.Name
			end)
		end
		if not name or name == "" then
			name = "ProximityPrompt"
		end
		return name
	end

	local function PromptPath(log): string
		local acts = log.Activations
		local latest = acts[#acts]
		if latest and latest.path then
			return latest.path
		end
		local path
		local ok = pcall(function()
			path = log.Instance:GetFullName()
		end)
		return (ok and path) or PromptTitle(log)
	end

	--// Left panel //------------------------------------------------------------------------------
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

		["UICorner"] = {
			CornerRadius = UDim.new(0, 4),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
		},
	})

	Interface.New("TextLabel", {
		Text = "Prompts",
		TextSize = 15,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = Header,
	})

	local HeaderCount = Interface.New("TextLabel", {
		Text = "0",
		TextSize = 15,
		TextTransparency = 0.4,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = Header,
	})

	local ListWrapper = Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -36),
		Parent = LeftList,

		["UICorner"] = {
			CornerRadius = UDim.new(0, 4),
		},
	})

	local EmptyHint = Interface.New("TextLabel", {
		Text = "No prompts captured yet.\nActivate a ProximityPrompt in-game and it shows up here.",
		TextSize = 13,
		TextWrapped = true,
		TextTransparency = 0.45,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 60),
		Parent = ListWrapper,
	})

	local PromptList = Interface.New("ScrollingFrame", {
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

	--// Divider (static — visual match to the remote view's resize handle) //----------------------
	Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.new(0, 240, 1, 0),
		Size = UDim2.new(0, 2, 1, -36),
		Parent = MainFrame,
	})

	--// Right panel //-----------------------------------------------------------------------------
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

	local DetailHeader = Interface.New("TextLabel", {
		Text = "Select a prompt to see its activations",
		TextSize = 14,
		TextTransparency = 0.35,
		Size = UDim2.new(1, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = RightWrap,
	})

	local ActivationsList = Interface.New("ScrollingFrame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -28),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		Parent = RightWrap,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 6),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
		},
	})

	--// Rendering //-------------------------------------------------------------------------------
	local function UpdateEmptyState()
		EmptyHint.Visible = PromptCount == 0
	end

	-- A labelled key/value row inside an activation's detail block.
	local function KV(parent, label: string, value: string, order: number)
		local Row = Interface.New("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = order,
			Parent = parent,
		})
		Interface.New("TextLabel", {
			Text = label,
			TextSize = 14,
			TextTransparency = 0.45,
			Size = UDim2.new(0.38, -4, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Row,
		})
		Interface.New("TextLabel", {
			Text = value,
			TextSize = 14,
			Position = UDim2.new(0.38, 0, 0, 0),
			Size = UDim2.new(0.62, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Row,
		})
	end

	local function MakeActivationFrame(snap, order: number)
		local Frame = Interface.New("Frame", {
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = BG,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = order,
			Parent = ActivationsList,

			Constants.MainUICorner,

			["UIListLayout"] = {
				Padding = UDim.new(0, 6),
			},

			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 6),
				PaddingRight = UDim.new(0, 6),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		-- header row: icon + title + time
		local Head = Interface.New("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 22),
			LayoutOrder = 0,
			Parent = Frame,
		})
		Interface.NewIcon("mouse-pointer-click", {
			ImageTransparency = 0.4,
			AnchorPoint = Vector2.yAxis,
			Position = UDim2.new(0, 2, 1, 0),
			Size = UDim2.fromOffset(20, 20),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Parent = Head,
		})
		Interface.New("TextLabel", {
			Position = UDim2.new(0, 28, 0, 0),
			Size = UDim2.new(0.5, -24, 1, 0),
			Text = (snap.actionText and snap.actionText ~= "" and snap.actionText) or "Triggered",
			TextSize = 16,
			TextTransparency = 0.1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Head,
		})
		Interface.New("TextLabel", {
			AnchorPoint = Vector2.one,
			Position = UDim2.new(1, -2, 1, 0),
			Size = UDim2.new(0.5, -2, 1, 0),
			Text = "Time: " .. os.date("%X", snap.time or os.time()),
			TextSize = 16,
			TextTransparency = 0.5,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = Head,
		})

		-- details block
		local Details = Interface.New("Frame", {
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = BG_INNER,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 1,
			Parent = Frame,

			Constants.MainUICorner,

			["UIListLayout"] = {
				Padding = UDim.new(0, 2),
			},

			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		local o = 0
		local function Add(label, value)
			if value == nil or value == "" then
				return
			end
			o += 1
			KV(Details, label, tostring(value), o)
		end

		Add("Object text", snap.objectText)
		if snap.holdDuration ~= nil then
			Add("Hold", snap.holdDuration > 0 and string.format("%.2gs", snap.holdDuration) or "instant")
		end
		Add("Max distance", snap.maxDistance)
		if snap.requiresLineOfSight ~= nil then
			Add("Requires LoS", snap.requiresLineOfSight and "yes" or "no")
		end
		Add("Keyboard key", snap.keyCode)
		Add("Gamepad key", snap.gamepadKeyCode)
		Add("Exclusivity", snap.exclusivity)
		if snap.enabled ~= nil then
			Add("Enabled", snap.enabled and "yes" or "no")
		end
		Add("Player", snap.player)

		-- full path on its own wrapped row
		if snap.path then
			o += 1
			local PathRow = Interface.New("Frame", {
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = o,
				Parent = Details,
			})
			Interface.New("TextLabel", {
				Text = snap.path,
				TextSize = 13,
				TextTransparency = 0.3,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = PathRow,
			})
		end

		return Frame
	end

	local function ClearActivationFrames()
		for _, Child in ipairs(ActivationsList:GetChildren()) do
			if Child:IsA("Frame") then
				Child:Destroy()
			end
		end
	end

	local MAX_SHOWN = 200

	-- Render newest-first: newest gets the smallest LayoutOrder so it sits at the top.
	local function RenderActivations(log)
		ClearActivationFrames()
		if not log then
			return
		end
		local acts = log.Activations
		local total = #acts
		local order = 0
		for i = total, math.max(1, total - MAX_SHOWN + 1), -1 do
			MakeActivationFrame(acts[i], order)
			order += 1
		end
		View.TopOrder = 0
		ActivationsList.CanvasPosition = Vector2.zero
	end

	local function AppendActivation(snap)
		View.TopOrder -= 1
		MakeActivationFrame(snap, View.TopOrder)

		-- trim the oldest visible frame if we're over the cap
		local frames = {}
		for _, Child in ipairs(ActivationsList:GetChildren()) do
			if Child:IsA("Frame") then
				table.insert(frames, Child)
			end
		end
		if #frames > MAX_SHOWN then
			local oldest
			for _, f in ipairs(frames) do
				if not oldest or f.LayoutOrder > oldest.LayoutOrder then
					oldest = f
				end
			end
			if oldest then
				oldest:Destroy()
			end
		end
	end

	local function SelectPrompt(log)
		if View.CurrentPrompt == log then
			return
		end

		if View.CurrentButton then
			wax.shared.TweenService
				:Create(View.CurrentButton, Constants.DefaultTweenInfo, { BackgroundTransparency = 1 })
				:Play()
		end

		View.CurrentPrompt = log
		local rec = log and Buttons[log]
		View.CurrentButton = rec and rec.Root or nil
		if View.CurrentButton then
			wax.shared.TweenService
				:Create(View.CurrentButton, Constants.DefaultTweenInfo, { BackgroundTransparency = 0 })
				:Play()
		end

		DetailHeader.Text = log and PromptPath(log) or "Select a prompt to see its activations"
		RenderActivations(log)
	end

	--// Left-list buttons //-----------------------------------------------------------------------
	local function RefreshButton(log)
		local rec = Buttons[log]
		if not rec then
			return
		end
		rec.Name.Text = PromptTitle(log)
		rec.Count.Text = "x" .. #log.Activations
		local dim = log.Ignored
		rec.Name.TextTransparency = dim and 0.55 or 0
		rec.Count.TextTransparency = dim and 0.55 or 0.2
		rec.Icon.ImageTransparency = dim and 0.6 or 0.15
	end

	local function CreateButton(log)
		local Root = Interface.New("TextButton", {
			BackgroundColor3 = SELECTED,
			BackgroundTransparency = 1,
			LayoutOrder = log.Index or 1,
			Size = UDim2.new(1, 0, 0, 30),
			Text = "",
			Parent = PromptList,

			["UICorner"] = {
				CornerRadius = UDim.new(0, 4),
			},

			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 6),
				PaddingRight = UDim.new(0, 6),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		local Icon = Interface.NewIcon("mouse-pointer-click", {
			ImageTransparency = 0.15,
			Size = UDim2.fromScale(1, 1),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Parent = Root,
		})

		local Name = Interface.New("TextLabel", {
			Position = UDim2.fromOffset(24, 0),
			Size = UDim2.new(1, -48, 1, 0),
			Text = PromptTitle(log),
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Root,
		})

		local Count = Interface.New("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			Text = "x" .. #log.Activations,
			TextSize = 15,
			TextTransparency = 0.2,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = Root,
		})

		Root.MouseButton1Click:Connect(function()
			SelectPrompt(log)
		end)

		local Menu = ContextMenu:Create(Root, {
			{
				Text = function()
					return log.Ignored and "Unignore" or "Ignore"
				end,
				Icon = function()
					return log.Ignored and "eye" or "eye-off"
				end,
				Callback = function()
					PromptSpy.SetIgnored(log, not log.Ignored)
					wax.shared.Sonner.success(
						(log.Ignored and "Started ignoring " or "Stopped ignoring ") .. PromptTitle(log)
					)
				end,
			},
			{
				Text = "Clear activations",
				Icon = "trash",
				Callback = function()
					PromptSpy.Clear(log)
				end,
			},
		}, true)
		Root.MouseButton2Click:Connect(Menu.Toggle)
		Menu:BindLongPress(Root)

		local rec = { Root = Root, Name = Name, Count = Count, Icon = Icon }
		Buttons[log] = rec
		return rec
	end

	local function EnsureButton(log)
		if Buttons[log] then
			return
		end
		CreateButton(log)
		PromptCount += 1
		HeaderCount.Text = tostring(PromptCount)
	end

	--// Live capture subscription //---------------------------------------------------------------
	PromptSpy.Subscribe(function(kind, log, snap)
		if kind == "ensure" then
			EnsureButton(log)
			RefreshButton(log)
			UpdateEmptyState()
		elseif kind == "activation" then
			EnsureButton(log)
			RefreshButton(log)
			if log == View.CurrentPrompt then
				AppendActivation(snap)
			end
			-- keep the detail header's path fresh as new snapshots arrive
			if log == View.CurrentPrompt then
				DetailHeader.Text = PromptPath(log)
			end
			UpdateEmptyState()
		elseif kind == "ignore" then
			RefreshButton(log)
		elseif kind == "clear" then
			if log == nil then
				for _, rec in pairs(Buttons) do
					rec.Root:Destroy()
				end
				table.clear(Buttons)
				PromptCount = 0
				HeaderCount.Text = "0"
				View.CurrentPrompt = nil
				View.CurrentButton = nil
				ClearActivationFrames()
				DetailHeader.Text = "Select a prompt to see its activations"
				UpdateEmptyState()
			else
				RefreshButton(log)
				if log == View.CurrentPrompt then
					RenderActivations(log)
				end
			end
		end
	end)

	-- seed from anything captured before the view existed
	for _, log in pairs(wax.shared.PromptLogs or {}) do
		EnsureButton(log)
		RefreshButton(log)
	end
	UpdateEmptyState()

	--// Public //----------------------------------------------------------------------------------
	function View.ClearAll()
		PromptSpy.Clear(nil)
		if wax.shared.Sonner then
			wax.shared.Sonner.success("Cleared prompt activity")
		end
	end

	return View
end
