--[[
	LedgerGoblin - Sender
	-------------------------------------------------------------------------
	Drains a plan one mail at a time. Each mail is staged on the Send Mail tab,
	checked against GetSendMailPrice(), sent, and the queue only advances on
	MAIL_SEND_SUCCESS. MAIL_FAILED or a 10 second silence stops the run, since
	the cause (full inbox, bad name) usually repeats for the rest of the queue.

	Manual sends through Blizzard's own Send button are watched too, so mail to
	your alts is logged and counted as on its way whichever way it was sent.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Sender = ns:NewModule("Sender")
local Planner, Roster, Ledger -- set at init

local C_Container = C_Container
local GetMoney = GetMoney
local GetTime = GetTime
local GetNetStats = GetNetStats
local SetSendMailMoney = SetSendMailMoney
local ClearSendMail = ClearSendMail
local ClickSendMailItemButton = ClickSendMailItemButton
local GetSendMailItem = GetSendMailItem
local GetSendMailPrice = GetSendMailPrice
local ClearCursor = ClearCursor
local InCombatLockdown = InCombatLockdown
local IsShiftKeyDown = IsShiftKeyDown
local hooksecurefunc = hooksecurefunc
local format = string.format
local tostring = tostring
local mathrandom = math.random
local mathmin = math.min
local mathmax = math.max

-- Captured before our hook goes on, so our own sends skip the manual watcher.
local SendMail = SendMail
local PickupContainerItem = C_Container.PickupContainerItem
local SplitContainerItem = C_Container.SplitContainerItem

local SUBJECT_MAX = 31 -- the subject box limit

local SEND_COOLDOWN = { 0.5, 1.5 }
local COMPOSE_SETTLE = { 0.3, 1.0 }
local LATENCY_FACTOR = 2
local ATTACH_RETRY_DELAY = 0.5
local MAX_ATTACH_RETRIES = 2
local LOCK_TIMEOUT = 5
local CONFIRM_TIMEOUT = 10

local SUBJECT_QUIPS = {
	L["Cha-ching!"],
	L["The goblin's cut"],
	L["Profit incoming"],
	L["Mailed with greed"],
	L["Another haul"],
	L["Gold rolls downhill"],
	L["For the warband"],
	L["Goblin Express"],
	L["Special delivery"],
	L["Restock, boss"],
	L["Hot goods"],
	L["Coin counted"],
	L["Pack it up"],
	L["Goblin-approved"],
}

-- The " #N" counter commits only on a confirmed send, so failures never burn
-- a number.
local function BuildSubject()
	local n = (ns.global.sendCount or 0) + 1
	local suffix = " #" .. n
	local quip = SUBJECT_QUIPS[mathrandom(#SUBJECT_QUIPS)]
	local room = SUBJECT_MAX - #suffix
	if #quip > room then
		quip = quip:sub(1, room)
	end
	return quip .. suffix, n
end

local tracing = false

local function trace(fmt, ...)
	if tracing then
		F.Print("|cff66ccff[trace]|r " .. fmt, ...)
	end
end

function Sender.ToggleTrace()
	tracing = not tracing
	F.Print(L["Send tracing %s."], tracing and L["on"] or L["off"])
end

-- Scales a delay with latency, clamped to a range.
local function Delay(range)
	local _, _, home, world = GetNetStats()
	local ms = mathmax(home or 0, world or 0)
	if ms <= 0 then
		return range[1]
	end
	return mathmin(range[2], mathmax(range[1], ms / 1000 * LATENCY_FACTOR))
end

local function Clear()
	ClearSendMail()
	ClearCursor()
end

-- Attachments live on the Send Mail tab. Composing on the Inbox tab sends an
-- empty letter, so switch first.
local function EnsureSendTab()
	local frame = _G["MailFrame"]
	local tab = _G["MailFrameTab2"]
	local selected = frame and (_G["PanelTemplates_GetSelectedTab"] and _G["PanelTemplates_GetSelectedTab"](frame) or frame.selectedTab)
	if tab and selected ~= 2 then
		tab:Click()
		return true
	end
	return false
end

local function FillFields(recipient, subject)
	local nameBox = _G["SendMailNameEditBox"]
	local subjectBox = _G["SendMailSubjectEditBox"]
	if nameBox then
		nameBox:SetText(recipient)
	end
	if subjectBox then
		subjectBox:SetText(subject)
	end
	if _G["SendMailFrame_Update"] then
		_G["SendMailFrame_Update"]()
	end
end

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

local queue = { jobs = nil, index = 0, pending = nil, token = 0, sent = 0 }
local itemsLocked, lockedAt = false, nil

local function Finish()
	ns.State.sending = false
	itemsLocked, lockedAt = false, nil
	queue.token = queue.token + 1
	queue.jobs, queue.index, queue.pending = nil, 0, nil
	Ledger.EndRun()
	ns:Fire("SEND_STATE")
end

local ProcessNext

local function Later(seconds, jobs)
	ns:After(seconds, function()
		if ns.State.sending and queue.jobs == jobs then
			ProcessNext()
		end
	end)
end

local function Advance()
	queue.index = queue.index + 1
	ProcessNext()
end

local function CompleteCurrent()
	local job = queue.pending
	queue.pending = nil
	ns.global.sendCount = job.subjectNumber
	trace("confirmed %s (#%d)", job.target, job.subjectNumber)
	Ledger.RecordSend(job.target, job.money or 0, job.items, job.postage)
	Roster.NoteRecent(job.target)
	queue.index = queue.index + 1
	Later(Delay(SEND_COOLDOWN), queue.jobs)
end

local function FailCurrent()
	local job = queue.pending
	queue.pending = nil
	queue.token = queue.token + 1
	Clear()
	F.Print(L["Mail to %s failed. Their inbox may be full, or the name can't receive mail."], job.target)
	Finish()
end

-- Stage the job's attachments. Returns attached count, or nil when the run
-- should wait and retry.
local function Attach(job, jobs)
	local attached = 0
	for i = 1, #job.items do
		local it = job.items[i]
		local partial = it.sendCount < it.count
		if partial then
			SplitContainerItem(it.bag, it.slot, it.sendCount)
		else
			PickupContainerItem(it.bag, it.slot)
		end
		ClickSendMailItemButton(attached + 1)
		local name = GetSendMailItem(attached + 1)
		trace("attach %s x%d -> %s", tostring(it.link), it.sendCount, tostring(name))
		if not name then
			Clear()
			job.retries = (job.retries or 0) + 1
			if job.retries <= MAX_ATTACH_RETRIES then
				Later(ATTACH_RETRY_DELAY, jobs)
			else
				F.Print(L["Skipped mail to %s. Could not attach %s."], job.target, it.link or "?")
				Advance()
			end
			return nil
		end
		attached = attached + 1
	end
	return attached
end

ProcessNext = function()
	local jobs = queue.jobs
	if not jobs or queue.index > #jobs then
		Finish()
		return
	end
	local job = jobs[queue.index]
	trace("job %d/%d to %s, %d attachment(s), %s", queue.index, #jobs, job.target, #job.items, F.MoneyText(job.money))

	if itemsLocked then
		if GetTime() - lockedAt <= LOCK_TIMEOUT then
			Later(0.1, jobs)
			return
		end
		itemsLocked = false
	end
	if EnsureSendTab() then
		Later(0.1, jobs)
		return
	end
	Clear()

	local attached = Attach(job, jobs)
	if not attached then
		return
	end
	if attached == 0 and (job.money or 0) == 0 then
		Clear()
		Advance()
		return
	end
	if (job.money or 0) > 0 then
		SetSendMailMoney(job.money)
	end

	-- GetSendMailPrice covers postage and the staged money.
	local price = GetSendMailPrice()
	local money = GetMoney()
	if F.NotSecret(money) and price > money then
		Clear()
		F.Print(L["Skipped mail to %s. Not enough gold for %s plus postage."], job.target, F.Money(job.money or 0))
		Advance()
		return
	end
	job.postage = price - (job.money or 0)

	if not job.subject then
		job.subject, job.subjectNumber = BuildSubject()
	end
	local recipient = F.MailRecipient(job.target)
	FillFields(recipient, job.subject)

	queue.pending = job
	queue.token = queue.token + 1
	local token = queue.token
	ns:After(Delay(COMPOSE_SETTLE), function()
		if not (ns.State.sending and queue.pending == job and queue.token == token) then
			return
		end
		FillFields(recipient, job.subject)
		trace("SendMail(%s) price %d", recipient, price)
		SendMail(recipient, job.subject, "")
		ns:After(CONFIRM_TIMEOUT, function()
			if queue.pending == job and queue.token == token then
				queue.pending = nil
				Clear()
				F.Print(L["Mail to %s was not confirmed within %d seconds. Stopping."], job.target, CONFIRM_TIMEOUT)
				Finish()
			end
		end)
	end)
end

local function Start(jobs)
	Ledger.BeginRun()
	ns.State.sending = true
	queue.jobs, queue.index, queue.pending = jobs, 1, nil
	ns:Fire("SEND_STATE")
	if EnsureSendTab() then
		Later(0.1, jobs)
	else
		ProcessNext()
	end
end

-- ---------------------------------------------------------------------------
-- Confirmation gates
-- ---------------------------------------------------------------------------

local function ConfirmText(jobs, isAuto)
	local db = ns.db
	local value = Planner.Value(jobs)
	if isAuto then
		for i = 1, #jobs do
			if Roster.IsManual(jobs[i].target) then
				return format(L["Auto-run wants to mail the cross-account alt %s. Send %s in %d mail(s)?"], jobs[i].target, F.Money(value), #jobs)
			end
		end
	end
	if db.confirmGold then
		local threshold = (db.confirmThreshold or 0) * C.COPPER_PER_GOLD
		if threshold > 0 and value >= threshold then
			return format(L["Send %s in %d mail(s)?"], F.Money(value), #jobs)
		end
	end
	if db.confirmItems and Planner.ItemCount(jobs) > 0 then
		return format(L["Send %d item(s) in %d mail(s)?"], Planner.ItemCount(jobs), #jobs)
	end
	return nil
end

-- Why a run can't start right now, or nil.
function Sender.Blocked()
	if not ns.State.mailboxOpen then
		return L["Open a mailbox first."]
	elseif ns.State.sending then
		return L["A send is already running."]
	elseif ns.State.collecting then
		return L["Wait for the inbox to finish collecting."]
	elseif InCombatLockdown() then
		return L["Can't send mail in combat."]
	elseif ns.global.demoBackup then
		return L["Demo data is loaded. /ledger demo off first."]
	end
	return nil
end

function Sender.Run(isAuto)
	local blocked = Sender.Blocked()
	if blocked then
		if not isAuto then
			F.Print(blocked)
		end
		return false
	end
	local jobs, abort, warnings = Planner.Build()
	for i = 1, #warnings do
		F.Print(warnings[i])
	end
	if abort then
		F.Print(abort)
		return false
	end
	if #jobs == 0 then
		if not isAuto then
			F.Print(L["Nothing to route."])
		end
		return false
	end
	local prompt = ConfirmText(jobs, isAuto)
	if prompt then
		local dialog = _G["StaticPopupDialogs"]["LEDGERGOBLIN_CONFIRM_SEND"]
		dialog.text = prompt
		_G["StaticPopup_Show"]("LEDGERGOBLIN_CONFIRM_SEND", nil, nil, { jobs = jobs })
		return true
	end
	Start(jobs)
	return true
end

-- From the confirmation popup. The plan is rebuilt, since bags may have
-- changed while the popup was open.
function Sender.RunConfirmed()
	if Sender.Blocked() then
		return
	end
	local jobs, abort = Planner.Build()
	if abort or #jobs == 0 then
		F.Print(abort or L["Nothing to route."])
		return
	end
	Start(jobs)
end

function Sender.Preview()
	local jobs, _, warnings = Planner.Build()
	for i = 1, #warnings do
		F.Print(warnings[i])
	end
	Ledger.PrintPreview(jobs)
end

-- ---------------------------------------------------------------------------
-- Manual sends
--   A secure post-hook on SendMail sees Blizzard's own Send button. Staged
--   attachments are read right away, before the server clears them.
-- ---------------------------------------------------------------------------

local manual -- { target, items = { {itemID, count, link} }, money }

local function OnSendMail(recipient)
	if ns.State.sending then
		return
	end
	local target = F.NormalizeTarget(recipient)
	if not target then
		return
	end
	local items = {}
	for i = 1, C.MAX_ATTACHMENTS do
		local _, itemID, _, count = GetSendMailItem(i)
		if itemID then
			items[#items + 1] = { itemID = itemID, sendCount = count or 1, link = _G["GetSendMailItemLink"] and _G["GetSendMailItemLink"](i) }
		end
	end
	local money = _G["GetSendMailMoney"] and _G["GetSendMailMoney"]() or 0
	manual = { target = target, items = items, money = money, postage = GetSendMailPrice() - money }
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

ns:RegisterEvent("MAIL_SHOW", function()
	ns.State.mailboxOpen = true
	ns:Fire("MAILBOX_STATE")
	local db = ns.db
	if db.autoRun and not (db.holdShiftToDisable and IsShiftKeyDown()) then
		ns:After(0.3, function()
			if ns.State.mailboxOpen and not ns.State.collecting then
				Sender.Run(true)
			end
		end)
	end
end)

ns:RegisterEvent("MAIL_CLOSED", function()
	ns.State.mailboxOpen = false
	manual = nil
	if ns.State.sending then
		Clear()
		Finish()
	end
	ns:Fire("MAILBOX_STATE")
end)

ns:RegisterEvent("MAIL_SEND_SUCCESS", function()
	if queue.pending then
		CompleteCurrent()
	elseif manual then
		local m = manual
		manual = nil
		Roster.NoteRecent(m.target)
		if Roster.IsKnown(m.target) then
			Ledger.RecordSend(m.target, m.money, m.items, m.postage)
		end
	end
end)

ns:RegisterEvent("MAIL_FAILED", function()
	if queue.pending then
		FailCurrent()
	end
	manual = nil
end)

ns:RegisterEvent("MAIL_LOCK_SEND_ITEMS", function()
	itemsLocked, lockedAt = true, GetTime()
end)

ns:RegisterEvent("MAIL_UNLOCK_SEND_ITEMS", function()
	itemsLocked = false
end)

ns:OnInit(function()
	Planner = ns:GetModule("Planner")
	Roster = ns:GetModule("Roster")
	Ledger = ns:GetModule("Ledger")
	hooksecurefunc("SendMail", OnSendMail)
end)

