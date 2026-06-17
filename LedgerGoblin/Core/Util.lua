--[[
	LedgerGoblin - Util
	-------------------------------------------------------------------------
	Cached global references + small pure helpers. Per the performance brief:
	every API we touch in a hot path (the bag scan / send loop) is localised
	once here so the engine never pays a global lookup mid-scan.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

-- Cached globals (hot-path). Keep these as upvalues for the helpers below.
local format = string.format
local floor = math.floor
local tostring = tostring
local type = type
local tonumber = tonumber

local GetCoinTextureString = GetCoinTextureString
local UnitName = UnitName
local GetNormalizedRealmName = GetNormalizedRealmName
local GetRealmName = GetRealmName
local issecretvalue = _G["issecretvalue"]

local COPPER_PER_GOLD = C.COPPER_PER_GOLD

-- Midnight (12.0+) restricted values. Guard before arithmetic, concat, compare,
-- or `#` on API returns that may be Secret in combat/instances. No-op on Classic.
function F.IsSecret(v)
	return issecretvalue and issecretvalue(v) or false
end

function F.NotSecret(v)
	return not F.IsSecret(v)
end

-- Chat output prefix, built once. Two-tone to match the brand: gold "Ledger",
-- green "Goblin".
local PREFIX = "|c" .. C.BrandHex .. "Ledger|r|c" .. C.GreenHex .. "Goblin|r: "

function F.Print(msg, ...)
	if select("#", ...) > 0 then
		msg = format(msg, ...)
	end
	-- DEFAULT_CHAT_FRAME is the canonical sink; AddMessage avoids the print()
	-- tostring dance and keeps our colour escape intact.
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

-- "Name-Realm" for a unit, normalised so it matches what the roster stores.
-- Returns nil if the name isn't available yet (e.g. very early login).
function F.FullName(unit)
	unit = unit or "player"
	local name, realm = UnitName(unit)
	if not name or name == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName and GetNormalizedRealmName() or (GetRealmName and GetRealmName():gsub("%s+", "")) or ""
	end
	if realm == "" then
		return name
	end
	return name .. "-" .. realm
end

-- Money formatting via Blizzard's coin string (icons). copper -> "1g 2s 3c".
function F.Money(copper)
	copper = copper or 0
	if GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	return floor(copper / COPPER_PER_GOLD) .. "g"
end

function F.GoldToCopper(gold)
	return (tonumber(gold) or 0) * COPPER_PER_GOLD
end

function F.CopperToGold(copper)
	return floor((copper or 0) / COPPER_PER_GOLD)
end

local COPPER_PER_SILVER = C.COPPER_PER_SILVER

-- Parse a user-typed money string into copper. Accepts:
--   "100"            -> 100 gold (bare numbers are gold, the common case)
--   "100g 50s 20c"   -> full g/s/c, any subset, any order, spaces optional
--   "50s", "20c"     -> silver / copper only
-- Returns nil when the string contains no recognisable amount, so callers can
-- reject bad input instead of silently routing 0.
function F.ParseMoney(text)
	if type(text) == "number" then
		return floor(text)
	end
	if type(text) ~= "string" then
		return nil
	end
	text = text:lower():gsub(",", "")

	local copper = 0
	local matched = false
	for amount, unit in text:gmatch("(%d+)%s*([gsc])") do
		amount = tonumber(amount)
		if amount then
			matched = true
			if unit == "g" then
				copper = copper + amount * COPPER_PER_GOLD
			elseif unit == "s" then
				copper = copper + amount * COPPER_PER_SILVER
			else
				copper = copper + amount
			end
		end
	end

	if not matched then
		-- No unit suffix: treat a bare number as gold.
		local bare = tonumber((text:gsub("%s+", "")))
		if bare then
			return floor(bare * COPPER_PER_GOLD)
		end
		return nil
	end

	return copper
end

-- Plain "Ng Ms Kc" text (no icons) for edit boxes, where coin textures don't fit.
function F.MoneyText(copper)
	copper = copper or 0
	local g = floor(copper / COPPER_PER_GOLD)
	local s = floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
	local c = copper % COPPER_PER_SILVER
	local parts = {}
	if g > 0 then
		parts[#parts + 1] = g .. "g"
	end
	if s > 0 then
		parts[#parts + 1] = s .. "s"
	end
	if c > 0 or #parts == 0 then
		parts[#parts + 1] = c .. "c"
	end
	return table.concat(parts, " ")
end

-- Deep-merge defaults into a saved table, repairing type mismatches. Lifted
-- from NexEnhance's CopyDefaults: a saved value whose type no longer matches
-- the default (schema drift across versions) is rebuilt from the default.
function F.CopyDefaults(defaults, target)
	if type(target) ~= "table" then
		target = {}
	end
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			target[key] = F.CopyDefaults(value, target[key])
		elseif target[key] == nil or type(target[key]) ~= type(value) then
			target[key] = value
		end
	end
	return target
end

-- Today's date key for analytics ("YYYY-MM-DD"), local time.
function F.DateKey()
	return date("%Y-%m-%d")
end

-- Trim + normalise a user-typed character name to "Name-Realm" shape. If the
-- user omits a realm we assume the current one. Returns nil for empty input.
function F.NormalizeTarget(input)
	if type(input) ~= "string" then
		return nil
	end
	input = input:gsub("^%s+", ""):gsub("%s+$", "")
	if input == "" then
		return nil
	end
	if not input:find("-", 1, true) then
		local realm = GetNormalizedRealmName and GetNormalizedRealmName() or (GetRealmName and GetRealmName():gsub("%s+", "")) or ""
		if realm ~= "" then
			input = input .. "-" .. realm
		end
	end
	return input
end

-- The recipient string to hand SendMail. We store targets as "Name-Realm" so
-- they stay unique across connected realms, but WoW *silently* drops same-realm
-- mail when you tack your OWN realm onto the name - local delivery wants a bare
-- "Name", and only connected/other realms want the "-Realm" suffix. So strip the
-- suffix when it's our own realm; the mail vanishing into the void with no
-- success/fail event is the symptom this exists to kill.
function F.MailRecipient(target)
	if type(target) ~= "string" or target == "" then
		return target
	end
	local name, realm = target:match("^(.-)%-(.+)$")
	if not name then
		return target -- already a bare name, nothing to strip
	end
	local myRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName():gsub("%s+", "")) or ""
	if myRealm ~= "" and realm:lower() == myRealm:lower() then
		return name
	end
	return target
end
