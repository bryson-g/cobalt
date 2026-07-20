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
		"Massless", "Material", "Color", "Transparency", "Reflectance", "CastShadow",
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

	local View = {
		Selected = nil,
	}
	local Expanded = {} -- [instance] = true
	local RowByInstance = {} -- [instance] = row TextButton (current render only)
	local SelectedRow = nil
	local FlatRows = {} -- current render order, for scroll-to-reveal

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

	local TreeWrapper = Interface.New("Frame", {
		AnchorPoint = Vector2.yAxis,
		BackgroundColor3 = BG,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 1, -36),
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
	local function ClearDetails()
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
							Row(propsBlock, name, FormatValue(value), order)
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

	local function MakeRow(entry, order: number)
		local instance, depth = entry.instance, entry.depth
		local isSelected = instance == View.Selected

		local RowButton = Interface.New("TextButton", {
			BackgroundColor3 = isSelected and SELECT_BLUE or SELECTED,
			BackgroundTransparency = isSelected and 0 or 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = order,
			Text = "",
			Parent = Tree,

			["UICorner"] = { CornerRadius = UDim.new(0, 4) },
		})

		local x = depth * INDENT

		-- expand/collapse chevron (only when the node actually has children)
		if entry.hasChildren then
			local Chevron = Interface.New("ImageButton", {
				BackgroundTransparency = 1,
				Position = UDim2.new(0, x, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				Size = UDim2.fromOffset(14, 14),
				Parent = RowButton,
			})
			Icons.SetIcon(Chevron, Expanded[instance] and "chevron-down" or "chevron-right")
			Chevron.ImageTransparency = 0.35
			Chevron.MouseButton1Click:Connect(function()
				Expanded[instance] = not Expanded[instance] or nil
				RenderTree()
			end)
		end

		local Icon = Interface.New("ImageLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, x + 16, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(14, 14),
			ImageTransparency = 0.2,
			Parent = RowButton,
		})
		Icons.SetIcon(Icon, IconFor(instance))

		Interface.New("TextLabel", {
			Position = UDim2.new(0, x + 34, 0, 0),
			Size = UDim2.new(1, -(x + 38), 1, 0),
			Text = instance.Name,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = RowButton,
		})

		RowButton.MouseButton1Click:Connect(function()
			SelectInstance(instance)
		end)

		RowByInstance[instance] = RowButton
		if isSelected then
			SelectedRow = RowButton
		end
		return RowButton
	end

	RenderTree = function()
		for _, child in ipairs(Tree:GetChildren()) do
			if child:IsA("TextButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
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
			MakeRow(entry, order)

			if Expanded[instance] then
				for index, child in ipairs(children) do
					if index > MAX_CHILDREN_PER_NODE then
						truncated = true
						break
					end
					walk(child, depth + 1)
				end
			end
		end

		walk(game, 0)

		if truncated then
			Interface.New("TextLabel", {
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
		SelectInstance(target, true)
		ScrollToSelected()
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
