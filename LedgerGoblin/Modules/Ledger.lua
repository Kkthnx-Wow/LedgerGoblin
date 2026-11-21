--[[
	LedgerGoblin - Ledger
	-------------------------------------------------------------------------
	Records what moves and prints it back.
	  Sends: a ring log plus per-day totals per target (gold, item units,
	  postage). Each send to an own alt also marks those items as on the way
	  in that alt's mailbox entry, until the alt opens its mailbox.
	  Income: inbox money per day, per character and per source.
	Day tables keep RETENTION_DAYS and are pruned once a day.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Ledger = ns:NewModule("Ledger")
local Roster -- set at init

local format = string.format
local time = time
local date = date
local pairs = pairs
local tremove = table.remove
local tsort = table.sort
local mathmax = math.max
local mathmin = math.min

local RETENTION_DAYS = 90
local PREVIEW_CAP = 15
local SOURCE = C.SOURCE

local SOURCE_LABEL = {
	[SOURCE.SALE] = L["Auction sales"],
	[SOURCE.REFUND] = L["Auction refunds"],
	[SOURCE.ALT] = L["From your alts"],
	[SOURCE.PLAYER] = L["From other players"],
	[SOURCE.OTHER] = L["Other mail"],
}
Ledger.SOURCE_LABEL = SOURCE_LABEL

local lastPrune

local function Prune()
	local today = F.DateKey()
	if lastPrune == today then
		return
	end
	lastPrune = today
	local cutoff = date("%Y-%m-%d", time() - RETENTION_DAYS * 86400)
	for _, book in pairs({ ns.global.analytics, ns.global.income }) do
		for day in pairs(book) do
			if day < cutoff then
				book[day] = nil
			end
		end
	end
end

local function Day(book)
	Prune()
	local key = F.DateKey()
	local day = book[key]
	if not day then
		day = {}
		book[key] = day
	end
	return day
end

-- ---------------------------------------------------------------------------
-- Sends
-- ---------------------------------------------------------------------------

local session -- target -> { copper, units } for the running batch

function Ledger.BeginRun()
	session = {}
end

function Ledger.EndRun()
	local s = session
	session = nil
	if not s or not next(s) then
		F.Print(L["Routing finished. No mail was sent."])
		return
	end
	local targets = {}
	for target in pairs(s) do
		targets[#targets + 1] = target
	end
	tsort(targets)
	for i = 1, #targets do
		local t = s[targets[i]]
		local parts = {}
		if t.units > 0 then
			parts[#parts + 1] = format(L["%d item(s)"], t.units)
		end
		if t.copper > 0 then
			parts[#parts + 1] = F.Money(t.copper)
		end
		F.Print(L["Sent %s to %s."], table.concat(parts, ", "), Roster.Colored(targets[i]))
	end
end

-- items: entries with itemID and sendCount (or count).
function Ledger.RecordSend(target, copper, items, postage)
	copper = copper or 0
	postage = postage or 0
	local units = 0
	local box = ns.global.mailbox[target]
	if not box then
		box = {}
		ns.global.mailbox[target] = box
	end
	box.pending = box.pending or {}
	for i = 1, #(items or {}) do
		local it = items[i]
		local n = it.sendCount or it.count or 1
		units = units + n
		if it.itemID then
			box.pending[it.itemID] = (box.pending[it.itemID] or 0) + n
		end
	end
	box.incoming = (box.incoming or 0) + 1
	box.incomingAt = box.incomingAt or time()

	if session then
		local s = session[target]
		if not s then
			s = { copper = 0, units = 0 }
			session[target] = s
		end
		s.copper = s.copper + copper
		s.units = s.units + units
	end

	local log = ns.global.log
	log[#log + 1] = { time = time(), from = ns.State.playerName, target = target, copper = copper, items = units, postage = postage }
	for _ = 1, #log - (ns.global.logMax or 200) do
		tremove(log, 1)
	end

	local day = Day(ns.global.analytics)
	local agg = day[target]
	if not agg then
		agg = { copper = 0, items = 0, postage = 0 }
		day[target] = agg
	end
	agg.copper = agg.copper + copper
	agg.items = agg.items + units
	agg.postage = (agg.postage or 0) + postage
	ns:Fire("MAILBOX_CHANGED")
end

-- ---------------------------------------------------------------------------
-- Income
-- ---------------------------------------------------------------------------

local function Say(fmt, ...)
	if ns.db.inbox.messages then
		F.Print(fmt, ...)
	end
end

function Ledger.RecordIncome(source, copper, sender)
	local me = ns.State.playerName
	if not me or not copper or copper <= 0 then
		return
	end
	if (source == SOURCE.ALT or source == SOURCE.PLAYER) and sender then
		Say(L["%s sent you %s."], sender, F.Money(copper))
	elseif source == SOURCE.REFUND then
		Say(L["Auction refund, %s."], F.Money(copper))
	end
	local day = Day(ns.global.income)
	local mine = day[me]
	if not mine then
		mine = {}
		day[me] = mine
	end
	mine[source] = (mine[source] or 0) + copper
end

-- trade: { kind = "sale"|"bought", item, count, copper, who }
function Ledger.RecordTrade(trade)
	if not trade or not trade.item then
		return
	end
	trade.time = time()
	trade.char = ns.State.playerName
	local trades = ns.global.trades
	trades[#trades + 1] = trade
	for _ = 1, #trades - (ns.global.tradesMax or 500) do
		tremove(trades, 1)
	end
	if trade.kind == "sale" then
		Say(L["Sold %s x%d for %s to %s."], trade.item, trade.count, F.Money(trade.copper), trade.who or "?")
	else
		Say(L["Bought %s x%d for %s from %s."], trade.item, trade.count, F.Money(trade.copper), trade.who or "?")
	end
end

-- Recent trades plus per-item sale totals over `days`.
function Ledger.PrintSales(days)
	days = days or 7
	local trades = ns.global.trades
	if #trades == 0 then
		F.Print(L["No auction sales or purchases recorded yet."])
		return
	end
	local cutoff = time() - days * 86400
	local byItem, order, earned, spent = {}, {}, 0, 0
	for i = 1, #trades do
		local t = trades[i]
		if t.time >= cutoff then
			if t.kind == "sale" then
				earned = earned + t.copper
				local agg = byItem[t.item]
				if not agg then
					agg = { count = 0, copper = 0 }
					byItem[t.item] = agg
					order[#order + 1] = t.item
				end
				agg.count = agg.count + t.count
				agg.copper = agg.copper + t.copper
			else
				spent = spent + t.copper
			end
		end
	end
	F.Print(L["Auctions, last %d days. Sold %s, bought %s."], days, F.Money(earned), F.Money(spent))
	tsort(order, function(a, b)
		return byItem[a].copper > byItem[b].copper
	end)
	for i = 1, mathmin(#order, 10) do
		local agg = byItem[order[i]]
		F.Print("  %s x%d  %s", order[i], agg.count, F.Money(agg.copper))
	end
	F.Print(L["Latest"])
	for i = #trades, mathmax(1, #trades - 4), -1 do
		local t = trades[i]
		F.Print(L["  %s ago, %s %s x%d, %s"], F.Ago(t.time), t.kind == "sale" and L["sold"] or L["bought"], t.item, t.count, F.Money(t.copper))
	end
end

-- source -> copper over the last `days` days (nil = everything kept).
function Ledger.IncomeTotals(days, character)
	local cutoff = days and date("%Y-%m-%d", time() - (days - 1) * 86400) or ""
	local totals, sum = {}, 0
	for day, byChar in pairs(ns.global.income) do
		if day >= cutoff then
			for who, sources in pairs(byChar) do
				if not character or who == character then
					for source, copper in pairs(sources) do
						totals[source] = (totals[source] or 0) + copper
						sum = sum + copper
					end
				end
			end
		end
	end
	return totals, sum
end

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

function Ledger.PrintPreview(jobs)
	if #jobs == 0 then
		F.Print(L["Preview. Nothing would be sent."])
		return
	end
	local byTarget, order = {}, {}
	for i = 1, #jobs do
		local job = jobs[i]
		local t = byTarget[job.target]
		if not t then
			t = { copper = 0, lines = {}, mails = 0 }
			byTarget[job.target] = t
			order[#order + 1] = job.target
		end
		t.mails = t.mails + 1
		t.copper = t.copper + (job.money or 0)
		for j = 1, #job.items do
			local it = job.items[j]
			t.lines[#t.lines + 1] = format("%s x%d", it.link or "?", it.sendCount or it.count or 1)
		end
	end
	F.Print(L["Preview. Would send"])
	for i = 1, #order do
		local target = order[i]
		local t = byTarget[target]
		F.Print("  %s (%d mail)%s", Roster.Colored(target), t.mails, t.copper > 0 and (" " .. F.Money(t.copper)) or "")
		for j = 1, mathmin(#t.lines, PREVIEW_CAP) do
			F.Print("    %s", t.lines[j])
		end
		if #t.lines > PREVIEW_CAP then
			F.Print(L["    and %d more"], #t.lines - PREVIEW_CAP)
		end
	end
end

function Ledger.PrintLog(limit)
	local log = ns.global.log
	if #log == 0 then
		F.Print(L["No transfers logged yet."])
		return
	end
	F.Print(L["Recent transfers"])
	for i = #log, mathmax(1, #log - (limit or 10) + 1), -1 do
		local e = log[i]
		F.Print(L["  %s ago, %d item(s), %s to %s"], F.Ago(e.time), e.items or 0, F.Money(e.copper or 0), Roster.Colored(e.target))
	end
end

function Ledger.PrintStats()
	local life, items, copper, postage = {}, 0, 0, 0
	for _, byTarget in pairs(ns.global.analytics) do
		for target, agg in pairs(byTarget) do
			local t = life[target]
			if not t then
				t = { items = 0, copper = 0 }
				life[target] = t
			end
			t.items = t.items + (agg.items or 0)
			t.copper = t.copper + (agg.copper or 0)
			items = items + (agg.items or 0)
			copper = copper + (agg.copper or 0)
			postage = postage + (agg.postage or 0)
		end
	end
	if not next(life) then
		F.Print(L["No transfers logged yet."])
		return
	end
	F.Print(L["Sent in the last %d days. %d item(s), %s, postage %s."], RETENTION_DAYS, items, F.Money(copper), F.Money(postage))
	local targets = {}
	for target in pairs(life) do
		targets[#targets + 1] = target
	end
	tsort(targets, function(a, b)
		return life[a].copper > life[b].copper
	end)
	for i = 1, #targets do
		local t = life[targets[i]]
		F.Print("  %s  %d item(s), %s", Roster.Colored(targets[i]), t.items, F.Money(t.copper))
	end
	F.Print(L["Mails sent, lifetime. %d."], ns.global.sendCount or 0)
end

function Ledger.PrintIncome(days)
	days = days or 7
	local totals, sum = Ledger.IncomeTotals(days)
	if sum == 0 then
		F.Print(L["No mail income recorded in the last %d days."], days)
		return
	end
	F.Print(L["Mail income, last %d days. %s"], days, F.Money(sum))
	for source, label in pairs(SOURCE_LABEL) do
		if (totals[source] or 0) > 0 then
			F.Print("  %s  %s", label, F.Money(totals[source]))
		end
	end
end

-- Per character mailbox state and gold, for /ledger alts.
function Ledger.PrintAlts()
	local list = Roster.List(true)
	if #list == 0 then
		F.Print(L["No characters known yet."])
		return
	end
	F.Print(L["Characters. Account gold %s"], F.Money(Roster.AccountGold()))
	for i = 1, #list do
		local key = list[i]
		local entry = ns.global.roster[key]
		local box = ns.global.mailbox[key]
		local mail = ""
		if box and ((box.count or 0) > 0 or box.incoming) then
			mail = format(L[", %d mail waiting"], (box.count or 0) + (box.incoming or 0))
			if box.expires then
				mail = mail .. format(L[", first expires in %s"], F.Until(box.expires))
			end
		end
		F.Print("  %s  %s%s", Roster.Colored(key), F.Money(entry.gold or 0), mail)
	end
end

function Ledger.ClearHistory()
	wipe(ns.global.log)
	wipe(ns.global.analytics)
	wipe(ns.global.income)
	wipe(ns.global.trades)
	F.Print(L["Transfer history and income cleared."])
end

ns:OnInit(function()
	Roster = ns:GetModule("Roster")
end)
