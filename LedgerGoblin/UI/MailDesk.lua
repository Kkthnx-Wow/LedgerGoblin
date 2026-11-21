--[[
	LedgerGoblin - Mail Desk
	-------------------------------------------------------------------------
	A strip above the mailbox with Send, Preview, Collect and Rules, plus a
	status line. Right-click Collect to pick a filter for one run. A Pick
	button beside the Send Mail "To" box fills it from your characters and
	recently mailed names.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F
local UI = ns.UI

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local format = string.format

local bar

local function SendTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Send by rules"])
	if not ns:GetModule("Rules").HasAny() then
		GameTooltip:AddLine(L["No rules yet. Type /ledger to set some up."], 1, 0.4, 0.4, true)
	else
		local s = ns:GetModule("Planner").Summary()
		if s.mails == 0 then
			GameTooltip:AddLine(L["Nothing matches your rules right now."], 0.8, 0.8, 0.8, true)
		else
			if s.units > 0 then
				GameTooltip:AddLine(format(L["%d item(s)"], s.units), 0.6, 1, 0.6)
			end
			if s.copper > 0 then
				GameTooltip:AddLine(F.Money(s.copper), 0.6, 1, 0.6)
			end
			GameTooltip:AddLine(format(L["%d mail(s)"], s.mails), 0.8, 0.8, 0.8)
		end
		for i = 1, #s.warnings do
			GameTooltip:AddLine(s.warnings[i], 1, 0.5, 0.2, true)
		end
		if s.abort then
			GameTooltip:AddLine(s.abort, 1, 0.3, 0.3, true)
		end
	end
	GameTooltip:Show()
end

local function CollectTooltip(self)
	local Inbox = ns:GetModule("Inbox")
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Collect"])
	GameTooltip:AddLine(format(L["Filter: %s"], Inbox.FilterLabel(ns.db.inbox.filter)), 0.8, 0.8, 0.8)
	local box = Inbox.Summary()
	if box and box.count then
		GameTooltip:AddLine(format(L["%d mail here, %d on the server"], box.count, box.total or box.count), 1, 1, 1)
		if (box.money or 0) > 0 then
			GameTooltip:AddLine(format(L["Gold waiting: %s"], F.Money(box.money)), 0.6, 1, 0.6)
		end
		if (box.cod or 0) > 0 then
			GameTooltip:AddLine(format(L["%d COD mail left for you to open"], box.cod), 1, 0.6, 0.2)
		end
	end
	GameTooltip:AddLine(L["Right-click to choose a filter for one run."], 0.6, 0.6, 0.6, true)
	GameTooltip:Show()
end

local function CollectMenu(owner)
	GameTooltip:Hide()
	local Inbox = ns:GetModule("Inbox")
	_G["MenuUtil"].CreateContextMenu(owner, function(_, root)
		root:CreateTitle(L["Collect once"])
		for _, key in ipairs({ C.COLLECT.ALL, C.COLLECT.GOLD, C.COLLECT.ITEMS, C.COLLECT.AUCTION, C.COLLECT.ALTS }) do
			root:CreateButton(Inbox.FilterLabel(key), function()
				Inbox.Collect(key)
			end)
		end
	end)
end

local function UpdateState()
	if not bar then
		return
	end
	local sending, collecting = ns.State.sending, ns.State.collecting
	bar.send:SetText(sending and L["Sending..."] or L["Send"])
	bar.send:SetEnabled(not sending and not collecting and ns:GetModule("Rules").HasAny())
	bar.preview:SetEnabled(not sending)
	bar.collect:SetText(collecting and L["Stop"] or L["Collect"])
	bar.collect:SetEnabled(not sending)

	local box = ns:GetModule("Inbox").Summary()
	if box and box.count then
		local text = format(L["%d mail"], box.count)
		if (box.total or 0) > box.count then
			text = text .. format(L[" (+%d on server)"], box.total - box.count)
		end
		if (box.money or 0) > 0 then
			text = text .. "  " .. F.Money(box.money)
		end
		bar.status:SetText(text)
	else
		bar.status:SetText("")
	end
end

local function AddPickButton()
	local nameBox = _G["SendMailNameEditBox"]
	if not nameBox or nameBox.LedgerGoblinPick then
		return
	end
	local pick = CreateFrame("Button", nil, nameBox, "UIPanelButtonTemplate")
	pick:SetSize(22, 20)
	pick:SetText("+")
	pick:SetPoint("LEFT", nameBox, "RIGHT", 2, 0)
	pick:SetScript("OnClick", function(self)
		UI.TargetMenu(self, function(key)
			nameBox:SetText(F.MailRecipient(key))
			if _G["SendMailFrame_Update"] then
				_G["SendMailFrame_Update"]()
			end
		end, true)
	end)
	UI.Tooltip(pick, L["Pick a recipient"], L["Your characters and names you mailed recently."])
	nameBox.LedgerGoblinPick = pick
end

local function Build()
	local mailFrame = _G["MailFrame"]
	if bar or not mailFrame then
		return
	end
	bar = CreateFrame("Frame", nil, mailFrame, "BackdropTemplate")
	bar:SetSize(mailFrame:GetWidth(), 52)
	bar:SetPoint("BOTTOMLEFT", mailFrame, "TOPLEFT", 0, 4)
	UI.Chrome(bar)

	local width = (mailFrame:GetWidth() - 16 - 3 * 4) / 4
	local function Btn(text, prev)
		local b = UI.Button(bar, text, width)
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else
			b:SetPoint("TOPLEFT", 8, -6)
		end
		b:SetScript("OnLeave", UI.HideTooltip)
		return b
	end

	bar.send = Btn(L["Send"])
	bar.send:SetScript("OnClick", function()
		ns:GetModule("Sender").Run()
	end)
	bar.send:SetScript("OnEnter", SendTooltip)
	-- A disabled button gets no OnEnter, so explain why it is off.
	bar.send:SetMotionScriptsWhileDisabled(true)

	bar.preview = Btn(L["Preview"], bar.send)
	bar.preview:SetScript("OnClick", function()
		ns:GetModule("Sender").Preview()
	end)
	UI.Tooltip(bar.preview, L["Preview"], L["List what Send would mail, without sending."])

	bar.collect = Btn(L["Collect"], bar.preview)
	bar.collect:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	bar.collect:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			CollectMenu(self)
		else
			ns:GetModule("Inbox").Collect()
		end
	end)
	bar.collect:SetScript("OnEnter", CollectTooltip)

	bar.rules = Btn(L["Rules"], bar.collect)
	bar.rules:SetScript("OnClick", function()
		ns.ToggleRuleWindow()
	end)
	UI.Tooltip(bar.rules, L["Rules"], L["Open the Rule Editor. Drag or shift-click items in to route them."])

	bar.status = UI.Label(bar, "", "GameFontHighlightSmall")
	bar.status:SetPoint("BOTTOMLEFT", 12, 7)
	bar.status:SetPoint("RIGHT", -12, 0)

	AddPickButton()
end

ns:RegisterEvent("MAIL_SHOW", function()
	Build()
	UpdateState()
end)
ns:On("SEND_STATE", UpdateState)
ns:On("COLLECT_STATE", UpdateState)
ns:On("MAILBOX_CHANGED", UpdateState)
ns:On("RULES_CHANGED", UpdateState)
