--!nonstrict
-- rh-farm fork — Seats view: every seat the character has sat on, newest first.
-- Click a row to select it; right-click for "Inspect in explorer", which jumps to the Inspect tab
-- with that seat revealed in the tree. Deliberately a flat vertical log (not grouped) — sitting is a
-- sequence of events, and the order is the useful part.

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")

local BG = Color3.fromRGB(25, 25, 25)
local SELECT_BLUE = Color3.fromRGB(38, 96, 190)

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
	SeatSpy: any,
	OnInspect: ((Instance) -> ())?,
})
	local MainFrame = props.MainFrame
	local ContextMenu = props.ContextMenu
	local SeatSpy = props.SeatSpy

	local View = { Selected = nil }
	local SelectedRow = nil
	local Rows = 0

	--// Layout //---------------------------------------------------------------------------------
	local Wrapper = Interface.New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.yAxis,
		Size = UDim2.new(1, 0, 1, -36),
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
		Parent = Wrapper,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		["UIPadding"] = { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) },
	})

	Interface.New("TextLabel", {
		Text = "Seats sat on",
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
		Parent = Wrapper,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local EmptyHint = Interface.New("TextLabel", {
		Text = "No seats yet — sit on something in game and it shows up here.",
		TextSize = 13,
		TextWrapped = true,
		TextTransparency = 0.45,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 40),
		Parent = ListWrapper,
	})

	local List = Interface.New("ScrollingFrame", {
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

	--// Rows //-----------------------------------------------------------------------------------
	local function Select(row)
		if SelectedRow and SelectedRow ~= row then
			SelectedRow.BackgroundTransparency = 1
			SelectedRow.BackgroundColor3 = BG
		end
		SelectedRow = row
		row.BackgroundColor3 = SELECT_BLUE
		row.BackgroundTransparency = 0
	end

	local function AddRow(event)
		Rows += 1
		EmptyHint.Visible = false
		HeaderCount.Text = tostring(Rows)

		local Row = Interface.New("TextButton", {
			BackgroundColor3 = BG,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			-- newest first: UIListLayout sorts ascending, so newer rows get a smaller order
			LayoutOrder = -(event.index or Rows),
			Text = "",
			Parent = List,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			["UIListLayout"] = { Padding = UDim.new(0, 2) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
			},
		})

		local Top = Interface.New("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			Parent = Row,
		})

		Interface.NewIcon("armchair", {
			ImageTransparency = 0.25,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(16, 16),
			Parent = Top,
		})

		Interface.New("TextLabel", {
			Position = UDim2.fromOffset(22, 0),
			Size = UDim2.new(1, -90, 1, 0),
			Text = ("%s  ·  %s"):format(tostring(event.name), tostring(event.class)),
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = Top,
		})

		Interface.New("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 80, 1, 0),
			Text = os.date("%X", event.time or os.time()),
			TextSize = 14,
			TextTransparency = 0.5,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = Top,
		})

		Interface.New("TextLabel", {
			Text = tostring(event.path or "?"),
			TextSize = 12,
			TextTransparency = 0.4,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Row,
		})

		Row.MouseButton1Click:Connect(function()
			View.Selected = event
			Select(Row)
		end)

		local Menu = ContextMenu:Create(Row, {
			{
				Text = "Inspect in explorer",
				Icon = "search",
				Callback = function()
					View.Selected = event
					Select(Row)
					if event.seat and props.OnInspect then
						props.OnInspect(event.seat)
					elseif wax.shared.Sonner then
						wax.shared.Sonner.warning("That seat no longer exists")
					end
				end,
			},
			{
				Text = "Copy path",
				Icon = "clipboard",
				Callback = function()
					local ok = pcall(setclipboard, tostring(event.path))
					if wax.shared.Sonner then
						if ok then
							wax.shared.Sonner.success("Copied seat path")
						else
							wax.shared.Sonner.error("Failed to copy path")
						end
					end
				end,
			},
			{
				Text = "Clear all",
				Icon = "trash",
				Callback = function()
					SeatSpy.Clear()
				end,
			},
		}, true)
		Row.MouseButton2Click:Connect(Menu.Toggle)
		Menu:BindLongPress(Row)
	end

	local function ClearRows()
		for _, child in ipairs(List:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		Rows = 0
		SelectedRow = nil
		View.Selected = nil
		HeaderCount.Text = "0"
		EmptyHint.Visible = true
	end

	--// Live //-----------------------------------------------------------------------------------
	SeatSpy.Subscribe(function(kind, event)
		if kind == "sat" then
			AddRow(event)
		elseif kind == "clear" then
			ClearRows()
		end
	end)

	-- seed anything captured before the view existed
	for _, event in ipairs(wax.shared.SeatLogs or {}) do
		AddRow(event)
	end

	function View.ClearAll()
		SeatSpy.Clear()
	end

	return View
end
