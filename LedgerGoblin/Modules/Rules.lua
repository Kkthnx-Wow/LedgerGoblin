--[[
	LedgerGoblin - Rules
	-------------------------------------------------------------------------
	Decides where an item goes and owns every change to the rule tables, so the
	settings panel, the rule editor and the slash command all go through the
	same checks. Any change fires RULES_CHANGED.

	Pipeline (C.ROUTE_ORDER), first match wins, exclusions checked first:
	  item     a specific itemID or exact name
	  type     item class or trade goods subclass (herbs, ore, cloth...)
	  boe      Bind on Equip gear still in bags
	  boa      account and warband bound items
	  quality  catch-all by quality
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local Rules = ns:NewModule("Rules")
local Items -- set at init

local C_Item = C_Item
local type = type
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local time = time
local strlower = string.lower
local floor = math.floor
local tremove = table.remove
local tsort = table.sort

local QUALITY_BY_ENUM = C.QUALITY_BY_ENUM
local ROUTE_ORDER = C.ROUTE_ORDER
local ACCOUNT_BOUND = C.ACCOUNT_BOUND
local BIND_ON_EQUIP = C.BIND.ON_EQUIP
local TypeKey = C.TypeKey

local function Live(entry)
	return entry and entry.enabled and entry.target ~= nil and entry.target ~= ""
end

local function RuleLive(rule)
	return rule.enabled ~= false and rule.match ~= nil and rule.target ~= nil and rule.target ~= ""
end

-- Lower-cased name rules, rebuilt on RULES_CHANGED, so the bag scan does not
-- lower-case every rule for every item.
local nameRules = {} -- lowered name -> rule
local idRules = {} -- itemID -> rule (first live rule wins)

local function IndexRules()
	nameRules, idRules = {}, {}
	local rules = ns.db.itemRules
	for i = 1, #rules do
		local rule = rules[i]
		if RuleLive(rule) then
			if type(rule.match) == "number" then
				if not idRules[rule.match] then
					idRules[rule.match] = rule
				end
			else
				local key = strlower(rule.match)
				if not nameRules[key] then
					nameRules[key] = rule
				end
			end
		end
	end
end

local resolvers = {
	item = function(db, itemID, name)
		local rule = idRules[itemID] or (name and nameRules[strlower(name)])
		if rule then
			return rule.target, rule
		end
	end,

	type = function(db, _, _, _, _, _, classID, subClassID)
		if not classID then
			return nil
		end
		local t = db.typeRules
		local entry = (subClassID and t[TypeKey(classID, subClassID)]) or nil
		if not Live(entry) then
			entry = t[TypeKey(classID)]
		end
		if Live(entry) then
			return entry.target
		end
	end,

	boe = function(db, _, _, _, bindType)
		if bindType == BIND_ON_EQUIP and Live(db.bind.boe) then
			return db.bind.boe.target
		end
	end,

	boa = function(db, _, _, _, bindType, warband)
		if (warband or (bindType and ACCOUNT_BOUND[bindType])) and Live(db.bind.boa) then
			return db.bind.boa.target
		end
	end,

	quality = function(db, _, _, quality)
		local key = quality and QUALITY_BY_ENUM[quality]
		local entry = key and db.quality[key]
		if Live(entry) then
			return entry.target
		end
	end,
}

-- target, category, itemRule (nil unless an item rule matched).
function Rules.Resolve(itemID, name, quality, bindType, warband, classID, subClassID)
	local db = ns.db
	if itemID and db.exclusions[itemID] then
		return nil
	end
	for i = 1, #ROUTE_ORDER do
		local category = ROUTE_ORDER[i]
		local target, rule = resolvers[category](db, itemID, name, quality, bindType, warband, classID, subClassID)
		if target then
			return target, category, rule
		end
	end
	return nil
end

function Rules.HasAny()
	local db = ns.db
	if not db then
		return false
	end
	if Live(db.gold) or next(idRules) or next(nameRules) then
		return true
	end
	for _, group in pairs({ db.quality, db.bind, db.typeRules }) do
		for _, entry in pairs(group) do
			if Live(entry) then
				return true
			end
		end
	end
	return false
end

-- Can a rule for `match` ever send anything? Returns routable, name, reason.
-- A live copy in bags decides first. Otherwise the static bind type does.
-- An uncached item passes, since the send-time checks still guard it.
function Rules.IsRoutable(match)
	local itemID, name
	if type(match) == "number" then
		itemID = match
	else
		itemID = F.ItemIDFromText(match)
		if not itemID then
			name = match
		end
	end

	local bindType, resolvedName
	if itemID then
		resolvedName, bindType = Items.Facts(itemID)
	elseif name then
		---@diagnostic disable-next-line: deprecated
		local getInfo = C_Item.GetItemInfo or _G["GetItemInfo"]
		local info = { getInfo(name) }
		resolvedName, bindType = info[1], info[14]
	end
	resolvedName = resolvedName or name

	local held = Items.HeldVerdict(itemID, name)
	if held == true then
		return true, resolvedName
	elseif held == false then
		return false, resolvedName, L["it's soulbound to this character"]
	end

	if bindType == C.BIND.ON_PICKUP or bindType == C.BIND.QUEST then
		if itemID and Items.IDIsWarband(itemID, bindType) then
			return true, resolvedName
		end
		return false, resolvedName, bindType == C.BIND.QUEST and L["it's a quest item"] or L["it's Bind on Pickup"]
	end
	return true, resolvedName
end

-- ---------------------------------------------------------------------------
-- Item type options for the settings panel
-- ---------------------------------------------------------------------------

local typeOptions

-- { key, label, classID, subClassID } for every type this client names.
function Rules.TypeOptions()
	if typeOptions then
		return typeOptions
	end
	typeOptions = {}
	local GetClassInfo = C_Item.GetItemClassInfo or _G["GetItemClassInfo"]
	local GetSubClassInfo = C_Item.GetItemSubClassInfo or _G["GetItemSubClassInfo"]
	if not (GetClassInfo and GetSubClassInfo) then
		return typeOptions
	end
	-- The client still names retired types, tagged "(OBSOLETE)". Skip them.
	local function Usable(label)
		return label and label ~= "" and not label:find("OBSOLETE", 1, true)
	end
	local tradeGoods = GetClassInfo(C.TRADEGOODS_CLASS) or ""
	local seen = {}
	for sub = 0, C.TRADEGOODS_MAX_SUBCLASS do
		local label = GetSubClassInfo(C.TRADEGOODS_CLASS, sub)
		if Usable(label) and not seen[label] then
			seen[label] = true
			typeOptions[#typeOptions + 1] = {
				key = TypeKey(C.TRADEGOODS_CLASS, sub),
				label = label,
				full = tradeGoods .. " " .. label,
				classID = C.TRADEGOODS_CLASS,
				subClassID = sub,
			}
		end
	end
	for i = 1, #C.WHOLE_CLASSES do
		local classID = C.WHOLE_CLASSES[i]
		local label = GetClassInfo(classID)
		if Usable(label) then
			typeOptions[#typeOptions + 1] = { key = TypeKey(classID), label = label, full = label, classID = classID }
		end
	end
	return typeOptions
end

-- Make sure every offered type has a saved entry the settings can bind to.
function Rules.EnsureTypeEntries()
	local t = ns.db.typeRules
	local options = Rules.TypeOptions()
	for i = 1, #options do
		local key = options[i].key
		if type(t[key]) ~= "table" then
			t[key] = { enabled = false, target = "" }
		end
	end
end

-- ---------------------------------------------------------------------------
-- Rule changes
-- ---------------------------------------------------------------------------

local function Changed()
	IndexRules()
	Rules.Snapshot()
	ns:Fire("RULES_CHANGED")
end
Rules.Changed = Changed

function Rules.FormatMatch(match)
	if type(match) == "number" then
		---@diagnostic disable-next-line: deprecated
		local getInfo = C_Item.GetItemInfo or _G["GetItemInfo"]
		local _, link = getInfo(match)
		return link or (L["itemID"] .. " " .. match)
	end
	return tostring(match)
end

-- Adds an item rule. Returns true on success, printing why not otherwise.
function Rules.AddItemRule(matchText, targetText, maxCount)
	matchText = F.Trim(matchText or "")
	local target = F.NormalizeTarget(targetText)
	if matchText == "" then
		F.Print(L["Enter an itemID or exact item name."])
		return false
	end
	if not target then
		F.Print(L["Enter a target character."])
		return false
	end
	if target == ns.State.playerName then
		F.Print(L["You can't mail yourself."])
		return false
	end

	local match = F.ItemIDFromText(matchText) or matchText
	local routable, name, reason = Rules.IsRoutable(match)
	if not routable then
		local label = name and ("|cffffffff" .. name .. "|r") or tostring(match)
		F.Print(L["%s can't be mailed because %s. Rule not added."], label, reason or L["it's bound"])
		return false
	end

	-- The roster only knows alts that have logged in with the addon, so an
	-- unknown name is a warning here and a hard stop at send time.
	if not ns:GetModule("Roster").IsKnown(target) then
		F.Print(L["%s isn't a character this account has seen yet. Check the spelling, or log in on it once."], target)
	end

	maxCount = tonumber(maxCount)
	ns.db.itemRules[#ns.db.itemRules + 1] = {
		match = match,
		target = target,
		max = maxCount and maxCount > 0 and floor(maxCount) or nil,
	}
	F.Print(L["Added item rule %s to %s."], Rules.FormatMatch(match), target)
	Changed()
	return true
end

function Rules.RemoveItemRule(index)
	local rules = ns.db.itemRules
	index = index or #rules
	local rule = rules[index]
	if not rule then
		return false
	end
	tremove(rules, index)
	F.Print(L["Removed item rule %s to %s."], Rules.FormatMatch(rule.match), rule.target or "?")
	Changed()
	return true
end

function Rules.ToggleItemRule(index, enabled)
	local rule = ns.db.itemRules[index]
	if not rule then
		return false
	end
	if enabled == nil then
		enabled = rule.enabled == false
	end
	rule.enabled = enabled
	Changed()
	return true
end

function Rules.SetAllItemRules(enabled)
	local rules = ns.db.itemRules
	for i = 1, #rules do
		rules[i].enabled = enabled
	end
	Changed()
end

-- Restock cap for an item rule. nil or 0 clears it.
function Rules.SetRuleMax(index, n)
	local rule = ns.db.itemRules[index]
	if not rule then
		return
	end
	n = tonumber(n)
	rule.max = n and n > 0 and floor(n) or nil
	Changed()
end

function Rules.SetKeep(itemID, n)
	if not itemID then
		return
	end
	n = tonumber(n)
	ns.db.keep[itemID] = n and n > 0 and floor(n) or nil
	Changed()
end

function Rules.SetExcluded(itemID, excluded)
	itemID = F.ItemIDFromText(itemID)
	if not itemID then
		F.Print(L["Enter a numeric itemID."])
		return false
	end
	ns.db.exclusions[itemID] = excluded and true or nil
	Changed()
	return true
end

-- ---------------------------------------------------------------------------
-- Rule snapshots, so one character can copy another's item rules
-- ---------------------------------------------------------------------------

local function CloneRule(rule)
	return { match = rule.match, target = rule.target, enabled = rule.enabled, max = rule.max }
end

local function RuleKey(rule)
	return type(rule.match) .. ":" .. tostring(rule.match) .. "\001" .. tostring(rule.target)
end

function Rules.Snapshot()
	local me = ns.State.playerName
	local snapshots = ns.global and ns.global.itemRuleSnapshots
	if not (me and snapshots) or ns.global.demoBackup then
		return
	end
	local rules = ns.db.itemRules
	if #rules == 0 then
		snapshots[me] = nil
		return
	end
	local copy = {}
	for i = 1, #rules do
		copy[i] = CloneRule(rules[i])
	end
	snapshots[me] = { updatedAt = time(), itemRules = copy }
end

-- Characters with saved rule sets, other than this one.
function Rules.SnapshotSources()
	local out = {}
	local me = ns.State.playerName
	for key, snap in pairs(ns.global.itemRuleSnapshots) do
		if key ~= me and type(snap) == "table" and type(snap.itemRules) == "table" and #snap.itemRules > 0 then
			out[#out + 1] = key
		end
	end
	tsort(out)
	return out
end

function Rules.MergeFrom(sourceKey)
	local snap = ns.global.itemRuleSnapshots[sourceKey]
	local source = snap and snap.itemRules
	if not source then
		return
	end
	local rules = ns.db.itemRules
	local have = {}
	for i = 1, #rules do
		have[RuleKey(rules[i])] = true
	end
	local added, skipped = 0, 0
	local me = ns.State.playerName
	for i = 1, #source do
		local rule = source[i]
		-- A rule that targets this character would mail to itself.
		if rule.match ~= nil and rule.target and rule.target ~= "" and rule.target ~= me then
			local key = RuleKey(rule)
			if have[key] then
				skipped = skipped + 1
			else
				have[key] = true
				rules[#rules + 1] = CloneRule(rule)
				added = added + 1
			end
		else
			skipped = skipped + 1
		end
	end
	F.Print(L["Merged %d rule(s) from %s. Skipped %d."], added, sourceKey, skipped)
	Changed()
end

ns:OnInit(function()
	Items = ns:GetModule("Items")
	IndexRules()
end)
ns:On("PLAYER_READY", Rules.Snapshot)
