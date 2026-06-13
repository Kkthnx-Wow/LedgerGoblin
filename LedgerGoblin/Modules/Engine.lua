--[[
	LedgerGoblin - Engine
	-------------------------------------------------------------------------
	The financial routing core. On a run it:
	  1. Scans bags once, classifying each item (quality + bind type, cached).
	  2. Resolves a destination per item through the category pipeline
	     (C.ROUTE_ORDER: specific item -> BoE -> BoA -> quality).
	  3. Computes gold to send (keep / fixed / percent) in copper, holding back a
	     learned repair reserve + postage.
	  4. Runs every safety gate (mailable item, known target, not self, funds).
	  5. Drains a send queue one mail at a time, advancing on MAIL_SEND_SUCCESS.

	Smart mailability: soulbound (BoP) items are skipped; Bind-on-Equip gear is
	mailable while unequipped; account/warband-bound items are mailable to your
	own alts even though the bag flags them "bound". Mail is irreversible, so
	auto-run is opt-in and the queue refuses to spend below postage + reserve.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Engine = ns:NewModule("Engine")

-- Cached globals (hot path: the scan + send loop).
local C_Container = C_Container
-- Classic exposes these as globals; retail moved them under C_Container. Resolve
-- via _G so a missing legacy global is simply nil (we fall back to C_Container).
local GetContainerNumSlotsLegacy = _G["GetContainerNumSlots"]
local GetContainerItemInfoLegacy = _G["GetContainerItemInfo"]
local PickupContainerItemLegacy = _G["PickupContainerItem"]
local ItemLocation = _G["ItemLocation"]
local GetMoney = GetMoney
local GetTime = GetTime
local GetNetStats = GetNetStats
local SendMail = SendMail
local SetSendMailMoney = SetSendMailMoney
local ClearSendMail = ClearSendMail
local ClickSendMailItemButton = ClickSendMailItemButton
local GetSendMailItem = _G["GetSendMailItem"]
local SendMailFrame_CanSend = _G["SendMailFrame_CanSend"]
local SendMailFrame_Update = _G["SendMailFrame_Update"]
local ClearCursor = ClearCursor
local InCombatLockdown = InCombatLockdown
local PanelTemplates_GetSelectedTab = _G["PanelTemplates_GetSelectedTab"]
local issecret = _G["issecretvalue"] -- Midnight only; nil elsewhere (guards handle it)
local IsShiftKeyDown = IsShiftKeyDown
local strlower = string.lower
local format = string.format
local mathmin = math.min
local mathmax = math.max
local mathfloor = math.floor
local pcall = pcall

local C_Item = C_Item
---@diagnostic disable-next-line: deprecated
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G["GetItemInfo"]

local MAX_ATTACHMENTS = C.MAX_ATTACHMENTS
local POSTAGE = C.MAIL_POSTAGE
local GOLD_MODE = C.GOLD_MODE
local QUALITY_BY_ENUM = C.QUALITY_BY_ENUM
local ROUTE_ORDER = C.ROUTE_ORDER
local ACCOUNT_BOUND = C.ACCOUNT_BOUND
local BIND_ON_EQUIP = C.BIND.ON_EQUIP
local MAIL_SUBJECT = "LedgerGoblin"

-- Breathers around SendMail. The queue is already one-in-flight and waits for
-- MAIL_SEND_SUCCESS, but the compose frame still needs a moment to digest item
-- locks, fields, and server latency. Use conservative floors, then scale up a
-- little on high-latency connections without letting the queue feel stuck.
local SEND_COOLDOWN_MIN_SECONDS = 0.5
local SEND_COOLDOWN_MAX_SECONDS = 1.5
local COMPOSE_SETTLE_MIN_SECONDS = 0.3
local COMPOSE_SETTLE_MAX_SECONDS = 1.0
local SEND_LATENCY_MULTIPLIER = 2
local ATTACH_RETRY_DELAY_SECONDS = 0.5
local MAX_ATTACH_RETRIES = 2
local SEND_ITEM_LOCK_TIMEOUT_SECONDS = 5

-- ---------------------------------------------------------------------------
-- Send-pipeline tracing
--   Off by default; /ledger trace flips it. When a batch mysteriously "gets
--   stuck", this narrates every step - attach results, money, the SendMail call,
--   and which of success/fail/timeout actually arrives - so we stop guessing and
--   see WHERE it dies. Output is gated so normal users never see the noise.
-- ---------------------------------------------------------------------------
local sendDebug = false

local function trace(fmt, ...)
	if not sendDebug then
		return
	end
	if select("#", ...) > 0 then
		F.Print("|cff66ccff[trace]|r " .. fmt, ...)
	else
		F.Print("|cff66ccff[trace]|r " .. fmt)
	end
end

local function LatencyDelay(minSeconds, maxSeconds)
	if not GetNetStats then
		return minSeconds
	end

	local _, _, homeMs, worldMs = GetNetStats()
	local latencyMs = mathmax(homeMs or 0, worldMs or 0)
	if latencyMs <= 0 then
		return minSeconds
	end

	local latencySeconds = (latencyMs / 1000) * SEND_LATENCY_MULTIPLIER
	return mathmin(maxSeconds, mathmax(minSeconds, latencySeconds))
end

local function ComposeSettleDelay()
	return LatencyDelay(COMPOSE_SETTLE_MIN_SECONDS, COMPOSE_SETTLE_MAX_SECONDS)
end

local function SendCooldownDelay()
	return LatencyDelay(SEND_COOLDOWN_MIN_SECONDS, SEND_COOLDOWN_MAX_SECONDS)
end

local function SafeCanSend()
	if not SendMailFrame_CanSend then
		return nil
	end
	local ok, canSend = pcall(SendMailFrame_CanSend)
	if ok then
		return canSend and true or false
	end
	return nil
end

local function UpdateComposeFrame()
	if SendMailFrame_Update then
		pcall(SendMailFrame_Update)
	end
end

local function PrepareComposeFields(recipient)
	local nameBox = _G["SendMailNameEditBox"]
	if nameBox and nameBox.SetText then
		nameBox:SetText(recipient)
	end

	local subjectBox = _G["SendMailSubjectEditBox"]
	if subjectBox and subjectBox.SetText then
		subjectBox:SetText(MAIL_SUBJECT)
	end

	UpdateComposeFrame()
	return nameBox, subjectBox
end

local function TraceComposeState(label)
	local nameBox = _G["SendMailNameEditBox"]
	local subjectBox = _G["SendMailSubjectEditBox"]
	local nameText = nameBox and nameBox.GetText and nameBox:GetText() or nil
	local subjectText = subjectBox and subjectBox.GetText and subjectBox:GetText() or nil
	trace(
		"  compose %s: to=%q subject=%q canSend=%s price=%s",
		label,
		tostring(nameText or ""),
		tostring(subjectText or ""),
		tostring(SafeCanSend()),
		tostring(GetSendMailPrice and GetSendMailPrice())
	)
end

function Engine.SetSendDebug(on)
	sendDebug = on and true or false
	F.Print("|cff66ccffLedgerGoblin send tracing %s.|r", sendDebug and "ON" or "OFF")
end

function Engine.ToggleSendDebug()
	Engine.SetSendDebug(not sendDebug)
end

function Engine.IsSendDebug()
	return sendDebug
end

-- Fallback repair reserve when we've never seen this character's repair cost at
-- a vendor yet. Conservative: better to under-send gold than strand someone.
local REPAIR_FALLBACK_COPPER = 100 * C.COPPER_PER_GOLD

-- Retail moved bag APIs under C_Container; Classic flavors may still expose the
-- older globals. Normalize both shapes to the small table the scan consumes.
local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlotsLegacy
local PickupContainerItem = (C_Container and C_Container.PickupContainerItem) or PickupContainerItemLegacy
-- Splits `amount` off a stack onto the cursor (for keep-N partial sends). Retail
-- under C_Container; legacy global on older flavors. nil -> we send full stacks.
local SplitContainerItem = (C_Container and C_Container.SplitContainerItem) or _G["SplitContainerItem"]
local GetContainerItemInfo
if C_Container and C_Container.GetContainerItemInfo then
	GetContainerItemInfo = C_Container.GetContainerItemInfo
else
	GetContainerItemInfo = function(bag, slot)
		local _, count, locked, quality, _, _, link, _, hasNoValue, itemID, isBound = GetContainerItemInfoLegacy(bag, slot)
		if not itemID and not link then
			return nil
		end
		return {
			stackCount = count,
			isLocked = locked,
			quality = quality,
			hyperlink = link,
			hasNoValue = hasNoValue,
			itemID = itemID,
			isBound = isBound,
		}
	end
end

-- Carry inventory runs backpack(0) -> the four bag slots(1-4) -> the reagent
-- bag(5). NUM_BAG_SLOTS only counts 1-4, so on its own it SKIPS the reagent bag -
-- which is exactly where ore/herbs/lumber live. Include it explicitly; an empty
-- reagent-bag slot just reports 0 slots, so scanning it is always safe.
local REAGENTBAG_CONTAINER = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
local function LastBag()
	return mathmax(_G["NUM_BAG_SLOTS"] or 4, REAGENTBAG_CONTAINER)
end

-- ---------------------------------------------------------------------------
-- Item classification (cached)
--   bindType + clean name never change for an itemID, so cache by itemID. A
--   miss (GetItemInfo not cached yet) returns nil bindType; the caller then
--   leaves bind-based decisions for the next run rather than guessing.
-- ---------------------------------------------------------------------------
local bindCache = {} -- itemID -> bindType (number)
local nameCache = {} -- itemID -> localized name (string)

local function ClassifyItem(itemID, link)
	local bindType = bindCache[itemID]
	local name = nameCache[itemID]
	if bindType ~= nil and name ~= nil then
		return name, bindType
	end

	-- GetItemInfo: name is [1], bindType is [14]. Index the result table directly
	-- so a miscounted placeholder can't silently read the wrong field (only runs
	-- on a cache miss, then the value is cached). Pass the link when we have it.
	local data = { GetItemInfo(link or itemID) }
	local n = data[1]
	local bt = data[14]
	if n then
		nameCache[itemID] = n
		name = n
	end
	if bt ~= nil then
		bindCache[itemID] = bt
		bindType = bt
	end
	return name, bindType
end

-- Can this item leave for another character at all?
--   * not bound             -> yes (includes BoE gear still in your bags)
--   * account/warband bound  -> yes (goes to your own alts)
--   * soulbound (BoP) / quest -> no
-- The mailability test is `(not isBound) or <account-bound>`, where the
-- account-bound half uses the tooltip-backed helpers below because GetItemInfo's
-- static bindType can't be trusted for Warbound reagents (see next comment).
--
-- Enum.ItemBind 7/8/9 (the static bindType) catches most account/warband items,
-- but GetItemInfo flat-out lies about a pile of Warbound reagents & trade goods
-- (Arden Lumber, looking at you) - reporting None/BoP for things the game itself
-- labels "Warbound". When the fast path is unsure we fall back to the item's
-- actual tooltip, which doesn't lie. Truth source: Enum.TooltipDataItemBinding.
local C_TooltipInfo = C_TooltipInfo
local WARBAND_BONDING = {
	[1] = true, -- Account ("Warbound")
	[2] = true, -- BnetAccount (legacy)
	[4] = true, -- BindToAccount (legacy)
	[5] = true, -- BindToBnetAccount ("Binds to Warband")
	[9] = true, -- AccountUntilEquipped ("Warbound until equipped")
	[10] = true, -- BindToAccountUntilEquipped ("Binds to Warband until equipped")
}

-- Localized binding strings, in case a tooltip line lacks the numeric `bonding`
-- field on some client. Built once from Blizzard's own globals so we stay
-- locale-safe instead of hard-coding English.
local WARBAND_STRINGS = {}
do
	local keys = {
		"ITEM_BIND_TO_BNETACCOUNT",
		"ITEM_BNETACCOUNTBOUND",
		"ITEM_ACCOUNTBOUND",
		"ITEM_BIND_TO_ACCOUNT",
	}
	for i = 1, #keys do
		local s = _G[keys[i]]
		if s then
			WARBAND_STRINGS[s] = true
		end
	end
end

-- Does this tooltip data describe a Warband/account-bound item (mailable to your
-- own alts)? Soulbound / BoP lines deliberately do NOT match.
local function TooltipSaysWarband(data)
	if not (data and data.lines) then
		return false
	end
	local lines = data.lines
	for i = 1, #lines do
		local line = lines[i]
		if line then
			if line.bonding and WARBAND_BONDING[line.bonding] then
				return true
			end
			local text = line.leftText
			if text and WARBAND_STRINGS[text] then
				return true
			end
		end
	end
	return false
end

-- Account/warband-bound verdict for a bag slot: trust the static bindType first
-- (cheap), then confirm via tooltip for the reagents GetItemInfo fibs about.
-- Only call this for items already known to be bound - no point tooltip-scanning
-- the entire bag.
local function IsBagSlotAccountBound(bag, slot, bindType)
	if bindType and ACCOUNT_BOUND[bindType] then
		return true
	end
	if C_TooltipInfo and C_TooltipInfo.GetBagItem then
		return TooltipSaysWarband(C_TooltipInfo.GetBagItem(bag, slot))
	end
	return false
end

-- Same idea for an item we only have an ID for (rule typed/pasted, not in bags).
local function IsItemIDAccountBound(itemID, bindType)
	if bindType and ACCOUNT_BOUND[bindType] then
		return true
	end
	if itemID and C_TooltipInfo and C_TooltipInfo.GetItemByID then
		return TooltipSaysWarband(C_TooltipInfo.GetItemByID(itemID))
	end
	return false
end

-- Blizzard's item APIs answer binding from a real inventory location. Prefer
-- that when a typed/dragged/shift-clicked item is currently in bags, because it
-- reflects the exact physical item (soulbound or not) instead of only the static
-- GetItemInfo bind type. Matches by itemID when we have one, otherwise by exact
-- (localized) name so name rules get the same live verdict.
--   Returns: true (mailable), false (soulbound -> blocked), or nil (not in bags).
local function IsInventoryMatchRoutable(itemID, name)
	if not (C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot) then
		return nil
	end

	local wantName = name and strlower(name)

	for bag = 0, LastBag() do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = GetContainerItemInfo(bag, slot)
			-- Skip locked slots: an item mid-move / pending a server action can
			-- report a transient binding. Fall through to another copy or to the
			-- static bind type rather than trust it.
			if info and not info.isLocked then
				local hit = itemID and info.itemID == itemID
				if not hit and wantName then
					local n = ClassifyItem(info.itemID, info.hyperlink)
					hit = n and strlower(n) == wantName
				end
				if hit then
					local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
					local ok, isBound = pcall(C_Item.IsBound, loc)
					if not ok then
						return nil
					end
					if not isBound then
						return true
					end

					local _, bindType = ClassifyItem(info.itemID, info.hyperlink)
					if IsBagSlotAccountBound(bag, slot, bindType) then
						return true
					end

					return false
				end
			end
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Rule resolution (priority pipeline)
-- ---------------------------------------------------------------------------

-- Per-category resolvers, keyed by the names in C.ROUTE_ORDER. Each returns a
-- target string or nil. Adding a category = add a key here + list it in ROUTE_ORDER.
local resolvers = {
	item = function(db, itemID, name)
		local rules = db.itemRules
		for i = 1, #rules do
			local rule = rules[i]
			local match = rule.match
			-- enabled defaults to true; only an explicit false disables a rule.
			if rule.enabled ~= false and match ~= nil and rule.target and rule.target ~= "" then
				if type(match) == "number" then
					if match == itemID then
						return rule.target
					end
				elseif name and strlower(match) == strlower(name) then
					return rule.target
				end
			end
		end
	end,

	boe = function(db, _, _, _, bindType)
		if bindType == BIND_ON_EQUIP then
			local b = db.bind.boe
			if b.enabled and b.target ~= "" then
				return b.target
			end
		end
	end,

	boa = function(db, _, _, _, bindType, accountBound)
		if accountBound or (bindType and ACCOUNT_BOUND[bindType]) then
			local b = db.bind.boa
			if b.enabled and b.target ~= "" then
				return b.target
			end
		end
	end,

	quality = function(db, _, _, quality)
		local qkey = quality and QUALITY_BY_ENUM[quality]
		if qkey then
			local q = db.quality[qkey]
			if q and q.enabled and q.target ~= "" then
				return q.target
			end
		end
	end,
}

-- Resolve a destination for an item, walking ROUTE_ORDER and stopping at the
-- first category that claims it. Excluded items short-circuit to nil.
local function ResolveTarget(itemID, name, quality, bindType, accountBound)
	local db = ns.db
	if itemID and db.exclusions[itemID] then
		return nil
	end
	for i = 1, #ROUTE_ORDER do
		local resolver = resolvers[ROUTE_ORDER[i]]
		if resolver then
			local target = resolver(db, itemID, name, quality, bindType, accountBound)
			if target then
				return target
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Bag scan -> per-target item lists
-- ---------------------------------------------------------------------------

-- Reused scratch so a scan doesn't allocate a fresh outer table each run.
local scanByTarget = {}

local function WipeByTarget()
	for k in pairs(scanByTarget) do
		scanByTarget[k] = nil
	end
end

-- Per-itemID slot entries gathered during a scan, so the keep pass can decide
-- which slots (and how much of a split stack) to actually send. Reused scratch.
local scanByItem = {}

local function WipeByItem()
	for k in pairs(scanByItem) do
		scanByItem[k] = nil
	end
end

-- Apply each itemID's "keep at least N" reserve. Walks that item's slots and
-- marks how much to send per slot: keep whole slots toward the reserve, then
-- split the slot that straddles the boundary, then send the rest in full. An
-- entry with sendCount == 0 is dropped from its target list.
local function ApplyKeepReserves(db)
	local keep = db.keep
	if not keep then
		return
	end
	for itemID, entries in pairs(scanByItem) do
		local keepN = keep[itemID]
		if keepN and keepN > 0 then
			local remaining = keepN
			for i = 1, #entries do
				local e = entries[i]
				local count = e.count or 1
				if remaining >= count then
					e.sendCount = 0 -- keep this whole slot in bags
					remaining = remaining - count
				elseif remaining > 0 then
					e.sendCount = count - remaining -- split: leave `remaining` behind
					remaining = 0
				else
					e.sendCount = count -- send the full stack
				end
			end
		end
	end

	-- Drop fully-kept slots from their target lists.
	for target, list in pairs(scanByTarget) do
		local w = 1
		for r = 1, #list do
			local e = list[r]
			if (e.sendCount or e.count or 1) > 0 then
				list[w] = e
				w = w + 1
			end
		end
		for i = #list, w, -1 do
			list[i] = nil
		end
		if #list == 0 then
			scanByTarget[target] = nil
		end
	end
end

-- Returns scanByTarget = { [target] = { {bag, slot, link, name, itemID, count,
-- sendCount}, ... } }. sendCount defaults to the full stack; ApplyKeepReserves
-- lowers it for items under a keep reserve.
local function ScanBags()
	WipeByTarget()
	WipeByItem()

	for bag = 0, LastBag() do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = GetContainerItemInfo(bag, slot)
			if info and info.itemID and not info.isLocked then
				local quality = info.quality
				local itemID = info.itemID
				-- Secret-value guard (Midnight): never branch on a secret. At a
				-- mailbox these are plain, but the check is one cheap call.
				local safe = not (issecret and (issecret(quality) or issecret(itemID)))
				if safe then
					local name, bindType = ClassifyItem(itemID, info.hyperlink)
					-- Only bound items need the tooltip fallback; unbound stuff (incl.
					-- BoE in bags) mails freely. This keeps the scan from tooltip-poking
					-- every single bag slot - just the bound ones GetItemInfo might fib about.
					local accountBound = info.isBound and IsBagSlotAccountBound(bag, slot, bindType) or false
					if (not info.isBound) or accountBound then
						local matchName = name or (info.hyperlink and info.hyperlink:match("%[(.-)%]"))
						local target = ResolveTarget(itemID, matchName, quality, bindType, accountBound)
						if target then
							local list = scanByTarget[target]
							if not list then
								list = {}
								scanByTarget[target] = list
							end
							local entry = {
								bag = bag,
								slot = slot,
								link = info.hyperlink,
								name = matchName,
								itemID = itemID,
								count = info.stackCount or 1,
								sendCount = info.stackCount or 1,
							}
							list[#list + 1] = entry
							local byItem = scanByItem[itemID]
							if not byItem then
								byItem = {}
								scanByItem[itemID] = byItem
							end
							byItem[#byItem + 1] = entry
						end
					end
				end
			end
		end
	end

	ApplyKeepReserves(ns.db)
	return scanByTarget
end

-- ---------------------------------------------------------------------------
-- Repair-reserve learning
--   GetRepairAllCost only returns a real number at a vendor, so capture it on
--   MERCHANT_SHOW and remember it per character. The reserve then reflects this
--   character's actual full-repair bill instead of a flat guess.
-- ---------------------------------------------------------------------------
local function CurrentRepairReserve()
	local me = ns.State.playerName
	local learned = me and ns.global.repairCost[me]
	return learned or REPAIR_FALLBACK_COPPER
end

ns:RegisterEvent("MERCHANT_SHOW", function()
	if not (ns.global and CanMerchantRepair and CanMerchantRepair()) then
		return
	end
	local cost = GetRepairAllCost and GetRepairAllCost()
	local me = ns.State.playerName
	if me and cost and cost > 0 and not (issecret and issecret(cost)) then
		ns.global.repairCost[me] = cost
	end
end)

-- ---------------------------------------------------------------------------
-- Plan building (items -> mail jobs, plus the gold calculation)
-- ---------------------------------------------------------------------------

-- Accumulate a warning once per distinct message (dedupes per-target spam).
local function Warn(warnings, seen, msg)
	if not seen[msg] then
		seen[msg] = true
		warnings[#warnings + 1] = msg
	end
end

-- Build the ordered job list. Each job: { target, items = {...}, money = copper }.
-- Returns jobs, abortReason (string or nil), warnings (array, may be empty).
-- BuildPlan never prints; callers decide whether to surface warnings (Run/Preview
-- do; the hover Summarize stays silent).
local function BuildPlan()
	local db = ns.db
	local Roster = ns:GetModule("Roster")
	local me = ns.State.playerName

	local byTarget = ScanBags()

	local warnings = {}
	local seen = {}

	-- Validate item targets and chunk into <=MAX_ATTACHMENTS mails.
	local jobs = {}
	for target, items in pairs(byTarget) do
		if target == me then
			Warn(warnings, seen, L["Skipped: cannot send to yourself."])
		elseif not Roster.IsKnown(target) then
			Warn(warnings, seen, format(L["Skipped: target '%s' is not a known character on this account."], target))
		else
			for i = 1, #items, MAX_ATTACHMENTS do
				local chunk = {}
				for j = i, mathmin(i + MAX_ATTACHMENTS - 1, #items) do
					chunk[#chunk + 1] = items[j]
				end
				jobs[#jobs + 1] = { target = target, items = chunk, money = 0 }
			end
		end
	end

	-- Gold routing (all copper). GetMoney can be a Secret in combat (Midnight);
	-- never do the arithmetic on a secret value.
	local gold = db.gold
	local current = GetMoney()
	local moneyReadable = not (issecret and issecret(current))
	if moneyReadable and gold.enabled and gold.target and gold.target ~= "" then
		local goldTarget = gold.target
		if goldTarget == me then
			Warn(warnings, seen, L["Skipped: cannot send to yourself."])
		elseif not Roster.IsKnown(goldTarget) then
			Warn(warnings, seen, format(L["Skipped: target '%s' is not a known character on this account."], goldTarget))
		else
			local desired = 0
			if gold.mode == GOLD_MODE.KEEP then
				desired = current - (gold.keepCopper or 0)
			elseif gold.mode == GOLD_MODE.FIXED then
				desired = gold.fixedCopper or 0
			elseif gold.mode == GOLD_MODE.PERCENT then
				desired = mathfloor(current * (gold.percent or 0) / 100)
			end

			-- Will this gold ride on an existing item mail, or need its own?
			local carrier
			for i = 1, #jobs do
				if jobs[i].target == goldTarget then
					carrier = jobs[i]
					break
				end
			end
			local mailsForPostage = #jobs + (carrier and 0 or 1)
			local postageTotal = mailsForPostage * POSTAGE
			local reserve = gold.reserveForRepairs and CurrentRepairReserve() or 0
			local available = current - reserve - postageTotal
			local sendCopper = mathmin(desired, available)

			if sendCopper and sendCopper > 0 then
				if carrier then
					carrier.money = sendCopper
				else
					jobs[#jobs + 1] = { target = goldTarget, items = {}, money = sendCopper }
				end
			end
		end
	end

	if #jobs == 0 then
		return jobs, nil, warnings
	end

	-- Final funds gate: postage for every mail + attached money must be covered.
	-- Skip the check if money is secret (can't compare) - the per-mail guard in
	-- ProcessNext still protects each send.
	if moneyReadable then
		local postageTotal = #jobs * POSTAGE
		local moneyTotal = 0
		for i = 1, #jobs do
			moneyTotal = moneyTotal + (jobs[i].money or 0)
		end
		if postageTotal + moneyTotal > current then
			return jobs, L["Not enough gold to cover postage; aborting."], warnings
		end
	end

	return jobs, nil, warnings
end

-- Print accumulated BuildPlan warnings (used by Run/Preview, not by hover).
local function FlushWarnings(warnings)
	if not warnings then
		return
	end
	for i = 1, #warnings do
		F.Print(warnings[i])
	end
end

-- Total gold value (copper) a plan moves, for the confirmation threshold.
local function PlanValue(jobs)
	local total = 0
	for i = 1, #jobs do
		total = total + (jobs[i].money or 0)
	end
	return total
end

-- ---------------------------------------------------------------------------
-- Send queue (event-driven; one mail in flight at a time)
-- ---------------------------------------------------------------------------

-- The mailbox opens on the Inbox tab. Attachment slots live on the Send Mail
-- tab (tab 2), so if we compose while Inbox is showing, ClickSendMailItemButton
-- has nowhere to attach - the items never stick and SendMail fires an empty
-- letter (the "it made the sound but sent nothing" bug). Force the Send tab.
local function EnsureSendTab()
	local MailFrame = _G["MailFrame"]
	local tab = _G["MailFrameTab2"]
	local selectedTab = MailFrame and ((PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(MailFrame)) or MailFrame.selectedTab or MailFrame.activeTab)
	if MailFrame and tab and tab.Click and selectedTab ~= 2 then
		tab:Click()
		return true
	end
	return false
end

local queue = { jobs = nil, index = 0, pending = nil, token = 0 }
local sendItemsLocked = false
local sendItemsLockStartedAt = nil

local function FinishRun()
	ns.State.sending = false
	sendItemsLocked = false
	sendItemsLockStartedAt = nil
	queue.token = queue.token + 1
	queue.jobs = nil
	queue.index = 0
	queue.pending = nil
	ns:GetModule("Logger").EndRun()
end

local ProcessNext -- forward decl

local function CompleteCurrent()
	local job = queue.pending
	if not job then
		return
	end
	queue.pending = nil
	trace("CompleteCurrent: %s confirmed; advancing to job %d", tostring(job.target), queue.index + 1)
	ns:GetModule("Logger").RecordMail(job.target, job.money or 0, job.items)
	queue.index = queue.index + 1
	-- Pace the next mail instead of slamming SendMail the moment success lands;
	-- bail if the run was cancelled (mailbox closed) during the wait.
	local cooldownDelay = SendCooldownDelay()
	trace("  next mail cooldown: %.2fs", cooldownDelay)
	ns:After(cooldownDelay, function()
		if ns.State.sending then
			ProcessNext()
		end
	end)
end

-- Blizzard rejected the send (recipient inbox full, unknown/cross-realm name,
-- etc.). Bump the token so the pending timeout can't also fire, drop the staged
-- mail, report it, and stop the run - the cause usually recurs for the rest of
-- the queue, so draining further would just spam failures.
local function FailCurrent()
	local job = queue.pending
	if not job then
		return
	end
	queue.pending = nil
	queue.token = queue.token + 1
	if ClearSendMail then
		ClearSendMail()
	end
	ClearCursor()
	F.Print(L["Mail to %s failed (inbox full, or the name/realm can't receive mail)."], job.target)
	FinishRun()
end

ProcessNext = function()
	local jobs = queue.jobs
	if not jobs or queue.index > #jobs then
		trace("ProcessNext: queue drained (index=%s, #jobs=%s) -> FinishRun", tostring(queue.index), tostring(jobs and #jobs))
		FinishRun()
		return
	end

	local job = jobs[queue.index]
	trace("ProcessNext: job %d/%d -> %s | %d item(s), money=%s", queue.index, #jobs, tostring(job.target), #job.items, tostring(job.money or 0))

	if sendItemsLocked then
		local now = GetTime and GetTime() or 0
		if sendItemsLockStartedAt and now - sendItemsLockStartedAt > SEND_ITEM_LOCK_TIMEOUT_SECONDS then
			trace("  send items still locked after %.1fs; proceeding anyway", now - sendItemsLockStartedAt)
			sendItemsLocked = false
			sendItemsLockStartedAt = nil
		else
			trace("  send items locked; waiting 0.1s before composing")
			ns:After(0.1, function()
				if ns.State.sending and queue.jobs == jobs then
					ProcessNext()
				end
			end)
			return
		end
	end

	if EnsureSendTab() then -- guards against the frame flipping back to Inbox
		trace("  not on Send Mail tab; switched, retrying in 0.1s")
		ns:After(0.1, function()
			if ns.State.sending then
				ProcessNext()
			end
		end)
		return
	end
	ClearCursor()
	if ClearSendMail then
		ClearSendMail()
	end

	for i = 1, #job.items do
		local it = job.items[i]
		local sendCount = it.sendCount or it.count or 1
		-- Partial stack (keep-N reserve): split the surplus onto the cursor and
		-- leave the kept remainder in the bag. Full stacks pick up whole.
		if sendCount < (it.count or 1) and SplitContainerItem then
			SplitContainerItem(it.bag, it.slot, sendCount)
		else
			PickupContainerItem(it.bag, it.slot)
		end
		ClickSendMailItemButton(i)
		if GetSendMailItem then
			local attachedName = GetSendMailItem(i)
			trace("  attach slot %d: %s (bag %s slot %s) -> GetSendMailItem=%s", i, tostring(it.link or it.name), tostring(it.bag), tostring(it.slot), tostring(attachedName))
			if not attachedName then
				if ClearSendMail then
					ClearSendMail()
				end
				ClearCursor()
				job.attachRetries = (job.attachRetries or 0) + 1
				trace("  attach FAILED (retry %d/%d)", job.attachRetries, MAX_ATTACH_RETRIES)
				if job.attachRetries <= MAX_ATTACH_RETRIES then
					-- No SendMail happened yet, so retrying this same chunk is safe.
					-- Usually this is a momentary item lock/server lag tantrum.
					ns:After(ATTACH_RETRY_DELAY_SECONDS, function()
						if ns.State.sending and queue.jobs == jobs and queue.index <= #jobs then
							ProcessNext()
						end
					end)
				else
					F.Print(L["Skipped mail to %s: could not attach %s."], job.target, it.link or it.name or "?")
					queue.index = queue.index + 1
					ProcessNext()
				end
				return
			end
		else
			trace("  attach slot %d: %s (no GetSendMailItem API - cannot verify)", i, tostring(it.link or it.name))
		end
	end

	if job.money and job.money > 0 then
		SetSendMailMoney(job.money)
		trace("  SetSendMailMoney(%d)", job.money)
	end

	-- Per-mail funds guard. Postage is flat (POSTAGE); the attached money is
	-- counted exactly once. NOTE: GetSendMailPrice() already bundles the staged
	-- SetSendMailMoney amount + postage on retail, so we must NOT add job.money
	-- to it (that double-counts the gold and wrongly skips every funded mail).
	-- BuildPlan already validated total funds; this just catches mid-run changes.
	local needed = POSTAGE + (job.money or 0)
	local money = GetMoney()
	if not (issecret and issecret(money)) and needed > money then
		if ClearSendMail then
			ClearSendMail()
		end
		ClearCursor()
		F.Print(L["Skipped mail to %s: not enough gold for %s plus postage."], job.target, F.Money(job.money or 0))
		queue.index = queue.index + 1
		ProcessNext()
		return
	end

	queue.pending = job
	-- Strip our own realm from the recipient: same-realm mail silently fails when
	-- addressed "Name-OwnRealm" (no success/fail event - it just doesn't send).
	local recipient = F.MailRecipient(job.target)
	-- Mirror the recipient into the visible To box too. SendMail's arg should be
	-- enough, but populating the field keeps Blizzard's send-validation happy and
	-- makes the open mail readable if a run ever stalls.
	local nameBox, subjectBox = PrepareComposeFields(recipient)
	trace(
		"  recipient: job.target=%s -> SendMail recipient=%s | nameBox=%s subjectBox=%s",
		tostring(job.target),
		tostring(recipient),
		nameBox and "found" or "MISSING",
		subjectBox and "found" or "MISSING"
	)
	TraceComposeState("after fields")
	local myToken = queue.token + 1
	queue.token = myToken

	-- Give Blizzard's compose frame a beat to digest attached items, money, and
	-- the recipient field before SendMail. Closing/reopening the mailbox "fixing"
	-- stuck batches is the smell this delay is here for.
	local composeDelay = ComposeSettleDelay()
	trace("  compose settle delay: %.2fs", composeDelay)
	ns:After(composeDelay, function()
		if not (ns.State.sending and queue.pending == job and queue.token == myToken) then
			trace("  settle aborted: sending=%s pending==job=%s tokenOK=%s", tostring(ns.State.sending), tostring(queue.pending == job), tostring(queue.token == myToken))
			return
		end
		-- Re-set the compose fields right before firing; nothing should have
		-- cleared them during the settle, but Blizzard's frame loves to surprise us.
		PrepareComposeFields(recipient)
		TraceComposeState("before SendMail")
		trace("  -> SendMail(%s, %q) | canSend=%s price=%s", tostring(recipient), MAIL_SUBJECT, tostring(SafeCanSend()), tostring(GetSendMailPrice and GetSendMailPrice()))
		SendMail(recipient, MAIL_SUBJECT, "")

		-- Timeout guard in case MAIL_SEND_SUCCESS never arrives. Do not record this
		-- as sent: a missing success event means Blizzard did not confirm the mail.
		ns:After(10, function()
			if queue.pending == job and queue.token == myToken then
				queue.pending = nil
				trace("  TIMEOUT: no MAIL_SEND_SUCCESS/MAIL_FAILED for %s within 10s", tostring(job.target))
				if ClearSendMail then
					ClearSendMail()
				end
				ClearCursor()
				F.Print(L["Mail to %s did not confirm within 10 seconds; stopping the run."], job.target)
				FinishRun()
			end
		end)
	end)
end

local function StartRun(jobs)
	trace("StartRun: %d job(s) queued", jobs and #jobs or 0)
	ns:GetModule("Logger").BeginRun()
	ns.State.sending = true
	queue.jobs = jobs
	queue.index = 1
	queue.pending = nil
	if EnsureSendTab() then
		ns:After(0.1, function()
			if ns.State.sending then
				ProcessNext()
			end
		end)
	else
		ProcessNext()
	end
end

-- ---------------------------------------------------------------------------
-- Public run entry points
-- ---------------------------------------------------------------------------

-- Manual / auto routing run. Returns false (with a printed reason) if it can't
-- start. Large sends (over the gold threshold) ask for confirmation first.
function Engine.Run()
	if not ns.State.mailboxOpen then
		F.Print(L["Open a mailbox first."])
		return false
	end
	if ns.State.sending then
		F.Print(L["A send is already in progress."])
		return false
	end
	if InCombatLockdown() then
		return false
	end

	local jobs, abort, warnings = BuildPlan()
	FlushWarnings(warnings)
	if abort then
		F.Print(abort)
		return false
	end
	if #jobs == 0 then
		F.Print(L["Nothing to route."])
		return false
	end

	-- Confirmation gate for big gold moves.
	local value = PlanValue(jobs)
	local threshold = (ns.db.confirmThreshold or 0) * C.COPPER_PER_GOLD
	if threshold > 0 and value >= threshold then
		local dialog = _G["StaticPopupDialogs"]["LEDGERGOBLIN_CONFIRM_SEND"]
		if dialog then
			dialog.text = format(L["Send %s and %d mail(s) now?"], F.Money(value), #jobs)
			_G["StaticPopup_Show"]("LEDGERGOBLIN_CONFIRM_SEND", nil, nil, { jobs = jobs })
			return true
		end
	end

	StartRun(jobs)
	return true
end

-- Internal: called by the confirmation popup's accept button.
function Engine.RunConfirmed(jobs)
	if ns.State.sending or not jobs then
		return
	end
	StartRun(jobs)
end

-- Dry run: build the plan and report it without sending a single mail.
function Engine.Preview()
	if not ns.State.mailboxOpen then
		F.Print(L["Open a mailbox first."])
		return
	end
	local jobs, _, warnings = BuildPlan()
	FlushWarnings(warnings)
	ns:GetModule("Logger").Preview(jobs)
end

-- For the mailbox button hover: how many items + how much gold a run would move
-- right now, plus warnings. Silent (no chat); cheap enough to call on tooltip show.
function Engine.Summarize()
	if not ns.State.mailboxOpen then
		return 0, 0
	end
	local jobs, _, warnings = BuildPlan()
	local items = 0
	for i = 1, #jobs do
		items = items + #jobs[i].items
	end
	return items, PlanValue(jobs), warnings
end

-- True when at least one routing rule could ever fire. Lets the UI disable the
-- mailbox Send button (with an explanation) when nothing is configured yet.
function Engine.HasAnyRule()
	local db = ns.db
	if not db then
		return false
	end
	if db.gold.enabled and db.gold.target ~= "" then
		return true
	end
	for _, q in pairs(db.quality) do
		if q.enabled and q.target ~= "" then
			return true
		end
	end
	for _, b in pairs(db.bind) do
		if b.enabled and b.target ~= "" then
			return true
		end
	end
	local rules = db.itemRules
	for i = 1, #rules do
		local rule = rules[i]
		if rule.enabled ~= false and rule.match ~= nil and rule.target and rule.target ~= "" then
			return true
		end
	end
	return false
end

-- Rule validation: can a rule for this match ever route to an alt? `match` may
-- be an itemID (number), an item link/string, or an exact item name. We resolve
-- it to an itemID when we can, then prefer Blizzard's live item-location binding
-- check if the item is currently in bags; otherwise we fall back to the static
-- bind type. Returns routable(bool), name, bindType.
--   Soulbound / Bind-on-Pickup and Quest items are blocked: they can never be
--   mailed off this character, so a rule for them would silently never fire.
--   bindType nil = GetItemInfo not cached yet -> fail OPEN (allow), since the
--   send-time gate still protects and we don't want to wrongly block unknown IDs.
function Engine.IsItemRoutable(match)
	-- Resolve the match to an itemID (numbers and links carry one) or, failing
	-- that, an exact name we can look up / scan bags by.
	local itemID, name
	if type(match) == "number" then
		itemID = match
	elseif type(match) == "string" then
		local id = match:match("|Hitem:(%d+)") or match:match("^item:(%d+)") or match:match("^(%d+)$")
		if id then
			itemID = tonumber(id)
		else
			name = match
		end
	end

	-- Static classification: an itemID classifies directly; a bare name resolves
	-- through GetItemInfo (only once the client has cached that item).
	local clsName, bindType
	if itemID then
		clsName, bindType = ClassifyItem(itemID, nil)
	elseif name then
		local data = { GetItemInfo(name) }
		clsName = data[1]
		bindType = data[14]
	end
	clsName = clsName or name

	-- Live inventory binding wins when the item sits in our bags right now.
	local inventoryRoutable = IsInventoryMatchRoutable(itemID, name)
	if inventoryRoutable ~= nil then
		return inventoryRoutable, clsName, bindType
	end

	if bindType == nil then
		return true, clsName, nil
	end
	if bindType == C.BIND.ON_PICKUP or bindType == C.BIND.QUEST then
		-- GetItemInfo mislabels some Warbound reagents as BoP; the tooltip is the
		-- tie-breaker before we refuse the rule.
		if IsItemIDAccountBound(itemID, bindType) then
			return true, clsName, bindType
		end
		return false, clsName, bindType
	end
	return true, clsName, bindType
end

-- Diagnostics: print why a run would (or wouldn't) route. Works anywhere - it
-- scans bags and reports each mailable item's classification + resolved target,
-- plus the gold calculation. Capped so it can't flood chat.
local DEBUG_ITEM_CAP = 40

function Engine.Debug()
	local db = ns.db
	local Roster = ns:GetModule("Roster")
	local me = ns.State.playerName
	F.Print(L["Debug - you are |cffffd200%s|r | HasAnyRule=%s | mailbox=%s"], tostring(me), tostring(Engine.HasAnyRule()), tostring(ns.State.mailboxOpen))

	local shown, mailableTotal, routedTotal, lockedTotal = 0, 0, 0, 0
	for bag = 0, LastBag() do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				if info.isLocked then
					lockedTotal = lockedTotal + 1
				end
				local name, bindType = ClassifyItem(info.itemID, info.hyperlink)
				local accountBound = info.isBound and IsBagSlotAccountBound(bag, slot, bindType) or false
				local mailable = (not info.isBound) or accountBound
				if mailable then
					mailableTotal = mailableTotal + 1
					local matchName = name or (info.hyperlink and info.hyperlink:match("%[(.-)%]"))
					local target = ResolveTarget(info.itemID, matchName, info.quality, bindType, accountBound)
					if target then
						routedTotal = routedTotal + 1
						if shown < DEBUG_ITEM_CAP then
							shown = shown + 1
							F.Print(L["%s q=%s bind=%s locked=%s -> %s"], info.hyperlink or tostring(info.itemID), tostring(info.quality), tostring(bindType), tostring(info.isLocked), target)
						end
					end
				end
			end
		end
	end
	F.Print(L["Debug - %d mailable, %d matched a rule, %d locked."], mailableTotal, routedTotal, lockedTotal)

	-- Authoritative: run the real plan and report exactly what it produced.
	local jobs, abort, warnings = BuildPlan()
	F.Print(L["Debug - BuildPlan produced |cffffd200%d|r job(s)."], #jobs)
	if abort then
		F.Print(L["Debug - abort: %s"], abort)
	end
	if warnings then
		for i = 1, #warnings do
			F.Print(L["Debug - skip: %s"], warnings[i])
		end
	end

	local g = db.gold
	local cur = GetMoney()
	if issecret and issecret(cur) then
		F.Print(L["Debug - gold value is secret right now (in combat?)."])
	else
		F.Print(L["Debug - gold enabled=%s target=%s known=%s self=%s | have %s, keep %s"], tostring(g.enabled), g.target ~= "" and g.target or "(none)", tostring(Roster.IsKnown(g.target)), tostring(g.target == me), F.Money(cur), F.Money(g.keepCopper))
	end
end

-- ---------------------------------------------------------------------------
-- Mailbox lifecycle
-- ---------------------------------------------------------------------------

ns:RegisterEvent("MAIL_SHOW", function()
	ns.State.mailboxOpen = true

	local db = ns.db
	if not db or not db.autoRun then
		return
	end
	if db.holdShiftToDisable and IsShiftKeyDown() then
		return
	end
	ns:After(0.2, function()
		if ns.State.mailboxOpen then
			Engine.Run()
		end
	end)
end)

ns:RegisterEvent("MAIL_CLOSED", function()
	ns.State.mailboxOpen = false
	if ns.State.sending then
		trace("event MAIL_CLOSED during active run -> cancelling (pending=%s, index=%s)", queue.pending and tostring(queue.pending.target) or "none", tostring(queue.index))
		if ClearSendMail then
			ClearSendMail()
		end
		ClearCursor()
		FinishRun()
	end
end)

ns:RegisterEvent("MAIL_SEND_SUCCESS", function()
	trace("event MAIL_SEND_SUCCESS (pending=%s)", queue.pending and tostring(queue.pending.target) or "none")
	if queue.pending then
		CompleteCurrent()
	end
end)

ns:RegisterEvent("MAIL_FAILED", function()
	trace("event MAIL_FAILED (pending=%s)", queue.pending and tostring(queue.pending.target) or "none")
	if queue.pending then
		FailCurrent()
	end
end)

ns:RegisterEvent("MAIL_SUCCESS", function()
	trace("event MAIL_SUCCESS (pending=%s)", queue.pending and tostring(queue.pending.target) or "none")
end)

ns:RegisterEvent("MAIL_LOCK_SEND_ITEMS", function()
	sendItemsLocked = true
	sendItemsLockStartedAt = GetTime and GetTime() or 0
	trace("event MAIL_LOCK_SEND_ITEMS")
end)

ns:RegisterEvent("MAIL_UNLOCK_SEND_ITEMS", function()
	sendItemsLocked = false
	sendItemsLockStartedAt = nil
	trace("event MAIL_UNLOCK_SEND_ITEMS")
end)

ns:RegisterEvent("MAIL_SEND_INFO_UPDATE", function()
	trace("event MAIL_SEND_INFO_UPDATE")
end)
