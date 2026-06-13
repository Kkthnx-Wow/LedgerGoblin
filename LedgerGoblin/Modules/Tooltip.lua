--[[
	LedgerGoblin - Tooltip
	-------------------------------------------------------------------------
	Surfaces the engine's routing decision on the item itself: hover anything in
	your bags and the tooltip shows where LedgerGoblin would mail it (or that
	it's excluded). The line only appears when we actually have an opinion -
	routed or excluded - so unconfigured items stay quiet.

	Retail/Midnight killed the old GameTooltip:HookScript("OnTooltipSetItem")
	path in favour of TooltipDataProcessor; we use that when present and fall
	back to the script hook for Classic flavors.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Tooltip = ns:NewModule("Tooltip")

-- Cached globals (tooltip code is on a hot, mouse-driven path).
local GameTooltip = GameTooltip
local format = string.format
local GREEN = C.GreenRGB

local C_Item = C_Item
---@diagnostic disable-next-line: deprecated
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G["GetItemInfoInstant"]

-- Which rule kind claimed the item, so a category route doesn't masquerade as a
-- specific-item rule. "item" gets no tag - that one's already self-explanatory.
local CATEGORY_TAG = {
	boe = L["Bind on Equip rule"],
	boa = L["Warband rule"],
	quality = L["quality rule"],
}

-- Add our line(s) for a resolved itemID. Kept tiny: one line, no allocations
-- beyond the format string, and only when there's something worth saying.
local function AppendHint(tip, itemID, link)
	if tip ~= GameTooltip then
		return -- ignore comparison/shopping tooltips and other frames
	end
	if not ns.db or not ns.db.tooltipHints or not itemID then
		return
	end

	local status, target, category = ns:GetModule("Engine").PreviewTarget(itemID, link)
	if status == "routed" and target then
		-- Drop the realm suffix when it's our own realm, matching how the mail
		-- actually addresses it. Colour the name by the alt's class (cached in the
		-- roster); falls back to white for alts we've never seen log in. C.Title
		-- carries the two-tone brand so the prefix matches the rest of the addon.
		local name = "|c" .. ns:GetModule("Roster").ClassHex(target) .. F.MailRecipient(target) .. "|r"
		local line = format(L["routes to %s"], name)
		-- Tag category routes so they don't read like a phantom specific rule.
		local tag = CATEGORY_TAG[category]
		if tag then
			line = line .. " |cff999999(" .. tag .. ")|r"
		end
		tip:AddLine(C.Title .. ": " .. line, GREEN[1], GREEN[2], GREEN[3])
	elseif status == "excluded" then
		tip:AddLine(C.Title .. ": " .. L["excluded from mailing"], 1, 0.3, 0.3)
	end
end

ns:OnInit(function()
	local processor = _G["TooltipDataProcessor"]
	local dataType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if processor and processor.AddTooltipPostCall and dataType then
		-- Modern path: data.id is the itemID, data.hyperlink the link.
		processor.AddTooltipPostCall(dataType, function(tip, data)
			if data then
				AppendHint(tip, data.id, data.hyperlink)
			end
		end)
		return
	end

	-- Classic fallback: parse the displayed item off the tooltip itself.
	if GameTooltip and GameTooltip.HookScript then
		GameTooltip:HookScript("OnTooltipSetItem", function(tip)
			local _, link = tip:GetItem()
			if link and GetItemInfoInstant then
				AppendHint(tip, GetItemInfoInstant(link), link)
			end
		end)
	end
end)
