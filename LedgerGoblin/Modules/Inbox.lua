--[[
	LedgerGoblin - Inbox
	-------------------------------------------------------------------------
	Three jobs on the receiving side.

	Scan. Every inbox update is read once (debounced) into the account-wide
	mailbox table: how many mails, gold and items wait here, and when the first
	one expires. Any character can then see where mail is waiting.

	Collect. Takes mail by filter, newest index first so taking one mail never
	shifts the ones still to do. One command at a time, waiting until
	C_Mail.IsCommandPending() clears. COD, GM letters and pending sale notices
	are never touched. Item taking stops at the free bag slot floor, and money
	that would pass the gold cap is left alone. When the server holds more
	mail than the 50 shown, the inbox is refreshed as soon as the client
	allows and collecting continues.

	Income. TakeInboxMoney and AutoLootMailItem are post-hooked, so money taken
	by our collector, Blizzard's Open All or a click is recorded by source
	once PLAYER_MONEY confirms it arrived.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Inbox = ns:NewModule("Inbox")
local Items, Roster, Ledger -- set at init

local C_Mail = C_Mail
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetInboxNumItems = GetInboxNumItems
local GetInboxHeaderInfo = GetInboxHeaderInfo
local GetInboxInvoiceInfo = GetInboxInvoiceInfo
local GetInboxItem = GetInboxItem
local HasInboxItem = HasInboxItem
local TakeInboxMoney = TakeInboxMoney
local TakeInboxItem = TakeInboxItem
local AutoLootMailItem = AutoLootMailItem
local CheckInbox = CheckInbox
local GetMoney = GetMoney
local GetTime = GetTime
local hooksecurefunc = hooksecurefunc
local type = type
local time = time
local pairs = pairs
local wipe = wipe
local tremove = table.remove
local mathmin = math.min
local mathfloor = math.floor

local MAX_RECEIVE = C.MAX_RECEIVE
local SOURCE = C.SOURCE
local COLLECT = C.COLLECT
local STEP_DELAY = _G["OPEN_ALL_MAIL_MIN_DELAY"] or 0.15
local MAX_TRIES_PER_MAIL = 4
local MAX_REFRESH_PASSES = 10
local GOLD_CAP = _G["MAXIMUM_BID_PRICE"] or 99999999999
local DAY = 86400

-- ---------------------------------------------------------------------------
-- Mail kinds
-- ---------------------------------------------------------------------------

local KIND = {
	SALE = "sale", -- auction sold, money
	PENDING_SALE = "pendingSale", -- sold, money not released yet
	BOUGHT = "bought", -- auction won, item
	EXPIRED = "expired", -- auction expired, item back
	CANCELLED = "cancelled", -- auction cancelled, item back
	REFUND = "refund", -- outbid or cancelled bid, money back
	ALT = "alt",
	PLAYER = "player",
	OTHER = "other",
	COD = "cod",
	GM = "gm",
	EMPTY = "empty",
}
Inbox.KIND = KIND

-- "Auction expired: %s" -> "^Auction expired: .+$". nil when the global is
-- missing, so that check is skipped instead of matching everything.
local function SubjectPattern(fmt)
	if type(fmt) ~= "string" then
		return nil
	end
	local before, after = fmt:match("^(.-)%%s(.*)$")
	if not before then
		return nil
	end
	local function esc(s)
		return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
	end
	return "^" .. esc(before) .. ".+" .. esc(after) .. "$"
end

local EXPIRED_PATTERN = SubjectPattern(_G["AUCTION_EXPIRED_MAIL_SUBJECT"])
local REMOVED_PATTERN = SubjectPattern(_G["AUCTION_REMOVED_MAIL_SUBJECT"])
local OUTBID_PATTERN = SubjectPattern(_G["AUCTION_OUTBID_MAIL_SUBJECT"])

local function Matches(subject, pattern)
	return pattern ~= nil and subject:find(pattern) ~= nil
end

-- kind, sender, money, cod, daysLeft, itemCount for one inbox index.
function Inbox.Classify(index)
	local _, _, sender, subject, money, cod, daysLeft, itemCount, _, _, _, canReply, isGM = GetInboxHeaderInfo(index)
	money, cod, itemCount, subject = money or 0, cod or 0, itemCount or 0, subject or ""

	local kind
	local invoiceType = GetInboxInvoiceInfo(index)
	if invoiceType == "seller" then
		kind = KIND.SALE
	elseif invoiceType == "seller_temp_invoice" then
		kind = KIND.PENDING_SALE
	elseif invoiceType == "buyer" then
		kind = KIND.BOUGHT
	elseif isGM then
		kind = KIND.GM
	elseif cod > 0 then
		kind = KIND.COD
	elseif money == 0 and itemCount == 0 then
		kind = KIND.EMPTY
	elseif Matches(subject, REMOVED_PATTERN) then
		kind = money > 0 and KIND.REFUND or KIND.CANCELLED
	elseif Matches(subject, EXPIRED_PATTERN) then
		kind = KIND.EXPIRED
	elseif Matches(subject, OUTBID_PATTERN) then
		kind = KIND.REFUND
	else
		local key = F.SenderKey(sender)
		if key and Roster.IsKnown(key) then
			kind = KIND.ALT
		elseif canReply then
			kind = KIND.PLAYER
		else
			kind = KIND.OTHER
		end
	end
	return kind, sender, money, cod, daysLeft, itemCount
end

local INCOME_SOURCE = {
	[KIND.SALE] = SOURCE.SALE,
	[KIND.REFUND] = SOURCE.REFUND,
	[KIND.ALT] = SOURCE.ALT,
	[KIND.PLAYER] = SOURCE.PLAYER,
}

-- ---------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------

-- Money and kind per index from the last scan. A post-hook may run after the
-- client already cleared the header, so NoteTake falls back to this.
local lastScan = {}

local function Scan()
	local me = ns.State.playerName
	if not (me and ns.State.mailboxOpen) then
		return
	end
	local shown, total = GetInboxNumItems()
	local box = ns.global.mailbox[me] or {}
	ns.global.mailbox[me] = box

	local money, cod, soonest = 0, 0, nil
	local items = {}
	wipe(lastScan)
	for i = 1, shown do
		local kind, _, m, _, daysLeft, itemCount = Inbox.Classify(i)
		lastScan[i] = { kind = kind, money = m }
		if kind == KIND.COD then
			cod = cod + 1
		end
		if kind ~= KIND.PENDING_SALE then
			money = money + m
		end
		if (m > 0 or itemCount > 0) and daysLeft and (not soonest or daysLeft < soonest) then
			soonest = daysLeft
		end
		if itemCount > 0 then
			for a = 1, MAX_RECEIVE do
				if HasInboxItem(i, a) then
					local _, itemID, _, count = GetInboxItem(i, a)
					if itemID then
						items[itemID] = (items[itemID] or 0) + (count or 1)
					end
				end
			end
		end
	end

	box.scanned = time()
	box.count = shown
	box.total = total or shown
	box.money = money
	box.cod = cod
	box.items = items
	box.expires = soonest and mathfloor(time() + soonest * DAY) or nil
	-- Mail sent to this character has arrived and is counted above now.
	box.pending = nil
	box.incoming = nil
	box.incomingAt = nil
	ns:Fire("MAILBOX_CHANGED")
end

local scanSoon = ns:Debounce(0.3, Scan)

-- ---------------------------------------------------------------------------
-- Income attribution
-- ---------------------------------------------------------------------------

local incoming = {} -- FIFO of { amount, source, at, trade, sender }
local lastMoney

-- Auction invoice for a sale or purchase mail, as a trade record.
local function Trade(index, kind, money)
	local _, itemName, player, bid, _, _, _, _, _, _, count = GetInboxInvoiceInfo(index)
	return {
		kind = kind == KIND.SALE and "sale" or "bought",
		item = itemName,
		count = count or 1,
		copper = kind == KIND.SALE and money or (bid or 0),
		who = player,
	}
end

local function NoteTake(index)
	local kind, sender, money = Inbox.Classify(index)
	if (money or 0) == 0 and lastScan[index] then
		kind, money = lastScan[index].kind, lastScan[index].money
	end
	if kind == KIND.BOUGHT then
		-- No money moves on a purchase mail, so it is recorded when taken.
		Ledger.RecordTrade(Trade(index, kind, money))
		return
	end
	local source = INCOME_SOURCE[kind] or SOURCE.OTHER
	if money and money > 0 and kind ~= KIND.PENDING_SALE then
		incoming[#incoming + 1] = {
			amount = money,
			source = source,
			at = GetTime(),
			trade = kind == KIND.SALE and Trade(index, kind, money) or nil,
			sender = sender,
		}
	end
end

local function OnMoney()
	local now = GetMoney()
	if F.IsSecret(now) then
		return
	end
	local before = lastMoney
	lastMoney = now
	if not before or #incoming == 0 then
		return
	end
	local gained = now - before
	-- Commands run one at a time, so arrivals come in the order they were
	-- taken. Entries older than 10s never arrived (mail failed) and are dropped.
	while incoming[1] and gained > 0 do
		local entry = incoming[1]
		if GetTime() - entry.at > 10 then
			tremove(incoming, 1)
		elseif entry.amount <= gained then
			gained = gained - entry.amount
			tremove(incoming, 1)
			Ledger.RecordIncome(entry.source, entry.amount, entry.sender)
			if entry.trade then
				Ledger.RecordTrade(entry.trade)
			end
			if Inbox.run then
				Inbox.run.copper = Inbox.run.copper + entry.amount
			end
		else
			break
		end
	end
end

-- ---------------------------------------------------------------------------
-- Collect
-- ---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:Hide()
local wait = 0

local WANTS = {
	[COLLECT.ALL] = {
		[KIND.SALE] = true,
		[KIND.BOUGHT] = true,
		[KIND.EXPIRED] = true,
		[KIND.CANCELLED] = true,
		[KIND.REFUND] = true,
		[KIND.ALT] = true,
		[KIND.PLAYER] = true,
		[KIND.OTHER] = true,
	},
	[COLLECT.AUCTION] = {
		[KIND.SALE] = true,
		[KIND.BOUGHT] = true,
		[KIND.EXPIRED] = true,
		[KIND.CANCELLED] = true,
		[KIND.REFUND] = true,
	},
	[COLLECT.ALTS] = { [KIND.ALT] = true },
}
WANTS[COLLECT.GOLD] = WANTS[COLLECT.ALL]
WANTS[COLLECT.ITEMS] = WANTS[COLLECT.ALL]

function Inbox.FilterLabel(filter)
	if filter == COLLECT.GOLD then
		return L["Gold only"]
	elseif filter == COLLECT.AUCTION then
		return L["Auction mail"]
	elseif filter == COLLECT.ALTS then
		return L["From my alts"]
	elseif filter == COLLECT.ITEMS then
		return L["Items only"]
	end
	return L["Everything"]
end

local function Stop(reason)
	driver:Hide()
	local run = Inbox.run
	Inbox.run = nil
	ns.State.collecting = false
	ns:Fire("COLLECT_STATE")
	if run then
		if run.mails > 0 or run.copper > 0 then
			F.Print(L["Collected %d mail(s), %s."], run.mails, F.Money(run.copper))
		end
		if run.bagsFull then
			F.Print(L["Stopped taking items with %d bag slot(s) left."], ns.db.inbox.freeSlots)
		end
		if run.capped then
			F.Print(L["Left some gold in the mail, it would pass the gold cap."])
		end
		if reason then
			F.Print(reason)
		end
		if run.mails > 0 and ns.db.inbox.sound and _G["PlaySound"] and _G["SOUNDKIT"] then
			_G["PlaySound"](_G["SOUNDKIT"].LOOT_WINDOW_COIN_SOUND or 120)
		end
		if run.thenSend and ns.State.mailboxOpen then
			ns:GetModule("Sender").Run(true)
		end
	end
end

-- One action on the mail at run.cursor, or a move to the next mail. Returns
-- true when it sent a server command.
local function Step(run)
	local shown, total = GetInboxNumItems()
	if run.cursor > shown then
		run.cursor = shown
	end
	if run.cursor < 1 then
		if (total or 0) > shown and run.passes < MAX_REFRESH_PASSES then
			local canCheck, wait2 = C_Mail.CanCheckInbox()
			if canCheck then
				run.passes = run.passes + 1
				run.waitingRefresh = true
				CheckInbox()
				return true
			end
			run.waitUntil = GetTime() + (wait2 or 5)
			return false
		end
		Stop()
		return false
	end

	local index = run.cursor
	local kind, _, money, _, _, itemCount = Inbox.Classify(index)
	-- A try counts only when the mail looks the same as last time, so a mail
	-- emptied one attachment at a time is not cut off.
	local sig = money .. ":" .. itemCount
	local tries = run.sig[index] == sig and (run.tries[index] or 0) or 0
	if not run.wants[kind] or tries >= MAX_TRIES_PER_MAIL or (money == 0 and itemCount == 0) then
		run.cursor = index - 1
		run.tries[index], run.sig[index] = nil, nil
		return false
	end
	run.tries[index], run.sig[index] = tries + 1, sig

	local takeMoney = money > 0
	if takeMoney then
		local have = GetMoney()
		if F.NotSecret(have) and have + money > GOLD_CAP then
			takeMoney = false
			run.capped = true
		end
	end

	if run.filter == COLLECT.GOLD then
		if takeMoney then
			NoteTake(index)
			TakeInboxMoney(index)
			run.mails = run.mails + 1
			return true
		end
		run.cursor = index - 1
		return false
	end

	local room = Items.FreeBagSlots() - ns.db.inbox.freeSlots
	if run.filter == COLLECT.ITEMS then
		-- Items one at a time, so the gold stays in the mail.
		if itemCount > 0 and room > 0 then
			for a = MAX_RECEIVE, 1, -1 do
				if HasInboxItem(index, a) then
					local _, itemID = GetInboxItem(index, a)
					if not run.failed[itemID] then
						TakeInboxItem(index, a)
						return true
					end
				end
			end
		elseif itemCount > 0 then
			run.bagsFull = true
		end
		run.cursor = index - 1
		return false
	end
	if itemCount > 0 and room >= itemCount and (takeMoney or money == 0) then
		NoteTake(index)
		AutoLootMailItem(index)
		run.mails = run.mails + 1
		return true
	elseif takeMoney then
		NoteTake(index)
		TakeInboxMoney(index)
		if itemCount == 0 then
			run.mails = run.mails + 1
		end
		return true
	elseif itemCount > 0 and room > 0 then
		for a = MAX_RECEIVE, 1, -1 do
			if HasInboxItem(index, a) then
				local _, itemID = GetInboxItem(index, a)
				if not run.failed[itemID] then
					TakeInboxItem(index, a)
					return true
				end
			end
		end
	end
	if itemCount > 0 and room <= 0 then
		run.bagsFull = true
	end
	run.cursor = index - 1
	return false
end

driver:SetScript("OnUpdate", function(_, elapsed)
	local run = Inbox.run
	if not run then
		driver:Hide()
		return
	end
	wait = wait - elapsed
	if wait > 0 or run.waitingRefresh or (run.waitUntil and GetTime() < run.waitUntil) then
		return
	end
	run.waitUntil = nil
	if C_Mail.IsCommandPending() then
		wait = STEP_DELAY
		return
	end
	-- Walk past skipped mail in one frame, stop at the first command.
	for _ = 1, 60 do
		if not Inbox.run then
			return
		end
		if Step(run) then
			wait = STEP_DELAY
			return
		end
		if run.waitUntil then
			return
		end
	end
end)

function Inbox.Collect(filter, thenSend)
	if not ns.State.mailboxOpen then
		F.Print(L["Open a mailbox first."])
		return false
	end
	if ns.State.sending then
		F.Print(L["A send is already running."])
		return false
	end
	if Inbox.run then
		Stop(L["Collecting stopped."])
		return false
	end
	filter = filter or ns.db.inbox.filter
	local shown = GetInboxNumItems()
	Inbox.run = {
		filter = filter,
		wants = WANTS[filter] or WANTS[COLLECT.ALL],
		cursor = shown,
		passes = 0,
		tries = {},
		sig = {},
		failed = {},
		mails = 0,
		copper = 0,
		thenSend = thenSend,
	}
	ns.State.collecting = true
	lastMoney = GetMoney()
	wait = 0
	driver:Show()
	ns:Fire("COLLECT_STATE")
	return true
end

function Inbox.IsCollecting()
	return Inbox.run ~= nil
end

-- What the current inbox holds, for the Collect button tooltip.
function Inbox.Summary()
	local me = ns.State.playerName
	return me and ns.global.mailbox[me]
end

-- ---------------------------------------------------------------------------
-- Expiry warning
-- ---------------------------------------------------------------------------

-- Mail between characters stays 30 days, so a send we logged but the
-- recipient has not opened yet expires 30 days after it went out.
local MAIL_LIFETIME = 30 * DAY

function Inbox.ExpiringList(withinDays)
	local out = {}
	local now = time()
	local limit = now + (withinDays or 0) * DAY
	for character, box in pairs(ns.global.mailbox) do
		local expires = box.expires
		if box.incomingAt then
			local sent = box.incomingAt + MAIL_LIFETIME
			expires = expires and mathmin(expires, sent) or sent
		end
		if expires and expires <= limit and ((box.count or 0) > 0 or box.incoming) then
			out[#out + 1] = { character = character, expires = expires, count = (box.count or 0) + (box.incoming or 0) }
		end
	end
	table.sort(out, function(a, b)
		return a.expires < b.expires
	end)
	return out
end

local function WarnExpiring()
	local days = ns.global.expiryWarnDays or 0
	if days <= 0 then
		return
	end
	local list = Inbox.ExpiringList(days)
	for i = 1, #list do
		local e = list[i]
		F.Print(L["Mail on %s expires in %s (%d mail)."], Roster.Colored(e.character), F.Until(e.expires), e.count)
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

ns:RegisterEvent("MAIL_INBOX_UPDATE", function()
	scanSoon()
	local run = Inbox.run
	if run and run.waitingRefresh then
		run.waitingRefresh = false
		run.cursor = GetInboxNumItems()
	end
end)

-- While the mailbox is open and the server holds more mail than the 50 the
-- client shows, ask for a refresh each time the client allows it.
local REFRESH_EVERY = 15
local refreshTicker

local function RefreshTick()
	if not ns.State.mailboxOpen or Inbox.run or ns.State.sending then
		return
	end
	local shown, total = GetInboxNumItems()
	if (total or 0) > shown and C_Mail.CanCheckInbox() then
		CheckInbox()
	end
end

ns:RegisterEvent("MAIL_SHOW", function()
	lastMoney = GetMoney()
	if not refreshTicker and C_Timer.NewTicker then
		refreshTicker = C_Timer.NewTicker(REFRESH_EVERY, RefreshTick)
	end
	local inbox = ns.db.inbox
	if inbox.autoCollect and not (ns.db.holdShiftToDisable and _G["IsShiftKeyDown"]()) then
		-- Hold the send auto-run until collecting is done.
		ns.State.collecting = true
		ns:After(0.5, function()
			ns.State.collecting = false
			if ns.State.mailboxOpen and not ns.State.sending then
				Inbox.Collect(inbox.filter, ns.db.autoRun)
			end
		end)
	end
end)

ns:RegisterEvent("MAIL_CLOSED", function()
	if refreshTicker then
		refreshTicker:Cancel()
		refreshTicker = nil
	end
	if Inbox.run then
		Stop()
	end
	ns.State.collecting = false
end)

ns:RegisterEvent("MAIL_FAILED", function(_, itemID)
	if Inbox.run and itemID then
		Inbox.run.failed[itemID] = true
	end
end)

ns:RegisterEvent("PLAYER_MONEY", OnMoney)

ns:On("PLAYER_READY", function()
	lastMoney = GetMoney()
	ns:After(8, WarnExpiring)
end)

ns:OnInit(function()
	Items = ns:GetModule("Items")
	Roster = ns:GetModule("Roster")
	Ledger = ns:GetModule("Ledger")
	-- The locals above are the unhooked originals, so the collector notes its
	-- own takes before each command and these hooks only see other callers.
	hooksecurefunc("TakeInboxMoney", NoteTake)
	hooksecurefunc("AutoLootMailItem", NoteTake)
end)

-- Exposed for the headless tests.
Inbox._SubjectPattern = SubjectPattern
