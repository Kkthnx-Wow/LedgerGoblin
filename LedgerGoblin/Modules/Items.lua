--[[
	LedgerGoblin - Items
	-------------------------------------------------------------------------
	Item facts the rules need: name, bind type, item class and subclass, and
	whether a bound item is warband bound (so it can still go to an alt). Also
	owns bag iteration and the per-character inventory snapshot restock rules
	read.

	Static facts are cached per itemID. The cache is wiped when it passes
	CACHE_MAX entries so tooltip browsing on the auction house cannot grow it
	without bound.
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local Items = ns:NewModule("Items")

local C_Container = C_Container
local C_Item = C_Item
local C_TooltipInfo = C_TooltipInfo
local ItemLocation = ItemLocation
local Enum = Enum
local pairs = pairs
local pcall = pcall
local wipe = wipe
local time = time
local strlower = string.lower
local mathmax = math.max

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo
---@diagnostic disable-next-line: deprecated
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G["GetItemInfo"]
---@diagnostic disable-next-line: deprecated
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G["GetItemInfoInstant"]

local ACCOUNT_BOUND = C.ACCOUNT_BOUND
local CACHE_MAX = 1500

-- ---------------------------------------------------------------------------
-- Bags
-- ---------------------------------------------------------------------------

-- Backpack 0, bags 1-4 and the reagent bag 5. NUM_BAG_SLOTS counts 1-4 only.
-- A missing reagent bag reports 0 slots, so scanning it is safe.
local REAGENT_BAG = (Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
Items.LAST_BAG = mathmax(_G["NUM_BAG_SLOTS"] or 4, REAGENT_BAG)

-- Bank containers, taken from Enum.BagIndex by name so Retail bank tabs and
-- the older bank bag layout both work. Warband (account) tabs are left out,
-- they belong to every character.
local BANK_BAGS = {}
do
	local seen = {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			BANK_BAGS[#BANK_BAGS + 1] = id
		end
	end
	add(Enum.BagIndex and Enum.BagIndex.Bank or -1)
	if Enum.BagIndex then
		for key, id in pairs(Enum.BagIndex) do
			if not key:find("Account", 1, true) and (key:find("^BankBag") or key:find("^CharacterBankTab") or key == "Reagentbank") then
				add(id)
			end
		end
	end
end

function Items.FreeBagSlots()
	local free = 0
	for bag = 0, Items.LAST_BAG do
		local n = C_Container.GetContainerNumFreeSlots(bag)
		if n then
			free = free + n
		end
	end
	return free
end

-- ---------------------------------------------------------------------------
-- Static item facts
-- ---------------------------------------------------------------------------

local facts = {} -- itemID -> { name, bindType, classID, subClassID, quality }
local factCount = 0

local function Remember(itemID, fact)
	if factCount >= CACHE_MAX then
		wipe(facts)
		factCount = 0
	end
	facts[itemID] = fact
	factCount = factCount + 1
end

-- name, bindType, classID, subClassID, quality. The class comes from
-- GetItemInfoInstant and is always there. Name, bind and quality need the
-- item in the client cache. On a miss they are nil and the fact is not stored,
-- so the next call tries again.
function Items.Facts(itemID, link)
	local fact = facts[itemID]
	if fact then
		return fact[1], fact[2], fact[3], fact[4], fact[5]
	end
	local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(link or itemID)
	local name, _, quality, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(link or itemID)
	if name and bindType ~= nil then
		Remember(itemID, { name, bindType, classID, subClassID, quality })
	elseif C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
	end
	return name, bindType, classID, subClassID, quality
end

-- ---------------------------------------------------------------------------
-- Warband binding
--   Enum.ItemBind 7/8/9 covers most account items, but GetItemInfo reports
--   some warbound reagents as None or Bind on Pickup. The item tooltip names
--   the real binding, so it settles bound items the static type calls BoP.
--   Values from Enum.TooltipDataItemBinding.
-- ---------------------------------------------------------------------------
local WARBAND_BONDING = {
	[1] = true, -- Account
	[2] = true, -- BnetAccount
	[4] = true, -- BindToAccount
	[5] = true, -- BindToBnetAccount
	[9] = true, -- AccountUntilEquipped
	[10] = true, -- BindToAccountUntilEquipped
}

local WARBAND_STRINGS = {}
for _, key in pairs({ "ITEM_BIND_TO_BNETACCOUNT", "ITEM_BNETACCOUNTBOUND", "ITEM_ACCOUNTBOUND", "ITEM_BIND_TO_ACCOUNT", "ITEM_ACCOUNTBOUND_UNTIL_EQUIP", "ITEM_BIND_TO_ACCOUNT_UNTIL_EQUIP" }) do
	local s = _G[key]
	if s then
		WARBAND_STRINGS[s] = true
	end
end

local function TooltipSaysWarband(data)
	local lines = data and data.lines
	if not lines then
		return false
	end
	for i = 1, #lines do
		local line = lines[i]
		if (line.bonding and WARBAND_BONDING[line.bonding]) or (line.leftText and WARBAND_STRINGS[line.leftText]) then
			return true
		end
	end
	return false
end

-- Only call for items the bag already reports bound.
function Items.SlotIsWarband(bag, slot, bindType)
	if bindType and ACCOUNT_BOUND[bindType] then
		return true
	end
	if C_TooltipInfo and C_TooltipInfo.GetBagItem then
		return TooltipSaysWarband(C_TooltipInfo.GetBagItem(bag, slot))
	end
	return false
end

local warbandByID = {} -- itemID -> bool, for items checked outside bags

function Items.IDIsWarband(itemID, bindType)
	if bindType and ACCOUNT_BOUND[bindType] then
		return true
	end
	local known = warbandByID[itemID]
	if known ~= nil then
		return known
	end
	local result = false
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		result = TooltipSaysWarband(C_TooltipInfo.GetItemByID(itemID))
	end
	warbandByID[itemID] = result
	return result
end

-- Can this bag slot leave the character? Unbound items (BoE included) and
-- warband items can. Soulbound and quest items cannot.
function Items.SlotIsMailable(bag, slot, info, bindType)
	if not info.isBound then
		return true, false
	end
	local warband = Items.SlotIsWarband(bag, slot, bindType)
	return warband, warband
end

-- Live answer for an item we hold. true = a mailable copy is in bags, false =
-- only bound copies, nil = not in bags. Matches by itemID or exact name.
function Items.HeldVerdict(itemID, name)
	if not (C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot) then
		return nil
	end
	local wantName = name and strlower(name)
	local verdict
	for bag = 0, Items.LAST_BAG do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local info = GetContainerItemInfo(bag, slot)
			-- A locked slot is mid-move and may report a passing binding.
			if info and not info.isLocked then
				local hit = itemID and info.itemID == itemID
				if not hit and wantName then
					local n = Items.Facts(info.itemID, info.hyperlink)
					hit = n and strlower(n) == wantName
				end
				if hit then
					local ok, bound = pcall(C_Item.IsBound, ItemLocation:CreateFromBagAndSlot(bag, slot))
					if ok then
						if not bound then
							return true
						end
						local _, bindType = Items.Facts(info.itemID, info.hyperlink)
						if Items.SlotIsWarband(bag, slot, bindType) then
							return true
						end
						verdict = false
					end
				end
			end
		end
	end
	return verdict
end

-- ---------------------------------------------------------------------------
-- Inventory snapshot (restock rules)
-- ---------------------------------------------------------------------------

local function CountInto(map, bags)
	wipe(map)
	for i = 1, #bags do
		local bag = bags[i]
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local info = GetContainerItemInfo(bag, slot)
			if info and info.itemID and F.NotSecret(info.itemID) then
				map[info.itemID] = (map[info.itemID] or 0) + (info.stackCount or 1)
			end
		end
	end
end

local CARRY_BAGS = {}
for bag = 0, Items.LAST_BAG do
	CARRY_BAGS[#CARRY_BAGS + 1] = bag
end

local function Snapshot()
	local me = ns.State.playerName
	if not (me and ns.global) then
		return nil
	end
	local inv = ns.global.inventory
	local snap = inv[me]
	if not snap then
		snap = { bags = {}, bank = {} }
		inv[me] = snap
	end
	return snap
end

local bankOpen = false

local function RefreshInventory()
	local snap = Snapshot()
	if not snap then
		return
	end
	CountInto(snap.bags, CARRY_BAGS)
	if bankOpen then
		CountInto(snap.bank, BANK_BAGS)
	end
	snap.at = time()
end

-- Bags plus last seen bank, for any character in the snapshot.
function Items.CountOn(character, itemID)
	local snap = ns.global.inventory[character]
	if not snap then
		return nil
	end
	return (snap.bags[itemID] or 0) + (snap.bank[itemID] or 0)
end

ns:On("PLAYER_READY", RefreshInventory)
ns:RegisterEvent("BAG_UPDATE_DELAYED", ns:Debounce(2, RefreshInventory))
ns:RegisterEvent("BANKFRAME_OPENED", function()
	bankOpen = true
	RefreshInventory()
end)
-- Bank slots may not be readable once the frame has closed, so the bank part
-- keeps whatever the last open-bank scan saw.
ns:RegisterEvent("BANKFRAME_CLOSED", function()
	bankOpen = false
end)
