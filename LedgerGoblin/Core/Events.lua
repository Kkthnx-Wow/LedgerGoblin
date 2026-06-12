--[[
	LedgerGoblin - Events
	-------------------------------------------------------------------------
	One shared frame for the whole addon. Handlers map event -> array of
	callbacks, fired in registration order. Arrays (not sets) keep the dispatch
	loop allocation-free and ordered, matching NexEnhance's central dispatcher.
--]]

local _, ns = ...

local frame = CreateFrame("Frame", "LedgerGoblinEventFrame")
local callbacks = {} -- event -> { fn, fn, ... }

frame:SetScript("OnEvent", function(_, event, ...)
	local list = callbacks[event]
	if not list then
		return
	end
	for i = 1, #list do
		local fn = list[i]
		if fn then
			fn(event, ...)
		end
	end
end)

-- Register a callback for an event. The frame only listens for events that
-- actually have a handler, so we never wake up for noise.
function ns:RegisterEvent(event, fn)
	local list = callbacks[event]
	if not list then
		list = {}
		callbacks[event] = list
		frame:RegisterEvent(event)
	end
	list[#list + 1] = fn
end

-- Lightweight one-shot timer wrapper so modules don't each reach for C_Timer.
function ns:After(seconds, fn)
	C_Timer.After(seconds, fn)
end
