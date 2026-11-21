-- Minimal WoW client stand-in for headless LedgerGoblin tests (Lua 5.1).
-- Covers only what the addon touches. Frames are permissive dummies that
-- remember scripts and events so tests can drive them.
local M = {}

local timers = {}
M.now = 1000

-- Runs timers in due order while moving the clock forward by `seconds`.
function M.advance(seconds)
	local target = M.now + seconds
	while true do
		local best
		for i = 1, #timers do
			if timers[i].due <= target and (not best or timers[i].due < timers[best].due) then
				best = i
			end
		end
		if not best then
			break
		end
		local t = table.remove(timers, best)
		if t.due > M.now then
			M.now = t.due
		end
		t.fn()
	end
	M.now = target
end

-- Short waits only, so 10 second timeouts do not fire by accident.
function M.flushTimers()
	M.advance(3)
end

local dummyMT = {}
local function Dummy()
	return setmetatable({}, dummyMT)
end
dummyMT.__index = function(t, k)
	local d = Dummy()
	rawset(t, k, d)
	return d
end
dummyMT.__call = function()
	return Dummy()
end

M.frames = {}
local function NewFrame(_, name)
	local f = Dummy()
	rawset(f, "scripts", {})
	rawset(f, "events", {})
	rawset(f, "SetScript", function(self, k, fn)
		self.scripts[k] = fn
	end)
	rawset(f, "HookScript", function() end)
	rawset(f, "RegisterEvent", function(self, e)
		self.events[e] = true
	end)
	rawset(f, "UnregisterEvent", function(self, e)
		self.events[e] = nil
	end)
	rawset(f, "Show", function(self)
		rawset(self, "shown", true)
	end)
	rawset(f, "Hide", function(self)
		rawset(self, "shown", false)
	end)
	rawset(f, "IsShown", function(self)
		return rawget(self, "shown") == true
	end)
	if name then
		_G[name] = f
	end
	M.frames[#M.frames + 1] = f
	return f
end

-- Send a game event to every frame listening for it.
function M.fire(event, ...)
	for i = 1, #M.frames do
		local f = M.frames[i]
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end

function M.install()
	local G = _G
	G.wipe = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	G.tinsert = table.insert
	G.date = os.date
	G.time = function()
		return M.now
	end
	G.GetTime = function()
		return M.now
	end
	G.hooksecurefunc = function(name, fn)
		local orig = G[name]
		G[name] = function(...)
			local r = { orig(...) }
			fn(...)
			return unpack(r)
		end
	end
	G.issecretvalue = function()
		return false
	end
	G.CreateFrame = NewFrame
	G.C_Timer = {
		After = function(delay, fn)
			timers[#timers + 1] = { due = M.now + delay, fn = fn }
		end,
	}
	G.C_AddOns = {
		GetAddOnMetadata = function()
			return "test"
		end,
	}
	G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, msg)
			M.chat[#M.chat + 1] = msg
		end,
	}
	M.chat = {}
	-- Tests change M.name / M.second to act as another client's names.
	M.name, M.second = "Main", nil
	G.UnitName = function()
		return M.name, M.second
	end
	G.GetNormalizedRealmName = function()
		return "Realm"
	end
	G.GetRealmName = function()
		return "Realm"
	end
	G.UnitClass = function()
		return "Warrior", "WARRIOR"
	end
	G.UnitFactionGroup = function()
		return "Horde"
	end
	M.money = 0
	G.GetMoney = function()
		return M.money
	end
	G.GetCoinTextureString = function(c)
		return tostring(c) .. "c"
	end
	G.GetNetStats = function()
		return 0, 0, 50, 50
	end
	G.InCombatLockdown = function()
		return false
	end
	G.IsShiftKeyDown = function()
		return false
	end
	G.IsAltKeyDown = function()
		return false
	end
	G.Enum = { BagIndex = { Backpack = 0, ReagentBag = 5, Bank = -1, CharacterBankTab_1 = 6, AccountBankTab_1 = 12 }, TooltipDataType = { Item = 0 } }
	G.NUM_BAG_SLOTS = 4
	G.StaticPopupDialogs = {}
	G.StaticPopup_Show = function(name)
		M.popup = name
	end
	G.YES, G.NO, G.ACCEPT, G.CANCEL, G.CLOSE = "Yes", "No", "Accept", "Cancel", "Close"
	G.UISpecialFrames = {}
	G.SlashCmdList = {}
	G.GameTooltip = Dummy()
	G.ItemLocation = nil
	G.ClearCursor = function() end
	G.CursorHasItem = function()
		return false
	end
end

return M
