--[[
	LedgerGoblin - Settings
	-------------------------------------------------------------------------
	The Blizzard Settings panel, written straight into ns.db and ns.global.
	Dependent rows only show while their parent toggle or mode is on.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F
local UI = ns.UI

local Settings = Settings
local CreateFrame = CreateFrame
local format = string.format
local type = type

local category

local function Notify()
	ns:GetModule("Rules").Changed()
end

-- "None" plus every known character, class coloured.
local function TargetOptions()
	local Roster = ns:GetModule("Roster")
	local container = Settings.CreateControlTextContainer()
	container:Add("", L["None"])
	for _, list in ipairs({ Roster.List(false), Roster.ManualList() }) do
		for i = 1, #list do
			container:Add(list[i], Roster.Colored(list[i]))
		end
	end
	return container:GetData()
end

local function Bind(variable, tbl, key, default, name, onChange)
	local setting = Settings.RegisterAddOnSetting(category, variable, key, tbl, type(default), name, default)
	if onChange then
		setting:SetValueChangedCallback(onChange)
	end
	return setting
end

local function DependsOn(child, parent, predicate)
	if not (child and parent and child.SetParentInitializer) then
		return
	end
	child:SetParentInitializer(parent, function()
		local value = parent:GetSetting():GetValue()
		if predicate then
			return predicate(value)
		end
		return value and true or false
	end)
end

-- No AddShownPredicate anywhere on this page. SettingsListMixin:Display calls
-- ShouldShow() outside a secure call, so an addon-written shown predicate
-- taints the panel. When the page is opened with Settings.OpenToCategory
-- (minimap, /ledger), ActivateCategory then reaches FocusContainer and
-- SmartNavigation:EnterFocusGroup, whose EnsureIsSecure prints "Interface
-- action failed because of an AddOn". Modify predicates (DependsOn) run inside
-- the secure SetDataProvider call and are safe, so rows for the other gold
-- modes are greyed instead of hidden, as Blizzard's Sound page does.
local function ActiveForMode(tbl, mode)
	return function(on)
		return on and tbl.mode == mode
	end
end

local function Redraw()
	Notify()
	local panel = _G["SettingsPanel"]
	if panel and panel:IsShown() and category then
		panel:DisplayCategory(category)
	end
end

local function Header(layout, text)
	layout:AddInitializer(_G["CreateSettingsListSectionHeaderInitializer"](text))
end

local function Desc(layout, text)
	local init = F.CreateSettingsDescription(text)
	if init then
		layout:AddInitializer(init)
	end
end

local SLIDER_RIGHT = _G["MinimalSliderWithSteppersMixin"] and _G["MinimalSliderWithSteppersMixin"].Label.Right

local function Slider(minV, maxV, step, fmt)
	local opts = Settings.CreateSliderOptions(minV, maxV, step)
	if SLIDER_RIGHT then
		opts:SetLabelFormatter(SLIDER_RIGHT, function(v)
			return format(fmt, v)
		end)
	end
	return opts
end

-- One dropdown per route. "None" turns the route off, any character turns it
-- on, so the list stays one row per type.
local function RouteRow(prefix, tbl, label, tooltip)
	local target = Bind(prefix, tbl, "target", "", label, function()
		tbl.enabled = tbl.target ~= ""
		Notify()
	end)
	Settings.CreateDropdown(category, target, TargetOptions, tooltip)
end

local function MoneyBox(layout, name, tooltip, tbl, key, enableInit, mode)
	local init = F.CreateSettingsEditBox(name, tooltip, function()
		return F.MoneyText(tbl[key])
	end, function(text)
		local copper = F.ParseMoney(text)
		if copper then
			tbl[key] = copper
			Notify()
		else
			F.Print(L["That amount isn't valid. Try a number, or 100g 50s 20c."])
		end
	end, 200)
	if init then
		layout:AddInitializer(init)
		DependsOn(init, enableInit, ActiveForMode(tbl, mode))
	end
end

local function Launcher()
	local frame = CreateFrame("Frame")
	local title = UI.Label(frame, L["Rule Editor"], "GameFontHighlightHuge")
	title:SetPoint("TOPLEFT", 16, -16)
	local desc = UI.Label(frame, L["Item routes open in their own window so your bags can stay open for dragging items in. Blizzard hides bags while this panel is open."], "GameFontHighlight")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", -16, 0)
	desc:SetWordWrap(true)
	local open = UI.Button(frame, L["Open Rule Editor"], 200)
	open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	open:SetScript("OnClick", function()
		_G["HideUIPanel"](_G["SettingsPanel"])
		ns.ToggleRuleWindow(true)
	end)
	UI.Label(frame, L["Also /ledger rules."], "GameFontDisableSmall"):SetPoint("TOPLEFT", open, "BOTTOMLEFT", 2, -10)
	local guideButton = UI.Button(frame, L["Open the guide"], 200)
	guideButton:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -40)
	guideButton:SetScript("OnClick", function()
		_G["HideUIPanel"](_G["SettingsPanel"])
		ns.ShowGuide(1)
	end)
	UI.Label(frame, L["A page by page tour of LedgerGoblin. Also /ledger guide."], "GameFontDisableSmall"):SetPoint("TOPLEFT", guideButton, "BOTTOMLEFT", 2, -10)
	return frame
end

local function Build()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory(C.Title)
	ns.settingsCategory = category
	local db, D = ns.db, C.CHAR_DEFAULTS

	Header(layout, C.Title)
	Desc(layout, L["LedgerGoblin mails gold and items to your alts by rule and collects your inbox by filter. Set routes below, open a mailbox, and press Send or Collect. Type /ledger help for every command."])

	-- Sending
	Header(layout, L["Sending"])
	Settings.CreateCheckbox(category, Bind("LG_autoRun", db, "autoRun", D.autoRun, L["Auto-send on open"]), L["Send everything your rules match as soon as the mailbox opens."])
	Settings.CreateCheckbox(category, Bind("LG_holdShift", db, "holdShiftToDisable", D.holdShiftToDisable, L["Shift skips auto runs"]), L["Holding Shift while the mailbox opens skips automatic sending and collecting."])
	local confirmGold = Settings.CreateCheckbox(category, Bind("LG_confirmGold", db, "confirmGold", D.confirmGold, L["Confirm gold sends"]), L["Ask before a run that moves at least the amount below."])
	DependsOn(Settings.CreateSlider(category, Bind("LG_confirm", db, "confirmThreshold", D.confirmThreshold, L["Confirm at"]), Slider(0, 20000, 250, "%dg"), L["Ask before sending at least this much gold. 0 never asks."]), confirmGold)
	Settings.CreateCheckbox(category, Bind("LG_confirmItems", db, "confirmItems", D.confirmItems, L["Confirm item sends"]), L["Ask before any run that attaches items."])
	Settings.CreateCheckbox(category, Bind("LG_altClick", db, "altClickAttach", D.altClickAttach, L["Alt-click attach all"]), L["On the Send Mail tab, alt-click a bag item to attach all of its stacks."])
	Settings.CreateCheckbox(category, Bind("LG_tooltipHints", db, "tooltipHints", D.tooltipHints, L["Tooltip hints"]), L["Item tooltips say where LedgerGoblin would mail the item."])
	Settings.CreateCheckbox(category, Bind("LG_sendOne", db, "sendIndividually", D.sendIndividually, L["One item per mail"], Notify), L["Put each item type in its own mail instead of mixing them. Costs no more postage, but uses more mails."])

	-- Inbox
	Header(layout, L["Inbox"])
	local inbox, Di = db.inbox, D.inbox
	Settings.CreateCheckbox(category, Bind("LG_autoCollect", inbox, "autoCollect", Di.autoCollect, L["Auto-collect on open"]), L["Take mail with the filter below as soon as the mailbox opens. Sending runs after it."])
	Settings.CreateDropdown(category, Bind("LG_collectFilter", inbox, "filter", Di.filter, L["Collect"]), function()
		local container = Settings.CreateControlTextContainer()
		local Inbox = ns:GetModule("Inbox")
		for _, key in ipairs({ C.COLLECT.ALL, C.COLLECT.GOLD, C.COLLECT.ITEMS, C.COLLECT.AUCTION, C.COLLECT.ALTS }) do
			container:Add(key, Inbox.FilterLabel(key))
		end
		return container:GetData()
	end, L["What the Collect button takes. COD mail, GM letters and pending sales are never taken."])
	Settings.CreateCheckbox(category, Bind("LG_inboxMessages", inbox, "messages", Di.messages, L["Chat line per mail"]), L["Print each auction sale, purchase, refund and gift as it is collected."])
	Settings.CreateCheckbox(category, Bind("LG_inboxSound", inbox, "sound", Di.sound, L["Sound when done"]), L["Play a coin sound when collecting finishes."])
	Settings.CreateSlider(category, Bind("LG_freeSlots", inbox, "freeSlots", Di.freeSlots, L["Keep bag slots free"]), Slider(0, 20, 1, "%d"), L["Stop taking items when only this many bag slots are left."])
	Settings.CreateSlider(category, Bind("LG_expiry", ns.global, "expiryWarnDays", C.GLOBAL_DEFAULTS.expiryWarnDays, L["Expiry warning"]), Slider(0, 15, 1, "%d d"), L["At login, list characters whose mail expires within this many days. 0 turns it off."])

	-- Gold
	Header(layout, L["Gold"])
	do
		local g, Dg = db.gold, D.gold
		local enableInit = Settings.CreateCheckbox(category, Bind("LG_goldEnable", g, "enabled", Dg.enabled, L["Send gold"], Redraw), L["Send gold to one character."])
		DependsOn(Settings.CreateDropdown(category, Bind("LG_goldTarget", g, "target", Dg.target, L["Send gold to"], Notify), TargetOptions, L["Send gold to"]), enableInit)
		DependsOn(Settings.CreateDropdown(category, Bind("LG_goldMode", g, "mode", Dg.mode, L["Gold mode"], Redraw), function()
			local container = Settings.CreateControlTextContainer()
			container:Add(C.GOLD_MODE.KEEP, L["Keep this much, send the rest"])
			container:Add(C.GOLD_MODE.FIXED, L["Send a fixed amount"])
			container:Add(C.GOLD_MODE.PERCENT, L["Send a percentage"])
			return container:GetData()
		end, L["Gold mode"]), enableInit)
		MoneyBox(layout, L["Amount to keep"], L["Left on this character, the rest is sent. Type 1000g 50s 20c or a plain number of gold."], g, "keepCopper", enableInit, C.GOLD_MODE.KEEP)
		MoneyBox(layout, L["Amount to send"], L["Sent each run. Type 100g 50s 20c or a plain number of gold."], g, "fixedCopper", enableInit, C.GOLD_MODE.FIXED)
		local pctInit = Settings.CreateSlider(category, Bind("LG_goldPct", g, "percent", Dg.percent, L["Percent"], Notify), Slider(0, 100, 5, "%d%%"), L["Send this share of your gold each run."])
		DependsOn(pctInit, enableInit, ActiveForMode(g, C.GOLD_MODE.PERCENT))
		DependsOn(Settings.CreateCheckbox(category, Bind("LG_goldReserve", g, "reserveForRepairs", Dg.reserveForRepairs, L["Repair reserve"], Notify), L["Never send below the highest repair bill seen at a vendor on this character, 100g until one is seen."]), enableInit)
	end

	-- Item types
	Header(layout, L["Item Type Routing"])
	Desc(layout, L["Route by item type, for example all herbs to your alchemist. A trade goods subtype wins over a whole class. Item routes win over these."])
	local Rules = ns:GetModule("Rules")
	Rules.EnsureTypeEntries()
	local options = Rules.TypeOptions()
	for i = 1, #options do
		local o = options[i]
		RouteRow("LG_t_" .. o.key, db.typeRules[o.key], o.label, format(L["Where %s goes. None turns it off."], o.full))
	end

	-- Bind
	Header(layout, L["Bind Routing"])
	Desc(layout, L["Bind on Equip gear still in your bags, and account or warband bound items for your own alts. These win over quality rules."])
	for i = 1, #C.BINDS do
		local b = C.BINDS[i]
		RouteRow("LG_b_" .. b.key, db.bind[b.key], b.label, format(L["Where %s goes. None turns it off."], b.label))
	end

	-- Quality
	Header(layout, L["Quality Routing"])
	Desc(layout, L["Catch-all by quality, checked last."])
	for i = 1, #C.QUALITIES do
		local q = C.QUALITIES[i]
		local qc = C.QualityColors and C.QualityColors[q.enum]
		local label = qc and (qc.hex .. q.label .. "|r") or q.label
		RouteRow("LG_q_" .. q.key, db.quality[q.key], label, format(L["Where %s items go. None turns it off."], label))
	end

	Settings.RegisterCanvasLayoutSubcategory(category, Launcher(), L["Rule Editor"])
	Settings.RegisterAddOnCategory(category)
end

function ns.OpenSettings()
	if category then
		Settings.OpenToCategory(category:GetID())
	end
end

ns:OnInit(function()
	if Settings and Settings.RegisterVerticalLayoutCategory then
		Build()
	end
end)
