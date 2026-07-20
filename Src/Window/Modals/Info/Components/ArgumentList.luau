--// Imports \\--
local Interface = require("@src/Utils/UI/Interface")

local LazySerializer = require("@src/Window/Utils/Text/LazySerializer")
local SyntaxHighlighter = require("@src/Window/Utils/Text/Highlighter")
local TextBounds = require("@src/Window/Utils/Text/TextBounds")

local ArgumentList = {}

local DefaultPreviewMaxLength = 500

type HolderOptions = {
	IsBlockedCall: boolean?,
	IsError: boolean?,
	IsPreview: boolean?,
	Label: string?,
	MaxPreviewLength: number?,
	PreviewCache: { [number]: string }?,
	Depth: number?, -- nesting level of an expanded table row
}

-- Expanding tables: a table argument otherwise renders as one truncated serialised blob, so nested
-- data can't actually be read. Rows for tables get a chevron and expand into their key/value pairs,
-- each of which is itself a row — so nested tables nest. Populated lazily on first expand.
local MAX_CHILD_ROWS = 200 -- a captured payload can be huge; cap what we draw per level
local MAX_DEPTH = 8 -- also stops a self-referencing table from nesting forever

local function IsExpandable(Value: any): boolean
	return typeof(Value) == "table"
end

-- Array part in order first, then remaining keys sorted, so payloads read predictably.
local function OrderedPairs(Table: { [any]: any })
	local Keys = {}
	local Seen = {}
	for Index = 1, #Table do
		Keys[#Keys + 1] = Index
		Seen[Index] = true
	end

	local Rest = {}
	for Key in pairs(Table) do
		if not Seen[Key] and Key ~= "n" then
			Rest[#Rest + 1] = Key
		end
	end
	table.sort(Rest, function(Left, Right)
		return tostring(Left) < tostring(Right)
	end)
	for _, Key in ipairs(Rest) do
		Keys[#Keys + 1] = Key
	end

	return Keys
end

local function TruncatePreviewText(Text: string, MaxLength: number): string
	local NormalizedText = Text:gsub("[\r\n\t]", " ")
	if #Text <= MaxLength then
		return NormalizedText
	end

	return NormalizedText:sub(1, MaxLength) .. "..."
end

function ArgumentList.CreatePreviewText(Value: any, MaxLength: number?): string
	MaxLength = MaxLength or DefaultPreviewMaxLength

	if typeof(Value) == "string" then
		return `"{TruncatePreviewText(Value, MaxLength)}"`
	end

	return TruncatePreviewText(tostring(LazySerializer.QuickSerializeArgument(Value)), MaxLength)
end

function ArgumentList.Clear(Frame: GuiObject)
	for _, Object in Frame:QueryDescendants("Frame") do
		Object:Destroy()
	end
end

function ArgumentList.CreateHolder(Index: number, Value: any, Parent: GuiObject, Options: HolderOptions | boolean?)
	if typeof(Options) ~= "table" then
		Options = {
			IsBlockedCall = Options,
		}
	end

	--// Variables \\--
	local IsBlockedCall = Options.IsBlockedCall
	local IsError = Options.IsError == true
	local PreviewCache = Options.PreviewCache
	local IsPreview = Options.IsPreview == true

	local Depth = Options.Depth or 0
	local Expandable = IsExpandable(Value) and Depth < MAX_DEPTH
	local ChevronPad = Expandable and 16 or 0

	--// UI \\--
	-- Holder grows to fit expanded children; the header keeps the original single-row geometry.
	local Holder = Interface.New("Frame", {
		BackgroundColor3 = if IsBlockedCall
			then Color3.fromRGB(58, 24, 24)
			else Color3.fromRGB(25, 25, 25),
		LayoutOrder = Index,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),

		["UICorner"] = {
			CornerRadius = UDim.new(0, 4),
		},

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 2),
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
		},

		Parent = Parent,
	})

	local Header = Interface.New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 15),
		LayoutOrder = 0,
		Parent = Holder,
	})

	local IndexLabel = Interface.New("TextLabel", {
		Position = UDim2.fromOffset(ChevronPad, 0),
		Size = UDim2.new(1, -ChevronPad, 1, 0),
		Text = Options.Label or Index,
		TextColor3 = if IsBlockedCall or IsError then Color3.fromRGB(255, 190, 190) else Color3.new(1, 1, 1),
		TextSize = 15,
		TextTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,

		Parent = Header,
	})
	local IndexX = TextBounds.GetCachedWidth(IndexLabel.Text, IndexLabel.FontFace, IndexLabel.TextSize)

	local TypeLabel = Interface.New("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		Text = typeof(Value),
		TextColor3 = if IsBlockedCall or IsError then Color3.fromRGB(255, 190, 190) else Color3.new(1, 1, 1),
		TextSize = 15,
		TextTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Top,

		Parent = Header,
	})
	local TypeX = TextBounds.GetCachedWidth(TypeLabel.Text, TypeLabel.FontFace, TypeLabel.TextSize)

	local Text
	if IsPreview then
		if PreviewCache then
			if not PreviewCache[Index] then
				PreviewCache[Index] = ArgumentList.CreatePreviewText(Value, Options.MaxPreviewLength)
			end

			Text = PreviewCache[Index]
		else
			Text = ArgumentList.CreatePreviewText(Value, Options.MaxPreviewLength)
		end
	else
		Text = tostring(LazySerializer.QuickSerializeArgument(Value)):gsub("<", "&lt;"):gsub(">", "&gt;")
	end

	local TextLabel = Interface.New("TextLabel", {
		Position = UDim2.fromOffset(ChevronPad + IndexX + 6, 0),
		Size = UDim2.new(1, -(ChevronPad + IndexX + TypeX + 10), 1, 0),
		TextColor3 = if IsBlockedCall or IsError
			then Color3.fromRGB(255, 190, 190)
			else Color3.fromHex(SyntaxHighlighter.GetArgumentColor(Value)),
		Text = Text,
		RichText = not IsPreview,
		TextSize = 15,
		TextTruncate = if IsPreview then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None,
		TextWrapped = not IsPreview,
		TextXAlignment = Enum.TextXAlignment.Left,

		Parent = Header,
	})

	if not IsPreview then
		local _, TextY = TextBounds.Get(TextLabel.Text, TextLabel.FontFace, TextLabel.TextSize, TextLabel.AbsoluteSize.X)
		Header.Size = UDim2.new(1, 0, 0, TextY)
	end

	--// Expandable table \\--
	if Expandable then
		local Children = Interface.New("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 1,
			Visible = false,
			Parent = Holder,

			["UIListLayout"] = {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, 2),
			},

			["UIPadding"] = { PaddingLeft = UDim.new(0, 10), PaddingTop = UDim.new(0, 2) },
		})

		local Chevron = Interface.New("TextButton", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.fromOffset(14, 15),
			Text = "▸",
			TextSize = 14,
			TextTransparency = 0.35,
			Parent = Header,
		})

		local Populated, Open = false, false
		Chevron.MouseButton1Click:Connect(function()
			Open = not Open
			Chevron.Text = Open and "▾" or "▸"
			Children.Visible = Open

            -- built on first open only: a big payload shouldn't cost anything until asked for
			if Open and not Populated then
				Populated = true
				local Keys = OrderedPairs(Value)
				for Position, Key in ipairs(Keys) do
					if Position > MAX_CHILD_ROWS then
						Interface.New("TextLabel", {
							BackgroundTransparency = 1,
							Size = UDim2.new(1, 0, 0, 15),
							LayoutOrder = Position,
							Text = ("… %d more"):format(#Keys - MAX_CHILD_ROWS),
							TextSize = 14,
							TextTransparency = 0.5,
							TextXAlignment = Enum.TextXAlignment.Left,
							Parent = Children,
						})
						break
					end
					ArgumentList.CreateHolder(Position, Value[Key], Children, {
						Label = tostring(Key),
						IsPreview = IsPreview,
						MaxPreviewLength = Options.MaxPreviewLength,
						IsBlockedCall = IsBlockedCall,
						Depth = Depth + 1,
					})
				end
				if #Keys == 0 then
					Interface.New("TextLabel", {
						BackgroundTransparency = 1,
						Size = UDim2.new(1, 0, 0, 15),
						Text = "(empty table)",
						TextSize = 14,
						TextTransparency = 0.5,
						TextXAlignment = Enum.TextXAlignment.Left,
						Parent = Children,
					})
				end
			end
		end)
	end

	return Holder
end

function ArgumentList.Populate(Frame: GuiObject, Values: { [any]: any }?)
	if not Values then
		return
	end

	for Index = 1, wax.shared.GetTableLength(Values) do
		if Index % 25 == 0 then
			task.wait()
		end

		ArgumentList.CreateHolder(Index, Values[Index], Frame)
	end
end

return ArgumentList
