--!nonstrict
-- rh-farm fork — Inspection view: Cmd+Click anything in the world to inspect it.
--
-- Left  = a Dex-style explorer tree (rooted at `game`, expand/collapse, auto-revealed to whatever you
--         just clicked, so you see the picked instance IN CONTEXT — its ancestors and its children).
-- Right = the details for the selected instance: name, class, full path, properties, attributes, tags.
--
-- Picking uses Mouse.Target (the part under the cursor) gated on the Command key. Clicks the engine
-- already routed to a GUI are skipped, so clicking Cobalt's own window never re-picks.
--
-- Properties: Luau has no generic property reflection without an API dump, so we read curated,
-- IsA-gated lists per class. That's deliberate — a real property name always wins over a same-named
-- child in Roblox's index order, so gating by IsA keeps the reads honest (no child shadowing).

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")
local Icons = require("@src/Utils/UI/Assets/Icons")

local BG = Color3.fromRGB(25, 25, 25)
local BG_INNER = Color3.fromRGB(15, 15, 15)
local SELECTED = Color3.fromRGB(50, 50, 50)
local SELECT_BLUE = Color3.fromRGB(38, 96, 190) -- selected explorer row

local ROW_HEIGHT = 22
local ROW_PADDING = 2
local INDENT = 14
local MAX_CHILDREN_PER_NODE = 200 -- a single node can hold thousands; cap what we render
local MAX_ROWS = 600

-- Lucide icon per class family (Cobalt only ships class images for remotes).
local function IconFor(instance): string
	local ok, isA = pcall(function()
		return function(class)
			return instance:IsA(class)
		end
	end)
	if not ok then
		return "circle"
	end
	if isA("Folder") then return "folder" end
	if isA("Model") then return "boxes" end
	if isA("LuaSourceContainer") then return "file-code" end
	if isA("ProximityPrompt") then return "mouse-pointer-click" end
	if isA("ClickDetector") then return "hand" end
	if isA("Attachment") then return "anchor" end
	if isA("Humanoid") then return "user" end
	if isA("Sound") then return "volume-2" end
	if isA("Decal") or isA("Texture") then return "image" end
	if isA("Light") then return "lightbulb" end
	if isA("Camera") then return "video" end
	if isA("ValueBase") then return "variable" end
	if isA("RemoteEvent") or isA("RemoteFunction") or isA("BindableEvent") or isA("BindableFunction") then
		return "radio"
	end
	if isA("LayerCollector") then return "app-window" end
	if isA("GuiObject") then return "square" end
	if isA("MeshPart") then return "box" end
	if isA("BasePart") then return "box" end
	if isA("Players") or isA("Player") then return "users" end
	if isA("Workspace") then return "globe" end
	return "circle"
end

-- IsA-gated property lists. Order matters only for readability.
local PROPERTY_SETS = {
	{ "Instance", { "Name", "ClassName", "Archivable" } },
	{ "BasePart", {
		"Size", "Position", "Orientation", "Anchored", "CanCollide", "CanQuery", "CanTouch",
		"Massless", "Material", "BrickColor", "Color", "Transparency", "Reflectance", "CastShadow",
		"CollisionGroup", "Shape", "AssemblyLinearVelocity",
	} },
	{ "MeshPart", { "MeshId", "TextureID", "DoubleSided" } },
	{ "Model", { "PrimaryPart", "WorldPivot", "ModelStreamingMode" } },
	{ "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "RigType", "DisplayName" } },
	{ "ProximityPrompt", {
		"ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled",
		"RequiresLineOfSight", "KeyboardKeyCode", "GamepadKeyCode", "Style", "Exclusivity", "UIOffset",
	} },
	{ "ClickDetector", { "MaxActivationDistance", "CursorIcon" } },
	{ "Attachment", { "Position", "Orientation", "WorldPosition", "Visible", "Axis" } },
	{ "Sound", { "SoundId", "Volume", "Playing", "Looped", "TimePosition", "TimeLength", "PlaybackSpeed" } },
	{ "Decal", { "Texture", "Transparency", "Face", "Color3" } },
	{ "Light", { "Brightness", "Color", "Enabled", "Shadows", "Range" } },
	{ "ValueBase", { "Value" } },
	{ "GuiObject", {
		"Position", "Size", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency",
		"Visible", "ZIndex", "ClipsDescendants", "Rotation", "LayoutOrder",
	} },
	{ "TextLabel", { "Text", "TextColor3", "TextSize", "TextTransparency", "RichText", "Font" } },
	{ "TextButton", { "Text", "TextColor3", "TextSize", "AutoButtonColor" } },
	{ "TextBox", { "Text", "PlaceholderText", "ClearTextOnFocus" } },
	{ "ImageLabel", { "Image", "ImageColor3", "ImageTransparency", "ScaleType" } },
	{ "ImageButton", { "Image", "ImageColor3", "ImageTransparency" } },
	{ "LayerCollector", { "Enabled", "ResetOnSpawn", "ZIndexBehavior", "DisplayOrder" } },
	{ "Camera", { "CFrame", "FieldOfView", "CameraType", "CameraSubject" } },
}

local function round(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

-- Render any Roblox value into a compact, readable string.
local function FormatValue(value): string
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
		return ("pos %s, %s, %s"):format(round(p.X), round(p.Y), round(p.Z))
	elseif t == "Color3" then
		return ("RGB %d, %d, %d"):format(value.R * 255, value.G * 255, value.B * 255)
	elseif t == "UDim2" then
		return ("{%s, %d}, {%s, %d}"):format(round(value.X.Scale), value.X.Offset, round(value.Y.Scale), value.Y.Offset)
	elseif t == "UDim" then
		return ("{%s, %d}"):format(round(value.Scale), value.Offset)
	elseif t == "EnumItem" then
		return value.Name
	elseif t == "Instance" then
		return ("%s (%s)"):format(value.Name, value.ClassName)
	elseif t == "BrickColor" then
		return value.Name
	end
	return tostring(value)
end

return function(props: {
	MainFrame: GuiObject,
	ContextMenu: any,
	GetDPIScale: () -> number,
	OnPicked: ((Instance) -> ())?, -- fired on a world pick, so the window can surface this tab
})
	local MainFrame = props.MainFrame
	local ContextMenu = props.ContextMenu

	local View = {
		Selected = nil,
	}
	local Expanded = {} -- [instance] = true
	local RowByInstance = {} -- [instance] = row TextButton (current render only)
	local SelectedRow = nil
	local FlatRows = {} -- current render order, for scroll-to-reveal

	-- Filter state. SearchVisible is the set of nodes to draw while filtering (matches AND their
	-- ancestors, so a hit is shown in context); SearchMatches is just the hits, for highlighting.
	-- Both nil when not filtering, which restores the normal expand/collapse tree untouched.
	local SearchVisible, SearchMatches = nil, nil
	local MATCH_YELLOW = Color3.fromRGB(235, 200, 110)

	--// Left: explorer tree //---------------------------------------------------------------------
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
		Text = "Explorer",
		TextSize = 15,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = Header,
	})

	local RefreshLabel = Interface.New("TextButton", {
		BackgroundTransparency = 1,
		Text = "refresh",
		TextSize = 13,
		TextTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = Header,
	})

	-- Arms a one-shot pick that needs NO modifier — the fallback if the platform doesn't report the
	-- Command key the way we expect. Sits just left of "refresh".
	local PickButton = Interface.New("TextButton", {
		BackgroundTransparency = 1,
		Text = "pick",
		TextSize = 13,
		TextTransparency = 0.45,
		Size = UDim2.new(1, -52, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = Header,
	})

	-- Same idea for on-screen UI: hover to outline whatever GuiObject is under the cursor, click to
	-- reveal it in the tree.
	local UIPickButton = Interface.New("TextButton", {
		BackgroundTransparency = 1,
		Text = "pick ui",
		TextSize = 13,
		TextTransparency = 0.45,
		Size = UDim2.new(1, -92, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = Header,
	})

	-- Filter box. Matching is over Name and ClassName; matches are shown with their ancestor chain so
	-- you still see where each hit lives.
	local SearchBox = Interface.New("TextBox", {
		BackgroundColor3 = BG_INNER,
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "",
		PlaceholderText = "Search name or class…",
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		["UIPadding"] = { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) },
	})

	local TreeWrapper = Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -66), -- header (30) + search (24) + gaps
		Parent = LeftList,

		["UICorner"] = { CornerRadius = UDim.new(0, 4) },
	})

	local Tree = Interface.New("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 2,
		Parent = TreeWrapper,

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, ROW_PADDING),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 4),
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
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

	--// Right: details //--------------------------------------------------------------------------
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
		Text = "⌘ + Click anything in the world to inspect it",
		TextSize = 14,
		TextTransparency = 0.35,
		Size = UDim2.new(1, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = RightWrap,
	})

	local Details = Interface.New("ScrollingFrame", {
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

	--// Details rendering //-----------------------------------------------------------------------
	local ClosePicker -- defined with the property editors below; ClearDetails calls it

	local function ClearDetails()
		ClosePicker() -- a popup anchored to a row we're about to destroy would be orphaned
		for _, child in ipairs(Details:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
	end

	local function Section(title: string, order: number)
		local Block = Interface.New("Frame", {
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = BG,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = order,
			Parent = Details,

			Constants.MainUICorner,
			["UIListLayout"] = { Padding = UDim.new(0, 4) },
			["UIPadding"] = {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 8),
			},
		})

		Interface.New("TextLabel", {
			Text = title,
			TextSize = 14,
			TextTransparency = 0.4,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Block,
		})

		return Block
	end

	--// Property editing //-------------------------------------------------------------------------
	-- Luau can't tell writable from read-only without an API dump, so rather than probing by writing
	-- (which would fire side effects), the handful of read-only names in our curated lists are listed
	-- here. Anything else gets an editor, and every write is pcall'd so a rejected assignment surfaces
	-- as a toast instead of an error.
	local READ_ONLY = {
		ClassName = true,
		TimeLength = true,
		AbsolutePosition = true,
		AbsoluteSize = true,
	}

	local ActivePicker -- { Popup, Backdrop } — only one colour picker open at a time

	ClosePicker = function()
		if not ActivePicker then
			return
		end
		pcall(function()
			ActivePicker.Popup:Destroy()
			ActivePicker.Backdrop:Destroy()
		end)
		ActivePicker = nil
	end

	local RenderDetailsRef -- assigned below; edits re-render so dependent values update

	local function ApplyProperty(instance, name: string, value): boolean
		local ok, err = pcall(function()
			instance[name] = value
		end)
		if ok then
			if RenderDetailsRef then
				RenderDetailsRef(instance)
			end
		else
			wax.shared.Sonner.error(("Couldn't set %s — %s"):format(name, tostring(err)))
		end
		return ok
	end

	-- "1, 2, 3" -> { 1, 2, 3 }; nil if fewer than `count` numbers were given
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

	local function EditorHolder(row)
		return Interface.New("Frame", {
			BackgroundColor3 = Color3.fromRGB(34, 34, 34),
			Position = UDim2.new(0.38, 0, 0, 0),
			Size = UDim2.new(0.62, 0, 0, 18),
			Parent = row,

			["UICorner"] = { CornerRadius = UDim.new(0, 3) },
		})
	end

	local function TextEditor(holder, text: string, commit: (string) -> ())
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

	local function ButtonEditor(holder, text: string)
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

	-- Swatch grid over the 128 BrickColor palette entries, which doubles as the Color3 picker (a full
	-- HSV wheel is overkill here; the palette is what these properties are usually set from anyway).
	local function OpenPalette(anchor, onPick: (BrickColor) -> ())
		ClosePicker()
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
			Position = UDim2.fromOffset(
				anchor.AbsolutePosition.X - origin.X,
				anchor.AbsolutePosition.Y - origin.Y + 22
			),
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
				ClosePicker()
			end)
		end

		Backdrop.MouseButton1Click:Connect(ClosePicker)
		ActivePicker = { Popup = Popup, Backdrop = Backdrop }
	end

	-- Build the right editor for the value's type. Returns false when the type isn't editable here.
	local function BuildEditor(row, instance, name: string, value): boolean
		local valueType = typeof(value)

		if valueType == "boolean" then
			local holder = EditorHolder(row)
			local button = ButtonEditor(holder, value and "true" or "false")
			button.MouseButton1Click:Connect(function()
				ApplyProperty(instance, name, not value)
			end)
			return true
		elseif valueType == "number" then
			local holder = EditorHolder(row)
			TextEditor(holder, tostring(round(value)), function(text)
				local parsed = tonumber(text)
				if parsed == nil then
					wax.shared.Sonner.warning(name .. " expects a number")
					return
				end
				ApplyProperty(instance, name, parsed)
			end)
			return true
		elseif valueType == "string" then
			local holder = EditorHolder(row)
			TextEditor(holder, value, function(text)
				ApplyProperty(instance, name, text)
			end)
			return true
		elseif valueType == "EnumItem" then
			local holder = EditorHolder(row)
			local button = ButtonEditor(holder, value.Name .. "  ▾")
			local menu
			button.MouseButton1Click:Connect(function()
				if not menu then
					local options = {}
					for _, item in ipairs(value.EnumType:GetEnumItems()) do
						options[#options + 1] = {
							Text = item.Name,
							Callback = function()
								ApplyProperty(instance, name, item)
							end,
						}
					end
					menu = ContextMenu:Create(button, options, true, { MaxHeight = 220 })
				end
				menu.Toggle()
			end)
			return true
		elseif valueType == "BrickColor" or valueType == "Color3" then
			local isBrick = valueType == "BrickColor"
			local colour = isBrick and value.Color or value
			local holder = EditorHolder(row)
			local Swatch = Interface.New("TextButton", {
				BackgroundColor3 = colour,
				Position = UDim2.fromOffset(3, 2),
				Size = UDim2.fromOffset(14, 14),
				Text = "",
				Parent = holder,
				["UICorner"] = { CornerRadius = UDim.new(0, 3) },
			})
			local label = ButtonEditor(holder, "")
			label.Position = UDim2.fromOffset(20, 0)
			label.Size = UDim2.new(1, -20, 1, 0)
			label.Text = isBrick and value.Name
				or ("%d, %d, %d"):format(colour.R * 255, colour.G * 255, colour.B * 255)

			local function pick()
				OpenPalette(Swatch, function(brick)
					ApplyProperty(instance, name, isBrick and brick or brick.Color)
				end)
			end
			Swatch.MouseButton1Click:Connect(pick)
			label.MouseButton1Click:Connect(pick)
			return true
		elseif valueType == "Vector3" or valueType == "Vector2" then
			local count = valueType == "Vector3" and 3 or 2
			local holder = EditorHolder(row)
			TextEditor(holder, FormatValue(value), function(text)
				local n = ParseNumbers(text, count)
				if not n then
					wax.shared.Sonner.warning(("%s expects %d numbers"):format(name, count))
					return
				end
				ApplyProperty(instance, name, count == 3 and Vector3.new(n[1], n[2], n[3]) or Vector2.new(n[1], n[2]))
			end)
			return true
		elseif valueType == "UDim2" then
			local holder = EditorHolder(row)
			TextEditor(holder, FormatValue(value), function(text)
				local n = ParseNumbers(text, 4)
				if not n then
					wax.shared.Sonner.warning(name .. " expects scaleX, offsetX, scaleY, offsetY")
					return
				end
				ApplyProperty(instance, name, UDim2.new(n[1], n[2], n[3], n[4]))
			end)
			return true
		elseif valueType == "UDim" then
			local holder = EditorHolder(row)
			TextEditor(holder, FormatValue(value), function(text)
				local n = ParseNumbers(text, 2)
				if not n then
					wax.shared.Sonner.warning(name .. " expects scale, offset")
					return
				end
				ApplyProperty(instance, name, UDim.new(n[1], n[2]))
			end)
			return true
		elseif valueType == "CFrame" then
			-- position only; the existing rotation is preserved so this can't silently un-rotate things
			local holder = EditorHolder(row)
			TextEditor(holder, FormatValue(value), function(text)
				local n = ParseNumbers(text, 3)
				if not n then
					wax.shared.Sonner.warning(name .. " expects x, y, z")
					return
				end
				local rotation = value - value.Position
				ApplyProperty(instance, name, CFrame.new(n[1], n[2], n[3]) * rotation)
			end)
			return true
		end

		return false -- instances, and anything exotic, stay read-only
	end

	local function Row(parent, label: string, value: string, order: number)
		local Line = Interface.New("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = order,
			Parent = parent,
		})
		Interface.New("TextLabel", {
			Text = label,
			TextSize = 14,
			TextTransparency = 0.45,
			Size = UDim2.new(0.38, -4, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = Line,
		})
		Interface.New("TextLabel", {
			Text = value,
			TextSize = 14,
			Position = UDim2.new(0.38, 0, 0, 0),
			Size = UDim2.new(0.62, 0, 0, 18),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = Line,
		})
	end

	local function RenderDetails(instance)
		ClearDetails()
		if not instance then
			DetailHeader.Text = "⌘ + Click anything in the world to inspect it"
			return
		end

		local fullName = "?"
		pcall(function()
			fullName = instance:GetFullName()
		end)
		DetailHeader.Text = ("%s  ·  %s"):format(instance.Name, instance.ClassName)

		-- identity
		local identity = Section("Identity", 0)
		Row(identity, "Name", instance.Name, 1)
		Row(identity, "ClassName", instance.ClassName, 2)
		Row(identity, "Path", fullName, 3)
		local parent = instance.Parent
		Row(identity, "Parent", parent and ("%s (%s)"):format(parent.Name, parent.ClassName) or "nil", 4)
		local okKids, kids = pcall(function()
			return #instance:GetChildren()
		end)
		Row(identity, "Children", okKids and tostring(kids) or "?", 5)

		-- properties (IsA-gated)
		local propsBlock = Section("Properties", 1)
		local order, seen, any = 0, {}, false
		for _, set in ipairs(PROPERTY_SETS) do
			local class, names = set[1], set[2]
			local okIsA, isA = pcall(function()
				return instance:IsA(class)
			end)
			if okIsA and isA then
				for _, name in ipairs(names) do
					if not seen[name] then
						seen[name] = true
						local okRead, value = pcall(function()
							return instance[name]
						end)
						if okRead then
							order += 1
							any = true
							if READ_ONLY[name] then
								Row(propsBlock, name, FormatValue(value), order)
							else
								-- editable when we have an editor for the type; otherwise plain text
								local editRow = Interface.New("Frame", {
									BackgroundTransparency = 1,
									Size = UDim2.new(1, 0, 0, 18),
									LayoutOrder = order,
									Parent = propsBlock,
								})
								Interface.New("TextLabel", {
									Text = name,
									TextSize = 14,
									TextTransparency = 0.45,
									Size = UDim2.new(0.38, -4, 0, 18),
									TextXAlignment = Enum.TextXAlignment.Left,
									Parent = editRow,
								})
								if not BuildEditor(editRow, instance, name, value) then
									editRow:Destroy()
									Row(propsBlock, name, FormatValue(value), order)
								end
							end
						end
					end
				end
			end
		end
		if not any then
			Row(propsBlock, "—", "no known properties for this class", 1)
		end

		-- attributes
		local okAttrs, attrs = pcall(function()
			return instance:GetAttributes()
		end)
		if okAttrs and type(attrs) == "table" and next(attrs) ~= nil then
			local block = Section("Attributes", 2)
			local keys = {}
			for key in pairs(attrs) do
				keys[#keys + 1] = key
			end
			table.sort(keys)
			for index, key in ipairs(keys) do
				Row(block, key, FormatValue(attrs[key]), index)
			end
		end

		-- tags
		local okTags, tags = pcall(function()
			return game:GetService("CollectionService"):GetTags(instance)
		end)
		if okTags and type(tags) == "table" and #tags > 0 then
			local block = Section("Tags", 3)
			Row(block, "CollectionService", table.concat(tags, ", "), 1)
		end
	end

	RenderDetailsRef = RenderDetails -- property edits re-render the pane

	--// Tree rendering //--------------------------------------------------------------------------
	local RenderTree

	local function SelectInstance(instance, reveal: boolean?)
		View.Selected = instance
		if reveal and instance then
			-- expand every ancestor so the picked instance is visible in context
			local node = instance.Parent
			while node do
				Expanded[node] = true
				node = node.Parent
			end
		end
		RenderTree()
		RenderDetails(instance)
	end
	View.Select = SelectInstance

	local function ChildrenOf(instance)
		local ok, children = pcall(function()
			return instance:GetChildren()
		end)
		return ok and children or {}
	end

	--// Row actions //-----------------------------------------------------------------------------

	-- Where should the character stand to be "at" this instance? Parts/attachments/models each
	-- expose their position differently; otherwise fall back to the first positioned descendant.
	local function TargetPosition(instance): Vector3?
		local ok, position = pcall(function()
			if instance:IsA("BasePart") then
				return instance.Position
			elseif instance:IsA("Attachment") then
				return instance.WorldPosition
			elseif instance:IsA("Model") then
				return instance:GetPivot().Position
			end
			return nil
		end)
		if ok and position then
			return position
		end
		local descendant = instance:FindFirstChildWhichIsA("BasePart", true)
		return descendant and descendant.Position or nil
	end

	local function TeleportTo(instance)
		local position = TargetPosition(instance)
		if not position then
			wax.shared.Sonner.warning("Nothing to teleport to — that instance has no position")
			return
		end
		local character = wax.shared.LocalPlayer and wax.shared.LocalPlayer.Character
		if not character then
			wax.shared.Sonner.error("No character to teleport")
			return
		end
		-- lift slightly so we land on top of the target rather than inside it
		local ok = pcall(function()
			character:PivotTo(CFrame.new(position + Vector3.new(0, 4, 0)))
		end)
		if ok then
			wax.shared.Sonner.success(("Teleported to %s"):format(instance.Name))
		else
			wax.shared.Sonner.error("Teleport failed")
		end
	end

	-- Destroy is client-side only (it won't replicate for server-owned instances). Refuse the cases
	-- that would break the tool or error anyway.
	local function CanDelete(instance): (boolean, string?)
		if instance == game then
			return false, "can't delete the DataModel"
		end
		if instance.Parent == game then
			return false, "can't delete a service"
		end
		local isCobalt = false
		pcall(function()
			local screen = wax.shared.ScreenGui
			isCobalt = screen ~= nil and (instance == screen or instance:IsDescendantOf(screen))
		end)
		if isCobalt then
			return false, "that's Cobalt's own UI"
		end
		return true, nil
	end

	local RowPool, ActiveRows = {}, {}
	local TruncatedLabel

	-- Rows are POOLED. Re-rendering used to destroy and rebuild every row, and each row eagerly built
	-- its own ContextMenu (three option buttons with icons) — thousands of instances per expand click,
	-- which is where the sluggishness came from. Now a row is built once, reused, and only has its
	-- properties updated; its menu is created on first right-click and its handlers read the row's
	-- CURRENT instance, so a recycled row acts on the right thing.
	local function BuildRow()
		local rec = {}

		rec.Root = Interface.New("TextButton", {
			BackgroundColor3 = SELECTED,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			Text = "",

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		})

		rec.Chevron = Interface.New("ImageButton", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(14, 14),
			ImageTransparency = 0.35,
			Visible = false,
			Parent = rec.Root,
		})

		rec.Icon = Interface.New("ImageLabel", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(14, 14),
			ImageTransparency = 0.2,
			Parent = rec.Root,
		})

		rec.Label = Interface.New("TextLabel", {
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = rec.Root,
		})

		rec.Root.MouseButton1Click:Connect(function()
			if rec.Instance then
				SelectInstance(rec.Instance)
			end
		end)

		rec.Chevron.MouseButton1Click:Connect(function()
			local instance = rec.Instance
			if not instance then
				return
			end
			Expanded[instance] = not Expanded[instance] or nil
			RenderTree()
		end)

		rec.Root.MouseButton2Click:Connect(function()
			if not rec.Instance then
				return
			end
			if not rec.Menu then
				rec.Menu = ContextMenu:Create(rec.Root, {
					{
						Text = "Teleport to",
						Icon = "map-pin",
						Callback = function()
							local instance = rec.Instance
							if not instance then return end
							SelectInstance(instance)
							TeleportTo(instance)
						end,
					},
					{
						Text = "Copy path",
						Icon = "clipboard",
						Callback = function()
							local instance = rec.Instance
							if not instance then return end
							local full
							pcall(function()
								full = instance:GetFullName()
							end)
							if pcall(setclipboard, tostring(full or instance.Name)) then
								wax.shared.Sonner.success("Copied path")
							else
								wax.shared.Sonner.error("Failed to copy path")
							end
						end,
					},
					{
						Text = "Delete",
						Icon = "trash",
						Callback = function()
							local instance = rec.Instance
							if not instance then return end
							local allowed, why = CanDelete(instance)
							if not allowed then
								wax.shared.Sonner.warning("Not deleted — " .. tostring(why))
								return
							end
							local name = instance.Name
							local wasSelected = View.Selected == instance
							if not pcall(function() instance:Destroy() end) then
								wax.shared.Sonner.error("Failed to delete " .. name)
								return
							end
							if wasSelected then
								View.Selected = nil
								RenderDetails(nil)
							end
							RenderTree()
							wax.shared.Sonner.success(("Deleted %s (client-side)"):format(name))
						end,
					},
				}, true)
				rec.Menu:BindLongPress(rec.Root)
			end
			rec.Menu.Toggle()
		end)

		return rec
	end

	local function ReleaseRows()
		for _, rec in ipairs(ActiveRows) do
			rec.Root.Parent = nil
			rec.Instance = nil
			RowPool[#RowPool + 1] = rec
		end
		table.clear(ActiveRows)
	end

	local function UseRow(entry, order: number)
		local rec = table.remove(RowPool) or BuildRow()
		local instance, depth = entry.instance, entry.depth
		local x = depth * INDENT
		local isSelected = instance == View.Selected

		rec.Instance = instance
		rec.Root.LayoutOrder = order
		rec.Root.BackgroundColor3 = isSelected and SELECT_BLUE or SELECTED
		rec.Root.BackgroundTransparency = isSelected and 0 or 1

		rec.Chevron.Visible = entry.hasChildren
		if entry.hasChildren then
			rec.Chevron.Position = UDim2.new(0, x, 0.5, 0)
			local want = Expanded[instance] and "chevron-down" or "chevron-right"
			if rec.ChevronIcon ~= want then -- icon lookups aren't free; only redo them on change
				rec.ChevronIcon = want
				Icons.SetIcon(rec.Chevron, want)
			end
		end

		rec.Icon.Position = UDim2.new(0, x + 16, 0.5, 0)
		local iconName = IconFor(instance)
		if rec.IconName ~= iconName then
			rec.IconName = iconName
			Icons.SetIcon(rec.Icon, iconName)
		end

		local isMatch = SearchMatches ~= nil and SearchMatches[instance] == true
		rec.Label.Position = UDim2.new(0, x + 34, 0, 0)
		rec.Label.Size = UDim2.new(1, -(x + 38), 1, 0)
		rec.Label.Text = instance.Name
		-- while filtering, tint actual hits so they stand out from the ancestor rows drawn for context
		rec.Label.TextColor3 = isMatch and MATCH_YELLOW or Color3.new(1, 1, 1)
		rec.Label.TextTransparency = (SearchMatches ~= nil and not isMatch) and 0.35 or 0

		rec.Root.Parent = Tree
		ActiveRows[#ActiveRows + 1] = rec
		RowByInstance[instance] = rec.Root
		if isSelected then
			SelectedRow = rec.Root
		end
		return rec.Root
	end

	RenderTree = function()
		ReleaseRows()
		if TruncatedLabel then
			TruncatedLabel:Destroy()
			TruncatedLabel = nil
		end
		table.clear(RowByInstance)
		table.clear(FlatRows)
		SelectedRow = nil

		local order = 0
		local truncated = false

		local function walk(instance, depth)
			if order >= MAX_ROWS then
				truncated = true
				return
			end
			local children = ChildrenOf(instance)
			order += 1
			local entry = { instance = instance, depth = depth, hasChildren = #children > 0 }
			FlatRows[order] = entry
			UseRow(entry, order)

			-- while filtering, the path to every hit is force-expanded; otherwise honour the toggles
			if Expanded[instance] or SearchVisible ~= nil then
				local rendered = 0
				for _, child in ipairs(children) do
					if SearchVisible == nil or SearchVisible[child] then
						rendered += 1
						if rendered > MAX_CHILDREN_PER_NODE then
							truncated = true
							break
						end
						walk(child, depth + 1)
					end
				end
			end
		end

		walk(game, 0)

		if truncated then
			TruncatedLabel = Interface.New("TextLabel", {
				Text = ("… list truncated (%d rows max)"):format(MAX_ROWS),
				TextSize = 12,
				TextTransparency = 0.5,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = order + 1,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = Tree,
			})
		end
	end

	-- Scroll the selected row into view. Deferred a frame on purpose: the tree uses
	-- AutomaticCanvasSize, so right after a rebuild the canvas hasn't been measured yet and any
	-- CanvasPosition we set is clamped straight back to 0 (which is why a reveal appeared to do
	-- nothing). Waiting for the next Heartbeat lets the layout size the canvas first.
	local function ScrollToSelected()
		local selected = View.Selected
		if not selected then
			return
		end
		local index
		for i, entry in ipairs(FlatRows) do
			if entry.instance == selected then
				index = i
				break
			end
		end
		if not index then
			return
		end

		task.defer(function()
			pcall(function()
				wax.shared.RunService.Heartbeat:Wait()
			end)
			if View.Selected ~= selected then
				return -- selection moved on while we waited
			end
			local y = (index - 1) * (ROW_HEIGHT + ROW_PADDING)
			Tree.CanvasPosition = Vector2.new(0, math.max(0, y - Tree.AbsoluteSize.Y / 2))
		end)
	end

	-- Select an instance, expand its ancestors, and scroll it into view. This is exactly what a world
	-- pick does, exposed so it can be driven programmatically (bridge/plugins) too.
	function View.Reveal(instance)
		SelectInstance(instance, true)
		ScrollToSelected()
	end

	--// Search //---------------------------------------------------------------------------------
	-- Bounded on purpose: the DataModel can hold tens of thousands of instances, and an unbounded
	-- walk would hang the client. We stop at either cap and say so rather than pretending the result
	-- is complete.
	-- A real game's DataModel runs to hundreds of thousands of instances, so a single-pass walk either
	-- misses things (if capped low) or freezes the client (if not). This yields every few thousand
	-- nodes instead: the cap stays high enough to actually reach everything, and a newer search
	-- supersedes an in-flight one via the token.
	local MAX_SCAN = 250000
	local MAX_MATCHES = 300
	local YIELD_EVERY = 3000
	local SearchRunToken = 0

	local function RunSearch(query: string)
		query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
		SearchRunToken += 1
		local token = SearchRunToken

		if query == "" then
			SearchVisible, SearchMatches = nil, nil
			RenderTree()
			return
		end

		task.spawn(function()
			local needle = query:lower()
			local visible, matches = {}, {}
			local scanned, found = 0, 0
			local hitCap, superseded = false, false

			local function markAncestors(instance)
				local node = instance
				while node and node ~= game do
					visible[node] = true
					node = node.Parent
				end
			end

			local function walk(instance)
				for _, child in ipairs(ChildrenOf(instance)) do
					if SearchRunToken ~= token then
						superseded = true
						return
					end
					scanned += 1
					if scanned >= MAX_SCAN or found >= MAX_MATCHES then
						hitCap = true
						return
					end
					if scanned % YIELD_EVERY == 0 then
						task.wait() -- keep the client responsive on a huge tree
					end

					local ok = pcall(function()
						if
							string.find(child.Name:lower(), needle, 1, true)
							or string.find(child.ClassName:lower(), needle, 1, true)
						then
							matches[child] = true
							found += 1
							markAncestors(child)
						end
					end)
					if ok then
						walk(child)
						if superseded or hitCap then
							return
						end
					end
				end
			end

			walk(game)
			if superseded or SearchRunToken ~= token then
				return -- a newer query started while we were walking
			end

			SearchVisible, SearchMatches = visible, matches
			RenderTree()

			if wax.shared.Sonner then
				if found == 0 then
					wax.shared.Sonner.info(("No instances matching %q"):format(query))
				elseif hitCap then
					wax.shared.Sonner.warning(("Showing first %d matches — narrow the term"):format(found))
				end
			end
		end)
	end

	-- Debounced so typing doesn't kick off a full-tree walk per keystroke; clearing resets instantly.
	local SearchToken = 0
	SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		SearchToken += 1
		local token = SearchToken
		local text = SearchBox.Text
		if text == "" then
			RunSearch("")
			return
		end
		task.delay(0.35, function()
			if SearchToken == token then
				RunSearch(text)
			end
		end)
	end)

	--// UI picker //-------------------------------------------------------------------------------
	-- Hover-outline the GuiObject under the cursor, click to reveal it in the tree. Hit-testing goes
	-- through PlayerGui:GetGuiObjectsAtPosition, which returns topmost-first and already respects
	-- render order — far more reliable than walking descendants and comparing bounds ourselves.
	local UIHighlight = Interface.New("Frame", {
		BackgroundColor3 = Color3.fromRGB(90, 160, 255),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3500,
		Parent = wax.shared.ScreenGui,

		["UIStroke"] = { Color = Color3.fromRGB(130, 195, 255), Thickness = 2 },
	})

	local UIHighlightLabel = Interface.New("TextLabel", {
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = Color3.fromRGB(20, 20, 20),
		Position = UDim2.new(0, 0, 0, -2),
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = "",
		TextSize = 12,
		ZIndex = 3501,
		Parent = UIHighlight,

		["UICorner"] = { CornerRadius = UDim.new(0, 3) },
		["UIPadding"] = { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) },
	})

	-- "Visible" has to mean actually on screen: every ancestor visible AND the containing
	-- ScreenGui/LayerCollector enabled, or we'd happily outline something nobody can see.
	local function IsOnScreen(object): boolean
		local node = object
		while node and node:IsA("GuiObject") do
			if not node.Visible then
				return false
			end
			node = node.Parent
		end
		local layer = object:FindFirstAncestorWhichIsA("LayerCollector")
		if layer and layer.Enabled == false then
			return false
		end
		return true
	end

	local function TopmostGuiAtCursor(): GuiObject?
		local playerGui = wax.shared.LocalPlayer and wax.shared.LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then
			return nil
		end
		local mousePos = wax.shared.UserInputService:GetMouseLocation()
		local inset = game:GetService("GuiService"):GetGuiInset()

		-- GetMouseLocation and AbsolutePosition don't always agree about the topbar inset, so try
		-- both and take whichever actually hits something.
		for _, point in ipairs({ mousePos, Vector2.new(mousePos.X, mousePos.Y + inset.Y) }) do
			local ok, objects = pcall(function()
				return playerGui:GetGuiObjectsAtPosition(point.X, point.Y)
			end)
			if ok and objects then
				for _, object in ipairs(objects) do -- topmost first
					local mine = false
					pcall(function()
						mine = object:IsDescendantOf(wax.shared.ScreenGui)
					end)
					if not mine and IsOnScreen(object) then
						return object
					end
				end
			end
		end
		return nil
	end

	local UIPickArmed, UIPickConnections, UIHovered = false, {}, nil

	local function SetUIPickArmed(value: boolean)
		UIPickArmed = value
		UIPickButton.Text = value and "picking ui…" or "pick ui"
		UIPickButton.TextTransparency = value and 0 or 0.45
		UIPickButton.TextColor3 = value and Color3.fromRGB(130, 195, 255) or Color3.new(1, 1, 1)
		UIHighlight.Visible = false
		UIHovered = nil

		for _, connection in ipairs(UIPickConnections) do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(UIPickConnections)

		if not value then
			return
		end

		table.insert(
			UIPickConnections,
			wax.shared.RunService.RenderStepped:Connect(function()
				local target = TopmostGuiAtCursor()
				UIHovered = target
				if not target then
					UIHighlight.Visible = false
					return
				end
				local origin = wax.shared.ScreenGui.AbsolutePosition
				UIHighlight.Position =
					UDim2.fromOffset(target.AbsolutePosition.X - origin.X, target.AbsolutePosition.Y - origin.Y)
				UIHighlight.Size = UDim2.fromOffset(target.AbsoluteSize.X, target.AbsoluteSize.Y)
				UIHighlightLabel.Text = ("%s (%s)"):format(target.Name, target.ClassName)
				UIHighlight.Visible = true
			end)
		)

		table.insert(
			UIPickConnections,
			wax.shared.UserInputService.InputBegan:Connect(function(input)
				-- deliberately NOT filtering gameProcessedEvent: the thing we're picking IS a GUI, so
				-- the engine will always report the click as processed
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
					return
				end
				local target = UIHovered
				if not target then
					return
				end
				SetUIPickArmed(false)
				View.Reveal(target)
				if props.OnPicked then
					pcall(props.OnPicked, target)
				end
				if wax.shared.Sonner then
					wax.shared.Sonner.info(("Inspecting %s (%s)"):format(target.Name, target.ClassName))
				end
			end)
		)
	end

	UIPickButton.MouseButton1Click:Connect(function()
		SetUIPickArmed(not UIPickArmed)
	end)

	RefreshLabel.MouseButton1Click:Connect(function()
		RenderTree()
	end)

	--// Picking: Cmd + Click //--------------------------------------------------------------------
	-- Modifier detection goes through InputObject:IsModifierKeyDown, which is the actual API for this
	-- (Meta == Command on macOS), rather than guessing which KeyCode the platform reports. The
	-- IsKeyDown sweep stays as a fallback, and the "pick" button arms a modifier-free pick in case a
	-- platform reports neither.
	local CommandKeys = {}
	for _, name in ipairs({ "LeftSuper", "RightSuper", "LeftMeta", "RightMeta" }) do
		local ok, key = pcall(function()
			return Enum.KeyCode[name]
		end)
		if ok and key then
			CommandKeys[#CommandKeys + 1] = key
		end
	end

	local UserInputService = wax.shared.UserInputService
	local function CommandHeld(input): boolean
		local ok, down = pcall(function()
			return input:IsModifierKeyDown(Enum.ModifierKey.Meta)
		end)
		if ok and down then
			return true
		end
		for _, key in ipairs(CommandKeys) do
			local okKey, held = pcall(function()
				return UserInputService:IsKeyDown(key)
			end)
			if okKey and held then
				return true
			end
		end
		return false
	end

	local Armed = false
	local function SetArmed(value: boolean)
		Armed = value
		PickButton.Text = value and "click a part…" or "pick"
		PickButton.TextTransparency = value and 0 or 0.45
		PickButton.TextColor3 = value and Color3.fromRGB(120, 170, 255) or Color3.new(1, 1, 1)
	end
	PickButton.MouseButton1Click:Connect(function()
		SetArmed(not Armed)
	end)

	local mouse
	pcall(function()
		mouse = wax.shared.LocalPlayer:GetMouse()
	end)

	wax.shared.Connect(UserInputService.InputBegan:Connect(function(input, processed)
		-- `processed` is true when the engine already routed the click to a GUI (including Cobalt's
		-- own window), so this never re-picks while you're using the UI.
		if processed or not mouse then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if not (Armed or CommandHeld(input)) then
			return
		end

		local target = mouse.Target
		if not target then
			if Armed and wax.shared.Sonner then
				wax.shared.Sonner.warning("Nothing under the cursor — aim at a part")
			end
			return
		end

		SetArmed(false)
		View.Reveal(target)
		if props.OnPicked then
			pcall(props.OnPicked, target) -- bring the Inspect tab forward so the pick is actually visible
		end
		if wax.shared.Sonner then
			wax.shared.Sonner.info(("Inspecting %s (%s)"):format(target.Name, target.ClassName))
		end
	end))

	-- seed the tree with the common roots open
	Expanded[game] = true
	pcall(function()
		Expanded[workspace] = true
	end)
	RenderTree()

	--// Public //----------------------------------------------------------------------------------
	function View.GetSelected()
		return View.Selected
	end

	return View
end
