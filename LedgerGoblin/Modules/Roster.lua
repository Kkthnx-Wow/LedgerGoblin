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
	entry.gold = GetMoney() -- copper; handy for analytics/UI, refreshed each login
	entry.lastSeen = time()
	ns.State.playerName = key
end

-- Public: is this "Name-Realm" a character we've seen on this account?
function Roster.IsKnown(target)
	if not target or target == "" then
		return false
	end
	return ns.global.roster[target] ~= nil
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

-- Public: class colour hex for a roster key, for prettier dropdowns. Falls back
-- to white when the class is unknown.
function Roster.ClassHex(key)
	local entry = ns.global.roster[key]
	local colors = _G["RAID_CLASS_COLORS"]
	if entry and entry.class and colors and colors[entry.class] then
		return colors[entry.class].colorStr or "ffffffff"
	end
	return "ffffffff"
end

ns:OnInit(function()
	-- DB is live; stamp now in case PLAYER_LOGIN already fired, and again on
	-- every future login.
	StampSelf()
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
	if ns.global then
		StampSelf()
	end
end)
