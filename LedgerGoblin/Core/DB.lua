--[[
	LedgerGoblin - DB
	-------------------------------------------------------------------------
	Wires SavedVariables to the namespace at ADDON_LOADED:
	  ns.db     -> this character's routing profile (LedgerGoblinCharDB)
	  ns.global -> account-wide roster + history (LedgerGoblinDB)
	Both are merged against their defaults so new schema keys appear and stale
	mismatched values are repaired. Modules read ns.db / ns.global directly.
--]]

local addonName, ns = ...
local C, F = ns.C, ns.F

ns:RegisterEvent("ADDON_LOADED", function(_, loaded)
	if loaded ~= addonName then
		return
	end

	-- The client guarantees these globals exist (possibly nil on first run) by
	-- the time our ADDON_LOADED fires. Merge against the canonical defaults.
	LedgerGoblinCharDB = F.CopyDefaults(C.CHAR_DEFAULTS, LedgerGoblinCharDB)
	LedgerGoblinDB = F.CopyDefaults(C.GLOBAL_DEFAULTS, LedgerGoblinDB)

	ns.db = LedgerGoblinCharDB
	ns.global = LedgerGoblinDB

	-- Fan out an internal "db ready" signal so modules can initialise. We reuse
	-- the event bus with a synthetic event name to avoid a second registry.
	if ns.OnDBReady then
		ns:OnDBReady()
	end
end)

-- Modules append to this list to be called once the DB is live (ADDON_LOADED).
local initQueue = {}
function ns:OnInit(fn)
	initQueue[#initQueue + 1] = fn
end

function ns:OnDBReady()
	for i = 1, #initQueue do
		initQueue[i]()
	end
end
