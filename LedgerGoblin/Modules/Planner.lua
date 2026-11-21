--[[
	LedgerGoblin - Planner
	-------------------------------------------------------------------------
	Turns bags and gold settings into mail jobs:
	  1. One bag scan. Each mailable slot is resolved through Rules.
	  2. Per item, keep reserves and restock caps decide how many to send.
	  3. Items are chunked into mails of up to 12 attachments per target.
	  4. Gold (keep, fixed or percent) rides on an item mail to the same target
	     or gets its own, after postage and the repair reserve.
	Job: { target, items = { {bag, slot, link, itemID, count, sendCount} }, money }

	Postage is planned at 30c per attachment, minimum one per mail. The sender
	checks GetSendMailPrice() once each mail is staged.

	Hover paths (Send button tooltip, item tooltips) read cached results that
	are dropped when bags, money, rules or the roster change.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Planner = ns:NewModule("Planner")
local Items, Rules, Roster -- set at init

local C_Container = C_Container
local GetMoney = GetMoney
local format = string.format
local mathmin = math.min
local mathmax = math.max
local mathfloor = math.floor
local pairs = pairs
local wipe = wipe
local tsort = table.sort

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo

local MAX_ATTACHMENTS = C.MAX_ATTACHMENTS
local POSTAGE_PER_ITEM = C.POSTAGE_PER_ITEM
local GOLD_MODE = C.GOLD_MODE
local REPAIR_FALLBACK = 100 * C.COPPER_PER_GOLD

function Planner.Postage(numItems)
	return POSTAGE_PER_ITEM * mathmax(1, numItems or 0)
end

-- ---------------------------------------------------------------------------
-- Repair reserve
--   GetRepairAllCost only answers at a repair vendor and reports the current
--   damage. The highest bill seen is the closest thing to a full repair, so
--   that is what the reserve holds back.
-- ---------------------------------------------------------------------------
local function RepairReserve()
	local me = ns.State.playerName
	return (me and ns.global.repairCost[me]) or REPAIR_FALLBACK
end
Planner.RepairReserve = RepairReserve

ns:RegisterEvent("MERCHANT_SHOW", function()
	if not (_G["CanMerchantRepair"] and _G["CanMerchantRepair"]()) then
		return
	end
	local cost = _G["GetRepairAllCost"]()
	local me = ns.State.playerName
	if me and cost and F.NotSecret(cost) and cost > (ns.global.repairCost[me] or 0) then
		ns.global.repairCost[me] = cost
	end
end)

-- ---------------------------------------------------------------------------
-- Bag scan
-- ---------------------------------------------------------------------------

local function Warn(warnings, seen, msg)
	if not seen[msg] then
		seen[msg] = true
		warnings[#warnings + 1] = msg
	end
end

-- How many units of an item the target already has or has on the way. nil
-- when the target has never logged in with the addon.
function Planner.TargetHolds(target, itemID)
	local held = Items.CountOn(target, itemID)
	if held == nil then
		return nil
	end
	local box = ns.global.mailbox[target]
	if box then
		held = held + ((box.items and box.items[itemID]) or 0) + ((box.pending and box.pending[itemID]) or 0)
	end
	return held
end

-- Returns byTarget = { [target] = { entry, ... } } after keep and restock.
local function ScanBags(warnings, seen)
	local byTarget, byItem = {}, {}

	for bag = 0, Items.LAST_BAG do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local info = GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID and not info.isLocked and F.NotSecret(itemID) and F.NotSecret(info.quality) then
				local name, bindType, classID, subClassID = Items.Facts(itemID, info.hyperlink)
				local mailable, warband = Items.SlotIsMailable(bag, slot, info, bindType)
				if mailable then
					name = name or (info.hyperlink and info.hyperlink:match("%[(.-)%]"))
					local target, _, rule = Rules.Resolve(itemID, name, info.quality, bindType, warband, classID, subClassID)
					if target then
						local entry = {
							bag = bag,
							slot = slot,
							link = info.hyperlink,
							itemID = itemID,
							count = info.stackCount or 1,
							target = target,
							rule = rule,
						}
						local group = byItem[itemID]
						if not group then
							group = {}
							byItem[itemID] = group
						end
						group[#group + 1] = entry
					end
				end
			end
		end
	end

	local keep = ns.db.keep
	for itemID, group in pairs(byItem) do
		-- Whole stacks first so at most one stack needs splitting.
		tsort(group, function(a, b)
			return a.count > b.count
		end)
		local total = 0
		for i = 1, #group do
			total = total + group[i].count
		end
		local allow = total - (keep[itemID] or 0)

		local first = group[1]
		local rule = first.rule
		if rule and rule.max then
			local holds = Planner.TargetHolds(first.target, itemID)
			if holds == nil then
				Warn(warnings, seen, format(L["Restock skipped for %s. Log in on that character once so its bags are known."], first.target))
				allow = 0
			else
				allow = mathmin(allow, rule.max - holds)
			end
		end

		for i = 1, #group do
			local e = group[i]
			local s = mathmax(0, mathmin(e.count, allow))
			e.sendCount = s
			allow = allow - s
			if s > 0 then
				local list = byTarget[e.target]
				if not list then
					list = {}
					byTarget[e.target] = list
				end
				list[#list + 1] = e
			end
		end
	end
	return byTarget
end

-- ---------------------------------------------------------------------------
-- Plan
-- ---------------------------------------------------------------------------

-- jobs, abortReason, warnings. Never prints.
function Planner.Build()
	local db = ns.db
	local me = ns.State.playerName
	local warnings, seen = {}, {}
	local byTarget = ScanBags(warnings, seen)

	local function TargetOK(target)
		if target == me then
			Warn(warnings, seen, L["Skipped a rule that targets this character."])
			return false
		elseif not Roster.IsKnown(target) then
			Warn(warnings, seen, format(L["Skipped %s, not a known character on this account."], target))
			return false
		end
		return true
	end

	local jobs = {}
	local targets = {}
	for target in pairs(byTarget) do
		targets[#targets + 1] = target
	end
	tsort(targets)
	for t = 1, #targets do
		local target = targets[t]
		local items = byTarget[target]
		if TargetOK(target) and db.sendIndividually then
			-- One item type per mail. Stable order by itemID.
			local byID, ids = {}, {}
			for i = 1, #items do
				local id = items[i].itemID
				if not byID[id] then
					byID[id] = {}
					ids[#ids + 1] = id
				end
				local group = byID[id]
				group[#group + 1] = items[i]
			end
			tsort(ids)
			for k = 1, #ids do
				local group = byID[ids[k]]
				for i = 1, #group, MAX_ATTACHMENTS do
					local chunk = {}
					for j = i, mathmin(i + MAX_ATTACHMENTS - 1, #group) do
						chunk[#chunk + 1] = group[j]
					end
					jobs[#jobs + 1] = { target = target, items = chunk, money = 0 }
				end
			end
		elseif TargetOK(target) then
			for i = 1, #items, MAX_ATTACHMENTS do
				local chunk = {}
				for j = i, mathmin(i + MAX_ATTACHMENTS - 1, #items) do
					chunk[#chunk + 1] = items[j]
				end
				jobs[#jobs + 1] = { target = target, items = chunk, money = 0 }
			end
		end
	end

	local current = GetMoney()
	local moneyReadable = F.NotSecret(current)
	local gold = db.gold
	if moneyReadable and gold.enabled and gold.target ~= "" and TargetOK(gold.target) then
		local desired = 0
		if gold.mode == GOLD_MODE.KEEP then
			desired = current - (gold.keepCopper or 0)
		elseif gold.mode == GOLD_MODE.FIXED then
			desired = gold.fixedCopper or 0
		elseif gold.mode == GOLD_MODE.PERCENT then
			desired = mathfloor(current * (gold.percent or 0) / 100)
		end

		local carrier
		for i = 1, #jobs do
			if jobs[i].target == gold.target then
				carrier = jobs[i]
				break
			end
		end
		local postage = carrier and 0 or Planner.Postage(0)
		for i = 1, #jobs do
			postage = postage + Planner.Postage(#jobs[i].items)
		end
		local reserve = gold.reserveForRepairs and RepairReserve() or 0
		local send = mathmin(desired, current - reserve - postage)
		if send > 0 then
			if carrier then
				carrier.money = send
			else
				jobs[#jobs + 1] = { target = gold.target, items = {}, money = send }
			end
		end
	end

	if #jobs > 0 and moneyReadable then
		local need = 0
		for i = 1, #jobs do
			need = need + Planner.Postage(#jobs[i].items) + (jobs[i].money or 0)
		end
		if need > current then
			return jobs, L["Not enough gold to cover postage. Nothing was sent."], warnings
		end
	end
	return jobs, nil, warnings
end

function Planner.Value(jobs)
	local total = 0
	for i = 1, #jobs do
		total = total + (jobs[i].money or 0)
	end
	return total
end

function Planner.ItemCount(jobs)
	local total = 0
	for i = 1, #jobs do
		local items = jobs[i].items
		for j = 1, #items do
			total = total + (items[j].sendCount or items[j].count or 1)
		end
	end
	return total
end

-- ---------------------------------------------------------------------------
-- Cached summary for hover tooltips
-- ---------------------------------------------------------------------------

local summary -- { units, copper, mails, warnings, abort }

function Planner.Summary()
	if not summary then
		local jobs, abort, warnings = Planner.Build()
		summary = {
			units = Planner.ItemCount(jobs),
			copper = Planner.Value(jobs),
			mails = #jobs,
			warnings = warnings,
			abort = abort,
		}
	end
	return summary
end

-- ---------------------------------------------------------------------------
-- Tooltip preview
--   status: "excluded", "notmailable" (reason), "routed" (target, category,
--   rule) or "none". One bag pass per bag change answers "do I hold a
--   mailable copy?" for every item, instead of a bag scan per hovered item.
-- ---------------------------------------------------------------------------

local preview = {} -- itemID -> { status, a, b, c }
local held -- itemID -> true (mailable copy) | false (only bound copies)

local function BuildHeld()
	held = {}
	for bag = 0, Items.LAST_BAG do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local info = GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID and not info.isLocked and F.NotSecret(itemID) and held[itemID] ~= true then
				local _, bindType = Items.Facts(itemID, info.hyperlink)
				held[itemID] = Items.SlotIsMailable(bag, slot, info, bindType)
			end
		end
	end
end

function Planner.PreviewTarget(itemID, link)
	if not itemID or F.IsSecret(itemID) then
		return "none"
	end
	local cached = preview[itemID]
	if cached then
		return cached[1], cached[2], cached[3], cached[4]
	end

	local status, a, b, c = "none", nil, nil, nil
	if ns.db.exclusions[itemID] then
		status = "excluded"
	else
		if not held then
			BuildHeld()
		end
		local name, bindType, classID, subClassID, quality = Items.Facts(itemID, link)
		local mailable, reason = held[itemID], nil
		if mailable == nil then
			mailable, _, reason = Rules.IsRoutable(itemID)
		elseif mailable == false then
			reason = L["it's soulbound to this character"]
		end
		if not mailable then
			status, a = "notmailable", reason
		else
			local warband = bindType ~= nil and Items.IDIsWarband(itemID, bindType) or false
			local target, category, rule = Rules.Resolve(itemID, name, quality, bindType, warband, classID, subClassID)
			if target then
				status, a, b, c = "routed", target, category, rule
			end
		end
		-- An uncached item answers "none" now and the real answer next hover.
		if not name then
			return status, a, b, c
		end
	end
	preview[itemID] = { status, a, b, c }
	return status, a, b, c
end

local function Dirty()
	summary = nil
end

local function BagsChanged()
	summary = nil
	held = nil
	wipe(preview)
end

local function RulesChanged()
	BagsChanged()
end

ns:OnInit(function()
	Items = ns:GetModule("Items")
	Rules = ns:GetModule("Rules")
	Roster = ns:GetModule("Roster")
end)

ns:RegisterEvent("BAG_UPDATE_DELAYED", BagsChanged)
ns:RegisterEvent("PLAYER_MONEY", Dirty)
ns:On("RULES_CHANGED", RulesChanged)
ns:On("ROSTER_CHANGED", Dirty)
ns:On("MAILBOX_CHANGED", Dirty)
