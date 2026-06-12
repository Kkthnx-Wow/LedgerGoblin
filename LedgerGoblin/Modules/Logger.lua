--[[
	LedgerGoblin - Logger
	-------------------------------------------------------------------------
	Three jobs, all fed by the engine as it sends:
	  1. Session accumulator -> one clean chat summary per routing run.
	  2. Rolling persistent log (ring-trimmed) -> account history.
	  3. Per-day analytics -> gold/items per target per day.
	Plus a dry-run Preview that lists the actual item names + gold per target so
	you can see exactly what a send would do. No spam: the run summary reports
	once at the end, not per mail.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Logger = ns:NewModule("Logger")

local format = string.format
local floor = math.floor
local sort = table.sort

-- "5s/3m/2h/4d ago" - compact relative time for the transfer log.
local function FormatAgo(when)
	local secs = time() - (when or 0)
	if secs < 60 then
		return format(L["%ds ago"], secs)
	elseif secs < 3600 then
		return format(L["%dm ago"], floor(secs / 60))
	elseif secs < 86400 then
		return format(L["%dh ago"], floor(secs / 3600))
	end
	return format(L["%dd ago"], floor(secs / 86400))
end

local PREVIEW_NAME_CAP = 15 -- how many item names to list before "...and N more"

-- The in-flight run's tally. target -> { copper, items }. Reset on BeginRun.
local session

function Logger.BeginRun()
	session = {}
end

-- Record one dispatched mail. copper is the gold-as-copper attached; itemList is
-- the array of item entries ({ link, name, ... }) carried in that mail. Persists
-- the counts to the account log + daily analytics.
function Logger.RecordMail(target, copper, itemList)
	copper = copper or 0
	local items = itemList and #itemList or 0

	-- Session tally (for the summary line).
	if session then
		local s = session[target]
		if not s then
			s = { copper = 0, items = 0 }
			session[target] = s
		end
		s.copper = s.copper + copper
		s.items = s.items + items
	end

	-- Persistent ring log.
	local log = ns.global.log
	log[#log + 1] = { time = time(), target = target, copper = copper, items = items }
	local overflow = #log - (ns.global.logMax or 200)
	if overflow > 0 then
		for i = 1, overflow do
			table.remove(log, 1)
		end
	end

	-- Daily analytics.
	local dayKey = F.DateKey()
	local day = ns.global.analytics[dayKey]
	if not day then
		day = {}
		ns.global.analytics[dayKey] = day
	end
	local agg = day[target]
	if not agg then
		agg = { copper = 0, items = 0 }
		day[target] = agg
	end
	agg.copper = agg.copper + copper
	agg.items = agg.items + items
end

-- Stable, sorted list of the targets present in a { [target] = ... } table.
local function SortedTargets(map)
	local targets = {}
	for target in pairs(map) do
		targets[#targets + 1] = target
	end
	table.sort(targets)
	return targets
end

-- Emit the summary for the run that just finished (counts + gold, kept clean).
function Logger.EndRun()
	if not session or not next(session) then
		F.Print(L["Mailbox routing finished: no mail was sent."])
		session = nil
		return
	end

	F.Print(L["Mailbox routing complete."])
	local targets = SortedTargets(session)
	for i = 1, #targets do
		local target = targets[i]
		local t = session[target]
		if t.copper and t.copper > 0 then
			F.Print(L["Sent %s to %s"], F.Money(t.copper), target)
		end
		if t.items and t.items > 0 then
			F.Print(L["Sent %d item(s) to %s"], t.items, target)
		end
	end

	session = nil
end

-- Dry-run report: list the actual items + gold each target would receive.
function Logger.Preview(jobs)
	if not jobs or #jobs == 0 then
		F.Print(L["Preview - nothing would be sent."])
		return
	end

	-- Fold the per-mail jobs back together per target for a readable report.
	local byTarget = {}
	for i = 1, #jobs do
		local job = jobs[i]
		local t = byTarget[job.target]
		if not t then
			t = { copper = 0, names = {} }
			byTarget[job.target] = t
		end
		t.copper = t.copper + (job.money or 0)
		for j = 1, #job.items do
			local it = job.items[j]
			t.names[#t.names + 1] = it.link or it.name or "?"
		end
	end

	F.Print(L["Preview - would send:"])
	local targets = SortedTargets(byTarget)
	for i = 1, #targets do
		local target = targets[i]
		local t = byTarget[target]
		if t.copper > 0 then
			F.Print(L["  %s -> %s"], F.Money(t.copper), target)
		end
		local n = #t.names
		if n > 0 then
			F.Print(L["  %d item(s) -> %s:"], n, target)
			local shown = math.min(n, PREVIEW_NAME_CAP)
			for j = 1, shown do
				F.Print(L["    %s"], t.names[j])
			end
			if n > shown then
				F.Print(L["    ...and %d more"], n - shown)
			end
		end
	end
end

-- Wipe persistent history (transfer log + per-day analytics). Roster and
-- learned repair costs are intentionally preserved.
function Logger.ClearHistory()
	if not ns.global then
		return
	end
	wipe(ns.global.log)
	wipe(ns.global.analytics)
	F.Print(L["Transfer history and stats cleared."])
end

-- ---------------------------------------------------------------------------
-- History reporting (surfaces the log + analytics the engine has been keeping)
-- ---------------------------------------------------------------------------

-- /ledger log: the most recent transfers, newest first.
function Logger.PrintLog(limit)
	local log = ns.global and ns.global.log
	if not log or #log == 0 then
		F.Print(L["No transfers logged yet."])
		return
	end
	limit = limit or 10
	F.Print(L["Recent transfers:"])
	local first = math.max(1, #log - limit + 1)
	for i = #log, first, -1 do
		local e = log[i]
		F.Print(L["  %s: %d item(s), %s -> %s"], FormatAgo(e.time), e.items or 0, F.Money(e.copper or 0), e.target or "?")
	end
end

-- /ledger stats: lifetime + today totals per destination, from the durable
-- per-day analytics (which, unlike the ring log, is never trimmed).
function Logger.PrintStats()
	local analytics = ns.global and ns.global.analytics
	if not analytics or not next(analytics) then
		F.Print(L["No transfers logged yet."])
		return
	end

	local life, lifeItems, lifeCopper = {}, 0, 0
	for _, byTarget in pairs(analytics) do
		for target, agg in pairs(byTarget) do
			local t = life[target]
			if not t then
				t = { items = 0, copper = 0 }
				life[target] = t
			end
			t.items = t.items + (agg.items or 0)
			t.copper = t.copper + (agg.copper or 0)
			lifeItems = lifeItems + (agg.items or 0)
			lifeCopper = lifeCopper + (agg.copper or 0)
		end
	end

	F.Print(L["LedgerGoblin stats"])
	F.Print(L["Lifetime: %d item(s), %s."], lifeItems, F.Money(lifeCopper))

	local targets = {}
	for target in pairs(life) do
		targets[#targets + 1] = target
	end
	sort(targets, function(a, b) return life[a].copper > life[b].copper end)
	for i = 1, #targets do
		local target = targets[i]
		F.Print(L["  %s: %d item(s), %s"], target, life[target].items, F.Money(life[target].copper))
	end

	local today = analytics[F.DateKey()]
	if today then
		local tItems, tCopper = 0, 0
		for _, agg in pairs(today) do
			tItems = tItems + (agg.items or 0)
			tCopper = tCopper + (agg.copper or 0)
		end
		F.Print(L["Today: %d item(s), %s."], tItems, F.Money(tCopper))
	end
end
