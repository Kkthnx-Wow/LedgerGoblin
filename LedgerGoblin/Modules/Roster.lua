--[[
	LedgerGoblin - Roster
	-------------------------------------------------------------------------
	The game has no list of a player's alts, so every login stamps the
	character into an account-wide roster. That roster is the menu of mail
	targets and the "is this one of mine?" safety check. Gold is refreshed on
	PLAYER_MONEY so the account total stays current. Recently mailed names are
	kept in a short list for the recipient menu.
--]]

local _, ns = ...
local F = ns.F

local Roster = ns:NewModule("Roster")

local GetMoney = GetMoney
local UnitClass = UnitClass
local UnitFactionGroup = UnitFactionGroup
local time = time
local pairs = pairs
local tsort = table.sort

local RECENT_MAX = 15

local function Entry(key)
	local roster = ns.global.roster
	local entry = roster[key]
	if not entry then
		entry = {}
		roster[key] = entry
	end
	return entry
end

local function StoreGold()
	local me = ns.State.playerName
	if not me then
		return
	end
	local money = GetMoney()
	if F.NotSecret(money) then
		Entry(me).gold = money
	end
end

-- 2.0 test builds keyed Forever characters "First-Surname". Move that entry
-- and its data to "First Surname" so it does not linger as a fake alt.
local function MoveOldForeverKey(key)
	if not F.UniqueNames() then
		return
	end
	local old = key:gsub(" ", "-", 1)
	if old == key then
		return
	end
	local g = ns.global
	for _, book in pairs({ g.roster, g.inventory, g.mailbox, g.repairCost, g.itemRuleSnapshots, g.recent }) do
		if book[old] ~= nil then
			if book[key] == nil then
				book[key] = book[old]
			end
			book[old] = nil
		end
	end
end

local function StampSelf()
	local key = F.FullName("player")
	if not key then
		return
	end
	MoveOldForeverKey(key)
	ns.State.playerName = key
	local entry = Entry(key)
	local _, classFile = UnitClass("player")
	entry.class = classFile
	entry.faction = UnitFactionGroup("player")
	entry.lastSeen = time()
	StoreGold()
end

-- Known target, auto-detected or hand-added.
function Roster.IsKnown(target)
	if not target or target == "" then
		return false
	end
	return ns.global.roster[target] ~= nil or ns.global.manualAlts[target] ~= nil
end

function Roster.IsManual(target)
	return target ~= nil and target ~= "" and ns.global.manualAlts[target] ~= nil
end

function Roster.AddManual(target)
	if not target or target == "" then
		return false
	end
	ns.global.manualAlts[target] = true
	ns:Fire("ROSTER_CHANGED")
	return true
end

function Roster.RemoveManual(target)
	if target then
		ns.global.manualAlts[target] = nil
		ns:Fire("ROSTER_CHANGED")
	end
end

local function SortedKeys(map, skip)
	local out = {}
	for key in pairs(map) do
		if key ~= skip then
			out[#out + 1] = key
		end
	end
	tsort(out)
	return out
end

function Roster.ManualList()
	return SortedKeys(ns.global.manualAlts)
end

-- Sorted auto-detected characters, without the current one unless asked.
function Roster.List(includeSelf)
	return SortedKeys(ns.global.roster, not includeSelf and ns.State.playerName or nil)
end

-- Newest first.
function Roster.RecentList()
	local recent = ns.global.recent
	local out = {}
	for key in pairs(recent) do
		out[#out + 1] = key
	end
	tsort(out, function(a, b)
		return recent[a] > recent[b]
	end)
	return out
end

function Roster.NoteRecent(target)
	if not target or target == "" then
		return
	end
	local recent = ns.global.recent
	recent[target] = time()
	local list = Roster.RecentList()
	for i = RECENT_MAX + 1, #list do
		recent[list[i]] = nil
	end
end

function Roster.AccountGold()
	local total = 0
	for _, entry in pairs(ns.global.roster) do
		total = total + (entry.gold or 0)
	end
	return total
end

-- Read at call time so a class colour addon that swaps the table is respected.
function Roster.ClassHex(key)
	local entry = ns.global.roster[key]
	local colors = _G["CUSTOM_CLASS_COLORS"] or _G["RAID_CLASS_COLORS"]
	local color = entry and entry.class and colors and colors[entry.class]
	return (color and color.colorStr) or "ffffffff"
end

function Roster.Colored(key)
	if not key or key == "" then
		return "|cff999999?|r"
	end
	return "|c" .. Roster.ClassHex(key) .. key .. "|r"
end

ns:OnInit(StampSelf)
-- PLAYER_READY tells the other modules the name and DB are both in place.
ns:RegisterEvent("PLAYER_LOGIN", function()
	StampSelf()
	ns:Fire("ROSTER_CHANGED")
	ns:Fire("PLAYER_READY")
end)
ns:RegisterEvent("PLAYER_MONEY", ns:Debounce(1, StoreGold))
-- GetMoney can still read 0 at PLAYER_LOGIN, so take it again once in world.
ns:RegisterEvent("PLAYER_ENTERING_WORLD", StoreGold)
ns:RegisterEvent("PLAYER_LOGOUT", StoreGold)
