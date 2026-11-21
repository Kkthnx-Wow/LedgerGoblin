--[[
	LedgerGoblin - Minimap
	-------------------------------------------------------------------------
	A draggable minimap button and the addon compartment entry. Left-click
	opens settings, right-click the Rule Editor. The tooltip shows account
	gold and any character whose mail expires soon.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local CreateFrame = CreateFrame
local GetCursorPosition = GetCursorPosition
local format = string.format
local rad = math.rad
local deg = math.deg
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2

local button

local function FillTooltip(tip)
	tip:AddLine(C.Title)
	tip:AddLine(format(L["Version %s"], ns.version), 0.7, 0.7, 0.7)
	tip:AddLine(format(L["Account gold: %s"], F.Money(ns:GetModule("Roster").AccountGold())), 1, 1, 1)
	local soon = ns:GetModule("Inbox").ExpiringList(ns.global.expiryWarnDays or 3)
	for i = 1, #soon do
		tip:AddLine(format(L["%s mail expires in %s"], ns:GetModule("Roster").Colored(soon[i].character), F.Until(soon[i].expires)), 1, 0.6, 0.2)
	end
	tip:AddLine(" ")
	tip:AddLine(L["Left-click: settings"], 0.8, 0.8, 0.8)
	tip:AddLine(L["Right-click: Rule Editor"], 0.8, 0.8, 0.8)
end

local function OnClick(_, mouse)
	if mouse == "RightButton" then
		ns.ToggleRuleWindow(true)
	else
		ns.OpenSettings()
	end
end

-- Named globals the TOC compartment entries call.
function LedgerGoblin_OnAddonCompartmentClick(_, mouse)
	OnClick(nil, mouse)
end

function LedgerGoblin_OnAddonCompartmentEnter(_, frame)
	GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
	FillTooltip(GameTooltip)
	GameTooltip:Show()
end

function LedgerGoblin_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end

local function Place()
	local mm = _G["Minimap"]
	local angle = rad(ns.global.minimap.angle or 215)
	local radius = mm:GetWidth() / 2 + 6
	button:ClearAllPoints()
	button:SetPoint("CENTER", mm, "CENTER", cos(angle) * radius, sin(angle) * radius)
end

local function Drag()
	local mm = _G["Minimap"]
	local mx, my = mm:GetCenter()
	local scale = mm:GetEffectiveScale()
	local px, py = GetCursorPosition()
	ns.global.minimap.angle = deg(atan2(py / scale - my, px / scale - mx))
	Place()
end

local function Build()
	local mm = _G["Minimap"]
	if not mm or button then
		return
	end
	button = CreateFrame("Button", "LedgerGoblinMinimapButton", mm)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("CENTER", 0, 1)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(19, 19)
	icon:SetTexture(C.Icon)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("CENTER", 0, 1)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	button:SetScript("OnClick", OnClick)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		FillTooltip(GameTooltip)
		GameTooltip:AddLine(L["Drag: move"], 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", ns.UI.HideTooltip)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", Drag)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	Place()
	button:SetShown(not ns.global.minimap.hide)
end

function ns.ToggleMinimapButton()
	local m = ns.global.minimap
	m.hide = not m.hide
	if button then
		button:SetShown(not m.hide)
	end
	F.Print(m.hide and L["Minimap button hidden. /ledger minimap shows it again."] or L["Minimap button shown."])
end

ns:OnInit(Build)
