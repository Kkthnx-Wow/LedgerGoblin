--[[
	LedgerGoblin - Slash commands
	-------------------------------------------------------------------------
	/ledger and /lg. Rule changes go through the Rules module so the same
	checks apply as in the editor.
--]]

local _, ns = ...
local L, F = ns.L, ns.F

local tonumber = tonumber
local type = type

local HELP = {
	L["/ledger  open settings"],
	L["/ledger guide  how LedgerGoblin works, page by page"],
	L["/ledger send  send by rules now"],
	L["/ledger preview  list what would be sent"],
	L["/ledger collect [all|gold|items|auction|alts]  take inbox mail"],
	L["/ledger rules  open the Rule Editor"],
	L["/ledger rule add <itemID|name> <character> [max]  add an item route"],
	L["/ledger rule list | remove [n] | toggle <n>"],
	L["/ledger keep <itemID> [n]  keep n in bags, send the rest"],
	L["/ledger exclude <itemID> | exclude remove <itemID>"],
	L["/ledger alts  gold and mail on every character"],
	L["/ledger income [days]  inbox income by source"],
	L["/ledger sales [days]  auction sales and purchases"],
	L["/ledger log | stats | reset"],
	L["/ledger alt add|remove|list|export|import  cross-account targets"],
	L["/ledger toggle  auto-send on this character"],
	L["/ledger minimap | trace"],
	L["/ledger demo | demo off  preview the Rule Editor with sample routes"],
}

local function Words(text)
	local first, rest = (text or ""):match("^(%S*)%s*(.-)$")
	return (first or ""):lower(), rest or ""
end

local function PrintRules()
	local rules = ns.db.itemRules
	if #rules == 0 then
		F.Print(L["No item routes yet."])
		return
	end
	local Rules = ns:GetModule("Rules")
	for i = 1, #rules do
		local rule = rules[i]
		local extra = ""
		if rule.enabled == false then
			extra = extra .. " " .. L["(off)"]
		end
		if rule.max then
			extra = extra .. " " .. L["(max"] .. " " .. rule.max .. ")"
		end
		local kept = type(rule.match) == "number" and ns.db.keep[rule.match]
		if kept then
			extra = extra .. " " .. L["(keep"] .. " " .. kept .. ")"
		end
		F.Print("%d. %s -> %s%s", i, Rules.FormatMatch(rule.match), rule.target or "?", extra)
	end
end

local handlers = {}

handlers[""] = function()
	ns.OpenSettings()
end

handlers.help = function()
	for i = 1, #HELP do
		F.Print(HELP[i])
	end
end

handlers.send = function()
	ns:GetModule("Sender").Run()
end

handlers.preview = function()
	ns:GetModule("Sender").Preview()
end

handlers.collect = function(rest)
	local filter = Words(rest)
	ns:GetModule("Inbox").Collect(filter ~= "" and filter or nil)
end

handlers.rules = function()
	ns.ToggleRuleWindow()
end

handlers.rule = function(rest)
	local Rules = ns:GetModule("Rules")
	local action, tail = Words(rest)
	if action == "add" then
		-- A trailing number is the max. Forever names have a space, so the
		-- character is everything between the item and that number.
		local a, b, c = tail:match("^(%S+)%s+(.-)%s+(%d+)$")
		if not a then
			a, b = tail:match("^(%S+)%s+(.+)$")
		end
		if a and b then
			Rules.AddItemRule(a, b, c)
		else
			F.Print(L["Usage: /ledger rule add <itemID|name> <character> [max]"])
		end
	elseif action == "list" then
		PrintRules()
	elseif action == "remove" then
		Rules.RemoveItemRule(tonumber(tail))
	elseif action == "toggle" then
		if not Rules.ToggleItemRule(tonumber(tail)) then
			F.Print(L["Usage: /ledger rule toggle <n>"])
		end
	else
		F.Print(L["Usage: /ledger rule add|list|remove|toggle"])
	end
end

handlers.keep = function(rest)
	local idText, n = Words(rest)
	local itemID = F.ItemIDFromText(idText)
	if not itemID then
		F.Print(L["Usage: /ledger keep <itemID> [n]"])
		return
	end
	ns:GetModule("Rules").SetKeep(itemID, n)
	local kept = ns.db.keep[itemID]
	if kept then
		F.Print(L["Keeping %d of item %d, the rest is sent."], kept, itemID)
	else
		F.Print(L["Keep reserve for item %d cleared."], itemID)
	end
end

handlers.exclude = function(rest)
	local Rules = ns:GetModule("Rules")
	local action, tail = Words(rest)
	if action == "remove" then
		if Rules.SetExcluded(tail, false) then
			F.Print(L["Item %s is no longer excluded."], tail)
		end
	elseif Rules.SetExcluded(rest, true) then
		F.Print(L["Item %s will never be mailed."], rest)
	end
end

handlers.alts = function()
	ns:GetModule("Ledger").PrintAlts()
end

handlers.income = function(rest)
	ns:GetModule("Ledger").PrintIncome(tonumber(rest))
end

handlers.sales = function(rest)
	ns:GetModule("Ledger").PrintSales(tonumber(rest))
end

handlers.log = function()
	ns:GetModule("Ledger").PrintLog()
end

handlers.stats = function()
	ns:GetModule("Ledger").PrintStats()
end

handlers.reset = function()
	_G["StaticPopup_Show"]("LEDGERGOBLIN_CONFIRM_RESET")
end

handlers.alt = function(rest)
	local Roster = ns:GetModule("Roster")
	local action, tail = Words(rest)
	if action == "add" then
		_G["StaticPopup_Show"]("LEDGERGOBLIN_ADD_MANUAL_ALT", nil, nil, { prefill = tail })
	elseif action == "remove" then
		local target = F.NormalizeTarget(tail)
		if target and Roster.IsManual(target) then
			Roster.RemoveManual(target)
			F.Print(L["Removed cross-account alt %s."], target)
		else
			F.Print(L["Usage: /ledger alt remove <character>"])
		end
	elseif action == "list" then
		local list = Roster.ManualList()
		if #list == 0 then
			F.Print(L["No cross-account alts added."])
		end
		for i = 1, #list do
			F.Print("  %s", list[i])
		end
	elseif action == "export" then
		ns.ShowExportAlts()
	elseif action == "import" then
		if tail ~= "" then
			ns.ImportAlts(tail)
		else
			_G["StaticPopup_Show"]("LEDGERGOBLIN_IMPORT_ALTS")
		end
	else
		F.Print(L["Usage: /ledger alt add|remove|list|export|import"])
	end
end

handlers.toggle = function()
	ns.db.autoRun = not ns.db.autoRun
	F.Print(ns.db.autoRun and L["Auto-send is on for this character."] or L["Auto-send is off for this character."])
end

handlers.minimap = function()
	ns.ToggleMinimapButton()
end

handlers.guide = function()
	ns.ShowGuide(1)
end

handlers.demo = function(rest)
	local Demo = ns:GetModule("Demo")
	if Words(rest) == "off" then
		Demo.Off()
	else
		Demo.On()
	end
end

handlers.trace = function()
	ns:GetModule("Sender").ToggleTrace()
end

local function HandleSlash(msg)
	local cmd, rest = Words(F.Trim(msg or ""))
	local handler = handlers[cmd]
	if handler then
		handler(rest)
	else
		handlers.help()
	end
end

ns:OnInit(function()
	_G["SLASH_LEDGERGOBLIN1"] = "/ledger"
	_G["SLASH_LEDGERGOBLIN2"] = "/lg"
	SlashCmdList["LEDGERGOBLIN"] = HandleSlash
end)
