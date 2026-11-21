--[[
	LedgerGoblin - Demo data
	-------------------------------------------------------------------------
	/ledger demo fills the Rule Editor with sample routes, exclusions and
	characters so the window can be previewed full. The real rules, keep
	amounts, exclusions and roster are copied aside first and /ledger demo off
	puts them back. Sample characters are tagged so nothing else treats them as
	real, and sending is blocked while the demo is loaded.
--]]

local _, ns = ...
local L, F = ns.L, ns.F

local Demo = ns:NewModule("Demo")

local pairs = pairs
local type = type

-- First name, surname or realm, class. Built into "First Surname" on
-- Forever and "Name-Realm" on Retail.
local PEOPLE = {
	{ "Brewgrin", "Skyrus", "MONK" },
	{ "Oretooth", "Ironvein", "WARRIOR" },
	{ "Stitchwick", "Skyrus", "MAGE" },
	{ "Hidebinder", "Mossjaw", "DRUID" },
	{ "Glimmerfang", "Duskwhistle", "PALADIN" },
	{ "Quillspark", "Area52", "PRIEST" },
	{ "Thisnameisreallylong", "Argentdawnmountain", "DEATHKNIGHT" },
	{ "Vaultkeeper", "Coinsworth", "ROGUE" },
}

local function Key(i)
	local p = PEOPLE[i]
	return F.UniqueNames() and (p[1] .. " " .. p[2]) or (p[1] .. "-" .. p[2])
end

-- itemID or exact name, PEOPLE index, max, keep.
local ROUTES = {
	{ 2447, 1, 200, 20 },
	{ 765, 1 },
	{ 785, 1, nil, 10 },
	{ 2770, 2, 500 },
	{ 2771, 2 },
	{ 2589, 3, nil, 40 },
	{ 2592, 3 },
	{ 4306, 3, 1000 },
	{ 2318, 4 },
	{ 2319, 4, 60 },
	{ 10940, 5 },
	{ 2672, 6, nil, 5 },
	{ "Shiny Red Apple", 7 },
	{ 4536, 8 },
	{ 159, 8, 20, 4 },
	{ 999999, 8 }, -- an ID the client does not know
}

local EXCLUDE = { 6948, 2934, 4540, 117, 2512, 2516, 3576, 2901 }

local function Copy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = Copy(v)
	end
	return out
end

function Demo.IsOn()
	return ns.global.demoBackup ~= nil
end

function Demo.On()
	if Demo.IsOn() then
		F.Print(L["Demo data is already loaded. /ledger demo off restores yours."])
		return
	end
	local db = ns.db
	ns.global.demoBackup = {
		owner = ns.State.playerName,
		itemRules = Copy(db.itemRules),
		keep = Copy(db.keep),
		exclusions = Copy(db.exclusions),
	}
	local rules = {}
	for i = 1, #ROUTES do
		local r = ROUTES[i]
		-- Every fifth route is off, to preview the disabled look.
		rules[i] = { match = r[1], target = Key(r[2]), max = r[3], enabled = i % 5 ~= 0 }
		if r[4] and type(r[1]) == "number" then
			db.keep[r[1]] = r[4]
		end
	end
	db.itemRules = rules
	for i = 1, #EXCLUDE do
		db.exclusions[EXCLUDE[i]] = true
	end
	for i = 1, #PEOPLE do
		local key = Key(i)
		if not ns.global.roster[key] then
			ns.global.roster[key] = { class = PEOPLE[i][3], gold = 0, demo = true }
		end
	end
	ns:GetModule("Rules").Changed()
	ns:Fire("ROSTER_CHANGED")
	F.Print(L["Demo data loaded. /ledger demo off restores your rules."])
	ns.ToggleRuleWindow(true)
end

function Demo.Off()
	local backup = ns.global.demoBackup
	if not backup then
		F.Print(L["No demo data is loaded."])
		return
	end
	if backup.owner ~= ns.State.playerName then
		F.Print(L["The demo was loaded on %s. Log in there to turn it off."], backup.owner or "?")
		return
	end
	local db = ns.db
	db.itemRules = backup.itemRules
	db.keep = backup.keep
	db.exclusions = backup.exclusions
	for key, entry in pairs(ns.global.roster) do
		if entry.demo then
			ns.global.roster[key] = nil
		end
	end
	ns.global.demoBackup = nil
	ns:GetModule("Rules").Changed()
	ns:Fire("ROSTER_CHANGED")
	F.Print(L["Demo data removed. Your rules are back."])
end
