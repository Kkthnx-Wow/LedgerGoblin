--[[
	LedgerGoblin - Rule Editor
	-------------------------------------------------------------------------
	A movable window for per-item routes and exclusions. It is not a UI panel,
	so it can stay open next to the bags for drag and shift-click entry.
	Each route row has an enable box, the item and target, a restock cap
	("max", top the target up to N), a keep reserve and a remove button.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F
local UI = ns.UI

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local format = string.format
local tostring = tostring
local type = type
local pairs = pairs
local wipe = wipe
local tsort = table.sort
local mathmax = math.max

local Rules, Roster -- set at init

local ROW_HEIGHT = 26
local editor
local filterText = ""

-- Column layout shared by the header strip and the rows. Boxes sit at fixed
-- offsets from the right edge so they line up under their headings.
local COL_ITEM = 46 -- after the check box and icon
local COL_TARGET = 236
local BOX_W = 42
local KEEP_RIGHT = -28
local MAX_RIGHT = KEEP_RIGHT - BOX_W - 8

-- ---------------------------------------------------------------------------
-- Route rows
-- ---------------------------------------------------------------------------

-- A flat numeric cell. Lighter than InputBoxTemplate, which drew a heavy
-- black box on every row.
local function NumberCell(row, tooltip, onCommit)
	local box = CreateFrame("EditBox", nil, row)
	box:SetSize(BOX_W, 18)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(6)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetJustifyH("CENTER")
	local bg = box:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.07)
	box.bg = bg
	local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("CENTER")
	hint:SetText("-")
	box.hint = hint
	box:SetScript("OnTextChanged", function(self)
		self.hint:SetShown(self:GetText() == "" and not self:HasFocus())
	end)
	box:SetScript("OnEditFocusGained", function(self)
		self.bg:SetColorTexture(1, 0.82, 0, 0.18)
		self.hint:Hide()
		self:HighlightText()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText(self.saved or "")
		self:ClearFocus()
	end)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	-- Commit only real edits, so tabbing through boxes does not churn rules.
	box:SetScript("OnEditFocusLost", function(self)
		self.bg:SetColorTexture(1, 1, 1, 0.07)
		self:HighlightText(0, 0)
		self.hint:SetShown(self:GetText() == "")
		if self:GetText() ~= (self.saved or "") then
			onCommit(row, self:GetText())
		end
	end)
	UI.Tooltip(box, nil, tooltip)
	return box
end

local function RowEnter(self)
	self.hl:Show()
	if self.itemID then
		UI.ItemTooltip(self, self.itemID)
		GameTooltip:AddLine(format(L["Item ID %d"], self.itemID), 0.6, 0.6, 0.6)
	else
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.matchName or "?", 1, 1, 1)
		GameTooltip:AddLine(L["Matches any item with this exact name."], 0.6, 0.6, 0.6, true)
	end
	-- The full target, since long names are cut in the column.
	GameTooltip:AddLine(format(L["Goes to %s"], self.targetText or "?"), 1, 1, 1)
	GameTooltip:Show()
end

local function RowLeave(self)
	self.hl:Hide()
	GameTooltip:Hide()
end

local function AcquireRow(holder, slot)
	holder.rows = holder.rows or {}
	local row = holder.rows[slot]
	if row then
		return row
	end
	row = CreateFrame("Frame", nil, holder)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(slot - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", 0, -(slot - 1) * ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", RowEnter)
	row:SetScript("OnLeave", RowLeave)

	if slot % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.03)
	end
	row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(1, 0.82, 0, 0.08)
	row.hl:Hide()

	row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.check:SetSize(20, 20)
	row.check:SetPoint("LEFT", 2, 0)
	row.check:SetScript("OnClick", function(self)
		Rules.ToggleItemRule(row.index, self:GetChecked() and true or false)
	end)
	UI.Tooltip(row.check, nil, L["Turn this route on or off without deleting it."])

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", 24, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.item = UI.Label(row, "", "GameFontHighlightSmall")
	row.item:SetPoint("LEFT", COL_ITEM, 0)
	row.item:SetWidth(COL_TARGET - COL_ITEM - 8)
	row.item:SetWordWrap(false)

	row.remove = CreateFrame("Button", nil, row)
	row.remove:SetSize(16, 16)
	row.remove:SetPoint("RIGHT", -6, 0)
	local x = row.remove:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	x:SetAllPoints()
	x:SetText("x")
	x:SetTextColor(0.8, 0.3, 0.3)
	row.remove:SetScript("OnEnter", function()
		x:SetTextColor(1, 0.45, 0.45)
	end)
	row.remove:SetScript("OnLeave", function()
		x:SetTextColor(0.8, 0.3, 0.3)
	end)
	row.remove:SetScript("OnClick", function()
		Rules.RemoveItemRule(row.index)
	end)
	UI.Tooltip(row.remove, nil, L["Remove this route."])

	row.keep = NumberCell(row, L["Keep at least this many in your bags and send the rest."], function(r, text)
		Rules.SetKeep(r.itemID, text)
	end)
	row.keep:SetPoint("RIGHT", KEEP_RIGHT, 0)

	row.max = NumberCell(row, L["Restock. Send only enough that the target holds this many, counting its bags, bank and mail. Empty sends everything."], function(r, text)
		Rules.SetRuleMax(r.index, text)
	end)
	row.max:SetPoint("RIGHT", MAX_RIGHT, 0)

	row.target = UI.Label(row, "", "GameFontHighlightSmall")
	row.target:SetPoint("LEFT", COL_TARGET, 0)
	row.target:SetPoint("RIGHT", row.max, "LEFT", -8, 0)
	row.target:SetWordWrap(false)

	holder.rows[slot] = row
	return row
end

local function MatchesFilter(rule, needle)
	if rule.target and rule.target:lower():find(needle, 1, true) then
		return true
	end
	if type(rule.match) == "number" then
		if tostring(rule.match):find(needle, 1, true) then
			return true
		end
		local _, _, _, _, link = UI.ItemDisplay(rule.match)
		local name = link and link:match("%[(.-)%]")
		return name ~= nil and name:lower():find(needle, 1, true) ~= nil
	end
	return tostring(rule.match):lower():find(needle, 1, true) ~= nil
end

-- Same-realm targets show without the realm, the way the mail addresses them.
local function TargetText(target)
	if not target or target == "" then
		return "|cff999999?|r"
	end
	return "|c" .. Roster.ClassHex(target) .. F.MailRecipient(target) .. "|r"
end

local visible = {}

local function FillRows(holder)
	local rules = ns.db.itemRules
	if not holder.empty then
		holder.empty = UI.Label(holder, "", "GameFontDisableSmall")
		holder.empty:SetPoint("TOPLEFT", 8, -6)
		holder.empty:SetPoint("RIGHT", -8, 0)
		holder.empty:SetWordWrap(true)
	end
	local needle = filterText ~= "" and filterText:lower() or nil
	wipe(visible)
	local on = 0
	for i = 1, #rules do
		if rules[i].enabled ~= false then
			on = on + 1
		end
		if not needle or MatchesFilter(rules[i], needle) then
			visible[#visible + 1] = i
		end
	end
	holder.empty:SetText(needle and L["No routes match your search."] or L["No item routes yet. Add one above, or shift-click an item from your bags into the first box."])
	holder.empty:SetShown(#visible == 0)
	if editor and editor.count then
		editor.count:SetText(#rules > 0 and format(L["%d routes, %d on"], #rules, on) or "")
	end

	for slot = 1, #visible do
		local index = visible[slot]
		local rule = rules[index]
		local row = AcquireRow(holder, slot)
		row.index = index
		local enabled = rule.enabled ~= false
		row.check:SetChecked(enabled)
		-- Off routes fade instead of recolouring, so item quality stays readable.
		row.item:SetAlpha(enabled and 1 or 0.4)
		row.icon:SetDesaturated(not enabled)
		row.icon:SetAlpha(enabled and 1 or 0.5)
		row.target:SetAlpha(enabled and 1 or 0.4)
		row.targetText = TargetText(rule.target)
		row.target:SetText(row.targetText)

		if type(rule.match) == "number" then
			row.itemID, row.matchName = rule.match, nil
			local icon, r, g, b, link = UI.ItemDisplay(rule.match)
			row.icon:SetTexture(icon)
			-- Plain quality-coloured name. Link brackets only add noise in a list.
			local name = link and link:match("%[(.-)%]")
			row.item:SetText(format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name or (L["Item"] .. " " .. rule.match)))
			local kept = ns.db.keep[rule.match]
			row.keep.saved = kept and tostring(kept) or ""
			row.keep:SetText(row.keep.saved)
			row.keep:Show()
		else
			row.itemID, row.matchName = nil, tostring(rule.match)
			row.icon:SetTexture(134400)
			row.item:SetText("|cffffffff\"" .. tostring(rule.match) .. "\"|r")
			row.keep:Hide()
		end
		row.max.saved = rule.max and tostring(rule.max) or ""
		row.max:SetText(row.max.saved)
		row:Show()
	end
	for slot = #visible + 1, #(holder.rows or {}) do
		holder.rows[slot]:Hide()
	end
	holder:SetHeight(mathmax(1, #visible * ROW_HEIGHT))
	local scroll = holder:GetParent()
	if scroll and scroll.UpdateScrollChildRect then
		scroll:UpdateScrollChildRect()
	end
end

-- ---------------------------------------------------------------------------
-- Exclusion chips
-- ---------------------------------------------------------------------------

local CHIP_HEIGHT, CHIP_PAD, CHIP_GAP = 20, 6, 6
local sorted = {}

local function AcquireChip(holder, i)
	holder.chips = holder.chips or {}
	local chip = holder.chips[i]
	if chip then
		return chip
	end
	chip = CreateFrame("Button", nil, holder)
	chip:SetHeight(CHIP_HEIGHT)
	local bg = chip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.06)
	local hi = chip:CreateTexture(nil, "HIGHLIGHT")
	hi:SetAllPoints()
	hi:SetColorTexture(1, 0.82, 0, 0.12)
	chip.icon = chip:CreateTexture(nil, "ARTWORK")
	chip.icon:SetSize(16, 16)
	chip.icon:SetPoint("LEFT", CHIP_PAD, 0)
	chip.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	chip.text = chip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	chip.text:SetPoint("LEFT", chip.icon, "RIGHT", 4, 0)
	chip:SetScript("OnEnter", function(self)
		UI.ItemTooltip(self, self.itemID)
		GameTooltip:AddLine(L["Click to stop excluding this item."], 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	chip:SetScript("OnLeave", UI.HideTooltip)
	chip:SetScript("OnClick", function(self)
		Rules.SetExcluded(self.itemID, false)
	end)
	holder.chips[i] = chip
	return chip
end

local function FillChips(holder)
	if not holder.empty then
		holder.empty = UI.Label(holder, L["No excluded items."], "GameFontDisableSmall")
		holder.empty:SetPoint("TOPLEFT", 4, -4)
	end
	wipe(sorted)
	for itemID in pairs(ns.db.exclusions) do
		sorted[#sorted + 1] = itemID
	end
	tsort(sorted)
	holder.empty:SetShown(#sorted == 0)

	local width = holder:GetWidth()
	if width <= 1 then
		width = 480
	end
	local x, y = 0, 0
	for i = 1, #sorted do
		local chip = AcquireChip(holder, i)
		chip.itemID = sorted[i]
		local icon, r, g, b, link = UI.ItemDisplay(sorted[i])
		chip.icon:SetTexture(icon)
		local name = link and link:match("%[(.-)%]")
		chip.text:SetText(name or format(L["Item %d"], sorted[i]))
		chip.text:SetTextColor(r, g, b)
		local w = CHIP_PAD * 2 + 20 + chip.text:GetStringWidth()
		if x > 0 and x + w > width then
			x, y = 0, y + CHIP_HEIGHT + 4
		end
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", x, -y)
		chip:SetWidth(w)
		chip:Show()
		x = x + w + CHIP_GAP
	end
	for i = #sorted + 1, #(holder.chips or {}) do
		holder.chips[i]:Hide()
	end
	holder:SetHeight(y + CHIP_HEIGHT + 4)
end

local function Refresh()
	if editor and editor:IsShown() then
		FillRows(editor.rows)
		FillChips(editor.chips)
	end
end

-- Redraw once item names load. Only listened to while the window is open.
local infoWatcher = CreateFrame("Frame")
infoWatcher:SetScript("OnEvent", ns:Debounce(0.1, Refresh))

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function Build()
	local win = CreateFrame("Frame", "LedgerGoblinRuleWindow", UIParent, "BackdropTemplate")
	win:SetSize(640, 680)
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
	UI.Chrome(win)
	tinsert(UISpecialFrames, "LedgerGoblinRuleWindow")

	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local icon = win:CreateTexture(nil, "ARTWORK")
	icon:SetSize(28, 28)
	icon:SetPoint("TOPLEFT", 16, -14)
	icon:SetTexture(C.Icon)
	local header = UI.Label(win, C.Title .. "  " .. L["Rule Editor"], "GameFontNormalLarge")
	header:SetPoint("LEFT", icon, "RIGHT", 8, 0)

	local desc = UI.Label(win, L["Item routes win over item type, bind and quality rules. Shift-click or drag an item into a box to fill its ID."], "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -10)
	desc:SetPoint("RIGHT", -16, 0)
	desc:SetWordWrap(true)

	-- Routes card
	local card = UI.Inset(win)
	card:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
	card:SetPoint("RIGHT", -16, 0)
	card:SetHeight(400)

	local title = UI.Label(card, L["Item Routes"], "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 12, -10)
	win.count = UI.Label(card, "", "GameFontDisableSmall")
	win.count:SetPoint("LEFT", title, "RIGHT", 10, -1)

	local match = UI.Input(card, 150)
	match:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 4, -22)
	UI.WireItemInput(match)
	UI.Label(card, L["ItemID or exact name"], "GameFontDisableSmall"):SetPoint("BOTTOMLEFT", match, "TOPLEFT", 0, 3)

	local target = UI.Input(card, 150)
	target:SetPoint("LEFT", match, "RIGHT", 16, 0)
	UI.Label(card, L["Target character"], "GameFontDisableSmall"):SetPoint("BOTTOMLEFT", target, "TOPLEFT", 0, 3)

	local pick = UI.Button(card, L["Pick"], 50)
	pick:SetPoint("LEFT", target, "RIGHT", 6, 0)
	pick:SetScript("OnClick", function(self)
		UI.TargetMenu(self, function(key)
			target:SetText(key)
		end)
	end)
	UI.Tooltip(pick, L["Pick"], L["Choose one of your characters."])

	local copy = UI.Button(card, L["Copy"], 60)
	copy:SetPoint("LEFT", pick, "RIGHT", 6, 0)
	copy:SetScript("OnClick", function(self)
		local MenuUtil = _G["MenuUtil"]
		MenuUtil.CreateContextMenu(self, function(_, root)
			root:CreateTitle(L["Copy item routes from"])
			local sources = Rules.SnapshotSources()
			if #sources == 0 then
				root:CreateButton(L["No other character has routes saved yet."], function() end)
			end
			for i = 1, #sources do
				local key = sources[i]
				local count = #ns.global.itemRuleSnapshots[key].itemRules
				root:CreateButton(format("%s (%d)", Roster.Colored(key), count), function()
					Rules.MergeFrom(key)
				end)
			end
		end)
	end)
	UI.Tooltip(copy, L["Copy"], L["Merge another character's item routes into this one. Duplicates and routes to this character are skipped."])

	local add = UI.Button(card, L["Add Route"], 100)
	add:SetPoint("TOPLEFT", match, "BOTTOMLEFT", -6, -10)
	add:SetScript("OnClick", function()
		if Rules.AddItemRule(match:GetText(), target:GetText()) then
			match:SetText("")
		end
		match:SetFocus()
	end)
	match:SetScript("OnEnterPressed", function()
		add:Click()
	end)
	target:SetScript("OnEnterPressed", function()
		add:Click()
	end)

	local all = UI.Button(card, L["All On"], 70)
	all:SetPoint("LEFT", add, "RIGHT", 8, 0)
	all:SetScript("OnClick", function()
		Rules.SetAllItemRules(true)
	end)
	local none = UI.Button(card, L["All Off"], 70)
	none:SetPoint("LEFT", all, "RIGHT", 4, 0)
	none:SetScript("OnClick", function()
		Rules.SetAllItemRules(false)
	end)

	local search = UI.Input(card, 130)
	search:SetPoint("LEFT", none, "RIGHT", 70, 0)
	UI.Label(card, _G["SEARCH"] or L["Search"], "GameFontDisableSmall"):SetPoint("RIGHT", search, "LEFT", -8, 0)
	search:SetScript("OnTextChanged", function(self)
		filterText = self:GetText() or ""
		Refresh()
	end)
	search:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)

	-- Column headings, on the same offsets the rows use.
	local head = CreateFrame("Frame", nil, card)
	head:SetHeight(16)
	head:SetPoint("TOPLEFT", add, "BOTTOMLEFT", 0, -10)
	head:SetPoint("RIGHT", -26, 0)
	local line = head:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	line:SetColorTexture(C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3], 0.25)
	local function Heading(text, x, right)
		local fs = UI.Label(head, text, "GameFontNormalSmall")
		if right then
			fs:SetWidth(BOX_W)
			fs:SetJustifyH("CENTER")
			fs:SetPoint("RIGHT", x, 1)
		else
			fs:SetPoint("LEFT", x, 1)
		end
	end
	Heading(L["Item"], COL_ITEM)
	Heading(L["Goes to"], COL_TARGET)
	Heading(L["Max"], MAX_RIGHT, true)
	Heading(L["Keep"], KEEP_RIGHT, true)

	local scroll, content = UI.ScrollList(card, ROW_HEIGHT * 2)
	scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
	scroll:SetPoint("BOTTOMRIGHT", -26, 10)
	win.rows = content

	-- Exclusions card
	local ex = UI.Inset(win)
	ex:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10)
	ex:SetPoint("BOTTOMRIGHT", -16, 16)

	local exTitle = UI.Label(ex, L["Never Mail"], "GameFontNormalLarge")
	exTitle:SetPoint("TOPLEFT", 12, -10)
	local exInput = UI.Input(ex, 150)
	exInput:SetPoint("TOPLEFT", exTitle, "BOTTOMLEFT", 4, -22)
	UI.WireItemInput(exInput)
	UI.Label(ex, L["ItemID"], "GameFontDisableSmall"):SetPoint("BOTTOMLEFT", exInput, "TOPLEFT", 0, 3)
	local exAdd = UI.Button(ex, L["Exclude"], 90)
	exAdd:SetPoint("LEFT", exInput, "RIGHT", 12, 0)
	exAdd:SetScript("OnClick", function()
		if Rules.SetExcluded(exInput:GetText(), true) then
			exInput:SetText("")
		end
	end)
	exInput:SetScript("OnEnterPressed", function()
		exAdd:Click()
	end)
	UI.Tooltip(exAdd, L["Exclude"], L["Never mail this item, even when a rule matches it."])

	local exScroll, exContent = UI.ScrollList(ex, 48)
	exScroll:SetPoint("TOPLEFT", exInput, "BOTTOMLEFT", -4, -10)
	exScroll:SetPoint("BOTTOMRIGHT", -26, 10)
	exContent.Relayout = function()
		FillChips(exContent)
	end
	win.chips = exContent

	win:SetScript("OnShow", function()
		infoWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		Refresh()
	end)
	win:SetScript("OnHide", function()
		infoWatcher:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
	end)
	editor = win
end

function ns.ToggleRuleWindow(show)
	if not editor then
		Build()
	end
	if show or not editor:IsShown() then
		editor:Show()
	else
		editor:Hide()
	end
end

ns:OnInit(function()
	Rules = ns:GetModule("Rules")
	Roster = ns:GetModule("Roster")
end)
ns:On("RULES_CHANGED", Refresh)
ns:On("ROSTER_CHANGED", Refresh)

