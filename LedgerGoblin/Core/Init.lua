--[[
	LedgerGoblin - Init
	-------------------------------------------------------------------------
	Creates the private addon namespace shared across every file. Nothing here
	touches the game yet; this is purely the shared table + a couple of metadata
	fields that the rest of the addon reads. Pattern lifted from NexEnhance: one
	`ns` table, zero globals (besides the two SavedVariables the client owns).
--]]

local addonName, ns = ...

-- Shared sub-tables. Modules hang their public surface off these so files never
-- reach for a global to talk to each other.
ns.name = addonName
ns.C = {} -- Constants
ns.F = {} -- Functions / helpers
ns.Modules = {} -- Registered module handles (by name)

-- Locale strings. Our keys ARE the enUS sentences, so a missing key (typo, or a
-- not-yet-translated string in another locale) falls back to the key itself -
-- degrading to readable English instead of erroring inside format()/concat.
ns.L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})

-- Read-only-ish runtime state. Populated during login; treated as the single
-- source of truth for "who am I and what's going on right now".
ns.State = {
	playerName = nil, -- "Name-Realm"
	realm = nil,
	mailboxOpen = false,
	sending = false, -- a send queue is currently draining
}

ns.version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.0.0"

-- Tiny module registry. Each module is just a table with optional lifecycle
-- hooks (OnInit at ADDON_LOADED, OnEnable at PLAYER_LOGIN). Kept deliberately
-- lighter than NexEnhance's NewModule - this addon has a handful of modules,
-- not dozens.
function ns:NewModule(name)
	assert(not ns.Modules[name], "LedgerGoblin: duplicate module " .. tostring(name))
	local module = {}
	ns.Modules[name] = module
	return module
end

function ns:GetModule(name)
	return ns.Modules[name]
end
