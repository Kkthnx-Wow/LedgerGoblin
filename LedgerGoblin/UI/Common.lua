--[[
	LedgerGoblin - UI Common
	-------------------------------------------------------------------------
	Widgets and helpers shared by the rule editor, settings and mail desk.
	Everything hangs off ns.UI.
--]]

local _, ns = ...
local C, L = ns.C, ns.L

local UI = {}
ns.UI = UI

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetCursorInfo = GetCursorInfo
local ClearCursor = ClearCursor
local C_Item = C_Item
local hooksecurefunc = hooksecurefunc
local tostring = tostring
local gsub = string.gsub

---@diagnostic disable-next-line: deprecated
local GetItemInfo = C_Item.GetItemInfo or _G["GetItemInfo"]
---@diagnostic disable-next-line: deprecated
local GetItemInfoInstant = C_Item.GetItemInfoInstant or _G["GetItemInfoInstant"]
local QUESTION_MARK_ICON = 134400

function UI.Label(parent, text, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

function UI.Input(parent, width)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetAutoFocus(false)
	box:SetSize(width, 24)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	return box
end

function UI.Button(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 120, 24)
	button:SetText(text)
	return button
end

function UI.Inset(parent)
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f:SetBackdropColor(0, 0, 0, 0.30)
	f:SetBackdropBorderColor(C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3], 0.18)
	return f
end

-- Dark window chrome with a thin gold edge, shared by the editor and desk.
function UI.Chrome(frame)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.06, 0.94)
	frame:SetBackdropBorderColor(C.BrandRGB[1], C.BrandRGB[2], C.BrandRGB[3], 0.7)
end

function UI.HideTooltip()
	GameTooltip:Hide()
end

-- Hover help on any control. HookScript keeps existing handlers.
function UI.Tooltip(frame, title, body)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if title then
			GameTooltip:AddLine(title, 1, 0.82, 0)
		end
		if body then
			GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
		end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", UI.HideTooltip)
end

function UI.ItemTooltip(owner, itemID)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetItemByID(itemID)
	GameTooltip:Show()
end

-- icon, r, g, b, link. Quality and link load async, the caller redraws on
-- GET_ITEM_INFO_RECEIVED.
function UI.ItemDisplay(itemID)
	local _, _, _, _, icon = GetItemInfoInstant(itemID)
	local _, link, quality = GetItemInfo(itemID)
	local qc = quality and C.QualityColors and C.QualityColors[quality]
	if not link and C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
	end
	if qc then
		return icon or QUESTION_MARK_ICON, qc.r, qc.g, qc.b, link
	end
	return icon or QUESTION_MARK_ICON, 0.62, 0.62, 0.62, link
end

function UI.PlainText(s)
	if not s then
		return ""
	end
	s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
	s = gsub(s, "|H.-|h", "")
	s = gsub(s, "|h", "")
	return (gsub(s, "|r", ""))
end

-- ---------------------------------------------------------------------------
-- Item inputs: drag an item in or shift-click one from bags to fill its ID
-- ---------------------------------------------------------------------------

local itemBoxes = {}
local hooked = false

local function FeedFocusedBox(link)
	if type(link) ~= "string" then
		return
	end
	for i = 1, #itemBoxes do
		local box = itemBoxes[i]
		if box:IsVisible() and box:HasFocus() then
			local id = link:match("|Hitem:(%d+)")
			box:SetText(id or link)
			box:SetCursorPosition(#box:GetText())
			-- A shift-click on a stack also opens the split slider after us.
			ns:After(0, function()
				local split = _G["StackSplitFrame"]
				if split and split:IsShown() then
					split:Hide()
				end
				ClearCursor()
			end)
			return
		end
	end
end

function UI.WireItemInput(box)
	box:HookScript("OnTextChanged", function(self)
		local id = self:GetText():match("|Hitem:(%d+)")
		if id then
			self:SetText(id)
			self:SetCursorPosition(#id)
		end
	end)
	local function TakeCursor(self)
		local kind, itemID = GetCursorInfo()
		if kind == "item" and itemID then
			self:SetText(tostring(itemID))
			ClearCursor()
		end
	end
	box:SetScript("OnReceiveDrag", TakeCursor)
	box:HookScript("OnMouseDown", TakeCursor)
	itemBoxes[#itemBoxes + 1] = box

	if not hooked and type(_G["HandleModifiedItemClick"]) == "function" then
		hooked = true
		hooksecurefunc("HandleModifiedItemClick", FeedFocusedBox)
	end
end

-- ---------------------------------------------------------------------------
-- Recipient menu: alts, recent names, cross-account alts
-- ---------------------------------------------------------------------------

function UI.TargetMenu(owner, onPick, withRecent)
	local MenuUtil = _G["MenuUtil"]
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		return
	end
	local Roster = ns:GetModule("Roster")
	MenuUtil.CreateContextMenu(owner, function(_, root)
		local function Add(key)
			root:CreateButton(Roster.Colored(key), function()
				onPick(key)
			end)
		end
		root:CreateTitle(L["Your characters"])
		local list = Roster.List(false)
		for i = 1, #list do
			Add(list[i])
		end
		if #list == 0 then
			root:CreateButton(L["None yet. Log in on an alt once so LedgerGoblin can see it."], function() end)
		end

		local manual = Roster.ManualList()
		if #manual > 0 then
			root:CreateDivider()
			root:CreateTitle(L["Cross-account alts"])
			for i = 1, #manual do
				Add(manual[i])
			end
		end

		if withRecent then
			-- Online friends and guild members, the other names people mail.
			local friends = {}
			local C_FriendList = _G["C_FriendList"]
			if C_FriendList and C_FriendList.GetNumFriends then
				for i = 1, C_FriendList.GetNumFriends() do
					local info = C_FriendList.GetFriendInfoByIndex(i)
					if info and info.name and info.connected then
						friends[#friends + 1] = info.name
					end
				end
			end
			if #friends > 0 then
				table.sort(friends)
				root:CreateDivider()
				root:CreateTitle(L["Friends online"])
				for i = 1, math.min(#friends, 15) do
					local name = friends[i]
					root:CreateButton(name, function()
						onPick(name)
					end)
				end
			end
			if _G["IsInGuild"] and _G["IsInGuild"]() and _G["GetNumGuildMembers"] then
				local guild = {}
				local me = ns.State.playerName
				for i = 1, _G["GetNumGuildMembers"]() do
					local name, _, _, _, _, _, _, _, online = _G["GetGuildRosterInfo"](i)
					if name and online and name ~= me and not Roster.IsKnown(name) then
						guild[#guild + 1] = name
					end
				end
				if #guild > 0 then
					table.sort(guild)
					root:CreateDivider()
					root:CreateTitle(L["Guild online"])
					for i = 1, math.min(#guild, 15) do
						local name = guild[i]
						root:CreateButton(name, function()
							onPick(name)
						end)
					end
				end
			end

			local recent = Roster.RecentList()
			local shown = 0
			for i = 1, #recent do
				if not Roster.IsKnown(recent[i]) then
					if shown == 0 then
						root:CreateDivider()
						root:CreateTitle(L["Recently mailed"])
					end
					shown = shown + 1
					root:CreateButton(recent[i], function()
						onPick(recent[i])
					end)
				end
			end
		end

		root:CreateDivider()
		root:CreateButton(L["Add cross-account alt..."], function()
			_G["StaticPopup_Show"]("LEDGERGOBLIN_ADD_MANUAL_ALT")
		end)
		root:CreateButton(L["Import cross-account alts..."], function()
			_G["StaticPopup_Show"]("LEDGERGOBLIN_IMPORT_ALTS")
		end)
		root:CreateButton(L["Export character list..."], ns.ShowExportAlts)
	end)
end

-- Vertical scroll viewport. Returns scroll, content.
function UI.ScrollList(parent, step)
	local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local cur = self:GetVerticalScroll()
		if ns.F.IsSecret(cur) then
			return
		end
		-- Range from the child height, GetVerticalScrollRange lagged behind a
		-- list that just grew and left the last rows out of reach.
		local range = math.max(0, content:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.max(0, math.min(range, cur - delta * (step or 56))))
	end)
	scroll:SetScript("OnSizeChanged", function(_, w)
		if w and w > 0 then
			content:SetWidth(w)
		end
		if content.Relayout then
			content.Relayout()
		end
	end)
	return scroll, content
end
