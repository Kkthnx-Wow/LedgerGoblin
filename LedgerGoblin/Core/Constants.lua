--[[
	LedgerGoblin - Constants
	-------------------------------------------------------------------------
	Immutable lookup data: brand colour, quality + bind definitions, mail
	limits, the routing-category priority pipeline, and the default per-character
	/ account database shapes. Defaults live here so DB.lua has exactly one
	schema to merge against.

	Money is stored in copper everywhere (the game's native unit) so we never
	lose silver/copper precision; the UI parses/formats g/s/c around it.
--]]

local _, ns = ...
local C, L = ns.C, ns.L

-- Brand. Two-tone name: "Ledger" in goblin gold, "Goblin" in goblin-skin green
-- (sampled from the addon art). Hex strings are AARRGGBB (include alpha).
C.BrandHex = "fff4c430" -- goblin gold
C.BrandRGB = { 0.957, 0.769, 0.188 } -- goblin gold as RGB (0-1), for textures
C.GreenHex = "ff8fc02e" -- goblin green: the art's yellow-green hue, brightened so
C.GreenRGB = { 0.561, 0.753, 0.180 } -- it reads clearly green next to the gold
C.Title = "|c" .. C.BrandHex .. "Ledger|r|c" .. C.GreenHex .. "Goblin|r"
C.Icon = "Interface\\AddOns\\LedgerGoblin\\Media\\Icon"

-- Blizzard's per-quality colour table; reused so our UI matches the game.
C.QualityColors = _G["ITEM_QUALITY_COLORS"]

-- Mail engine limits (Blizzard constants, with literal fallbacks so a missing
-- global never nils out the math).
C.MAX_ATTACHMENTS = _G["ATTACHMENTS_MAX_SEND"] or 12
C.MAIL_POSTAGE = 30 -- copper per mail, flat
C.COPPER_PER_GOLD = 10000
C.COPPER_PER_SILVER = 100

-- Enum.ItemBind values (14th return of GetItemInfo). Hard-coded with the wiki
-- values so we don't depend on Enum being populated for items: 2 = Bind on
-- Equip; 7/8/9 = account/warband bound (mailable to your own alts even when the
-- bag reports them "bound"). 1 = Bind on Pickup (soulbound, never mailable).
C.BIND = {
	NONE = 0,
	ON_PICKUP = 1,
	ON_EQUIP = 2,
	ON_USE = 3,
	QUEST = 4,
	TO_WOW_ACCOUNT = 7,
	TO_BNET_ACCOUNT = 8,
	TO_BNET_ACCOUNT_UNTIL_EQUIP = 9,
}

-- Account-bound (warband / legacy BoA) bind types: still mailable to same-account
-- characters. Used both by the BoA category and by the mailability gate.
C.ACCOUNT_BOUND = {
	[C.BIND.TO_WOW_ACCOUNT] = true,
	[C.BIND.TO_BNET_ACCOUNT] = true,
	[C.BIND.TO_BNET_ACCOUNT_UNTIL_EQUIP] = true,
}

-- Item qualities we route by. Order is the priority we present them in the UI.
-- `key` matches the per-quality rule table; `enum` is the Blizzard quality int.
C.QUALITIES = {
	{ key = "poor", enum = 0, label = L["Poor"] },
	{ key = "common", enum = 1, label = L["Common"] },
	{ key = "uncommon", enum = 2, label = L["Uncommon"] },
	{ key = "rare", enum = 3, label = L["Rare"] },
	{ key = "epic", enum = 4, label = L["Epic"] },
}

-- enum -> quality key, for fast lookup during the bag scan.
C.QUALITY_BY_ENUM = {}
for i = 1, #C.QUALITIES do
	C.QUALITY_BY_ENUM[C.QUALITIES[i].enum] = C.QUALITIES[i].key
end

-- Bind-based routing categories. Same { enabled, target } shape as qualities,
-- but matched on the item's bind type. Listed in UI/priority order.
C.BINDS = {
	{ key = "boe", label = L["Bind on Equip"] },
	{ key = "boa", label = L["Account Bound (Warband)"] },
}

-- Gold routing modes.
C.GOLD_MODE = {
	KEEP = "keep", -- keep N copper on this char, send the remainder
	FIXED = "fixed", -- send exactly N copper
	PERCENT = "percent", -- send N% of current gold
}

-- ---------------------------------------------------------------------------
-- Routing category pipeline
--   The engine walks these in order and stops at the first that yields a target
--   for an item. This is the single source of truth for routing priority, so
--   adding a future category is a one-line change here + a classifier branch.
--     1. exclusions  (handled before the pipeline - never send)
--     2. item        specific itemID / name rules
--     3. boe         bind-on-equip gear
--     4. boa         account/warband-bound items
--     5. quality     catch-all by item quality
-- ---------------------------------------------------------------------------
C.ROUTE_ORDER = { "item", "boe", "boa", "quality" }

-- ---------------------------------------------------------------------------
-- Default databases
--   CHAR_DEFAULTS  -> LedgerGoblinCharDB  (this character's routing profile)
--   GLOBAL_DEFAULTS-> LedgerGoblinDB      (account-wide roster + history)
-- ---------------------------------------------------------------------------
C.CHAR_DEFAULTS = {
	autoRun = false, -- OFF by default: mail transfers are irreversible
	holdShiftToDisable = true, -- when autoRun is on, Shift skips a given open
	confirmThreshold = 1000, -- gold value above which a send asks for confirmation

	gold = {
		enabled = false,
		target = "", -- "Name-Realm"
		mode = C.GOLD_MODE.KEEP,
		keepCopper = 1000 * C.COPPER_PER_GOLD, -- keep this much (KEEP mode)
		fixedCopper = 100 * C.COPPER_PER_GOLD, -- send this much (FIXED mode)
		percent = 50, -- send this percent (PERCENT mode)
		reserveForRepairs = true, -- never spend below the learned repair cost
	},

	-- Per-quality routing. Each entry: { enabled, target }.
	quality = {
		poor = { enabled = false, target = "" },
		common = { enabled = false, target = "" },
		uncommon = { enabled = false, target = "" },
		rare = { enabled = false, target = "" },
		epic = { enabled = false, target = "" },
	},

	-- Bind-based routing. Each entry: { enabled, target }.
	bind = {
		boe = { enabled = false, target = "" },
		boa = { enabled = false, target = "" },
	},

	-- Specific-item rules, evaluated before category rules, in array order.
	-- Each: { match = itemID(number) or name(string), target = "Name-Realm",
	-- enabled = bool }. A nil `enabled` is treated as true (back-compat with
	-- rules saved before the toggle existed).
	itemRules = {},

	-- Items never to send, keyed by itemID. value = true.
	exclusions = {},

	-- "Keep at least N in bags" reserves, keyed by itemID. The engine sends the
	-- surplus above N (splitting a stack when needed) and leaves N behind. Only
	-- itemID-keyed; applies no matter which rule routes the item.
	keep = {},
}

C.GLOBAL_DEFAULTS = {
	-- Account roster cache. key = "Name-Realm", value = { class, faction, gold, lastSeen }.
	roster = {},

	-- Learned repair cost per character (copper). Captured at vendors so the
	-- repair reserve is real, not a flat guess. key = "Name-Realm".
	repairCost = {},

	-- Rolling transfer log (most recent last). Each: { time, target, copper, items }.
	log = {},
	logMax = 200,

	-- Per-day analytics. key = "YYYY-MM-DD", value = { [target] = { copper, items } }.
	analytics = {},
}
