--!nonstrict
-- rh-farm fork — top-level view switcher: a segmented control (e.g. [ Remotes | Prompts ]) centered in
-- the topbar. Selecting a tab shows one view root and hides the others so the two capture streams never
-- share the same pane. Purely presentational — the caller wires OnSelected to toggle its view roots.

local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")

return function(props: {
	Parent: GuiObject,
	Tabs: { string },
	OnSelected: (name: string) -> (),
})
	local Switcher = {
		Buttons = {},
		Current = nil,
	}

	local Container = Interface.New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(18, 18, 18),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(74 * #props.Tabs, 26),
		ZIndex = 3,
		Parent = props.Parent,

		["UICorner"] = {
			CornerRadius = UDim.new(0, 6),
		},

		["UIListLayout"] = {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			HorizontalFlex = Enum.UIFlexAlignment.Fill,
		},

		["UIPadding"] = {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 2),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
		},
	})
	Switcher.Container = Container

	function Switcher:Select(Name: string, Force: boolean?)
		if self.Current == Name and not Force then
			return
		end

		for TabName, Button in pairs(self.Buttons) do
			local Active = TabName == Name
			wax.shared.TweenService
				:Create(Button, Constants.DefaultTweenInfo, {
					BackgroundTransparency = Active and 0 or 1,
				})
				:Play()
		end

		self.Current = Name
		props.OnSelected(Name)
	end

	for Order, Name in ipairs(props.Tabs) do
		local Button = Interface.New("TextButton", {
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			BackgroundTransparency = 1,
			LayoutOrder = Order,
			Size = UDim2.fromScale(0, 1),
			Text = Name,
			TextSize = 13,
			ZIndex = 3,
			Parent = Container,

			["UICorner"] = {
				CornerRadius = UDim.new(0, 4),
			},
		})

		Switcher.Buttons[Name] = Button
		Button.MouseButton1Click:Connect(function()
			Switcher:Select(Name)
		end)
	end

	return Switcher
end
