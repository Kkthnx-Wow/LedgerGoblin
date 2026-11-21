--[[
	LedgerGoblin - Guide
	-------------------------------------------------------------------------
	A paged walkthrough. Each page has a title, a short text and a small drawn
	snippet of the part of the addon it explains, built from plain frames so
	it never touches real rules or mail. It opens once at the first login on
	the account and comes back with /ledger guide.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F
local UI = ns.UI

local CreateFrame = CreateFrame
local C_Item = C_Item
local InCombatLockdown = InCombatLockdown
local format = string.format

local WIDTH, HEIGHT = 580, 440
local SNIPPET_H = 170

local guide
local pages = {}

-- ---------------------------------------------------------------------------
-- Snippet helpers
-- ---------------------------------------------------------------------------

local function ClassText(name, class)
	local colors = _G["CUSTOM_CLASS_COLORS"] or _G["RAID_CLASS_COLORS"]
	local c = colors and colors[class]
	return c and ("|c" .. c.colorStr .. name .. "|r") or name
end

-- Sample names that read right on either client.
local function Sample(first, last, realm)
	if F.UniqueNames() then
		return first .. " " .. last
	end
	return first .. (realm and ("-" .. realm) or "")
end

local function Text(parent, text, template, x, y)
	local fs = UI.Label(parent, text, template or "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x or 0, y or 0)
	return fs
end

local function Icon(parent, texture, size, x, y)
	local tex = parent:CreateTexture(nil, "ARTWORK")
	tex:SetSize(size, size)
	tex:SetPoint("TOPLEFT", x, y)
	tex:SetTexture(texture)
	tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	return tex
end

local function FakeButton(parent, text, width, x, y)
	local b = UI.Button(parent, text, width)
	b:SetPoint("TOPLEFT", x, y)
	b:EnableMouse(false)
	return b
end

local function Stripe(parent, y, height, alpha)
	local tex = parent:CreateTexture(nil, "BACKGROUND")
	tex:SetPoint("TOPLEFT", 0, y)
	tex:SetPoint("TOPRIGHT", 0, y)
	tex:SetHeight(height)
	tex:SetColorTexture(1, 1, 1, alpha)
	return tex
end

-- Icon and name for a real item, with a fallback while it loads.
local function ItemLook(itemID, fallback)
	local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or 134400
	local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
	return icon, name or fallback
end

-- A route row like the Rule Editor's, drawn only.
local function RouteRow(parent, y, itemID, fallback, quality, target, max, keep, off)
	local icon, item = ItemLook(itemID, fallback)
	if (y / 24) % 2 == 0 then
		Stripe(parent, y, 24, 0.04)
	end
	local check = parent:CreateTexture(nil, "ARTWORK")
	check:SetSize(18, 18)
	check:SetPoint("TOPLEFT", 6, y - 3)
	check:SetAtlas(off and "checkbox-minimal" or "checkmark-minimal")
	if not check:GetAtlas() then
		check:SetTexture(off and "Interface\\Buttons\\UI-CheckBox-Up" or "Interface\\Buttons\\UI-CheckBox-Check")
	end
	local ic = Icon(parent, icon, 18, 28, y - 3)
	local qc = C.QualityColors and C.QualityColors[quality]
	local name = Text(parent, (qc and qc.hex or "|cffffffff") .. item .. "|r", nil, 52, y - 6)
	local tgt = Text(parent, target, nil, 200, y - 6)
	local maxText = Text(parent, max or "-", max and "GameFontHighlightSmall" or "GameFontDisableSmall", 0, 0)
	maxText:ClearAllPoints()
	maxText:SetPoint("TOPRIGHT", -70, y - 6)
	local keepText = Text(parent, keep or "-", keep and "GameFontHighlightSmall" or "GameFontDisableSmall", 0, 0)
	keepText:ClearAllPoints()
	keepText:SetPoint("TOPRIGHT", -24, y - 6)
	if off then
		for _, region in ipairs({ ic, name, tgt, maxText, keepText }) do
			region:SetAlpha(0.4)
		end
		ic:SetDesaturated(true)
	end
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------

pages[#pages + 1] = {
	title = L["Welcome to LedgerGoblin"],
	text = L["The goblin runs your mailbox. Tell it once where your gold and items belong, then open any mailbox and press Send. It packs the mails, pays the postage and sends them one by one. Press Collect and it empties your inbox the same careful way, writing down where every coin came from."],
	snippet = function(f)
		local logo = f:CreateTexture(nil, "ARTWORK")
		logo:SetSize(120, 120)
		logo:SetPoint("LEFT", 20, 0)
		logo:SetTexture(C.Icon)
		local lines = {
			L["Send gold and items to your alts by rule"],
			L["Collect your inbox by filter"],
			L["Keep a ledger of sales, income and mail"],
			L["Nothing is ever sent until you say so"],
		}
		for i = 1, #lines do
			local fs = UI.Label(f, "|cff8fc02e+|r  " .. lines[i], "GameFontHighlight")
			fs:SetPoint("TOPLEFT", 160, -22 - (i - 1) * 32)
		end
	end,
}

pages[#pages + 1] = {
	title = L["Your characters"],
	text = L["The game does not list your alts, so LedgerGoblin learns them. Log in once on each character and it joins the list, with its class colour and gold. Only characters on that list can receive mail. Alts on another account can be added by hand from the + picker."],
	snippet = function(f)
		local rows = {
			{ Sample("Brewgrin", "Skyrus", "Area52"), "HUNTER", 1842000 },
			{ Sample("Oretooth", "Ironvein", "Area52"), "WARRIOR", 120500 },
			{ Sample("Stitchwick", "Skyrus", "Area52"), "MAGE", 9876543 },
			{ Sample("Hidebinder", "Mossjaw", "Area52"), "DRUID", 4300 },
		}
		Text(f, L["Character"], "GameFontNormalSmall", 12, -8)
		local goldHead = Text(f, L["Gold"], "GameFontNormalSmall", 0, 0)
		goldHead:ClearAllPoints()
		goldHead:SetPoint("TOPRIGHT", -12, -8)
		for i = 1, #rows do
			local y = -26 - (i - 1) * 24
			if i % 2 == 0 then
				Stripe(f, y, 24, 0.04)
			end
			Text(f, ClassText(rows[i][1], rows[i][2]), "GameFontHighlight", 12, y - 5)
			local g = Text(f, F.Money(rows[i][3]), nil, 0, 0)
			g:ClearAllPoints()
			g:SetPoint("TOPRIGHT", -12, y - 6)
		end
		local total = Text(f, format(L["Account gold %s"], F.Money(1842000 + 120500 + 9876543 + 4300)), "GameFontNormal", 0, 0)
		total:ClearAllPoints()
		total:SetPoint("BOTTOMRIGHT", -12, 10)
	end,
}

pages[#pages + 1] = {
	title = L["Item routes"],
	text = L["Routes say where an item goes. Open the Rule Editor, then shift-click or drag an item from your bags into the first box and pick a character. Max tops that character up to a number, counting its bags, bank and mail. Keep holds some back in your bags."],
	button = { L["Open Rule Editor"], function()
		ns.ToggleRuleWindow(true)
	end },
	snippet = function(f)
		Text(f, L["Item"], "GameFontNormalSmall", 52, -8)
		Text(f, L["Goes to"], "GameFontNormalSmall", 200, -8)
		local m = Text(f, L["Max"], "GameFontNormalSmall", 0, 0)
		m:ClearAllPoints()
		m:SetPoint("TOPRIGHT", -62, -8)
		local k = Text(f, L["Keep"], "GameFontNormalSmall", 0, 0)
		k:ClearAllPoints()
		k:SetPoint("TOPRIGHT", -16, -8)
		local brew = ClassText(Sample("Brewgrin", "Skyrus"), "HUNTER")
		local ore = ClassText(Sample("Oretooth", "Ironvein"), "WARRIOR")
		local cloth = ClassText(Sample("Stitchwick", "Skyrus"), "MAGE")
		RouteRow(f, -24, 2447, L["Peacebloom"], 1, brew, "200", "20")
		RouteRow(f, -48, 2770, L["Copper Ore"], 1, ore, "500")
		RouteRow(f, -72, 2589, L["Linen Cloth"], 1, cloth, nil, "40")
		RouteRow(f, -96, 2771, L["Tin Ore"], 1, ore, nil, nil, true)
		Text(f, L["Faded routes are switched off. Tick the box to turn one back on."], "GameFontDisableSmall", 12, -132)
	end,
}

pages[#pages + 1] = {
	title = L["Bigger rules"],
	text = L["Not every item needs its own route. In the settings you can send whole item types, like every herb, Bind on Equip gear, warband items or anything of a quality. Each item stops at the first rule that wants it, in this order."],
	button = { L["Open settings"], function()
		ns.OpenSettings()
	end },
	snippet = function(f)
		local steps = {
			{ L["Never Mail"], L["items you never want sent"] },
			{ L["Item routes"], L["one exact item to one character"] },
			{ L["Item types"], L["herbs, ore, cloth, gems, recipes"] },
			{ L["Bind"], L["Bind on Equip gear and warband items"] },
			{ L["Quality"], L["the catch-all, checked last"] },
		}
		for i = 1, #steps do
			local y = -10 - (i - 1) * 30
			local num = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
			num:SetPoint("TOPLEFT", 16, y)
			num:SetText(i)
			Text(f, steps[i][1], "GameFontHighlight", 44, y - 2)
			Text(f, "|cff999999" .. steps[i][2] .. "|r", nil, 190, y - 4)
		end
	end,
}

pages[#pages + 1] = {
	title = L["Sending"],
	text = L["Open a mailbox and the goblin's bar sits on top of it. Hover Send to see what would go, Preview lists it in chat, Send does it. Each mail waits for the server to confirm before the next. On the Send Mail tab, alt-click a bag item to attach every stack of it, and the + beside the To box picks a recipient."],
	snippet = function(f)
		local bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
		bar:SetSize(380, 52)
		bar:SetPoint("TOP", 0, -12)
		UI.Chrome(bar)
		local w = (380 - 16 - 12) / 4
		FakeButton(bar, L["Send"], w, 8, -6)
		FakeButton(bar, L["Preview"], w, 8 + (w + 4), -6)
		FakeButton(bar, L["Collect"], w, 8 + (w + 4) * 2, -6)
		FakeButton(bar, L["Rules"], w, 8 + (w + 4) * 3, -6)
		Text(bar, format(L["%d mail"], 7) .. "  " .. F.Money(1250000), nil, 12, -34)
		local tip = CreateFrame("Frame", nil, f, "BackdropTemplate")
		tip:SetSize(150, 64)
		tip:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)
		UI.Chrome(tip)
		Text(tip, L["Send by rules"], "GameFontNormal", 10, -8)
		Text(tip, "|cff99ff99" .. format(L["%d item(s)"], 64) .. "|r", nil, 10, -26)
		Text(tip, "|cffcccccc" .. format(L["%d mail(s)"], 3) .. "|r", nil, 10, -42)
		local note = UI.Label(f, L["Hovering Send shows what would go. Postage is 30 copper per attachment, and gold always leaves postage and a repair reserve behind."], "GameFontHighlightSmall")
		note:SetPoint("TOPLEFT", tip, "TOPRIGHT", 14, -4)
		note:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
		note:SetWordWrap(true)
	end,
}

pages[#pages + 1] = {
	title = L["Collecting"],
	text = L["Collect takes your mail by filter, newest first, one letter at a time. It never opens COD mail or GM letters, stops when your bags are nearly full, and keeps checking the server when more than 50 mails are waiting. Right-click Collect to use another filter once."],
	snippet = function(f)
		local rows = {
			{ L["Everything"], L["all mail except COD, GM letters and pending sales"] },
			{ L["Gold only"], L["takes the gold, leaves the items"] },
			{ L["Items only"], L["takes the items, leaves the gold"] },
			{ L["Auction mail"], L["sales, purchases, expired and cancelled auctions"] },
			{ L["From my alts"], L["mail from your own characters"] },
		}
		for i = 1, #rows do
			local y = -8 - (i - 1) * 28
			if i % 2 == 1 then
				Stripe(f, y + 2, 26, 0.04)
			end
			Text(f, rows[i][1], "GameFontNormal", 12, y - 4)
			Text(f, rows[i][2], nil, 130, y - 5)
		end
	end,
}

pages[#pages + 1] = {
	title = L["Your ledger"],
	text = L["Everything that moves is written down. At login you are warned about mail that is about to expire on any character. These commands show the books, and /ledger help lists the rest."],
	snippet = function(f)
		local cmds = {
			{ "/ledger alts", L["gold and waiting mail on every character"] },
			{ "/ledger income", L["gold from the inbox, by source"] },
			{ "/ledger sales", L["what sold, for how much, to whom"] },
			{ "/ledger log", L["the last sends"] },
			{ "/ledger rules", L["open the Rule Editor"] },
			{ "/ledger guide", L["open this guide again"] },
		}
		for i = 1, #cmds do
			local y = -8 - (i - 1) * 25
			Text(f, "|cfff4c430" .. cmds[i][1] .. "|r", "GameFontHighlight", 12, y)
			Text(f, cmds[i][2], nil, 140, y - 1)
		end
	end,
}

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function ShowPage(index)
	guide.index = index
	for i = 1, #pages do
		pages[i].frame:SetShown(i == index)
		guide.dots[i]:SetVertexColor(i == index and 1 or 0.4, i == index and 0.82 or 0.4, i == index and 0 or 0.4)
	end
	local page = pages[index]
	guide.title:SetText(page.title)
	guide.text:SetText(page.text)
	guide.step:SetText(format(L["%d of %d"], index, #pages))
	guide.back:SetEnabled(index > 1)
	guide.next:SetText(index == #pages and L["Done"] or L["Next"])
	if page.button then
		guide.action:SetText(page.button[1])
		guide.action.run = page.button[2]
		guide.action:Show()
	else
		guide.action:Hide()
	end
end

local function Build()
	local win = CreateFrame("Frame", "LedgerGoblinGuide", UIParent, "BackdropTemplate")
	win:SetSize(WIDTH, HEIGHT)
	win:SetPoint("CENTER", 0, 40)
	win:SetFrameStrata("DIALOG")
	win:SetToplevel(true)
	win:EnableMouse(true)
	win:SetMovable(true)
	win:SetClampedToScreen(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	UI.Chrome(win)
	tinsert(UISpecialFrames, "LedgerGoblinGuide")

	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local icon = win:CreateTexture(nil, "ARTWORK")
	icon:SetSize(28, 28)
	icon:SetPoint("TOPLEFT", 16, -14)
	icon:SetTexture(C.Icon)
	UI.Label(win, C.Title .. "  " .. L["Guide"], "GameFontNormalLarge"):SetPoint("LEFT", icon, "RIGHT", 8, 0)
	win.step = UI.Label(win, "", "GameFontDisableSmall")
	win.step:SetPoint("TOPRIGHT", -40, -22)

	win.title = UI.Label(win, "", "GameFontNormalHuge")
	win.title:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 2, -14)

	win.text = UI.Label(win, "", "GameFontHighlight")
	win.text:SetPoint("TOPLEFT", win.title, "BOTTOMLEFT", 0, -8)
	win.text:SetPoint("RIGHT", -20, 0)
	win.text:SetWordWrap(true)
	win.text:SetSpacing(2)

	local area = UI.Inset(win)
	area:SetHeight(SNIPPET_H)
	area:SetPoint("BOTTOMLEFT", 16, 52)
	area:SetPoint("BOTTOMRIGHT", -16, 52)
	for i = 1, #pages do
		local f = CreateFrame("Frame", nil, area)
		f:SetAllPoints()
		pages[i].snippet(f)
		f:Hide()
		pages[i].frame = f
	end

	-- Page dots, centred under the snippet. Clicking one jumps to its page.
	win.dots = {}
	local dotW = 8
	local startX = -((#pages - 1) * (dotW + 8)) / 2
	for i = 1, #pages do
		local dot = CreateFrame("Button", nil, win)
		dot:SetSize(dotW + 4, dotW + 4)
		dot:SetPoint("BOTTOM", startX + (i - 1) * (dotW + 8), 20)
		local tex = dot:CreateTexture(nil, "ARTWORK")
		tex:SetSize(dotW, dotW)
		tex:SetPoint("CENTER")
		tex:SetColorTexture(1, 1, 1, 1)
		dot:SetScript("OnClick", function()
			ShowPage(i)
		end)
		win.dots[i] = tex
	end

	-- It opens by itself only once, so the hint says how to get it back.
	UI.Label(win, L["/ledger guide reopens this"], "GameFontDisableSmall"):SetPoint("BOTTOMLEFT", 18, 20)

	win.next = UI.Button(win, L["Next"], 90)
	win.next:SetPoint("BOTTOMRIGHT", -16, 14)
	win.next:SetScript("OnClick", function()
		if win.index >= #pages then
			ns.global.guideSeen = true
			win:Hide()
		else
			ShowPage(win.index + 1)
		end
	end)
	win.back = UI.Button(win, L["Back"], 90)
	win.back:SetPoint("RIGHT", win.next, "LEFT", -6, 0)
	win.back:SetScript("OnClick", function()
		ShowPage(win.index - 1)
	end)
	win.action = UI.Button(win, "", 150)
	win.action:SetPoint("BOTTOMLEFT", area, "TOPLEFT", 0, 8)
	win.action:SetScript("OnClick", function(self)
		if self.run then
			self.run()
		end
	end)

	guide = win
end

function ns.ShowGuide(page)
	if not guide then
		Build()
	end
	ShowPage(page or 1)
	guide:Show()
end

-- First login on the account. Closing it counts as seen, so it shows once.
ns:On("PLAYER_READY", function()
	if ns.global.guideSeen then
		return
	end
	ns:After(4, function()
		if not ns.global.guideSeen and not InCombatLockdown() then
			ns.ShowGuide(1)
			ns.global.guideSeen = true
		end
	end)
end)
