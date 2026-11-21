--[[
	LedgerGoblin - Events
	-------------------------------------------------------------------------
	One shared frame for game events plus a tiny internal message bus.
	Game events: ns:RegisterEvent(event, fn) / ns:UnregisterEvent(event, fn).
	Messages: ns:On(message, fn) / ns:Fire(message, ...). Messages let the
	rule editor, planner and UI stay in sync without reaching into each other.
--]]

local _, ns = ...

local CreateFrame = CreateFrame
local C_Timer = C_Timer

local frame = CreateFrame("Frame")
local callbacks = {} -- event -> { fn, ... }

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

-- The frame listens only to events that have a handler.
function ns:RegisterEvent(event, fn)
	local list = callbacks[event]
	if not list then
		list = {}
		callbacks[event] = list
		frame:RegisterEvent(event)
	end
	list[#list + 1] = fn
end

-- Remove one handler. Builds a new list so a dispatch already looping over the
-- old one is not disturbed. The frame stops listening once the list is empty.
function ns:UnregisterEvent(event, fn)
	local list = callbacks[event]
	if not list then
		return
	end
	local kept = {}
	for i = 1, #list do
		if list[i] ~= fn then
			kept[#kept + 1] = list[i]
		end
	end
	if #kept == 0 then
		callbacks[event] = nil
		frame:UnregisterEvent(event)
	else
		callbacks[event] = kept
	end
end

local listeners = {} -- message -> { fn, ... }

function ns:On(message, fn)
	local list = listeners[message]
	if not list then
		list = {}
		listeners[message] = list
	end
	list[#list + 1] = fn
end

function ns:Fire(message, ...)
	local list = listeners[message]
	if not list then
		return
	end
	for i = 1, #list do
		list[i](message, ...)
	end
end

function ns:After(seconds, fn)
	C_Timer.After(seconds, fn)
end

-- Coalesce bursts (BAG_UPDATE_DELAYED, MAIL_INBOX_UPDATE) into one call.
-- Returns a function that schedules `fn` once per `delay` window.
function ns:Debounce(delay, fn)
	local pending = false
	local function run()
		pending = false
		fn()
	end
	return function()
		if pending then
			return
		end
		pending = true
		C_Timer.After(delay, run)
	end
end
