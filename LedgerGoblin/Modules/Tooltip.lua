--[[
	LedgerGoblin - Tooltip
	-------------------------------------------------------------------------
	Item tooltips say where LedgerGoblin would mail the item, or that it is
	excluded. Unrouted items stay quiet. Answers come from the planner's cached
	preview, so hovering does not rescan bags.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Planner, Roster -- set at init

local GameTooltip = GameTooltip
local format = string.format
local GREEN = C.GreenRGB

local CATEGORY_TAG = {
	type = L["item type rule"],
	boe = L["Bind on Equip rule"],
	boa = L["warband rule"],
	quality = L["quality rule"],
}

local function AppendHint(tip, data)
	if tip ~= GameTooltip or not (data and data.id) or not ns.db.tooltipHints then
		return
	end
	local status, target, category, rule = Planner.PreviewTarget(data.id, data.hyperlink)
	if status == "routed" then
		local line = format(L["routes to %s"], "|c" .. Roster.ClassHex(target) .. F.MailRecipient(target) .. "|r")
		local tag = CATEGORY_TAG[category]
		if tag then
			line = line .. " |cff999999(" .. tag .. ")|r"
		elseif rule and rule.max then
			local holds = Planner.TargetHolds(target, data.id)
			line = line .. " |cff999999(" .. format(L["restock to %d, has %s"], rule.max, holds and tostring(holds) or "?") .. ")|r"
		end
		tip:AddLine(C.Title .. ": " .. line, GREEN[1], GREEN[2], GREEN[3])
	elseif status == "excluded" then
		tip:AddLine(C.Title .. ": " .. L["excluded from mailing"], 1, 0.3, 0.3)
	end
end

ns:OnInit(function()
	Planner = ns:GetModule("Planner")
	Roster = ns:GetModule("Roster")
	local processor = _G["TooltipDataProcessor"]
	if processor and processor.AddTooltipPostCall and Enum.TooltipDataType then
		processor.AddTooltipPostCall(Enum.TooltipDataType.Item, AppendHint)
	end
end)
