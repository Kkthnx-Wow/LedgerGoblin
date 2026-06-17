--[[
	LedgerGoblin - Roster
	-------------------------------------------------------------------------
	WoW gives addons no clean way to enumerate every alt on an account, so we
	build the list the only reliable way: stamp the current character into an
	account-wide cache every time they log in. Over time that becomes the menu
	of valid mail targets, and the safety layer's "does this character exist?"
	check. Self-correcting: gold/lastSeen refresh on each login.
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local Roster = ns:NewModule("Roster")

local GetMoney = GetMoney
local UnitClass = UnitClass
local UnitFactionGroup = UnitFactionGroup

-- Record (or refresh) the current character in the account roster.
local function StampSelf()
	local key = F.FullName("player")
	if not key then
		return
	end
	local roster = ns.global.roster
	local entry = roster[key]
	if not entry then
		entry = {}
		roster[key] = entry
	end
	local _, classFile = UnitClass("player")
	entry.class = classFile
	entry.faction = UnitFactionGroup("player")
	local money = GetMoney()
	if F.NotSecret(money) then
		entry.gold = money -- copper; handy for analytics/UI, refreshed each login
	end
	entry.lastSeen = time()
	ns.State.playerName = key
end

-- Public: is this "Name-Realm" a valid mail target? True for auto-detected alts
-- (seen log in on this account) OR manually whitelisted cross-account alts.
function Roster.IsKnown(target)
	if not target or target == "" then
		return false
	end
	return ns.global.roster[target] ~= nil or (ns.global.manualAlts and ns.global.manualAlts[target] ~= nil)
end

-- Public: was this target hand-added (cross-account), rather than auto-detected?
-- Used to apply the extra confirmation gate before unattended sends to it.
function Roster.IsManual(target)
	return target ~= nil and target ~= "" and ns.global.manualAlts ~= nil and ns.global.manualAlts[target] ~= nil
end

-- Public: add / remove a manual cross-account target. The caller owns the
-- confirmation friction (these bypass auto-detection); we just store the key.
function Roster.AddManual(target)
	if not target or target == "" then
		return false
	end
	ns.global.manualAlts[target] = true
	return true
end

function Roster.RemoveManual(target)
	if target and ns.global.manualAlts then
		ns.global.manualAlts[target] = nil
	end
end

-- Public: sorted array of manual cross-account target keys.
function Roster.ManualList()
	local out = {}
	local manual = ns.global.manualAlts
	if manual then
		for key in pairs(manual) do
			out[#out + 1] = key
		end
		table.sort(out)
	end
	return out
end

-- Public: sorted array of known character keys ("Name-Realm"), excluding the
-- current character by default (you rarely mail yourself).
function Roster.List(includeSelf)
	local out = {}
	local me = ns.State.playerName
	for key in pairs(ns.global.roster) do
		if includeSelf or key ~= me then
			out[#out + 1] = key
		end
	end
	table.sort(out)
	return out
end

-- Class colours are read per dropdown entry / rule row / tooltip hint, so cache
-- the table at module scope instead of a global lookup each call. Re-grabbed on
-- login so a custom-class-colour addon that swaps the table is still respected.
local classColors = _G["RAID_CLASS_COLORS"]

-- Public: class colour hex for a roster key, for prettier dropdowns. Falls back
-- to white when the class is unknown.
function Roster.ClassHex(key)
	local entry = ns.global.roster[key]
	if entry and entry.class and classColors and classColors[entry.class] then
		return classColors[entry.class].colorStr or "ffffffff"
	end
	return "ffffffff"
end

ns:OnInit(function()
	-- DB is live; stamp now in case PLAYER_LOGIN already fired, and again on
	-- every future login.
	StampSelf()
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
	classColors = _G["RAID_CLASS_COLORS"] or classColors
	if ns.global then
		StampSelf()
	end
end)
