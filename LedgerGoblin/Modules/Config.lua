--[[
	LedgerGoblin - Config
	-------------------------------------------------------------------------
	The /ledger command and the Settings panel. The panel covers the main
	routing surface (auto-run, gold with g/s/c money inputs, per-quality and
	per-bind targets) using Blizzard's vertical-layout Settings API, writing
	straight into ns.db. A custom canvas sub-page handles dynamic rule rows
	(specific-item routing and exclusions), because the vertical list is static.

	Dependent rows (targets, money fields) appear only when their parent toggle /
	mode is active, so the panel never shows controls that can't do anything.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Config = ns:NewModule("Config")

local format = string.format
local tostring = tostring
local tonumber = tonumber
local gsub = string.gsub
local wipe = wipe

local CreateFrame = CreateFrame

-- luacheck: globals MenuUtil GameTooltip

local category -- our Settings category handle
local ruleEditor
local mailBar -- holder frame for mailbox buttons (repositioned per tab)

-- Confirmation popup for large sends. Engine fills in `text` before showing and
-- passes the planned jobs through as data so we route exactly what was offered.
_G["StaticPopupDialogs"]["LEDGERGOBLIN_CONFIRM_SEND"] = {
	text = "",
	button1 = _G["YES"] or "Yes",
	button2 = _G["NO"] or "No",
	OnAccept = function(_, data)
		ns:GetModule("Engine").RunConfirmed(data and data.jobs)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}

-- Wipe the transfer log + daily analytics (roster and learned repair costs are
-- kept - they're useful and self-rebuild). Confirmed because history is gone for
-- good.
_G["StaticPopupDialogs"]["LEDGERGOBLIN_CONFIRM_RESET"] = {
	text = L["Clear all LedgerGoblin transfer history and stats? This cannot be undone."],
	button1 = _G["YES"] or "Yes",
	button2 = _G["NO"] or "No",
	OnAccept = function()
		ns:GetModule("Logger").ClearHistory()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}

-- Build the dynamic list of mail targets: "None" plus every known alt, each
-- coloured by class. Evaluated fresh each time a dropdown opens.
local function TargetOptions()
	local Roster = ns:GetModule("Roster")
	local container = Settings.CreateControlTextContainer()
	container:Add("", L["None"])
	local list = Roster.List(false)
	for i = 1, #list do
		local key = list[i]
		container:Add(key, "|c" .. Roster.ClassHex(key) .. key .. "|r")
	end
	return container:GetData()
end

-- Register a setting bound directly to tbl[key], typed from its default.
local function Bind(variable, tbl, key, default, name)
	return Settings.RegisterAddOnSetting(category, variable, key, tbl, type(default), name, default)
end

-- Grey out / hide a child row until its parent toggle (or predicate) is true.
local function DependsOn(child, parent, predicate)
	if not (child and parent and child.SetParentInitializer) then
		return
	end
	child:SetParentInitializer(parent, function()
		local setting = parent.GetSetting and parent:GetSetting()
		if not (setting and setting.GetValue) then
			return false
		end
		if predicate then
			return predicate(setting:GetValue())
		end
		return setting:GetValue() and true or false
	end)
end

-- Re-draw the settings list when a value change should re-evaluate dependent
-- rows (e.g. gold mode swapping which money box is visible).
local function RefreshSettings()
	local panel = _G["SettingsPanel"]
	if panel and panel.DisplayCategory and ns.settingsCategory then
		panel:DisplayCategory(ns.settingsCategory)
	end
end

local function AddHeader(layout, text)
	local init = _G["CreateSettingsListSectionHeaderInitializer"]
	if init then
		layout:AddInitializer(init(text))
	end
end

-- Settings sliders show no value without a right-side label formatter, so wire
-- one (with a unit suffix) here. The thumb value was being cut off otherwise.
local SLIDER_LABEL_RIGHT
do
	local mixin = _G["MinimalSliderWithSteppersMixin"]
	if mixin and mixin.Label then
		SLIDER_LABEL_RIGHT = mixin.Label.Right
	end
end

local function SliderOptions(minV, maxV, step, formatter)
	local opts = Settings.CreateSliderOptions(minV, maxV, step)
	if SLIDER_LABEL_RIGHT and formatter and opts.SetLabelFormatter then
		opts:SetLabelFormatter(SLIDER_LABEL_RIGHT, formatter)
	end
	return opts
end

-- Wrapped explanatory paragraph under a header (no-op if the helper is absent).
local function AddDesc(layout, text)
	local init = F.CreateSettingsDescription and F.CreateSettingsDescription(text)
	if init then
		layout:AddInitializer(init)
	end
end

-- ---------------------------------------------------------------------------
-- Rule editor canvas
-- ---------------------------------------------------------------------------

local scratch = {}

local function CreateLabel(parent, text, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local function CreateInput(parent, width)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetAutoFocus(false)
	box:SetSize(width, 24)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	return box
end

local function CreateButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 120, 24)
	button:SetText(text)
	return button
end

-- A subtle dark panel to group a section, so the editor reads as cards rather
-- than a wall of controls.
local function CreateInset(parent)
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
		f:SetBackdropColor(0, 0, 0, 0.30)
		-- Faint goblin-gold edge so the cards belong to the same set as the
		-- window's gold border, without shouting.
		f:SetBackdropBorderColor(C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3], 0.18)
	end
	return f
end

local GetCursorInfo = GetCursorInfo
local ClearCursor = ClearCursor

-- Boxes wired with WireItemInput, so the shift-click hook can find whichever one
-- has focus. A single secure post-hook on ChatEdit_InsertLink feeds them all.
local wiredItemBoxes = {}
local linkHookInstalled = false

-- Pull the itemID out of an item link (numeric -> rule routes & guards cleanly);
-- fall back to the raw text for anything that isn't an item.
local function ItemIDFromLink(link)
	if type(link) ~= "string" then
		return nil
	end
	return link:match("|Hitem:(%d+)") or link:match("^item:(%d+)")
end

-- Retail's default ChatEdit_InsertLink only deigns to feed chat and a handful of
-- blessed edit boxes, so a shift-clicked item simply ghosts our custom box. A
-- secure post-hook (taint-free; the battle-tested Ace3/PhanxConfig pattern)
-- routes the link to whichever of our boxes is visible and focused.
local function InstallLinkHook()
	if linkHookInstalled or type(hooksecurefunc) ~= "function" then
		return
	end
	linkHookInstalled = true
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if type(link) ~= "string" then
			return
		end
		for i = 1, #wiredItemBoxes do
			local box = wiredItemBoxes[i]
			if box:IsVisible() and box:HasFocus() then
				local id = ItemIDFromLink(link)
				box:SetText(id or link)
				box:SetCursorPosition(box:GetText():len())
				return
			end
		end
	end)
end

-- Make an edit box "drop-and-go": shift-clicking or dragging an item in fills
-- its itemID automatically (links are converted; bag items are picked off the
-- cursor). Turns rule entry from "go look up the ID" into one gesture.
local function WireItemInput(box)
	-- Convert any item link that reaches the box (paste, or a flavor that inserts
	-- directly) down to its bare ID, regardless of how the text arrived.
	box:HookScript("OnTextChanged", function(self)
		local id = self:GetText():match("|Hitem:(%d+)")
		if id then
			self:SetText(id)
			self:SetCursorPosition(#id)
		end
	end)
	local function takeCursorItem(self)
		local kind, itemID = GetCursorInfo()
		if kind == "item" and itemID then
			self:SetText(tostring(itemID))
			ClearCursor()
		end
	end
	box:SetScript("OnReceiveDrag", takeCursorItem)
	box:HookScript("OnMouseDown", takeCursorItem)

	wiredItemBoxes[#wiredItemBoxes + 1] = box
	InstallLinkHook()
end

-- Friendly label for a rule's match. For an itemID we show the item link if the
-- client has it cached (so the list reads "[Copper Ore]" not "itemID 2770");
-- otherwise we fall back to the raw ID so the row is never blank.
local function FormatMatch(match)
	if type(match) == "number" then
		---@diagnostic disable-next-line: deprecated
		local getInfo = (C_Item and C_Item.GetItemInfo) or _G["GetItemInfo"]
		if getInfo then
			local data = { getInfo(match) }
			local link = data[2]
			if link then
				return link
			end
		end
		return format(L["itemID %d"], match)
	end
	return tostring(match)
end

---@diagnostic disable-next-line: deprecated
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G["GetItemInfoInstant"]
local QUESTION_MARK_ICON = 134400 -- INV_Misc_QuestionMark, the universal "unknown item" icon

-- Visual bits for an itemID: file icon, quality colour (r,g,b), and the item
-- link (nil if the client hasn't cached the item yet). The icon resolves
-- instantly; quality/link are async, so on a miss we ask the client to load the
-- item and return neutral grey - callers recolour on GET_ITEM_INFO_RECEIVED.
local function ItemDisplay(itemID)
	local icon = QUESTION_MARK_ICON
	if GetItemInfoInstant then
		local _, _, _, _, ic = GetItemInfoInstant(itemID)
		if ic then
			icon = ic
		end
	end

	local r, g, b = 0.62, 0.62, 0.62 -- "loading" grey until quality is known
	local link
	---@diagnostic disable-next-line: deprecated
	local getInfo = (C_Item and C_Item.GetItemInfo) or _G["GetItemInfo"]
	if getInfo then
		local data = { getInfo(itemID) }
		link = data[2]
		local quality = data[3]
		local qc = quality and C.QualityColors and C.QualityColors[quality]
		if qc then
			r, g, b = qc.r, qc.g, qc.b
		end
	end

	-- Not cached: kick off a load; the editor refreshes when it arrives.
	if not link and C_Item and C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
	end

	return icon, r, g, b, link
end

-- Show an item's full tooltip (icon + stats) for a row/chip, anchored to it.
local function ShowItemTooltip(owner, itemID)
	if not (GameTooltip and itemID) then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetItemByID(itemID)
	GameTooltip:Show()
end

-- Strip colour + hyperlink escapes so a coloured item link becomes plain
-- "[Name]" text (used for the dimmed look on disabled rules, where we want a
-- single flat grey rather than the item's own colour).
local function PlainText(s)
	if not s then
		return ""
	end
	s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
	s = gsub(s, "|H.-|h", "")
	s = gsub(s, "|h", "")
	s = gsub(s, "|r", "")
	return s
end

-- "Name-Realm" wrapped in its class colour (white if the alt isn't in the
-- roster yet).
local function TargetColored(target)
	if not target or target == "" then
		return "|cff999999?|r"
	end
	local Roster = ns:GetModule("Roster")
	local hex = (Roster and Roster.ClassHex and Roster.ClassHex(target)) or "ffffffff"
	return "|c" .. hex .. target .. "|r"
end

-- Neutral grey arrow between match and target.
local RULE_ARROW = "|cff808080  ->  |r"

-- Pop a class-coloured menu of known alts and write the chosen name into `box`.
local function ShowTargetMenu(owner, box)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		return
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(L["Target character"])
		local Roster = ns:GetModule("Roster")
		local list = Roster.List(false)
		if #list == 0 then
			root:CreateButton(L["No known characters yet. Log into an alt once so LedgerGoblin can see it."], function() end)
			return
		end
		for i = 1, #list do
			local key = list[i]
			root:CreateButton("|c" .. Roster.ClassHex(key) .. key .. "|r", function()
				box:SetText(key)
			end)
		end
	end)
end

local GameTooltip = _G["GameTooltip"]

-- Forward declaration: the row helpers below remove rules and then refresh the
-- editor, but RefreshRuleEditor is defined further down.
local RefreshRuleEditor

-- Delete a single rule by its position in the list, then redraw.
local function RemoveItemRule(index)
	local rules = ns.db.itemRules
	local rule = rules[index]
	if not rule then
		return
	end
	table.remove(rules, index)
	F.Print(L["Removed item rule: %s -> %s"], FormatMatch(rule.match), rule.target or "")
	RefreshRuleEditor()
end

-- Toggle a rule's enabled flag (nil/true -> false -> true) and redraw.
local function ToggleItemRule(index)
	local rule = ns.db.itemRules[index]
	if not rule then
		return
	end
	rule.enabled = (rule.enabled == false)
	RefreshRuleEditor()
end

-- Bulk enable/disable every rule at once - a lifesaver for long lists. One
-- redraw at the end instead of per-row.
local function SetAllItemRules(enabled)
	local rules = ns.db.itemRules
	for i = 1, #rules do
		rules[i].enabled = enabled
	end
	RefreshRuleEditor()
end

-- Set/clear an itemID's keep-N reserve from a row's edit box. n<=0 or empty
-- clears the reserve entirely (send everything again).
local function SetKeepForItem(itemID, n)
	if not itemID then
		return
	end
	n = tonumber(n)
	if not n or n <= 0 then
		ns.db.keep[itemID] = nil
	else
		ns.db.keep[itemID] = math.floor(n)
	end
end

-- Each rule row carries: an enable checkbox, the "match -> target" label, a
-- keep-N box (only meaningful for itemID rules; hidden for name rules), and a
-- remove button. Rows are pooled and re-bound to a rule index on each refresh.
local ROW_HEIGHT = 28

local function AcquireRuleRow(holder, index)
	holder.rows = holder.rows or {}
	local row = holder.rows[index]
	if row then
		return row
	end

	row = CreateFrame("Frame", nil, holder)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

	local hl = row:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.04)
	row.bg = hl

	-- The row itself (the area not covered by a child control) shows the item's
	-- tooltip on hover.
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		if self.itemID then
			ShowItemTooltip(self, self.itemID)
		end
	end)
	row:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)

	-- Enable / disable.
	local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	check:SetSize(22, 22)
	check:SetPoint("LEFT", 0, 0)
	check:SetScript("OnClick", function()
		ToggleItemRule(row.index)
	end)
	check:SetScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(L["Enable or disable this route without deleting it."], 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	check:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	row.check = check

	-- Item icon, just right of the checkbox.
	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("LEFT", check, "RIGHT", 2, 0)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.icon = icon

	-- Remove button (far right).
	local remove = CreateFrame("Button", nil, row)
	remove:SetSize(18, 18)
	remove:SetPoint("RIGHT", -2, 0)
	local rx = remove:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	rx:SetAllPoints()
	rx:SetText("x")
	rx:SetTextColor(1, 0.35, 0.35)
	remove.label = rx
	remove:SetScript("OnClick", function()
		RemoveItemRule(row.index)
	end)
	remove:SetScript("OnEnter", function(self)
		rx:SetTextColor(1, 0.6, 0.6)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(L["Click to remove this route."], 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	remove:SetScript("OnLeave", function()
		rx:SetTextColor(1, 0.35, 0.35)
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	row.remove = remove

	-- Keep-N box (right side, before remove).
	local keep = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	keep:SetSize(40, 18)
	keep:SetPoint("RIGHT", remove, "LEFT", -10, 0)
	keep:SetAutoFocus(false)
	keep:SetNumeric(true)
	keep:SetJustifyH("CENTER")
	keep:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	local commitKeep = function(self)
		SetKeepForItem(row.itemID, self:GetText())
		RefreshRuleEditor()
	end
	keep:SetScript("OnEnterPressed", function(self)
		commitKeep(self)
		self:ClearFocus()
	end)
	keep:SetScript("OnEditFocusLost", commitKeep)
	keep:SetScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(L["Keep at least this many in your bags; send the rest."], 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	keep:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	row.keep = keep

	local keepLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	keepLabel:SetPoint("RIGHT", keep, "LEFT", -8, 0)
	keepLabel:SetText(L["keep"])
	row.keepLabel = keepLabel

	-- The "match -> target" label fills the middle, between icon and keep.
	local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	text:SetPoint("RIGHT", keepLabel, "LEFT", -10, 0)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	row.text = text

	holder.rows[index] = row
	return row
end

local function FillRuleRows(holder, rules)
	if not holder then
		return
	end
	holder.rows = holder.rows or {}

	if not holder.empty then
		local e = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		e:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, -4)
		e:SetText(L["No specific item rules configured."])
		holder.empty = e
	end

	local n = #rules
	holder.empty:SetShown(n == 0)

	-- Match the scroll child's width to its viewport so rows fill it and the
	-- right-hand controls line up under the scrollbar gap.
	local scroll = holder:GetParent()
	local w = (scroll and scroll.GetWidth and scroll:GetWidth()) or 0
	if w <= 0 then
		w = 480
	end
	holder:SetWidth(w)

	for i = 1, n do
		local row = AcquireRuleRow(holder, i)
		local rule = rules[i]
		row.index = i
		row.rule = rule

		local enabled = rule.enabled ~= false
		row.check:SetChecked(enabled)

		-- Each segment carries its OWN colour escape (item = quality/link colour,
		-- target = class colour, arrow = grey) and the FontString base stays
		-- white, so no single colour bleeds across the line. Disabled rules drop
		-- to a flat grey instead.
		local target = rule.target or ""
		if type(rule.match) == "number" then
			row.itemID = rule.match
			local icon, r, g, b, link = ItemDisplay(rule.match)
			row.icon:SetTexture(icon)
			row.icon:Show()

			if enabled then
				-- Prefer the item link (self-coloured) plus a dim itemID tag, so
				-- same-named items (e.g. different upgrade tiers) are
				-- distinguishable and a mistyped ID is obvious. While the item is
				-- still loading we only have the quality-coloured "[itemID]".
				local matchText
				if link then
					matchText = link .. format(" |cff7f7f7f(%d)|r", rule.match)
				else
					matchText = format("|cff%02x%02x%02x[%d]|r", r * 255, g * 255, b * 255, rule.match)
				end
				row.text:SetText(matchText .. RULE_ARROW .. TargetColored(target))
				row.text:SetTextColor(1, 1, 1)
			else
				local matchText = link and (PlainText(link) .. format(" (%d)", rule.match)) or format(L["[%d]"], rule.match)
				row.text:SetText(format("%s  ->  %s", matchText, target ~= "" and target or "?"))
				row.text:SetTextColor(0.5, 0.5, 0.5)
			end

			local kept = ns.db.keep[rule.match]
			row.keep:SetText(kept and tostring(kept) or "")
			row.keep:Show()
			row.keepLabel:Show()
		else
			row.itemID = nil
			row.icon:Hide()
			if enabled then
				local matchText = "|cffffffff" .. PlainText(FormatMatch(rule.match)) .. "|r"
				row.text:SetText(matchText .. RULE_ARROW .. TargetColored(target))
				row.text:SetTextColor(1, 1, 1)
			else
				row.text:SetText(format("%s  ->  %s", PlainText(FormatMatch(rule.match)), target ~= "" and target or "?"))
				row.text:SetTextColor(0.5, 0.5, 0.5)
			end
			row.keep:SetText("")
			row.keep:Hide()
			row.keepLabel:Hide()
		end

		row:Show()
	end
	for i = n + 1, #holder.rows do
		holder.rows[i]:Hide()
	end

	-- Grow the scroll child so everything is reachable by scrolling.
	holder:SetHeight(math.max(1, n * ROW_HEIGHT))
end

-- Drop a single exclusion by itemID, then redraw.
local function RemoveExclusionByID(itemID)
	if not ns.db.exclusions[itemID] then
		return
	end
	ns.db.exclusions[itemID] = nil
	F.Print(L["Removed exclusion for itemID %d."], itemID)
	RefreshRuleEditor()
end

-- Exclusions render as a wrapping flow of chips: [icon][coloured name], each
-- with the item's tooltip on hover and click-to-remove. Chips are pooled.
local CHIP_HEIGHT = 20
local CHIP_PAD = 6 -- inner left/right padding inside a chip
local CHIP_GAP = 6 -- gap between chips on a line

local function AcquireChip(holder, index)
	holder.chips = holder.chips or {}
	local chip = holder.chips[index]
	if chip then
		return chip
	end

	chip = CreateFrame("Button", nil, holder)
	chip:SetHeight(CHIP_HEIGHT)

	local bg = chip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.06)
	chip.bg = bg

	local hi = chip:CreateTexture(nil, "HIGHLIGHT")
	hi:SetAllPoints()
	hi:SetColorTexture(1, 0.82, 0, 0.12)

	local icon = chip:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", CHIP_PAD, 0)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	chip.icon = icon

	local text = chip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
	chip.text = text

	chip:SetScript("OnEnter", function(self)
		if not (GameTooltip and self.itemID) then
			return
		end
		ShowItemTooltip(self, self.itemID)
		GameTooltip:AddLine(L["Click to remove this excluded item."], 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	chip:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	chip:SetScript("OnClick", function(self)
		RemoveExclusionByID(self.itemID)
	end)

	holder.chips[index] = chip
	return chip
end

local function FillExclusionChips(holder)
	if not holder then
		return
	end
	holder.chips = holder.chips or {}

	if not holder.empty then
		local e = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		e:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, -4)
		e:SetText(L["No exclusions configured."])
		holder.empty = e
	end

	wipe(scratch)
	for itemID, enabled in pairs(ns.db.exclusions) do
		if enabled then
			scratch[#scratch + 1] = itemID
		end
	end
	table.sort(scratch)

	local n = #scratch
	holder.empty:SetShown(n == 0)

	local scroll = holder:GetParent()
	local width = (scroll and scroll.GetWidth and scroll:GetWidth()) or 0
	if width <= 0 then
		width = 480
	end
	holder:SetWidth(width)

	local x, y = 0, 0
	for i = 1, n do
		local itemID = scratch[i]
		local chip = AcquireChip(holder, i)
		chip.itemID = itemID

		local icon, r, g, b = ItemDisplay(itemID)
		chip.icon:SetTexture(icon)
		chip.text:SetText(format(L["[%d]"], itemID))
		chip.text:SetTextColor(r, g, b)

		local w = CHIP_PAD + 16 + 4 + chip.text:GetStringWidth() + CHIP_PAD
		if x > 0 and (x + w) > width then
			x = 0
			y = y + CHIP_HEIGHT + 4
		end
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", holder, "TOPLEFT", x, -y)
		chip:SetWidth(w)
		chip:Show()

		x = x + w + CHIP_GAP
	end
	for i = n + 1, #holder.chips do
		holder.chips[i]:Hide()
	end

	holder:SetHeight(math.max(1, y + CHIP_HEIGHT + 4))
end

function RefreshRuleEditor()
	if not ruleEditor then
		return
	end

	FillRuleRows(ruleEditor.ruleListHolder, ns.db.itemRules)
	FillExclusionChips(ruleEditor.exclHolder)
end

-- Items not seen this session aren't cached, so the first draw shows a grey
-- numeric fallback. The client fires GET_ITEM_INFO_RECEIVED once each item
-- loads; redraw (debounced) so names + quality colours fill in.
local infoWatcher = CreateFrame("Frame")
infoWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
infoWatcher:SetScript("OnEvent", function(self)
	if not (ruleEditor and ruleEditor:IsShown()) or self.pending then
		return
	end
	self.pending = true
	C_Timer.After(0.1, function()
		self.pending = false
		RefreshRuleEditor()
	end)
end)

local function AddItemRule(matchText, targetText)
	matchText = (matchText or ""):gsub("^%s+", ""):gsub("%s+$", "")
	targetText = F.NormalizeTarget(targetText)
	if matchText == "" then
		F.Print(L["Enter an itemID or exact item name."])
		return
	end
	if not targetText then
		F.Print(L["Enter a target character."])
		return
	end

	-- A shift-clicked or pasted item arrives as a full hyperlink, not a bare ID.
	-- Pull the itemID out so it stores (and routes) as a numeric rule and runs
	-- the soulbound/BoP guard below, instead of slipping through as a name.
	local linkID = matchText:match("|Hitem:(%d+)") or matchText:match("^item:(%d+)")
	local match = tonumber(linkID) or tonumber(matchText) or matchText

	-- Block rules for items that can never be mailed off this character
	-- (soulbound / Bind-on-Pickup / quest): the rule would silently never fire.
	-- This now covers itemID, link, AND name matches - any of them is resolved
	-- and, when it sits in our bags, checked against its live binding.
	local routable, name = ns:GetModule("Engine").IsItemRoutable(match)
	if not routable then
		local label
		if name then
			label = "|cffffffff" .. name .. "|r"
		elseif type(match) == "number" then
			label = format(L["[%d]"], match)
		else
			label = "|cffffffff" .. tostring(match) .. "|r"
		end
		F.Print(L["%s can't be mailed from this character - rule not added."], label)
		return
	end

	ns.db.itemRules[#ns.db.itemRules + 1] = { match = match, target = targetText }
	F.Print(L["Added item rule: %s -> %s"], FormatMatch(match), targetText)
	RefreshRuleEditor()
end

local function RemoveLastItemRule()
	local rules = ns.db.itemRules
	local rule = rules[#rules]
	if not rule then
		return
	end
	rules[#rules] = nil
	F.Print(L["Removed item rule: %s -> %s"], FormatMatch(rule.match), rule.target or "")
	RefreshRuleEditor()
end

local function PrintItemRules()
	local rules = ns.db.itemRules
	if #rules == 0 then
		F.Print(L["No specific item rules configured."])
		return
	end
	for i = 1, #rules do
		local rule = rules[i]
		local suffix = ""
		if rule.enabled == false then
			suffix = " " .. L["(disabled)"]
		end
		if type(rule.match) == "number" then
			local kept = ns.db.keep[rule.match]
			if kept then
				suffix = suffix .. " " .. format(L["(keep %d)"], kept)
			end
		end
		F.Print(L["%d. %s -> %s"] .. suffix, i, FormatMatch(rule.match), rule.target or "")
	end
end

local function AddExclusion(itemText)
	local itemID = tonumber(itemText)
	if not itemID then
		F.Print(L["Enter a numeric itemID."])
		return
	end
	ns.db.exclusions[itemID] = true
	F.Print(L["Added exclusion for itemID %d."], itemID)
	RefreshRuleEditor()
end

local function RemoveLastExclusion()
	local last
	for itemID, enabled in pairs(ns.db.exclusions) do
		if enabled and (not last or itemID > last) then
			last = itemID
		end
	end
	if not last then
		return
	end
	ns.db.exclusions[last] = nil
	F.Print(L["Removed exclusion for itemID %d."], last)
	RefreshRuleEditor()
end

-- A vertical scroll viewport with a content child the lists lay out into. The
-- child's width is matched to the viewport at fill time. Returns scroll, content.
local function CreateScrollList(parent)
	local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local cur = self:GetVerticalScroll()
		local maxScroll = self:GetVerticalScrollRange()
		local new = cur - delta * (ROW_HEIGHT * 2)
		if new < 0 then
			new = 0
		elseif new > maxScroll then
			new = maxScroll
		end
		self:SetVerticalScroll(new)
	end)

	-- Keep the child matched to the viewport once layout resolves, then let the
	-- owner re-flow (chips wrap to width; rows auto-fill via their anchors).
	scroll:SetScript("OnSizeChanged", function(self, w)
		if w and w > 0 then
			content:SetWidth(w)
		end
		if content._relayout then
			content._relayout()
		end
	end)

	return scroll, content
end

-- Build the editor's controls (two cards: specific item rules + exclusions)
-- into `frame`, anchored below `anchorTop`. Sets frame.ruleListHolder (rule rows)
-- and frame.exclHolder (exclusion chips) for RefreshRuleEditor. Shared by window.
local function BuildEditorContent(frame, anchorTop)
	local desc = CreateLabel(frame, L["Rules refresh when you add or remove entries. Targets must be known characters on this account before the engine will send. Priority: specific item, then bind type, then quality."], "GameFontHighlight")
	desc:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(true)

	-- ---- Card 1: specific item rules ----
	local rulesInset = CreateInset(frame)
	rulesInset:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
	rulesInset:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	rulesInset:SetHeight(336)

	local rulesHeader = CreateLabel(rulesInset, L["Specific Item Rules"], "GameFontNormalLarge")
	rulesHeader:SetPoint("TOPLEFT", 12, -10)
	rulesHeader:SetTextColor(1, 0.82, 0)

	local tip = CreateLabel(rulesInset, L["Tip: shift-click or drag an item here to fill its ID."], "GameFontDisableSmall")
	tip:SetPoint("TOPRIGHT", -12, -12)

	local matchInput = CreateInput(rulesInset, 150)
	matchInput:SetPoint("TOPLEFT", rulesHeader, "BOTTOMLEFT", 4, -22)
	matchInput:SetText("")
	WireItemInput(matchInput)

	local matchLabel = CreateLabel(rulesInset, L["ItemID or exact item name"], "GameFontDisableSmall")
	matchLabel:SetPoint("BOTTOMLEFT", matchInput, "TOPLEFT", 0, 3)

	local targetInput = CreateInput(rulesInset, 150)
	targetInput:SetPoint("LEFT", matchInput, "RIGHT", 16, 0)

	local targetLabel = CreateLabel(rulesInset, L["Target character"], "GameFontDisableSmall")
	targetLabel:SetPoint("BOTTOMLEFT", targetInput, "TOPLEFT", 0, 3)

	-- Roster picker fills the target box from a class-coloured menu of alts.
	local pick = CreateButton(rulesInset, L["Pick"], 50)
	pick:SetPoint("LEFT", targetInput, "RIGHT", 6, 0)
	pick:SetScript("OnClick", function(self)
		ShowTargetMenu(self, targetInput)
	end)

	local addRule = CreateButton(rulesInset, L["Add Rule"], 100)
	addRule:SetPoint("TOPLEFT", matchInput, "BOTTOMLEFT", 0, -10)
	addRule:SetScript("OnClick", function()
		AddItemRule(matchInput:GetText(), targetInput:GetText())
		matchInput:SetText("")
		matchInput:SetFocus()
	end)
	matchInput:SetScript("OnEnterPressed", function()
		addRule:Click()
	end)
	targetInput:SetScript("OnEnterPressed", function()
		addRule:Click()
	end)

	local listLabel = CreateLabel(rulesInset, L["Your routes - tick to enable, set keep to hold some back, x to remove:"], "GameFontDisableSmall")
	listLabel:SetPoint("TOPLEFT", addRule, "BOTTOMLEFT", 0, -12)

	-- Bulk toggles for long lists. Right-aligned on the list-label line so they
	-- never crowd the routes themselves.
	local uncheckAll = CreateButton(rulesInset, L["Uncheck All"], 90)
	uncheckAll:SetPoint("BOTTOMRIGHT", rulesInset, "TOPRIGHT", -12, 0)
	uncheckAll:SetPoint("TOP", listLabel, "TOP", 0, 6)
	uncheckAll:SetScript("OnClick", function()
		SetAllItemRules(false)
	end)

	local checkAll = CreateButton(rulesInset, L["Check All"], 80)
	checkAll:SetPoint("RIGHT", uncheckAll, "LEFT", -6, 0)
	checkAll:SetScript("OnClick", function()
		SetAllItemRules(true)
	end)

	-- Scrollable viewport for the pooled rule rows. FillRuleRows lays rows out
	-- into the scroll child and grows it so every rule is reachable.
	local ruleScroll, ruleContent = CreateScrollList(rulesInset)
	ruleScroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -4)
	ruleScroll:SetPoint("BOTTOMRIGHT", rulesInset, "BOTTOMRIGHT", -26, 12)
	frame.ruleListHolder = ruleContent

	-- ---- Card 2: exclusions ----
	local exclInset = CreateInset(frame)
	exclInset:SetPoint("TOPLEFT", rulesInset, "BOTTOMLEFT", 0, -14)
	exclInset:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	exclInset:SetHeight(176)

	local exclHeader = CreateLabel(exclInset, L["Excluded Items"], "GameFontNormalLarge")
	exclHeader:SetPoint("TOPLEFT", 12, -10)
	exclHeader:SetTextColor(1, 0.82, 0)

	local exclTip = CreateLabel(exclInset, L["Tip: shift-click or drag an item here to fill its ID."], "GameFontDisableSmall")
	exclTip:SetPoint("TOPRIGHT", -12, -12)

	local exclInput = CreateInput(exclInset, 150)
	exclInput:SetPoint("TOPLEFT", exclHeader, "BOTTOMLEFT", 4, -22)
	WireItemInput(exclInput)

	local exclLabel = CreateLabel(exclInset, L["Exclude itemID"], "GameFontDisableSmall")
	exclLabel:SetPoint("BOTTOMLEFT", exclInput, "TOPLEFT", 0, 3)

	local addExcl = CreateButton(exclInset, L["Add Exclusion"], 120)
	addExcl:SetPoint("LEFT", exclInput, "RIGHT", 16, 0)
	addExcl:SetScript("OnClick", function()
		AddExclusion(exclInput:GetText())
		exclInput:SetText("")
		exclInput:SetFocus()
	end)
	exclInput:SetScript("OnEnterPressed", function()
		addExcl:Click()
	end)

	local removeExcl = CreateButton(exclInset, L["Remove Last Exclusion"], 160)
	removeExcl:SetPoint("LEFT", addExcl, "RIGHT", 8, 0)
	removeExcl:SetScript("OnClick", RemoveLastExclusion)

	local hint = CreateLabel(exclInset, L["Hover an item to identify it; click it to remove."], "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", exclInput, "BOTTOMLEFT", 0, -10)

	-- Scrollable flow of exclusion chips ([icon][coloured name], click to remove).
	local exclScroll, exclContent = CreateScrollList(exclInset)
	exclScroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -4)
	exclScroll:SetPoint("BOTTOMRIGHT", exclInset, "BOTTOMRIGHT", -26, 12)
	exclContent._relayout = function()
		FillExclusionChips(exclContent)
	end
	frame.exclHolder = exclContent
end

-- Standalone, movable Rule Editor window. Deliberately NOT a UIPanel (shown with
-- :Show(), not ShowUIPanel), so it coexists with open bags - the whole reason it
-- lives here instead of inside Blizzard's Settings panel, which the UIPanel
-- manager refuses to show alongside the (combined) bag frame. Drag/shift-click
-- item entry only works when bags can be open, hence this window.
local function CreateRuleWindow()
	local win = CreateFrame("Frame", "LedgerGoblinRuleWindow", _G["UIParent"], "BackdropTemplate")
	win:SetSize(560, 654)
	win:SetPoint("CENTER")
	win:SetFrameStrata("HIGH")
	win:SetToplevel(true)
	win:EnableMouse(true)
	win:SetMovable(true)
	win:SetClampedToScreen(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()

	-- Clean window chrome: a dark fill with a thin, gold-tinted tooltip-style
	-- border, replacing the chunky DialogBox gold rope. The thin bevel reads as
	-- "Warcraft" without the bulk, and matches the inset cards inside.
	local r, g, b = C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3]
	if win.SetBackdrop then
		win:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		win:SetBackdropColor(0.05, 0.05, 0.06, 0.95)
		win:SetBackdropBorderColor(r, g, b, 0.8)
	end

	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Icon chip + title, then a hairline gold divider that the content hangs off.
	local icon = win:CreateTexture(nil, "ARTWORK")
	icon:SetSize(28, 28)
	icon:SetPoint("TOPLEFT", 16, -14)
	icon:SetTexture(C.Icon)

	local header = CreateLabel(win, C.Title .. "  " .. L["Rule Editor"], "GameFontNormalLarge")
	header:SetPoint("LEFT", icon, "RIGHT", 8, 0)

	local divider = win:CreateTexture(nil, "ARTWORK")
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -10)
	divider:SetPoint("RIGHT", win, "RIGHT", -16, 0)
	divider:SetColorTexture(r, g, b, 0.35)

	BuildEditorContent(win, divider)

	-- Escape closes it, like any well-behaved window.
	local special = _G["UISpecialFrames"]
	if special then
		special[#special + 1] = "LedgerGoblinRuleWindow"
	end

	win:SetScript("OnShow", RefreshRuleEditor)
	ruleEditor = win
	return win
end

-- Lazily build + toggle the standalone window. `show` forces it open.
local function ToggleRuleWindow(show)
	if not ruleEditor then
		CreateRuleWindow()
	end
	if show or not ruleEditor:IsShown() then
		ruleEditor:Show()
		RefreshRuleEditor()
	else
		ruleEditor:Hide()
	end
end
ns.ToggleRuleWindow = ToggleRuleWindow

-- Settings-panel launcher: a small canvas whose only job is to bounce you to the
-- standalone window. We HideUIPanel(SettingsPanel) first because the Settings
-- panel and the bag frame can't be shown together (Blizzard UIPanel rule), and
-- the editor needs bags open for drag/shift-click entry.
local function CreateRuleLauncher()
	local frame = CreateFrame("Frame")

	local title = CreateLabel(frame, L["Rule Editor"], "GameFontHighlightHuge")
	title:SetPoint("TOPLEFT", 16, -16)

	local desc = CreateLabel(frame, L["Per-item routing opens in its own movable window so you can keep your bags open and drag items straight in (Blizzard won't show bags while this Settings panel is open)."], "GameFontHighlight")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(true)

	local open = CreateButton(frame, L["Open Rule Editor"], 200)
	open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	open:SetScript("OnClick", function()
		local panel = _G["SettingsPanel"]
		if panel and panel:IsShown() and _G["HideUIPanel"] then
			_G["HideUIPanel"](panel)
		end
		ToggleRuleWindow(true)
	end)

	local hint = CreateLabel(frame, L["You can also open it any time with /ledger rules."], "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 2, -10)

	return frame
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------

local function BuildPanel()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then
		return
	end

	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory(C.Title)
	ns.settingsCategory = category

	local db = ns.db
	local D = C.CHAR_DEFAULTS

	-- Intro: one paragraph that explains the whole addon before any control.
	AddHeader(layout, C.Title)
	AddDesc(layout, L["LedgerGoblin sends gold and items to your alts by rule. Set up routes below, open a mailbox, and click Send (or let it run automatically). Use the Rule Editor for per-item routes; type /ledger for all commands."])

	-- General. Visible label = the setting's name (kept short so it isn't cut
	-- off); the full sentence rides along as the hover tooltip + description.
	AddHeader(layout, L["Routing Rules"])
	do
		local s = Bind("LG_autoRun", db, "autoRun", D.autoRun, L["Auto-run on mailbox open"])
		Settings.CreateCheckbox(category, s, L["Auto-run when the mailbox opens"])
		AddDesc(layout, L["Open the mailbox and LedgerGoblin sends everything your rules match, automatically."])

		local s2 = Bind("LG_holdShift", db, "holdShiftToDisable", D.holdShiftToDisable, L["Hold Shift to skip auto-run"])
		Settings.CreateCheckbox(category, s2, L["Hold Shift to skip auto-run"])

		local sConfirm = Bind("LG_confirm", db, "confirmThreshold", D.confirmThreshold, L["Confirm large sends"])
		Settings.CreateSlider(
			category,
			sConfirm,
			SliderOptions(0, 20000, 250, function(v)
				return v .. "g"
			end),
			L["Ask before sending if a run would move at least this much gold. Set to 0 to never ask."]
		)
		AddDesc(layout, L["Ask before sending if a run would move at least this much gold. Set to 0 to never ask."])
	end

	-- Gold
	AddHeader(layout, L["Gold"])
	AddDesc(layout, L["Send gold to your chosen character"])
	do
		local g = db.gold
		local Dg = D.gold

		local sEnable = Bind("LG_goldEnable", g, "enabled", Dg.enabled, L["Enable gold routing"])
		local enableInit = Settings.CreateCheckbox(category, sEnable, L["Enable gold routing"])
		sEnable:SetValueChangedCallback(RefreshSettings)

		local sTarget = Bind("LG_goldTarget", g, "target", Dg.target, L["Destination"])
		local targetInit = Settings.CreateDropdown(category, sTarget, TargetOptions, L["Send gold to"])
		DependsOn(targetInit, enableInit)

		local sMode = Bind("LG_goldMode", g, "mode", Dg.mode, L["Gold mode"])
		local modeInit = Settings.CreateDropdown(category, sMode, function()
			local container = Settings.CreateControlTextContainer()
			container:Add(C.GOLD_MODE.KEEP, L["Keep this much, send the rest"])
			container:Add(C.GOLD_MODE.FIXED, L["Send a fixed amount"])
			container:Add(C.GOLD_MODE.PERCENT, L["Send a percentage"])
			return container:GetData()
		end, L["Gold mode"])
		DependsOn(modeInit, enableInit)
		sMode:SetValueChangedCallback(RefreshSettings)

		-- KEEP / FIXED amounts as g/s/c money boxes; only the active mode's box
		-- shows. PERCENT stays a slider (it's a 0-100 value, not money).
		local keepBox = F.CreateSettingsEditBox(L["Amount to keep here"], L["Amount left on this character; the remainder is sent. Type like 1000g 50s 20c."], function()
			return F.MoneyText(g.keepCopper)
		end, function(text)
			local c = F.ParseMoney(text)
			if c then
				g.keepCopper = c
			else
				F.Print(L["That amount isn't valid. Try a number, or 100g 50s 20c."])
			end
		end, 200)
		if keepBox then
			layout:AddInitializer(keepBox)
			DependsOn(keepBox, enableInit, function(enabled)
				return enabled and g.mode == C.GOLD_MODE.KEEP
			end)
		end

		local fixedBox = F.CreateSettingsEditBox(L["Amount to send"], L["Exact amount sent each run. Type like 100g 50s 20c."], function()
			return F.MoneyText(g.fixedCopper)
		end, function(text)
			local c = F.ParseMoney(text)
			if c then
				g.fixedCopper = c
			else
				F.Print(L["That amount isn't valid. Try a number, or 100g 50s 20c."])
			end
		end, 200)
		if fixedBox then
			layout:AddInitializer(fixedBox)
			DependsOn(fixedBox, enableInit, function(enabled)
				return enabled and g.mode == C.GOLD_MODE.FIXED
			end)
		end

		local sPct = Bind("LG_goldPct", g, "percent", Dg.percent, L["Percent"])
		local pctInit = Settings.CreateSlider(
			category,
			sPct,
			SliderOptions(0, 100, 5, function(v)
				return v .. "%"
			end),
			L["Send a percentage"]
		)
		DependsOn(pctInit, enableInit, function(enabled)
			return enabled and g.mode == C.GOLD_MODE.PERCENT
		end)

		local sReserve = Bind("LG_goldReserve", g, "reserveForRepairs", Dg.reserveForRepairs, L["Reserve for repairs"])
		local reserveInit = Settings.CreateCheckbox(category, sReserve, L["Reserve for repairs"])
		DependsOn(reserveInit, enableInit)
		AddDesc(layout, L["Never send gold below your learned full-repair cost (captured at vendors)."])
	end

	-- Bind-based routing (BoE / account-bound). More specific than quality.
	AddHeader(layout, L["Bind Routing"])
	AddDesc(layout, L["Route by how an item binds. Bind on Equip gear is sent while still unequipped; account-bound items go to your own alts. These win over quality rules."])
	for i = 1, #C.BINDS do
		local b = C.BINDS[i]
		local tbl = db.bind[b.key]
		local def = D.bind[b.key]

		local sEnable = Bind("LG_b_" .. b.key .. "_en", tbl, "enabled", def.enabled, format(L["Route %s"], b.label))
		local enableInit = Settings.CreateCheckbox(category, sEnable, format(L["Route %s"], b.label))

		local sTarget = Bind("LG_b_" .. b.key .. "_tg", tbl, "target", def.target, L["Destination"])
		local targetInit = Settings.CreateDropdown(category, sTarget, TargetOptions, format(L["Send %s to"], b.label))
		DependsOn(targetInit, enableInit)
	end

	-- Per-quality routing: one enable toggle per quality, then a destination row
	-- that only appears when that quality is enabled.
	AddHeader(layout, L["Item Quality Routing"])
	AddDesc(layout, L["Catch-all by quality. More specific rules (item, then bind type) win over these."])
	for i = 1, #C.QUALITIES do
		local q = C.QUALITIES[i]
		local tbl = db.quality[q.key]
		local def = D.quality[q.key]
		local qc = C.QualityColors and C.QualityColors[q.enum]
		local coloured = qc and (qc.hex .. q.label .. "|r") or q.label

		local sEnable = Bind("LG_q_" .. q.key .. "_en", tbl, "enabled", def.enabled, format(L["Route %s items"], coloured))
		local enableInit = Settings.CreateCheckbox(category, sEnable, format(L["Route %s items"], coloured))

		local sTarget = Bind("LG_q_" .. q.key .. "_tg", tbl, "target", def.target, format(L["Send %s items to"], coloured))
		local targetInit = Settings.CreateDropdown(category, sTarget, TargetOptions, format(L["Send %s items to"], coloured))
		DependsOn(targetInit, enableInit)
	end

	if Settings.RegisterCanvasLayoutSubcategory then
		Settings.RegisterCanvasLayoutSubcategory(category, CreateRuleLauncher(), L["Rule Editor"])
	end

	Settings.RegisterAddOnCategory(category)
end

-- ---------------------------------------------------------------------------
-- Mailbox buttons
-- ---------------------------------------------------------------------------

local function SendButton_OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Ledger Send"])

	local Engine = ns:GetModule("Engine")
	if not Engine.HasAnyRule() then
		GameTooltip:AddLine(L["No rules configured yet - open /ledger to set up routing."], 1, 0.4, 0.4, true)
	else
		local items, copper, warnings = Engine.Summarize()
		if items == 0 and copper == 0 then
			GameTooltip:AddLine(L["Nothing matches your rules right now."], 0.8, 0.8, 0.8, true)
		else
			if items > 0 then
				GameTooltip:AddLine(format(L["Will send: %d item(s)"], items), 0.6, 1, 0.6)
			end
			if copper > 0 then
				GameTooltip:AddLine(format(L["Will send: %s"], F.Money(copper)), 0.6, 1, 0.6)
			end
		end
		if warnings then
			for i = 1, #warnings do
				GameTooltip:AddLine(warnings[i], 1, 0.5, 0.2, true)
			end
		end
	end
	GameTooltip:Show()
end

local function PreviewButton_OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Preview"])
	GameTooltip:AddLine(L["Show what would be sent, without sending anything."], 0.8, 0.8, 0.8, true)
	GameTooltip:Show()
end

local function RulesButton_OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Rules"])
	GameTooltip:AddLine(L["Open the Rule Editor window. Drag or shift-click items from your bags to route them."], 0.8, 0.8, 0.8, true)
	GameTooltip:Show()
end

local function Button_OnLeave()
	GameTooltip:Hide()
end

-- Reflect "are there any rules?" on the Send button each time the mailbox opens.
local function UpdateMailButtons()
	if not mailBar then
		return
	end
	mailBar.send:SetEnabled(ns:GetModule("Engine").HasAnyRule())
end

-- LedgerGoblin's mailbox toolbar: a styled strip attached just ABOVE the mail
-- frame, centered. The same spot is clear on both tabs (no overlap with the
-- Inbox Prev/Next, the Send Mail money row, or the bottom tabs), so there's no
-- per-tab repositioning to fight Blizzard's layout. The dark fill + thin gold
-- border matches the Rule Editor window so the addon reads as one piece.
local function CreateMailboxButtons()
	local MailFrame = _G["MailFrame"]
	if not mailBar and MailFrame then
		local bar = CreateFrame("Frame", nil, MailFrame, "BackdropTemplate")
		bar:SetSize(302, 36)
		bar:SetPoint("BOTTOMRIGHT", MailFrame, "TOPRIGHT", 0, 4)
		if bar.SetBackdrop then
			bar:SetBackdrop({
				bgFile = "Interface\\Buttons\\WHITE8X8",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				edgeSize = 14,
				insets = { left = 3, right = 3, top = 3, bottom = 3 },
			})
			bar:SetBackdropColor(0.05, 0.05, 0.06, 0.92)
			bar:SetBackdropBorderColor(C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3], 0.6)
		end

		local send = CreateButton(bar, L["Ledger Send"], 108)
		send:SetPoint("LEFT", bar, "LEFT", 8, 0)
		send:SetScript("OnClick", function()
			ns:GetModule("Engine").Run()
		end)
		send:SetScript("OnEnter", SendButton_OnEnter)
		send:SetScript("OnLeave", Button_OnLeave)

		local preview = CreateButton(bar, L["Preview"], 86)
		preview:SetPoint("LEFT", send, "RIGHT", 6, 0)
		preview:SetScript("OnClick", function()
			ns:GetModule("Engine").Preview()
		end)
		preview:SetScript("OnEnter", PreviewButton_OnEnter)
		preview:SetScript("OnLeave", Button_OnLeave)

		local rules = CreateButton(bar, L["Rules"], 80)
		rules:SetPoint("LEFT", preview, "RIGHT", 6, 0)
		rules:SetScript("OnClick", function()
			ToggleRuleWindow()
		end)
		rules:SetScript("OnEnter", RulesButton_OnEnter)
		rules:SetScript("OnLeave", Button_OnLeave)

		bar.send = send
		mailBar = bar
	end

	UpdateMailButtons()
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
	F.Print(L["Commands:"])
	F.Print(L["/ledger - open the configuration panel"])
	F.Print(L["/ledger rules - open the Rule Editor window"])
	F.Print(L["/ledger rule add <itemID|name> <Target-Realm> - add an item route"])
	F.Print(L["/ledger rule list - list item routes"])
	F.Print(L["/ledger rule remove [n] - remove route n (or the last one)"])
	F.Print(L["/ledger rule toggle <n> - enable/disable route n"])
	F.Print(L["/ledger keep <itemID> [N] - keep N in bags, send the rest (omit N to clear)"])
	F.Print(L["/ledger exclude <itemID> - never mail this item"])
	F.Print(L["/ledger exclude remove <itemID> - stop excluding this item"])
	F.Print(L["/ledger send - route mail now (manual run)"])
	F.Print(L["/ledger preview - show what would be sent, without sending"])
	F.Print(L["/ledger log - show recent transfers"])
	F.Print(L["/ledger stats - show lifetime and today's totals"])
	F.Print(L["/ledger reset - clear transfer history and stats"])
	F.Print(L["/ledger debug - explain why items do or don't route"])
	F.Print(L["/ledger trace - toggle verbose send-pipeline tracing"])
	F.Print(L["/ledger toggle - enable/disable auto-run on this character"])
end

local function HandleSlash(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	local Engine = ns:GetModule("Engine")

	if cmd == "" then
		if Settings and Settings.OpenToCategory and ns.settingsCategory then
			Settings.OpenToCategory(ns.settingsCategory:GetID())
		else
			PrintHelp()
		end
	elseif cmd == "send" then
		Engine.Run()
	elseif cmd == "preview" then
		Engine.Preview()
	elseif cmd == "log" then
		ns:GetModule("Logger").PrintLog()
	elseif cmd == "stats" then
		ns:GetModule("Logger").PrintStats()
	elseif cmd == "reset" then
		local dialog = _G["StaticPopupDialogs"]["LEDGERGOBLIN_CONFIRM_RESET"]
		if dialog then
			_G["StaticPopup_Show"]("LEDGERGOBLIN_CONFIRM_RESET")
		end
	elseif cmd == "keep" then
		-- /ledger keep <itemID> [N]   (omit N to clear the reserve)
		local idText, nText = rest:match("^(%S*)%s*(.-)$")
		local itemID = tonumber(idText)
		if not itemID then
			F.Print(L["Usage: /ledger keep <itemID> [N]"])
			return
		end
		local n = tonumber(nText)
		if not n or n <= 0 then
			ns.db.keep[itemID] = nil
			F.Print(L["Cleared keep reserve for itemID %d."], itemID)
		else
			ns.db.keep[itemID] = math.floor(n)
			F.Print(L["Keeping %d of itemID %d; the rest will be sent."], math.floor(n), itemID)
		end
		RefreshRuleEditor()
	elseif cmd == "debug" then
		Engine.Debug()
	elseif cmd == "trace" then
		Engine.ToggleSendDebug()
	elseif cmd == "rules" then
		ToggleRuleWindow()
	elseif cmd == "toggle" then
		ns.db.autoRun = not ns.db.autoRun
		F.Print(L["Auto-run is now %s on this character."], ns.db.autoRun and L["Enabled"] or L["Disabled"])
	elseif cmd == "rule" then
		-- /ledger rule add <itemID|name> <Target-Realm>
		local action, tail = rest:match("^(%S*)%s*(.-)$")
		if action == "add" then
			local a, b = tail:match("^(%S+)%s+(.+)$")
			if not (a and b) then
				F.Print(L["Usage: /ledger rule add <itemID|name> <Target-Realm>"])
				return
			end
			-- Route through AddItemRule so the soulbound/quest guard applies here too.
			AddItemRule(a, b)
		elseif action == "list" then
			PrintItemRules()
		elseif action == "remove" then
			local index = tonumber(tail)
			if index then
				RemoveItemRule(index)
			else
				RemoveLastItemRule()
			end
		elseif action == "toggle" then
			local index = tonumber(tail)
			local rule = index and ns.db.itemRules[index]
			if rule then
				rule.enabled = (rule.enabled == false)
				F.Print(L["Route %d is now %s."], index, rule.enabled and L["Enabled"] or L["Disabled"])
				RefreshRuleEditor()
			else
				F.Print(L["Usage: /ledger rule toggle <n>"])
			end
		else
			F.Print(L["Usage: /ledger rule add|list|remove|toggle"])
		end
	elseif cmd == "exclude" then
		-- "/ledger exclude remove <id>" deletes; "/ledger exclude <id>" adds.
		local action, tail = rest:match("^(%S*)%s*(.-)$")
		if action == "remove" then
			local id = tonumber(tail)
			if id and ns.db.exclusions[id] then
				ns.db.exclusions[id] = nil
				F.Print(L["Removed exclusion for itemID %d."], id)
				RefreshRuleEditor()
			else
				F.Print(L["Usage: /ledger exclude remove <itemID>"])
			end
		else
			local id = tonumber(rest)
			if id then
				ns.db.exclusions[id] = true
				F.Print(L["Added exclusion for itemID %d."], id)
				RefreshRuleEditor()
			else
				F.Print(L["Usage: /ledger exclude <itemID>"])
			end
		end
	else
		PrintHelp()
	end
end

-- ---------------------------------------------------------------------------
-- Addon compartment (retail minimap + button tray)
-- TOC registers these globals; left-click opens settings, right-click rules.
-- ---------------------------------------------------------------------------

local function OpenSettings()
	if Settings and Settings.OpenToCategory and ns.settingsCategory then
		Settings.OpenToCategory(ns.settingsCategory:GetID())
	else
		PrintHelp()
	end
end

function LedgerGoblin_OnAddonCompartmentEnter(_, buttonFrame)
	local tip = _G["GameTooltip"]
	if not tip then
		return
	end
	tip:SetOwner(buttonFrame, "ANCHOR_LEFT")
	tip:AddLine(C.Title)
	tip:AddLine(format(L["Version %s"], ns.version), 0.7, 0.7, 0.7)
	tip:AddLine(L["Left-click: open settings."], 0.8, 0.8, 0.8)
	tip:AddLine(L["Right-click: open Rule Editor."], 0.8, 0.8, 0.8)
	tip:Show()
end

function LedgerGoblin_OnAddonCompartmentLeave()
	local tip = _G["GameTooltip"]
	if tip then
		tip:Hide()
	end
end

function LedgerGoblin_OnAddonCompartmentClick(_, button)
	if button == "RightButton" then
		ToggleRuleWindow(true)
	else
		OpenSettings()
	end
end

ns:OnInit(function()
	BuildPanel()

	ns:RegisterEvent("MAIL_SHOW", CreateMailboxButtons)

	_G["SLASH_LEDGERGOBLIN1"] = "/ledger"
	_G["SLASH_LEDGERGOBLIN2"] = "/lg"
	_G["SlashCmdList"]["LEDGERGOBLIN"] = HandleSlash
end)
