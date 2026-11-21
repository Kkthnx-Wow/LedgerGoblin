--[[
	LedgerGoblin - Constants
	-------------------------------------------------------------------------
	Lookup data and the saved-variable schema. Money is copper everywhere.
--]]

local _, ns = ...
local C, L = ns.C, ns.L

-- Brand. "Ledger" in goblin gold, "Goblin" in goblin green.
C.BrandHex = "fff4c430"
C.BrandRGB = { 0.957, 0.769, 0.188 }
C.GreenHex = "ff8fc02e"
C.GreenRGB = { 0.561, 0.753, 0.180 }
C.Title = "|c" .. C.BrandHex .. "Ledger|r|c" .. C.GreenHex .. "Goblin|r"
C.Icon = [[Interface\AddOns\LedgerGoblin\Media\Icon]] -- 64x64 TGA from the logo

C.QualityColors = _G["ITEM_QUALITY_COLORS"]

-- Mail limits. ATTACHMENTS_MAX_SEND is 12 and ATTACHMENTS_MAX_RECEIVE 16 in
-- both the Retail and Forever MailFrame.lua.
C.MAX_ATTACHMENTS = _G["ATTACHMENTS_MAX_SEND"] or 12
C.MAX_RECEIVE = _G["ATTACHMENTS_MAX_RECEIVE"] or 16
-- Postage per attachment (minimum one) used only to plan ahead. The sender
-- checks the real GetSendMailPrice() once a mail is staged.
C.POSTAGE_PER_ITEM = 30
C.COPPER_PER_GOLD = 10000
C.COPPER_PER_SILVER = 100

-- Enum.ItemBind values (14th return of GetItemInfo).
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

-- Account and warband binds can still go to same-account characters.
C.ACCOUNT_BOUND = {
	[C.BIND.TO_WOW_ACCOUNT] = true,
	[C.BIND.TO_BNET_ACCOUNT] = true,
	[C.BIND.TO_BNET_ACCOUNT_UNTIL_EQUIP] = true,
}

C.QUALITIES = {
	{ key = "poor", enum = 0, label = L["Poor"] },
	{ key = "common", enum = 1, label = L["Common"] },
	{ key = "uncommon", enum = 2, label = L["Uncommon"] },
	{ key = "rare", enum = 3, label = L["Rare"] },
	{ key = "epic", enum = 4, label = L["Epic"] },
}

C.QUALITY_BY_ENUM = {}
for i = 1, #C.QUALITIES do
	C.QUALITY_BY_ENUM[C.QUALITIES[i].enum] = C.QUALITIES[i].key
end

C.BINDS = {
	{ key = "boe", label = L["Bind on Equip"] },
	{ key = "boa", label = L["Account Bound (Warband)"] },
}

C.GOLD_MODE = {
	KEEP = "keep",
	FIXED = "fixed",
	PERCENT = "percent",
}

-- Item type routing. Trade goods are offered per subclass, the rest as a whole
-- class. Names come from C_Item.GetItemClassInfo / GetItemSubClassInfo at run
-- time, and an entry whose name the client can't resolve is not offered, so
-- Forever and Retail each show only the types they really have.
C.TRADEGOODS_CLASS = 7
C.TRADEGOODS_MAX_SUBCLASS = 24
C.WHOLE_CLASSES = { 3, 9, 8, 16, 17, 0 } -- gem, recipe, enhancement, glyph, battle pet, consumable

-- Key for a type rule. Subclass rules win over a whole-class rule.
function C.TypeKey(classID, subClassID)
	if subClassID then
		return "c" .. classID .. "s" .. subClassID
	end
	return "c" .. classID
end

-- Routing pipeline, first match wins. Exclusions are checked before it.
C.ROUTE_ORDER = { "item", "type", "boe", "boa", "quality" }

-- Inbox collect filters.
C.COLLECT = {
	ALL = "all",
	GOLD = "gold",
	AUCTION = "auction",
	ALTS = "alts",
	ITEMS = "items",
}

-- Income sources recorded by the ledger.
C.SOURCE = {
	SALE = "sale", -- auction sold
	REFUND = "refund", -- outbid or cancelled bid returned
	ALT = "alt", -- one of your own characters
	PLAYER = "player", -- anyone else
	OTHER = "other", -- system mail, unknown sender
}

C.SCHEMA = 2

C.CHAR_DEFAULTS = {
	schema = C.SCHEMA,
	autoRun = false, -- mail is irreversible, so off by default
	holdShiftToDisable = true,
	confirmGold = true,
	confirmThreshold = 1000, -- gold
	confirmItems = false,
	tooltipHints = true,
	altClickAttach = true, -- alt-click a bag item attaches every stack of it
	sendIndividually = false, -- one item type per mail instead of mixing

	gold = {
		enabled = false,
		target = "",
		mode = C.GOLD_MODE.KEEP,
		keepCopper = 1000 * C.COPPER_PER_GOLD,
		fixedCopper = 100 * C.COPPER_PER_GOLD,
		percent = 50,
		reserveForRepairs = true,
	},

	quality = {
		poor = { enabled = false, target = "" },
		common = { enabled = false, target = "" },
		uncommon = { enabled = false, target = "" },
		rare = { enabled = false, target = "" },
		epic = { enabled = false, target = "" },
	},

	bind = {
		boe = { enabled = false, target = "" },
		boa = { enabled = false, target = "" },
	},

	-- C.TypeKey -> { enabled, target }. Entries appear when the settings panel
	-- offers that type.
	typeRules = {},

	-- { match = itemID or name, target = "Name-Realm", enabled = bool }.
	-- A nil enabled counts as true.
	itemRules = {},

	exclusions = {}, -- itemID -> true
	keep = {}, -- itemID -> count to keep in bags

	inbox = {
		filter = C.COLLECT.ALL, -- what the Collect button takes
		autoCollect = false, -- collect when the mailbox opens
		freeSlots = 1, -- stop taking items with this many bag slots left
		messages = false, -- a chat line per collected sale, purchase or gift
		sound = false, -- a coin sound when collecting finishes
	},
}

C.GLOBAL_DEFAULTS = {
	schema = C.SCHEMA,

	-- "Name-Realm" -> { class, faction, gold, lastSeen }
	roster = {},

	-- "Name-Realm" -> highest repair bill seen at a vendor (copper)
	repairCost = {},

	-- Ring log, newest last: { time, from, target, copper, items, postage }
	log = {},
	logMax = 200,

	-- "YYYY-MM-DD" -> { [target] = { copper, items, postage } } for sends
	analytics = {},

	-- "YYYY-MM-DD" -> { [character] = { [source] = copper } } for inbox money
	income = {},

	-- Ring of auction trades seen in the inbox, newest last:
	-- { time, char, kind = "sale"|"bought", item, count, copper, who }
	trades = {},
	tradesMax = 500,

	-- "Name-Realm" -> { scanned, count, total, money, items, cod, expires,
	-- incoming, incomingAt }. Filled on each inbox scan and on each send to an
	-- own alt, so any character can see where mail is waiting or expiring.
	mailbox = {},

	-- Warn at login when mail on any character expires within this many days.
	-- 0 turns the warning off.
	expiryWarnDays = 3,

	-- "Name-Realm" -> { [itemID] = count } across bags, bank and reagent bank,
	-- refreshed as bags change. Restock rules read the target's entry.
	inventory = {},

	itemRuleSnapshots = {},
	manualAlts = {},
	recent = {}, -- "Name-Realm" -> last time mailed
	sendCount = 0,
	guideSeen = false, -- the guide opens once at the first login on the account
	minimap = { angle = 215, hide = false },
}
