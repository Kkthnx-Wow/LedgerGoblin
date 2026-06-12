--[[
	LedgerGoblin - Widgets
	-------------------------------------------------------------------------
	Blizzard's vertical Settings layout ships checkboxes/dropdowns/sliders but no
	free-text or body-text element. These two small custom rows fill that gap so
	the panel can host g/s/c money inputs and per-setting explanations without a
	separate canvas. Pattern mirrors NexEnhance's Widgets.lua: an XML template
	carrying a mixin, built through Settings.CreateElementInitializer.
--]]

local _, ns = ...
local F = ns.F

local CreateFrame = CreateFrame
local UIParent = UIParent

-- luacheck: globals LedgerGoblinSettingsDescriptionMixin LedgerGoblinSettingsEditBoxMixin

-- ---------------------------------------------------------------------------
-- Description paragraph
-- ---------------------------------------------------------------------------
LedgerGoblinSettingsDescriptionMixin = {}

function LedgerGoblinSettingsDescriptionMixin:Init(initializer)
	local data = initializer:GetData()
	self.Text:SetText(data and data.text or "")
	self.Text:SetTextColor(0.85, 0.85, 0.85)
end

local descMeasure
local DESC_MEASURE_WIDTH = 540

local function MeasureDescriptionHeight(text)
	if not descMeasure then
		descMeasure = UIParent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		descMeasure:Hide()
		descMeasure:SetWidth(DESC_MEASURE_WIDTH)
		descMeasure:SetJustifyH("LEFT")
		descMeasure:SetWordWrap(true)
	end
	descMeasure:SetText(text or "")
	return (descMeasure:GetStringHeight() or 12) + 12
end

--- Initializer that renders `text` as a wrapped paragraph for layout:AddInitializer.
function F.CreateSettingsDescription(text)
	if not (Settings and Settings.CreateElementInitializer) then return end
	local initializer = Settings.CreateElementInitializer("LedgerGoblinSettingsDescriptionTemplate", { text = text })
	local height = MeasureDescriptionHeight(text)
	initializer.GetExtent = function() return height end
	return initializer
end

-- ---------------------------------------------------------------------------
-- Inline edit box row
-- ---------------------------------------------------------------------------
LedgerGoblinSettingsEditBoxMixin = {}

local function editBox_OnEnterPressed(self)
	local owner = self:GetParent()
	local data = owner and owner._lgData
	if data and data.setValue then
		data.setValue(self:GetText() or "")
		if data.getValue then
			self:SetText(data.getValue() or "")
		end
	end
	self:ClearFocus()
end

local function editBox_OnEscapePressed(self)
	local owner = self:GetParent()
	local data = owner and owner._lgData
	if data and data.getValue then
		self:SetText(data.getValue() or "")
	end
	self:ClearFocus()
end

-- Blizzard anchors control labels at LEFT + 37; mirror it so our row lines up
-- with the surrounding checkboxes/dropdowns.
local SETTINGS_LABEL_INDENT = 37

function LedgerGoblinSettingsEditBoxMixin:EvaluateState()
	local initializer = self.initializer
	local enabled = true
	if initializer and initializer.EvaluateModifyPredicates then
		enabled = initializer:EvaluateModifyPredicates()
	end

	local nameColor = enabled and NORMAL_FONT_COLOR or GRAY_FONT_COLOR
	self.Text:SetTextColor(nameColor:GetRGB())
	local d = enabled and 0.75 or 0.4
	self.Description:SetTextColor(d, d, d)

	if self.EditBox then
		self.EditBox:SetEnabled(enabled)
		if not enabled then
			self.EditBox:ClearFocus()
		end
		self.EditBox:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
	end
end

function LedgerGoblinSettingsEditBoxMixin:Init(initializer)
	local data = initializer:GetData()
	self._lgData = data
	self.initializer = initializer

	if self.cbrHandles then
		self.cbrHandles:Unregister()
	elseif Settings and Settings.CreateCallbackHandleContainer then
		self.cbrHandles = Settings.CreateCallbackHandleContainer()
	end
	local parentInitializer = initializer.GetParentInitializer and initializer:GetParentInitializer()
	if parentInitializer then
		local parentSetting = parentInitializer:GetSetting()
		if self.cbrHandles and parentSetting then
			self.cbrHandles:SetOnValueChangedCallback(parentSetting:GetVariable(), self.EvaluateState, self)
		end
	end

	self.Text:SetText(data and data.name or "")
	self.Description:SetText(data and data.tooltip or "")

	local indent = (initializer.GetIndent and initializer:GetIndent()) or 0
	self.Text:ClearAllPoints()
	self.Text:SetPoint("TOPLEFT", indent + SETTINGS_LABEL_INDENT, -4)

	if not self.EditBox then
		local box = CreateFrame("EditBox", nil, self, "InputBoxTemplate")
		box:SetAutoFocus(false)
		box:SetSize(180, 22)
		box:SetScript("OnEnterPressed", editBox_OnEnterPressed)
		box:SetScript("OnEscapePressed", editBox_OnEscapePressed)
		self.EditBox = box
	end

	-- Drop the box below the (possibly wrapped) description, derived from the
	-- measured height (anchoring to the description's BOTTOMLEFT is unreliable).
	local descHeight = self.Description:GetStringHeight()
	if not descHeight or descHeight <= 0 then descHeight = 12 end
	self.EditBox:ClearAllPoints()
	self.EditBox:SetPoint("TOPLEFT", self.Text, "BOTTOMLEFT", 6, -(descHeight + 11))
	self.EditBox:SetWidth((data and data.width) or 180)
	self.EditBox:SetText((data and data.getValue and data.getValue()) or "")

	self:EvaluateState()
end

function LedgerGoblinSettingsEditBoxMixin:Release()
	if self.cbrHandles then
		self.cbrHandles:Unregister()
	end
end

--- Initializer for an inline edit box row. The value is owned by the caller via
--- getValue/setValue, so it can read/write any saved field (we use it for money,
--- parsing g/s/c on commit).
function F.CreateSettingsEditBox(name, tooltip, getValue, setValue, width)
	if not (Settings and Settings.CreateElementInitializer) then return end
	local initializer = Settings.CreateElementInitializer("LedgerGoblinSettingsEditBoxTemplate", {
		name = name,
		tooltip = tooltip,
		getValue = getValue,
		setValue = setValue,
		width = width or 180,
	})
	initializer.GetExtent = function() return 74 end
	return initializer
end
