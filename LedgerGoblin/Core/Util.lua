--[[
	LedgerGoblin - Util
	-------------------------------------------------------------------------
	Small pure helpers: printing, names, money parsing and formatting, schema
	merging, secret-value guards.
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local format = string.format
local floor = math.floor
local tostring = tostring
local tonumber = tonumber
local type = type
local pairs = pairs
local select = select
local date = date
local tconcat = table.concat

local UnitName = UnitName
local GetNormalizedRealmName = GetNormalizedRealmName
local GetRealmName = GetRealmName
local issecretvalue = _G["issecretvalue"]

local COPPER_PER_GOLD = C.COPPER_PER_GOLD
local COPPER_PER_SILVER = C.COPPER_PER_SILVER

-- Midnight restricted values. Never compare, add or concat one.
function F.IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end

function F.NotSecret(v)
	return not F.IsSecret(v)
end

local PREFIX = C.Title .. ": "

function F.Print(msg, ...)
	if select("#", ...) > 0 then
		msg = format(msg, ...)
	end
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

function F.Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The realm name without spaces, as it appears in "Name-Realm". Empty during
-- the first frames of login, so it is not cached.
function F.MyRealm()
	if GetNormalizedRealmName then
		local realm = GetNormalizedRealmName()
		if realm and realm ~= "" then
			return realm
		end
	end
	if GetRealmName then
		return (GetRealmName():gsub("%s+", ""))
	end
	return ""
end

-- Forever names are unique across the region and carry a surname. UnitName
-- returns (first, surname), the full name joins them with a space, and the
-- realm is never part of the address. Retail returns (name, realm) and mail
-- uses Name-Realm. Asked each time, the answer is fixed per client.
function F.UniqueNames()
	local fn = _G["RegionalUniqueNamesEnabled"]
	return fn ~= nil and fn() == true
end

local function SurnameSeparator()
	local consts = _G["Constants"] and _G["Constants"].CharacterNameSeparatorConsts
	return (consts and consts.CHARACTERNAME_SURNAME_SEPARATOR) or " "
end

-- The key a character is stored and mailed under. "First Surname" on
-- Forever, "Name-Realm" on Retail.
function F.FullName(unit)
	local name, second = UnitName(unit or "player")
	if not name or name == "" then
		return nil
	end
	if F.UniqueNames() then
		if second and second ~= "" then
			return name .. SurnameSeparator() .. second
		end
		return name
	end
	local realm = (second and second ~= "") and second or F.MyRealm()
	if realm == "" then
		return name
	end
	return name .. "-" .. realm
end

-- Typed names become stored keys. Retail adds our realm to a bare name,
-- Forever only tidies spaces. Returns nil for empty input.
function F.NormalizeTarget(input)
	if type(input) ~= "string" then
		return nil
	end
	input = F.Trim(input):gsub("%s+", " ")
	if input == "" then
		return nil
	end
	if F.UniqueNames() then
		return input
	end
	if not input:find("-", 1, true) then
		local realm = F.MyRealm()
		if realm ~= "" then
			input = input .. "-" .. realm
		end
	end
	return input
end

-- Retail same-realm mail addressed "Name-MyRealm" does not arrive and fires
-- neither MAIL_SEND_SUCCESS nor MAIL_FAILED, so drop our own realm there.
-- Forever keys are already the address.
function F.MailRecipient(target)
	if type(target) ~= "string" or target == "" or F.UniqueNames() then
		return target
	end
	local name, realm = target:match("^(.-)%-(.+)$")
	if not name then
		return target
	end
	local myRealm = F.MyRealm()
	if myRealm ~= "" and realm:lower() == myRealm:lower() then
		return name
	end
	return target
end

-- Inbox senders: "Name" or "Name-Realm" on Retail, the full name on Forever.
function F.SenderKey(sender)
	if type(sender) ~= "string" or sender == "" then
		return nil
	end
	if F.UniqueNames() or sender:find("-", 1, true) then
		return sender
	end
	local realm = F.MyRealm()
	return realm ~= "" and (sender .. "-" .. realm) or sender
end

-- Item ID from a number, a bare number string, an item link or "item:123".
function F.ItemIDFromText(text)
	if type(text) == "number" then
		return text
	end
	if type(text) ~= "string" then
		return nil
	end
	local id = text:match("|Hitem:(%d+)") or text:match("^item:(%d+)") or text:match("^%s*(%d+)%s*$")
	return id and tonumber(id) or nil
end

-- The coin string moved to C_CurrencyInfo, and the old global is gone on
-- current clients. GetMoneyString is FrameXML Lua, looked up at call time.
local CoinString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or _G["GetCoinTextureString"]

function F.Money(copper)
	copper = copper or 0
	if CoinString then
		return CoinString(copper)
	end
	local GetMoneyString = _G["GetMoneyString"]
	if GetMoneyString then
		return GetMoneyString(copper)
	end
	return F.MoneyText(copper)
end

-- Plain "1g 2s 3c" for edit boxes.
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
	return tconcat(parts, " ")
end

-- "100" is 100 gold. "100g 50s 20c" in any order. nil when nothing parses, so
-- bad input is rejected instead of becoming 0.
function F.ParseMoney(text)
	if type(text) == "number" then
		return floor(text)
	end
	if type(text) ~= "string" then
		return nil
	end
	text = text:lower():gsub(",", "")

	local copper, matched = 0, false
	for amount, unit in text:gmatch("(%d+)%s*([gsc])") do
		amount = tonumber(amount)
		matched = true
		if unit == "g" then
			copper = copper + amount * COPPER_PER_GOLD
		elseif unit == "s" then
			copper = copper + amount * COPPER_PER_SILVER
		else
			copper = copper + amount
		end
	end

	if not matched then
		local bare = tonumber((text:gsub("%s+", "")))
		if bare and bare >= 0 then
			return floor(bare * COPPER_PER_GOLD)
		end
		return nil
	end
	return copper
end

-- Deep-merge defaults into a saved table. A saved value whose type no longer
-- matches its default is rebuilt from the default.
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

function F.DateKey(when)
	return date("%Y-%m-%d", when)
end

-- "5s", "3m", "2h", "4d" since a timestamp.
function F.Ago(when)
	local secs = time() - (when or 0)
	if secs < 60 then
		return format("%ds", secs)
	elseif secs < 3600 then
		return format("%dm", floor(secs / 60))
	elseif secs < 86400 then
		return format("%dh", floor(secs / 3600))
	end
	return format("%dd", floor(secs / 86400))
end

-- Days and hours until a timestamp, for expiry text.
function F.Until(when)
	local secs = (when or 0) - time()
	if secs <= 0 then
		return "0h"
	end
	local days = floor(secs / 86400)
	local hours = floor((secs % 86400) / 3600)
	if days > 0 then
		return format("%dd %dh", days, hours)
	end
	return format("%dh", hours)
end
