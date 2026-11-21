--[[
	LedgerGoblin - DB
	-------------------------------------------------------------------------
	Wires SavedVariables at ADDON_LOADED:
	  ns.db     -> LedgerGoblinCharDB (this character's rules)
	  ns.global -> LedgerGoblinDB     (account roster, mailboxes, history)
	Both merge against Constants defaults, then run schema migrations once.
--]]

local addonName, ns = ...
local C, F = ns.C, ns.F

local pairs = pairs
local type = type

local initQueue = {}

-- Modules queue setup that needs the DB.
function ns:OnInit(fn)
	initQueue[#initQueue + 1] = fn
end

-- `from` is the schema the saved table had before the defaults merge, which
-- would otherwise stamp the new number on an old table.
local function MigrateChar(db, from)
	if from < 2 then
		-- Routes are one dropdown now, a target means on. A disabled 1.x route
		-- keeps no target so it stays off.
		for _, group in pairs({ db.quality, db.bind }) do
			for _, entry in pairs(group) do
				if type(entry) == "table" and not entry.enabled then
					entry.target = ""
				end
			end
		end
		for _, rule in pairs(db.itemRules) do
			if type(rule) == "table" and type(rule.match) == "string" then
				-- 1.x stored links typed into the slash command as names.
				local id = F.ItemIDFromText(rule.match)
				if id then
					rule.match = id
				end
			end
		end
	end
	db.schema = C.SCHEMA
end

local function MigrateGlobal(global)
	global.schema = C.SCHEMA
end

local function OnAddonLoaded(event, loaded)
	if loaded ~= addonName then
		return
	end
	ns:UnregisterEvent(event, OnAddonLoaded)

	local saved = LedgerGoblinCharDB
	local from = type(saved) == "table" and (saved.schema or 1) or C.SCHEMA
	LedgerGoblinCharDB = F.CopyDefaults(C.CHAR_DEFAULTS, saved)
	LedgerGoblinDB = F.CopyDefaults(C.GLOBAL_DEFAULTS, LedgerGoblinDB)
	MigrateChar(LedgerGoblinCharDB, from)
	MigrateGlobal(LedgerGoblinDB)

	ns.db = LedgerGoblinCharDB
	ns.global = LedgerGoblinDB

	for i = 1, #initQueue do
		initQueue[i]()
	end
end

ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)
