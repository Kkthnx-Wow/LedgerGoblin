--[[
	LedgerGoblin - Init
	-------------------------------------------------------------------------
	Creates the private namespace every file shares. One `ns` table, no globals
	besides the two SavedVariables and the three compartment callbacks the TOC
	names.
--]]

local addonName, ns = ...

local C_AddOns = C_AddOns

ns.name = addonName
ns.C = {} -- Constants
ns.F = {} -- Helpers
ns.Modules = {}

-- Keys are the enUS sentences, so a missing translation reads as English.
ns.L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})

-- Runtime state shared by the mail modules. Only the module named in the
-- comment writes each field.
ns.State = {
	playerName = nil, -- "Name-Realm" (Roster)
	mailboxOpen = false, -- (Sender)
	sending = false, -- a send queue is draining (Sender)
	collecting = false, -- the inbox collector is running (Inbox)
}

ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "0.0.0"

-- Forever reports WOW_PROJECT_ID 18 (camelot). It loads the mainline mail,
-- container and settings frames, so most code paths are shared with Retail.
local projectID = _G["WOW_PROJECT_ID"]
ns.IsForever = projectID ~= nil and projectID == (_G["WOW_PROJECT_CAMELOT"] or 18)
ns.IsRetail = projectID ~= nil and projectID == _G["WOW_PROJECT_MAINLINE"]

function ns:NewModule(name)
	assert(not ns.Modules[name], "LedgerGoblin: duplicate module " .. tostring(name))
	local module = {}
	ns.Modules[name] = module
	return module
end

function ns:GetModule(name)
	return ns.Modules[name]
end
