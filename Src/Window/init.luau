--// Imports \\--
local Interface = require("@src/Utils/UI/Interface")
local Constants = require("@src/Window/Constants")

local DPI = require("@src/Window/Utils/DPI")
local Resize = require("@src/Window/Utils/Input/Resize")

local AssetManager = require("@src/Utils/UI/Assets/Manager")
local PluginManager = require("@src/Utils/Plugins/Manager")

--// Components \\--
local ModalController = require("@src/Window/Components/Modal")
local ContextMenuController = require("@src/Window/Components/ContextMenu")

--// Variables \\--
local Window = {
	Dialogs = {},
	Modals = {},
}

--// Assets \\--
local CobaltLogo = AssetManager.GetImage("Logo")

local DPIHandler
local function GetDPIScale()
	return DPIHandler and DPIHandler:GetDPIScale() or 1
end

--// UI \\--
local ScreenGui = Interface.New("ScreenGui", {
	Name = "Cobalt",
	ResetOnSpawn = false,
	Parent = Interface.GetScreenParent(),
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
wax.shared.ScreenGui = ScreenGui

local MainFrame = Interface.New("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(640, 420),
	ZIndex = 0,

	Constants.MainUICorner,
	Parent = ScreenGui,
})
do
	Resize.new({
		MainFrame = MainFrame,

		-- rh fork: wide enough for the tab strip's five tabs (the strip is its own row now, so this is
		-- no longer competing with the topbar title/buttons).
		MinimumSize = Vector2.new(600, 240),

		CornerHandleSize = 20,
		HandleSize = 6,
		GetDPIScale = GetDPIScale,
	})
end

--// Minimized \\--
local ShowButton = Interface.New("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	Position = UDim2.new(0.5, 0, 0, 36),
	Size = UDim2.fromOffset(36, 36),
	Text = "",
	Visible = false,

	["ImageLabel"] = {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Image = CobaltLogo,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -10, 1, -10),
	},

	["UIStroke"] = {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = Color3.new(1, 1, 1),
	},

	Constants.MainUICorner,
	Parent = ScreenGui,
})
do
	ShowButton.MouseButton1Click:Connect(function()
		ShowButton.Visible = false
		MainFrame.Visible = true
	end)
end

--// Sonner (Notifications) \\--
local NotificationWrapper = Interface.New("ScrollingFrame", {
	Name = "Sonner",
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(285, 115),
	Position = UDim2.fromScale(1, 1),
	AnchorPoint = Vector2.new(1, 1),
	ZIndex = 5000,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	ScrollingEnabled = false,
	ClipsDescendants = true,
	Parent = MainFrame,
})
do
	wax.shared.Sonner.init(NotificationWrapper)
end

--// Pagination \\--
local PaginationFactory = require(script.Utils.Pagination)

local PaginationManager = PaginationFactory.new({
	TotalItems = 0,
})

--// DPI \\--
DPIHandler = DPI.new({
	Scale = Interface.New("UIScale", {
		Parent = ScreenGui,
	}),
	SaveKey = "WindowDPIScale",
})

--// ContextMenus \\--
local ContextMenus = ContextMenuController.new(ScreenGui, {
	GetDPIScale = GetDPIScale,

	TweenInfo = Constants.DefaultTweenInfo,
})

--// Dialogs \\--
Window.Dialog = require(script.Components.Dialog)({
	MainFrame = MainFrame,
})

local QueryBuilder = require(script.Components.QueryBuilder)
do
	QueryBuilder.ContextMenu = ContextMenus
	Window.QueryBuilder = QueryBuilder
end

Window.Dialogs = require(script.Components.Dialogs)

--// Modal Controller \\--
Window.Modals.Controller = ModalController.new(MainFrame, {
	TweenInfo = Constants.DefaultTweenInfo,
})

--// View Roots \\--
-- rh fork: one transparent root per view so the capture streams never share a pane; the tab strip
-- just toggles which root is Visible. Active=false (default) so a root never intercepts clicks meant
-- for the chrome, and ZIndex 0 keeps it under the topbar buttons.
--
-- Geometry note: every view anchors its children to the BOTTOM of its root with height `1, -36`,
-- i.e. each view leaves 36px free at the top of its own root. So offsetting the roots down by the
-- tab strip's height lands all content below topbar+strip WITHOUT touching any view's internals.
local TAB_STRIP_HEIGHT = 30

local function NewViewRoot(visible: boolean)
	return Interface.New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, TAB_STRIP_HEIGHT),
		Size = UDim2.new(1, 0, 1, -TAB_STRIP_HEIGHT),
		ZIndex = 0,
		Visible = visible,
		Parent = MainFrame,
	})
end

local RemotesRoot = NewViewRoot(true)
local PromptsRoot = NewViewRoot(false)
local InspectionRoot = NewViewRoot(false)
local SeatsRoot = NewViewRoot(false)
local SessionsRoot = NewViewRoot(false)

--// Views \\--
local LogsPage = require(script.Views.Logs)({
	MainFrame = RemotesRoot,
	Window = Window,
	ContextMenu = ContextMenus,
	PaginationManager = PaginationManager,
	GetDPIScale = GetDPIScale,
})
Window.Logs = LogsPage

-- rh fork: the Prompts view (ProximityPrompt activity), fed live by Spy/PromptSpy.
local PromptsView = require(script.Views.Prompts)({
	MainFrame = PromptsRoot,
	ContextMenu = ContextMenus,
	PromptSpy = wax.shared.PromptSpy,
	GetDPIScale = GetDPIScale,
})
Window.Prompts = PromptsView

-- rh fork: the Inspection view (Cmd+Click an instance -> explorer tree + properties). Declared ahead
-- of the topbar switcher so a world pick can bring its tab forward — otherwise picking while another
-- tab is open updates a pane you can't see.
local Switcher
local InspectionView = require(script.Views.Inspection)({
	MainFrame = InspectionRoot,
	ContextMenu = ContextMenus,
	GetDPIScale = GetDPIScale,
	OnPicked = function()
		if Switcher then
			Switcher:Select("Inspect")
		end
	end,
})
Window.Inspection = InspectionView

-- rh fork: Seats (what the character sat on) and Sessions (recordings from the topbar record button).
local SeatsView = require(script.Views.Seats)({
	MainFrame = SeatsRoot,
	ContextMenu = ContextMenus,
	SeatSpy = wax.shared.SeatSpy,
	OnInspect = function(instance)
		if Switcher then
			Switcher:Select("Inspect")
		end
		InspectionView.Reveal(instance)
	end,
})
Window.Seats = SeatsView

local SessionsView = require(script.Views.Sessions)({
	MainFrame = SessionsRoot,
	ContextMenu = ContextMenus,
	Recorder = wax.shared.Recorder,
})
Window.Sessions = SessionsView

wax.shared.ClearLogs = LogsPage.ClearLogs
wax.shared.GetCurrentLog = LogsPage.GetCurrentLog

--// Modal Builders \\--
local SettingsBuilder = require(script.Components.Modal.Builder.Settings)({
	ContextMenu = ContextMenus,
})

--// Modals \\--
Window.Modals.Settings = require(script.Modals.Settings)({
	ModalController = Window.Modals.Controller,
	SettingsBuilder = SettingsBuilder,
	DPIHandler = DPIHandler,
	PaginationManager = PaginationManager,
	LogsPage = LogsPage,
	Window = Window,
})

Window.Modals.Plugins = require(script.Modals.Plugins)({
	ModalController = Window.Modals.Controller,
	SettingsBuilder = SettingsBuilder,
	GetDPIScale = GetDPIScale,
})

Window.Modals.Info = require(script.Modals.Info)({
	ModalController = Window.Modals.Controller,
	ContextMenu = ContextMenus,
	GetDPIScale = GetDPIScale,
	LogsPage = LogsPage,
})

Window.Modals.Search = require(script.Modals.Search)({
	ModalController = Window.Modals.Controller,
	LogsPage = LogsPage,
})

PluginManager.AttachWindow({
	ModalController = Window.Modals.Controller,
	InfoModal = Window.Modals.Info,
	PluginsModal = Window.Modals.Plugins,
	GetCurrentLog = LogsPage.GetCurrentLog,
	ClearLogs = LogsPage.ClearLogs,
	GetDPIScale = GetDPIScale,
})

--// Topbar \\--
local Topbar = require(script.Components.Topbar)({
	MainFrame = MainFrame,
	ShowButton = ShowButton,
	CobaltLogo = CobaltLogo,
	Modals = Window.Modals,
	GetDPIScale = GetDPIScale,
})

--// View Switcher \\--
-- rh fork: the tab strip lives on its own row under the topbar. It started centered IN the topbar,
-- but at five tabs there's no width left there between the title and the action buttons — a
-- dedicated strip keeps every tab legible and scales to further views.
local TabStrip = Interface.New("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 0, TAB_STRIP_HEIGHT),
	ZIndex = 2,
	Parent = MainFrame,

	["UIPadding"] = {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
	},
})

local CurrentMode = "Remotes"
Switcher = require(script.Components.ViewSwitcher)({
	Parent = TabStrip,
	Tabs = { "Remotes", "Prompts", "Inspect", "Seats", "Sessions" },
	OnSelected = function(Name)
		CurrentMode = Name
		RemotesRoot.Visible = Name == "Remotes"
		PromptsRoot.Visible = Name == "Prompts"
		InspectionRoot.Visible = Name == "Inspect"
		SeatsRoot.Visible = Name == "Seats"
		SessionsRoot.Visible = Name == "Sessions"
	end,
})
Switcher:Select("Remotes", true)
Window.Switcher = Switcher

-- rh fork: the topbar "clear" button clears whichever stream is in view.
wax.shared.ClearActiveView = function()
	if CurrentMode == "Prompts" then
		PromptsView.ClearAll()
	elseif wax.shared.ClearLogs then
		pcall(wax.shared.ClearLogs)
		if wax.shared.Sonner then
			wax.shared.Sonner.success("Cleared captured calls")
		end
	end
end

return Window
