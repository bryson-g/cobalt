--!nonstrict
-- rh-farm fork — shared type-aware value editor.
--
-- Extracted from the Explorer's property pane so the Playground can edit remote arguments with the
-- same controls instead of a second, drifting implementation. The caller supplies a holder frame and
-- an onCommit callback; this decides which control the value's type deserves and fills the holder.
--
-- Build() returns false for types it can't meaningfully edit (instances, functions, tables), letting
-- the caller fall back to a read-only row rather than pretending the value is editable.

local Interface = require("@src/Utils/UI/Interface")

local ValueEditor = {}

local function round(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

--- Compact, readable rendering of any Roblox value.
function ValueEditor.Format(value): string
	local t = typeof(value)
	if value == nil then
		return "nil"
	elseif t == "string" then
		local s = value:gsub("\n", "\\n")
		return #s > 120 and (s:sub(1, 120) .. "…") or s
	elseif t == "number" then
		return tostring(round(value))
	elseif t == "boolean" then
		return value and "true" or "false"
	elseif t == "Vector3" then
		return ("%s, %s, %s"):format(round(value.X), round(value.Y), round(value.Z))
	elseif t == "Vector2" then
		return ("%s, %s"):format(round(value.X), round(value.Y))
	elseif t == "CFrame" then
		local p = value.Position
		return ("%s, %s, %s"):format(round(p.X), round(p.Y), round(p.Z))
	elseif t == "Color3" then
		return ("%d, %d, %d"):format(value.R * 255, value.G * 255, value.B * 255)
	elseif t == "UDim2" then
		return ("%s, %d, %s, %d"):format(round(value.X.Scale), value.X.Offset, round(value.Y.Scale), value.Y.Offset)
	elseif t == "UDim" then
		return ("%s, %d"):format(round(value.Scale), value.Offset)
	elseif t == "EnumItem" then
		return value.Name
	elseif t == "Instance" then
		return ("%s (%s)"):format(value.Name, value.ClassName)
	elseif t == "BrickColor" then
		return value.Name
	elseif t == "table" then
		local count = 0
		for _ in pairs(value) do
			count += 1
		end
		return ("table (%d)"):format(count)
	end
	return tostring(value)
end

-- "1, 2, 3" -> { 1, 2, 3 }; nil unless at least `count` numbers parse
local function ParseNumbers(text: string, count: number): { number }?
	local numbers = {}
	for piece in tostring(text):gmatch("[^,%s]+") do
		numbers[#numbers + 1] = tonumber(piece)
	end
	for index = 1, count do
		if numbers[index] == nil then
			return nil
		end
	end
	return numbers
end

--// Controls //------------------------------------------------------------------------------------

local function TextControl(holder, text: string, commit: (string) -> ())
	local Box = Interface.New("TextBox", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = holder,

		["UIPadding"] = { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) },
	})
	Box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			commit(Box.Text)
		end
	end)
	return Box
end

local function ButtonControl(holder, text: string)
	return Interface.New("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = holder,

		["UIPadding"] = { PaddingLeft = UDim.new(0, 6) },
	})
end

-- One colour picker at a time, shared across every editor on screen.
local ActivePicker

function ValueEditor.ClosePicker()
	if not ActivePicker then
		return
	end
	pcall(function()
		ActivePicker.Popup:Destroy()
		ActivePicker.Backdrop:Destroy()
	end)
	ActivePicker = nil
end

-- Swatch grid over the 128 BrickColor palette entries; doubles as the Color3 picker.
local function OpenPalette(anchor, onPick: (BrickColor) -> ())
	ValueEditor.ClosePicker()
	local screen = wax.shared.ScreenGui
	local origin = screen.AbsolutePosition

	local Backdrop = Interface.New("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 3999,
		Parent = screen,
	})

	local Popup = Interface.New("Frame", {
		BackgroundColor3 = Color3.fromRGB(20, 20, 20),
		Size = UDim2.fromOffset(190, 200),
		Position = UDim2.fromOffset(anchor.AbsolutePosition.X - origin.X, anchor.AbsolutePosition.Y - origin.Y + 22),
		ZIndex = 4000,
		Parent = screen,

		["UICorner"] = { CornerRadius = UDim.new(0, 6) },
		["UIStroke"] = { Color = Color3.fromRGB(70, 70, 70) },
		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
		},
	})

	local Grid = Interface.New("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		ZIndex = 4001,
		Parent = Popup,

		["UIGridLayout"] = {
			CellSize = UDim2.fromOffset(19, 19),
			CellPadding = UDim2.fromOffset(3, 3),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	})

	for index = 0, 127 do
		local brick = BrickColor.palette(index)
		local Swatch = Interface.New("TextButton", {
			BackgroundColor3 = brick.Color,
			Size = UDim2.fromOffset(19, 19),
			LayoutOrder = index,
			Text = "",
			ZIndex = 4002,
			Parent = Grid,

			["UICorner"] = { CornerRadius = UDim.new(0, 3) },
		})
		Swatch.MouseButton1Click:Connect(function()
			onPick(brick)
			ValueEditor.ClosePicker()
		end)
	end

	Backdrop.MouseButton1Click:Connect(ValueEditor.ClosePicker)
	ActivePicker = { Popup = Popup, Backdrop = Backdrop }
end

--// Build //---------------------------------------------------------------------------------------

--- Fill `holder` with the control this value's type deserves. opts.ContextMenu is required for enum
--- dropdowns; opts.Warn (optional) reports invalid input. Returns false if the type isn't editable.
function ValueEditor.Build(holder, value, opts, onCommit: (any) -> ()): boolean
	opts = opts or {}
	local warn_ = opts.Warn or function(message)
		if wax.shared.Sonner then
			wax.shared.Sonner.warning(message)
		end
	end
	local valueType = typeof(value)

	if valueType == "boolean" then
		local button = ButtonControl(holder, value and "true" or "false")
		button.MouseButton1Click:Connect(function()
			onCommit(not value)
		end)
		return true
	elseif valueType == "number" then
		TextControl(holder, tostring(round(value)), function(text)
			local parsed = tonumber(text)
			if parsed == nil then
				warn_("Expected a number")
				return
			end
			onCommit(parsed)
		end)
		return true
	elseif valueType == "string" then
		TextControl(holder, value, function(text)
			onCommit(text)
		end)
		return true
	elseif valueType == "EnumItem" then
		local button = ButtonControl(holder, value.Name .. "  ▾")
		local menu
		button.MouseButton1Click:Connect(function()
			if not menu and opts.ContextMenu then
				local options = {}
				for _, item in ipairs(value.EnumType:GetEnumItems()) do
					options[#options + 1] = {
						Text = item.Name,
						Callback = function()
							onCommit(item)
						end,
					}
				end
				menu = opts.ContextMenu:Create(button, options, true, { MaxHeight = 220 })
			end
			if menu then
				menu.Toggle()
			end
		end)
		return true
	elseif valueType == "BrickColor" or valueType == "Color3" then
		local isBrick = valueType == "BrickColor"
		local colour = isBrick and value.Color or value
		local Swatch = Interface.New("TextButton", {
			BackgroundColor3 = colour,
			Position = UDim2.fromOffset(3, 2),
			Size = UDim2.fromOffset(14, 14),
			Text = "",
			Parent = holder,
			["UICorner"] = { CornerRadius = UDim.new(0, 3) },
		})
		local label = ButtonControl(holder, ValueEditor.Format(value))
		label.Position = UDim2.fromOffset(20, 0)
		label.Size = UDim2.new(1, -20, 1, 0)

		local function pick()
			OpenPalette(Swatch, function(brick)
				onCommit(isBrick and brick or brick.Color)
			end)
		end
		Swatch.MouseButton1Click:Connect(pick)
		label.MouseButton1Click:Connect(pick)
		return true
	elseif valueType == "Vector3" or valueType == "Vector2" then
		local count = valueType == "Vector3" and 3 or 2
		TextControl(holder, ValueEditor.Format(value), function(text)
			local n = ParseNumbers(text, count)
			if not n then
				warn_(("Expected %d numbers"):format(count))
				return
			end
			onCommit(count == 3 and Vector3.new(n[1], n[2], n[3]) or Vector2.new(n[1], n[2]))
		end)
		return true
	elseif valueType == "UDim2" then
		TextControl(holder, ValueEditor.Format(value), function(text)
			local n = ParseNumbers(text, 4)
			if not n then
				warn_("Expected scaleX, offsetX, scaleY, offsetY")
				return
			end
			onCommit(UDim2.new(n[1], n[2], n[3], n[4]))
		end)
		return true
	elseif valueType == "UDim" then
		TextControl(holder, ValueEditor.Format(value), function(text)
			local n = ParseNumbers(text, 2)
			if not n then
				warn_("Expected scale, offset")
				return
			end
			onCommit(UDim.new(n[1], n[2]))
		end)
		return true
	elseif valueType == "CFrame" then
		-- position only; the existing rotation is preserved so editing can't silently un-rotate
		TextControl(holder, ValueEditor.Format(value), function(text)
			local n = ParseNumbers(text, 3)
			if not n then
				warn_("Expected x, y, z")
				return
			end
			onCommit(CFrame.new(n[1], n[2], n[3]) * (value - value.Position))
		end)
		return true
	end

	return false
end

return ValueEditor
