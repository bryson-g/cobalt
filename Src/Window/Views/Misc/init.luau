--!nonstrict
-- rh-farm fork — Misc: a scrolling list of small one-off tools that don't warrant their own tab.
-- Each tool is a card (title, hint line, a row of buttons); add another by calling Card(...) below.
--
-- First tool: copy the character's CFrame (position + orientation in one value) and return to the
-- last copied one. The copied CFrame is kept in memory exactly, so the return is lossless; the
-- clipboard string is the same value rounded for readability/paste.

local Interface = require("@src/Utils/UI/Interface")

local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
})
	local MainFrame = props.MainFrame

	--// Layout //---------------------------------------------------------------------------------
	local Wrapper = Interface.New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.yAxis,
		Size = UDim2.new(1, 0, 1, -36),
		Position = UDim2.fromScale(0, 1),
		Parent = MainFrame,

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		},
	})

	local List = Interface.New("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		Parent = Wrapper,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 8),
		},

		["UIPadding"] = { PaddingRight = UDim.new(0, 4) },
	})

	local order = 0

	--- A tool card. Returns the card + a Button(text, colour?, callback) helper for its action row.
	local function Card(title: string, hint: string?)
		order += 1
		local Root = Interface.New("Frame", {
			BackgroundColor3 = BG,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = order,
			Parent = List,

			["UICorner"] = { CornerRadius = UDim.new(0, 6) },
			["UIListLayout"] = { Padding = UDim.new(0, 6) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 10),
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 10),
			},
		})

		Interface.New("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			Text = title,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Root,
		})

		local HintLabel = Interface.New("TextLabel", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 16),
			LayoutOrder = 1,
			Text = hint or "",
			TextSize = 13,
			TextTransparency = 0.4,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = hint ~= nil,
			Parent = Root,
		})

		local Actions = Interface.New("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			LayoutOrder = 2,
			Parent = Root,

			["UIListLayout"] = {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 6),
			},
		})

		local buttonOrder = 0
		local function Button(text: string, colour: Color3?, callback: () -> ())
			buttonOrder += 1
			local btn = Interface.New("TextButton", {
				BackgroundColor3 = colour or Color3.fromRGB(45, 45, 45),
				Size = UDim2.fromOffset(#text * 7 + 18, 24),
				LayoutOrder = buttonOrder,
				Text = text,
				TextSize = 13,
				Parent = Actions,

				["UICorner"] = { CornerRadius = UDim.new(0, 4) },
			})
			btn.MouseButton1Click:Connect(callback)
			return btn
		end

		return { Root = Root, Hint = HintLabel, Button = Button }
	end

	--// Tool: character CFrame //------------------------------------------------------------------
	do
		local LastCFrame = nil

		local function character()
			local player = wax.shared.LocalPlayer
			return player and player.Character
		end

		local function round(n)
			return math.floor(n * 1000 + 0.5) / 1000
		end

		-- Full 12-component CFrame string, so orientation is preserved on paste (not just position).
		local function toString(cf): string
			local parts = {}
			for _, component in ipairs({ cf:GetComponents() }) do
				parts[#parts + 1] = round(component)
			end
			return ("CFrame.new(%s)"):format(table.concat(parts, ", "))
		end

		local card = Card("Character CFrame", "Nothing copied yet.")
		local returnButton

		card.Button("Copy CFrame", Color3.fromRGB(45, 70, 110), function()
			local char = character()
			local ok, cf = pcall(function()
				return char:GetPivot()
			end)
			if not (ok and typeof(cf) == "CFrame") then
				wax.shared.Sonner.error("No character to read")
				return
			end
			LastCFrame = cf
			local text = toString(cf)
			card.Hint.Text = "Copied: " .. text
			if returnButton then
				returnButton.TextTransparency = 0
				returnButton.BackgroundColor3 = Color3.fromRGB(40, 90, 60)
			end
			if pcall(setclipboard, text) then
				wax.shared.Sonner.success("Copied character CFrame")
			else
				wax.shared.Sonner.warning("Saved CFrame (clipboard unavailable)")
			end
		end)

		returnButton = card.Button("Return to copied", Color3.fromRGB(35, 35, 35), function()
			if not LastCFrame then
				wax.shared.Sonner.warning("Copy a CFrame first")
				return
			end
			local char = character()
			local ok = char
				and pcall(function()
					char:PivotTo(LastCFrame)
				end)
			if ok then
				wax.shared.Sonner.success("Returned to copied CFrame")
			else
				wax.shared.Sonner.error("Couldn't move the character")
			end
		end)
		returnButton.TextTransparency = 0.5 -- dim until something's been copied
	end

	return {}
end
