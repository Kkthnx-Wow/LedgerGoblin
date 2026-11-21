--[[
	LedgerGoblin - Attach
	-------------------------------------------------------------------------
	With the Send Mail tab open, alt-click a bag item to attach every unlocked
	stack of that item, up to the free attachment slots. Bag buttons built on
	ContainerFrameItemButtonTemplate call HandleModifiedItemClick with the
	item location on any modified click, so a secure post-hook on it sees the
	click without touching the button.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local C_Container = C_Container
local ClickSendMailItemButton = ClickSendMailItemButton
local HasSendMailItem = HasSendMailItem
local ClearCursor = ClearCursor
local CursorHasItem = CursorHasItem
local IsAltKeyDown = IsAltKeyDown
local hooksecurefunc = hooksecurefunc

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local PickupContainerItem = C_Container.PickupContainerItem

local MAX_ATTACHMENTS = C.MAX_ATTACHMENTS

local function NextFreeSlot()
	for i = 1, MAX_ATTACHMENTS do
		if not HasSendMailItem(i) then
			return i
		end
	end
	return nil
end

local function AttachAll(itemID)
	local Items = ns:GetModule("Items")
	local added = 0
	for bag = 0, Items.LAST_BAG do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local info = GetContainerItemInfo(bag, slot)
			if info and info.itemID == itemID and not info.isLocked then
				local free = NextFreeSlot()
				if not free then
					if added == 0 then
						F.Print(L["All attachment slots are full."])
					end
					return added
				end
				PickupContainerItem(bag, slot)
				ClickSendMailItemButton(free)
				if CursorHasItem() then
					-- The client refused it (soulbound, quest item).
					ClearCursor()
					return added
				end
				added = added + 1
			end
		end
	end
	return added
end

local function OnModifiedClick(_, itemLocation)
	if not (ns.db and ns.db.altClickAttach and IsAltKeyDown()) then
		return
	end
	local sendFrame = _G["SendMailFrame"]
	if not (sendFrame and sendFrame:IsVisible()) or ns.State.sending then
		return
	end
	if not (itemLocation and itemLocation.IsBagAndSlot and itemLocation:IsBagAndSlot()) then
		return
	end
	local bag, slot = itemLocation:GetBagAndSlot()
	local info = GetContainerItemInfo(bag, slot)
	if info and info.itemID and F.NotSecret(info.itemID) then
		AttachAll(info.itemID)
	end
end

ns:OnInit(function()
	if type(_G["HandleModifiedItemClick"]) == "function" then
		hooksecurefunc("HandleModifiedItemClick", OnModifiedClick)
	end
end)
